using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace CodexSwitch.Core;

public sealed record SocksLimiterConfig(
    string ListenHost,
    int ListenPort,
    string ViaHost,
    int ViaPort,
    string UpstreamHost,
    int UpstreamPort,
    string Username,
    string Password,
    int MaxConcurrent = 8,
    int MaxInflightDials = 1,
    int DialIntervalMs = 250,
    double QueueWaitSeconds = 8,
    double HandshakeTimeoutSeconds = 20)
{
    public static SocksLimiterConfig Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var listen = Split(Required(root, "listen"));
        var via = Split(Required(root, "via"));
        var upstream = Split(Required(root, "upstream"));
        return new SocksLimiterConfig(
            listen.Host, listen.Port,
            via.Host, via.Port,
            upstream.Host, upstream.Port,
            Text(root, "username"),
            Text(root, "password"),
            Math.Max(1, (int)Num(root, "max_concurrent", 8)),
            Math.Max(1, (int)Num(root, "max_inflight_dials", 1)),
            Math.Max(0, (int)Num(root, "dial_interval_ms", 250)),
            Num(root, "queue_wait_s", 8),
            Num(root, "handshake_timeout_s", 20));
    }

    private static string Required(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : throw new InvalidOperationException("限流配置缺少 " + name);

    private static string Text(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";

    private static double Num(JsonElement root, string name, double fallback) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble()
            : fallback;

    private static (string Host, int Port) Split(string value)
    {
        var text = (value ?? "").Trim();
        var idx = text.LastIndexOf(':');
        if (idx <= 0 || !int.TryParse(text[(idx + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535)
            throw new InvalidOperationException("地址需要 host:port：" + value);
        var host = text[..idx];
        if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
        return (host, port);
    }
}

/// <summary>
/// Local SOCKS5 that paces dials to a residential proxy.
/// mihomo sends AI destinations here. Each dial goes out through mihomo's first-hop SOCKS, then the residential SOCKS.
/// </summary>
public sealed class SocksLimiter : IAsyncDisposable
{
    private const byte Ver = 5;
    private const byte CmdConnect = 1;
    private const byte AtypV4 = 1;
    private const byte AtypDomain = 3;
    private const byte AtypV6 = 4;
    private const byte MethodNone = 0;
    private const byte MethodUser = 2;
    private const byte RepOk = 0;
    private const byte RepFail = 1;
    private const byte RepTtl = 6;

    private readonly SocksLimiterConfig config;
    private readonly Action<string>? log;
    private readonly Action<int, int>? onState;
    private readonly SemaphoreSlim slots;
    private readonly SemaphoreSlim inflight;
    private readonly SemaphoreSlim dialLock = new(1, 1);
    private readonly CancellationTokenSource shutdown = new();
    private readonly TaskCompletionSource started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object socketGate = new();
    private readonly List<Socket> sockets = [];
    private readonly IdnMapping idn = new();
    private long lastDial;
    private int active;
    private int waiting;
    private Task? run;

    public SocksLimiter(SocksLimiterConfig config, Action<string>? log = null, Action<int, int>? onState = null)
    {
        this.config = config;
        this.log = log;
        this.onState = onState;
        slots = new SemaphoreSlim(Math.Max(1, config.MaxConcurrent), Math.Max(1, config.MaxConcurrent));
        inflight = new SemaphoreSlim(Math.Max(1, config.MaxInflightDials), Math.Max(1, config.MaxInflightDials));
    }

    public int Active => Volatile.Read(ref active);
    public int Waiting => Volatile.Read(ref waiting);
    public int BoundPort { get; private set; }
    public Task Started => started.Task;

    public Task RunAsync(CancellationToken cancellationToken)
    {
        if (run != null) throw new InvalidOperationException("限流器已经在运行。");
        run = RunCore(cancellationToken);
        return run;
    }

    public async ValueTask DisposeAsync()
    {
        shutdown.Cancel();
        Socket[] open;
        lock (socketGate) open = sockets.ToArray();
        foreach (var socket in open)
        {
            try { socket.Close(); } catch (ObjectDisposedException) { }
        }
        if (run != null)
        {
            try { await run.WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (TimeoutException) { }
            catch (OperationCanceledException) { }
        }
    }

    private async Task RunCore(CancellationToken outer)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(outer, shutdown.Token);
        var ct = linked.Token;
        var listener = new TcpListener(IPAddress.Parse(config.ListenHost), config.ListenPort);
        using var stopAccept = shutdown.Token.Register(() =>
        {
            try { listener.Stop(); } catch (SocketException) { }
        });
        try
        {
            listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            listener.Start();
            BoundPort = ((IPEndPoint)listener.LocalEndpoint).Port;
            started.TrySetResult();
            log?.Invoke($"INFO listen {config.ListenHost}:{BoundPort} via {config.ViaHost}:{config.ViaPort} -> {config.UpstreamHost}:{config.UpstreamPort} max={config.MaxConcurrent} interval={config.DialIntervalMs}ms");
            while (!ct.IsCancellationRequested)
            {
                Socket socket;
                try { socket = await listener.AcceptSocketAsync(ct); }
                catch (OperationCanceledException) { break; }
                catch (ObjectDisposedException) { break; }
                catch (SocketException) when (ct.IsCancellationRequested) { break; }
                Track(socket);
                _ = Task.Run(() => Handle(socket, ct), CancellationToken.None);
            }
        }
        catch (Exception ex)
        {
            started.TrySetException(ex);
            throw;
        }
        finally
        {
            try { listener.Stop(); } catch (SocketException) { }
        }
    }

    private async Task Handle(Socket socket, CancellationToken ct)
    {
        var dest = "-";
        var gotSlot = false;
        NetworkStream? clientStream = null;
        NetworkStream? upstreamStream = null;
        var replied = false;
        try
        {
            socket.NoDelay = true;
            clientStream = new NetworkStream(socket, ownsSocket: false);
            using var greetCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            greetCts.CancelAfter(TimeSpan.FromSeconds(10));
            var head = await ReadExact(clientStream, 2, greetCts.Token);
            if (head[0] != Ver) return;
            if (head[1] > 0) await ReadExact(clientStream, head[1], greetCts.Token);
            await clientStream.WriteAsync(new byte[] { Ver, MethodNone }, greetCts.Token);

            var cmd = await ReadExact(clientStream, 3, greetCts.Token);
            var target = await ReadAddr(clientStream, greetCts.Token);
            dest = target.Host + ":" + target.Port.ToString(CultureInfo.InvariantCulture);
            if (cmd[0] != Ver || cmd[1] != CmdConnect)
            {
                await Reply(clientStream, RepFail, ct);
                replied = true;
                return;
            }

            log?.Invoke($"INFO queue dest={dest} peer={Peer(socket)} active={Active} waiting={Waiting}");
            var queuedAt = DateTime.UtcNow;
            await Acquire(socket, ct);
            gotSlot = true;
            var waited = (DateTime.UtcNow - queuedAt).TotalSeconds;
            if (waited > 0.05)
                log?.Invoke($"INFO dequeued dest={dest} waited={waited.ToString("0.00", CultureInfo.InvariantCulture)}s active={Active}");

            upstreamStream = await Dial(target.Host, target.Port, ct);
            await Reply(clientStream, RepOk, ct);
            replied = true;
            log?.Invoke($"INFO spliced dest={dest} active={Active}");
            await Splice(socket, upstreamStream.Socket, ct);
        }
        catch (TimeoutException ex)
        {
            log?.Invoke($"WARNING queue timeout dest={dest} {ex.Message}");
            if (!replied && clientStream != null) await TryReply(clientStream, RepTtl);
        }
        catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or InvalidOperationException or EndOfStreamException)
        {
            if (dest != "-" && !ct.IsCancellationRequested && !shutdown.IsCancellationRequested)
                log?.Invoke($"WARNING fail dest={dest} {ex.GetType().Name}: {ex.Message}");
            if (!replied && clientStream != null) await TryReply(clientStream, RepFail);
        }
        finally
        {
            if (upstreamStream != null)
            {
                Socket? upstream = null;
                try { upstream = upstreamStream.Socket; } catch (ObjectDisposedException) { }
                try { upstreamStream.Close(); } catch (ObjectDisposedException) { }
                if (upstream != null) Close(upstream);
            }
            Close(socket);
            if (gotSlot) Release();
            if (gotSlot) log?.Invoke($"INFO closed dest={dest} active={Active} waiting={Waiting}");
        }
    }

    private async Task Acquire(Socket client, CancellationToken ct)
    {
        Interlocked.Increment(ref waiting);
        Changed();
        try
        {
            var deadline = DateTime.UtcNow.AddSeconds(config.QueueWaitSeconds);
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                if (IsClosed(client)) throw new IOException("client gone while queued");
                var remaining = deadline - DateTime.UtcNow;
                if (remaining <= TimeSpan.Zero)
                    throw new TimeoutException($"queue wait {config.QueueWaitSeconds.ToString("0", CultureInfo.InvariantCulture)}s exceeded (active={Active} waiting={Waiting})");
                var slice = TimeSpan.FromMilliseconds(Math.Min(200, Math.Max(1, remaining.TotalMilliseconds)));
                if (await slots.WaitAsync(slice, ct)) break;
            }
        }
        finally
        {
            Interlocked.Decrement(ref waiting);
            Changed();
        }
        Interlocked.Increment(ref active);
        Changed();
    }

    private void Release()
    {
        if (Interlocked.Decrement(ref active) < 0) Interlocked.Exchange(ref active, 0);
        try { slots.Release(); } catch (SemaphoreFullException) { }
        Changed();
    }

    private async Task<NetworkStream> Dial(string destHost, int destPort, CancellationToken ct)
    {
        await inflight.WaitAsync(ct);
        try
        {
            await dialLock.WaitAsync(ct);
            try
            {
                var now = StopwatchTimestamp();
                var elapsed = (now - Interlocked.Read(ref lastDial)) / (double)System.Diagnostics.Stopwatch.Frequency;
                var gap = config.DialIntervalMs / 1000.0 - elapsed;
                if (gap > 0 && lastDial != 0) await Task.Delay(TimeSpan.FromSeconds(gap), ct);
                Interlocked.Exchange(ref lastDial, StopwatchTimestamp());
            }
            finally { dialLock.Release(); }

            using var dialCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            dialCts.CancelAfter(TimeSpan.FromSeconds(Math.Max(1, config.HandshakeTimeoutSeconds)));
            var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            Track(socket);
            try
            {
                await socket.ConnectAsync(config.ViaHost, config.ViaPort, dialCts.Token);
                var stream = new NetworkStream(socket, ownsSocket: true);
                await Handshake(stream, null, null, dialCts.Token);
                await ConnectCommand(stream, config.UpstreamHost, config.UpstreamPort, dialCts.Token);
                await Handshake(stream, config.Username, config.Password, dialCts.Token);
                await ConnectCommand(stream, destHost, destPort, dialCts.Token);
                return stream;
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                Close(socket);
                throw new TimeoutException($"dial timeout {destHost}:{destPort}");
            }
            catch
            {
                Close(socket);
                throw;
            }
        }
        finally { inflight.Release(); }
    }

    private async Task Handshake(NetworkStream stream, string? username, string? password, CancellationToken ct)
    {
        var user = username ?? "";
        if (user.Length > 0)
        {
            await stream.WriteAsync(new byte[] { Ver, 1, MethodUser }, ct);
            var chosen = await ReadExact(stream, 2, ct);
            if (chosen[1] != MethodUser) throw new IOException("upstream auth method " + chosen[1]);
            var u = Encoding.UTF8.GetBytes(user);
            var p = Encoding.UTF8.GetBytes(password ?? "");
            if (u.Length > 255 || p.Length > 255) throw new InvalidOperationException("SOCKS 用户名或密码过长。");
            var auth = new byte[3 + u.Length + p.Length];
            auth[0] = 1;
            auth[1] = (byte)u.Length;
            u.CopyTo(auth, 2);
            auth[2 + u.Length] = (byte)p.Length;
            p.CopyTo(auth, 3 + u.Length);
            await stream.WriteAsync(auth, ct);
            var result = await ReadExact(stream, 2, ct);
            if (result[1] != 0) throw new IOException("upstream socks auth failed");
        }
        else
        {
            await stream.WriteAsync(new byte[] { Ver, 1, MethodNone }, ct);
            var chosen = await ReadExact(stream, 2, ct);
            if (chosen[0] != Ver || chosen[1] != MethodNone) throw new IOException("socks method " + chosen[1]);
        }
    }

    private async Task ConnectCommand(NetworkStream stream, string host, int port, CancellationToken ct)
    {
        var req = new byte[3 + EncodedAddrLength(host)];
        req[0] = Ver;
        req[1] = CmdConnect;
        EncodeAddr(host, port).CopyTo(req, 3);
        await stream.WriteAsync(req, ct);
        var hdr = await ReadExact(stream, 3, ct);
        await ReadAddr(stream, ct);
        if (hdr[0] != Ver || hdr[1] != RepOk) throw new IOException($"socks connect rep={hdr[1]} {host}:{port}");
    }

    private static async Task Splice(Socket left, Socket right, CancellationToken ct)
    {
        var a = Pipe(left, right, ct);
        var b = Pipe(right, left, ct);
        await Task.WhenAll(a, b);
    }

    private static async Task Pipe(Socket src, Socket dst, CancellationToken ct)
    {
        var buf = new byte[65536];
        try
        {
            while (true)
            {
                var n = await src.ReceiveAsync(buf, SocketFlags.None, ct);
                if (n == 0) break;
                var sent = 0;
                while (sent < n)
                {
                    var wrote = await dst.SendAsync(buf.AsMemory(sent, n - sent), SocketFlags.None, ct);
                    if (wrote == 0) return;
                    sent += wrote;
                }
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException or OperationCanceledException) { }
        finally
        {
            try { dst.Shutdown(SocketShutdown.Send); } catch (Exception ex) when (ex is ObjectDisposedException or SocketException) { }
        }
    }

    private static async Task Reply(NetworkStream stream, byte rep, CancellationToken ct)
    {
        var buf = new byte[] { Ver, rep, 0, AtypV4, 0, 0, 0, 0, 0, 0 };
        await stream.WriteAsync(buf, ct);
        await stream.FlushAsync(ct);
    }

    private static async Task TryReply(NetworkStream stream, byte rep)
    {
        try { await Reply(stream, rep, CancellationToken.None); } catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException) { }
    }

    private byte[] EncodeAddr(string host, int port)
    {
        Span<byte> portBytes = stackalloc byte[2];
        portBytes[0] = (byte)(port >> 8);
        portBytes[1] = (byte)port;
        if (TryIpv4(host, out var v4)) return Concat(new byte[] { AtypV4 }, v4, portBytes);
        if (IPAddress.TryParse(host, out var ip) && ip.AddressFamily == AddressFamily.InterNetworkV6 && host.Contains(':'))
            return Concat(new byte[] { AtypV6 }, ip.GetAddressBytes(), portBytes);
        var ascii = idn.GetAscii(host);
        if (ascii.Length is 0 or > 255) throw new InvalidOperationException("域名过长：" + host);
        return Concat(new byte[] { AtypDomain, (byte)ascii.Length }, Encoding.ASCII.GetBytes(ascii), portBytes);
    }

    private int EncodedAddrLength(string host)
    {
        if (TryIpv4(host, out _)) return 1 + 4 + 2;
        if (IPAddress.TryParse(host, out var ip) && ip.AddressFamily == AddressFamily.InterNetworkV6 && host.Contains(':')) return 1 + 16 + 2;
        return 1 + 1 + idn.GetAscii(host).Length + 2;
    }

    private async Task<(string Host, int Port)> ReadAddr(NetworkStream stream, CancellationToken ct)
    {
        var atyp = (await ReadExact(stream, 1, ct))[0];
        string host;
        if (atyp == AtypV4) host = new IPAddress(await ReadExact(stream, 4, ct)).ToString();
        else if (atyp == AtypDomain)
        {
            var n = (await ReadExact(stream, 1, ct))[0];
            host = idn.GetUnicode(Encoding.ASCII.GetString(await ReadExact(stream, n, ct)));
        }
        else if (atyp == AtypV6) host = new IPAddress(await ReadExact(stream, 16, ct)).ToString();
        else throw new InvalidOperationException("bad atyp " + atyp);
        var p = await ReadExact(stream, 2, ct);
        return (host, (p[0] << 8) | p[1]);
    }

    private static bool TryIpv4(string host, out byte[] bytes)
    {
        bytes = [];
        var parts = host.Split('.');
        if (parts.Length != 4) return false;
        bytes = new byte[4];
        for (var i = 0; i < 4; i++)
        {
            if (!byte.TryParse(parts[i], NumberStyles.Integer, CultureInfo.InvariantCulture, out bytes[i])) return false;
        }
        return true;
    }

    private static byte[] Concat(byte[] head, byte[] mid, ReadOnlySpan<byte> tail)
    {
        var buf = new byte[head.Length + mid.Length + tail.Length];
        head.CopyTo(buf, 0);
        mid.CopyTo(buf, head.Length);
        tail.CopyTo(buf.AsSpan(head.Length + mid.Length));
        return buf;
    }

    private static async Task<byte[]> ReadExact(NetworkStream stream, int count, CancellationToken ct)
    {
        var buf = new byte[count];
        var off = 0;
        while (off < count)
        {
            var n = await stream.ReadAsync(buf.AsMemory(off, count - off), ct);
            if (n == 0) throw new EndOfStreamException("连接提前关闭");
            off += n;
        }
        return buf;
    }

    private static bool IsClosed(Socket socket)
    {
        try { return socket.Poll(0, SelectMode.SelectRead) && socket.Available == 0; }
        catch (ObjectDisposedException) { return true; }
        catch (SocketException) { return true; }
    }

    private static string Peer(Socket socket)
    {
        try { return socket.RemoteEndPoint?.ToString() ?? "-"; }
        catch (ObjectDisposedException) { return "-"; }
    }

    private static long StopwatchTimestamp() => System.Diagnostics.Stopwatch.GetTimestamp();

    private void Changed()
    {
        try { onState?.Invoke(Active, Waiting); } catch (Exception ex) when (ex is IOException or ObjectDisposedException) { }
    }

    private void Track(Socket socket)
    {
        lock (socketGate) sockets.Add(socket);
    }

    private void Close(Socket socket)
    {
        lock (socketGate) sockets.Remove(socket);
        try { socket.Close(); } catch (ObjectDisposedException) { }
    }
}
