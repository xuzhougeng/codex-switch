#!/usr/bin/env python3
"""Queue and pace SOCKS5 dials to a US residential proxy.

Claude / mihomo talk to this local SOCKS5. Extra connections wait here
instead of bursting the home SOCKS5 (which then RST / connection refused).
Upstream is reached through mihomo's first hop (via).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import socket
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Optional, Tuple

log = logging.getLogger("socks-limiter")

SOCKS5_VERSION = 5
CMD_CONNECT = 1
ATYP_IPV4 = 1
ATYP_DOMAIN = 3
ATYP_IPV6 = 4
METHOD_NO_AUTH = 0
METHOD_USERPASS = 2
REP_OK = 0
REP_FAIL = 1
REP_UNREACHABLE = 4
REP_REFUSED = 5
REP_TTL = 6


@dataclass
class Config:
    listen: str
    via: str
    upstream: str
    username: str
    password: str
    max_concurrent: int = 8
    max_inflight_dials: int = 1
    dial_interval_ms: int = 250
    queue_wait_s: float = 8.0
    handshake_timeout_s: float = 20.0

    @property
    def listen_host_port(self) -> Tuple[str, int]:
        return _split_host_port(self.listen)

    @property
    def via_host_port(self) -> Tuple[str, int]:
        return _split_host_port(self.via)

    @property
    def upstream_host_port(self) -> Tuple[str, int]:
        return _split_host_port(self.upstream)


def _split_host_port(value: str) -> Tuple[str, int]:
    host, port_s = value.rsplit(":", 1)
    return host, int(port_s)


class DialLimiter:
    def __init__(
        self,
        max_concurrent: int,
        interval_s: float,
        queue_wait_s: float,
        max_inflight_dials: int = 1,
    ):
        self._sem = asyncio.Semaphore(max_concurrent)
        self._inflight = asyncio.Semaphore(max(1, max_inflight_dials))
        self._interval_s = interval_s
        self._queue_wait_s = queue_wait_s
        self._dial_lock = asyncio.Lock()
        self._last_dial = 0.0
        self.waiting = 0
        self.active = 0

    async def acquire(self, writer: Optional[asyncio.StreamWriter] = None) -> None:
        self.waiting += 1
        try:
            deadline = time.monotonic() + self._queue_wait_s
            while True:
                if writer is not None and writer.is_closing():
                    raise ConnectionError("client gone while queued")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"queue wait {self._queue_wait_s:.0f}s exceeded "
                        f"(active={self.active} waiting={self.waiting})"
                    )
                try:
                    await asyncio.wait_for(self._sem.acquire(), timeout=min(0.2, remaining))
                    break
                except asyncio.TimeoutError:
                    continue
        finally:
            self.waiting -= 1
        self.active += 1

    @asynccontextmanager
    async def pace_dial(self):
        async with self._inflight:
            async with self._dial_lock:
                now = time.monotonic()
                gap = self._last_dial + self._interval_s - now
                if gap > 0:
                    await asyncio.sleep(gap)
                self._last_dial = time.monotonic()
            yield

    def release(self) -> None:
        if self.active > 0:
            self.active -= 1
        self._sem.release()


def socks_reply(rep: int) -> bytes:
    return bytes([SOCKS5_VERSION, rep, 0, ATYP_IPV4, 0, 0, 0, 0, 0, 0])


def encode_addr(host: str, port: int) -> bytes:
    port_b = port.to_bytes(2, "big")
    try:
        packed = socket.inet_pton(socket.AF_INET, host)
        return bytes([ATYP_IPV4]) + packed + port_b
    except OSError:
        pass
    try:
        packed = socket.inet_pton(socket.AF_INET6, host)
        return bytes([ATYP_IPV6]) + packed + port_b
    except OSError:
        pass
    raw = host.encode("idna")
    if len(raw) > 255:
        raise ValueError(f"domain too long: {host}")
    return bytes([ATYP_DOMAIN, len(raw)]) + raw + port_b


async def read_socks_addr(reader: asyncio.StreamReader) -> Tuple[str, int]:
    atyp = (await reader.readexactly(1))[0]
    if atyp == ATYP_IPV4:
        host = socket.inet_ntop(socket.AF_INET, await reader.readexactly(4))
    elif atyp == ATYP_DOMAIN:
        n = (await reader.readexactly(1))[0]
        host = (await reader.readexactly(n)).decode("idna")
    elif atyp == ATYP_IPV6:
        host = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
    else:
        raise ValueError(f"bad atyp {atyp}")
    port = int.from_bytes(await reader.readexactly(2), "big")
    return host, port


async def socks5_handshake(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    username: Optional[str] = None,
    password: Optional[str] = None,
) -> None:
    if username:
        writer.write(bytes([SOCKS5_VERSION, 1, METHOD_USERPASS]))
    else:
        writer.write(bytes([SOCKS5_VERSION, 1, METHOD_NO_AUTH]))
    await writer.drain()
    ver, method = await reader.readexactly(2)
    if ver != SOCKS5_VERSION:
        raise ConnectionError(f"socks ver {ver}")
    if username:
        if method != METHOD_USERPASS:
            raise ConnectionError(f"upstream auth method {method}")
        u, p = username.encode(), password.encode()
        writer.write(bytes([1, len(u)]) + u + bytes([len(p)]) + p)
        await writer.drain()
        auth_ver, status = await reader.readexactly(2)
        if status != 0:
            raise ConnectionError("upstream socks auth failed")
    elif method != METHOD_NO_AUTH:
        raise ConnectionError(f"socks method {method}")


async def socks5_connect_cmd(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    host: str,
    port: int,
) -> None:
    writer.write(bytes([SOCKS5_VERSION, CMD_CONNECT, 0]) + encode_addr(host, port))
    await writer.drain()
    ver, rep, _rsv = await reader.readexactly(3)
    if ver != SOCKS5_VERSION:
        raise ConnectionError(f"socks cmd ver {ver}")
    await read_socks_addr(reader)
    if rep != REP_OK:
        raise ConnectionError(f"socks connect rep={rep} {host}:{port}")


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except (ConnectionError, asyncio.IncompleteReadError, OSError):
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def splice(
    a_r: asyncio.StreamReader,
    a_w: asyncio.StreamWriter,
    b_r: asyncio.StreamReader,
    b_w: asyncio.StreamWriter,
) -> None:
    try:
        await asyncio.gather(pipe(a_r, b_w), pipe(b_r, a_w))
    finally:
        for w in (a_w, b_w):
            try:
                w.close()
                await w.wait_closed()
            except Exception:
                pass


def _set_nodelay(writer: asyncio.StreamWriter) -> None:
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass


class Server:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.limiter = DialLimiter(
            cfg.max_concurrent,
            cfg.dial_interval_ms / 1000.0,
            cfg.queue_wait_s,
            cfg.max_inflight_dials,
        )

    async def handle(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer = writer.get_extra_info("peername")
        dest = "-"
        got_slot = False
        up_w: Optional[asyncio.StreamWriter] = None
        _set_nodelay(writer)
        try:
            ver, nmethods = await asyncio.wait_for(reader.readexactly(2), 10)
            if ver != SOCKS5_VERSION:
                return
            await reader.readexactly(nmethods)
            writer.write(bytes([SOCKS5_VERSION, METHOD_NO_AUTH]))
            await writer.drain()

            ver, cmd, _rsv = await reader.readexactly(3)
            dest_host, dest_port = await read_socks_addr(reader)
            dest = f"{dest_host}:{dest_port}"
            if ver != SOCKS5_VERSION or cmd != CMD_CONNECT:
                writer.write(socks_reply(REP_FAIL))
                await writer.drain()
                return

            log.info(
                "queue dest=%s peer=%s active=%s waiting=%s",
                dest,
                peer,
                self.limiter.active,
                self.limiter.waiting,
            )
            t0 = time.monotonic()
            await self.limiter.acquire(writer)
            got_slot = True
            queued = time.monotonic() - t0
            if queued > 0.05:
                log.info("dequeued dest=%s waited=%.2fs active=%s", dest, queued, self.limiter.active)

            async with self.limiter.pace_dial():
                up_r, up_w = await self._dial_upstream(dest_host, dest_port)
            writer.write(socks_reply(REP_OK))
            await writer.drain()
            log.info("spliced dest=%s active=%s", dest, self.limiter.active)
            await splice(reader, writer, up_r, up_w)
            up_w = None
        except TimeoutError as e:
            log.warning("queue timeout dest=%s %s", dest, e)
            try:
                writer.write(socks_reply(REP_TTL))
                await writer.drain()
            except Exception:
                pass
        except Exception as e:
            log.warning("fail dest=%s %s: %s", dest, type(e).__name__, e)
            try:
                writer.write(socks_reply(REP_FAIL))
                await writer.drain()
            except Exception:
                pass
        finally:
            if up_w is not None:
                try:
                    up_w.close()
                    await up_w.wait_closed()
                except Exception:
                    pass
            if got_slot:
                self.limiter.release()
                log.info("closed dest=%s active=%s waiting=%s", dest, self.limiter.active, self.limiter.waiting)
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    async def _dial_upstream(
        self, dest_host: str, dest_port: int
    ) -> Tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        via_host, via_port = self.cfg.via_host_port
        up_host, up_port = self.cfg.upstream_host_port
        timeout = self.cfg.handshake_timeout_s

        async def _open() -> Tuple[asyncio.StreamReader, asyncio.StreamWriter]:
            r, w = await asyncio.open_connection(via_host, via_port)
            _set_nodelay(w)
            await socks5_handshake(r, w)
            await socks5_connect_cmd(r, w, up_host, up_port)
            await socks5_handshake(r, w, self.cfg.username, self.cfg.password)
            await socks5_connect_cmd(r, w, dest_host, dest_port)
            return r, w

        return await asyncio.wait_for(_open(), timeout=timeout)


def load_config(path: str) -> Config:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return Config(
        listen=data["listen"],
        via=data["via"],
        upstream=data["upstream"],
        username=data["username"],
        password=data["password"],
        max_concurrent=int(data.get("max_concurrent", 8)),
        max_inflight_dials=int(data.get("max_inflight_dials", 1)),
        dial_interval_ms=int(data.get("dial_interval_ms", 250)),
        queue_wait_s=float(data.get("queue_wait_s", 8)),
        handshake_timeout_s=float(data.get("handshake_timeout_s", 20)),
    )


async def main_async(cfg: Config) -> None:
    server = Server(cfg)
    host, port = cfg.listen_host_port
    srv = await asyncio.start_server(server.handle, host, port)
    log.info(
        "listen %s via %s -> %s max=%s inflight=%s interval=%sms queue_wait=%ss",
        cfg.listen,
        cfg.via,
        cfg.upstream,
        cfg.max_concurrent,
        cfg.max_inflight_dials,
        cfg.dial_interval_ms,
        cfg.queue_wait_s,
    )
    stop = asyncio.Event()

    def _stop(*_args: object) -> None:
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _stop)
        except NotImplementedError:
            pass
    async with srv:
        await stop.wait()
        srv.close()
        await srv.wait_closed()


def main() -> None:
    for key in (
        "http_proxy",
        "https_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "all_proxy",
    ):
        os.environ.pop(key, None)
    parser = argparse.ArgumentParser(description="Local SOCKS5 dial limiter")
    parser.add_argument(
        "-c",
        "--config",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "socks-limiter.json"),
    )
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    cfg = load_config(args.config)
    asyncio.run(main_async(cfg))


if __name__ == "__main__":
    main()
