"""Local-only two-hop SOCKS fixture. Never contacts an external host."""
import asyncio
import json
import sys

HOME_PORT = None
OK = b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00'

async def destination(reader):
    version, command, _, kind = await reader.readexactly(4)
    assert version == 5 and command == 1
    if kind == 1:
        host = '.'.join(map(str, await reader.readexactly(4)))
    elif kind == 3:
        length = (await reader.readexactly(1))[0]
        host = (await reader.readexactly(length)).decode()
    else:
        raise ValueError('Unexpected address type')
    port = int.from_bytes(await reader.readexactly(2), 'big')
    return host, port

async def copy(reader, writer):
    try:
        while data := await reader.read(4096):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()

async def handle(reader, writer, home):
    try:
        version, count = await reader.readexactly(2)
        methods = await reader.readexactly(count)
        method = 2 if home else 0
        assert version == 5 and method in methods
        writer.write(bytes([5, method]))
        await writer.drain()
        if home:
            version, length = await reader.readexactly(2)
            user = await reader.readexactly(length)
            length = (await reader.readexactly(1))[0]
            password = await reader.readexactly(length)
            valid = version == 1 and user == b'test-user' and password == b'test-password'
            writer.write(bytes([1, 0 if valid else 1]))
            await writer.drain()
            if not valid:
                return
        host, port = await destination(reader)
        if home:
            assert host == 'www.gstatic.com' and port == 80
            writer.write(OK)
            await writer.drain()
            await reader.readuntil(b'\r\n\r\n')
            writer.write(b'HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n')
            await writer.drain()
        else:
            assert host == '127.0.0.1' and port == HOME_PORT
            other_reader, other_writer = await asyncio.open_connection('127.0.0.1', HOME_PORT)
            writer.write(OK)
            await writer.drain()
            await asyncio.gather(copy(reader, other_writer), copy(other_reader, writer))
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        writer.close()

async def web(reader, writer):
    """Serve fake GitHub responses through SOCKS without any external connections."""
    try:
        version, count = await reader.readexactly(2)
        methods = await reader.readexactly(count)
        assert version == 5 and 0 in methods
        writer.write(b'\x05\x00')
        await writer.drain()
        host, port = await destination(reader)
        assert host in ('github.com', 'github.githubassets.com') and port == 80
        writer.write(OK)
        await writer.drain()
        await reader.readuntil(b'\r\n\r\n')
        writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nmock github')
        await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        writer.close()

async def main():
    global HOME_PORT
    home = await asyncio.start_server(lambda r, w: handle(r, w, True), '127.0.0.1', 0)
    HOME_PORT = home.sockets[0].getsockname()[1]
    relay = await asyncio.start_server(lambda r, w: handle(r, w, False), '127.0.0.1', 0)
    github = await asyncio.start_server(web, '127.0.0.1', 0)
    with open(sys.argv[1], 'w') as output:
        json.dump({'home': HOME_PORT, 'relay': relay.sockets[0].getsockname()[1],
                   'web': github.sockets[0].getsockname()[1]}, output)
    async with home, relay, github:
        await asyncio.gather(home.serve_forever(), relay.serve_forever(), github.serve_forever())

asyncio.run(main())
