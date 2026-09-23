using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using CodexSwitch.Core;

static class SocksLimiterChecks
{
    public static async Task Run()
    {
        await using var echo = await TinyServer.Echo();
        await using var upstream = await TinyServer.Socks("user", "secret");
        await using var via = await TinyServer.Socks(null, null);
        var logs = new ConcurrentQueue<string>();
        var config = new SocksLimiterConfig("127.0.0.1", 0, "127.0.0.1", via.Port, "127.0.0.1", upstream.Port, "user", "secret", 1, 1, 0, 0.7, 3);
        await using var limiter = new SocksLimiter(config, logs.Enqueue);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        var run = limiter.RunAsync(cts.Token);
        await limiter.Started.WaitAsync(cts.Token);

        var pong = await Socks.RoundTrip("127.0.0.1", limiter.BoundPort, "127.0.0.1", echo.Port, "ping", cts.Token);
        if (pong != "ping") throw new InvalidOperationException("往返结果是 " + pong);
        await WaitActive(limiter, 0, cts.Token);

        using var held = await Socks.Open("127.0.0.1", limiter.BoundPort, "127.0.0.1", echo.Port, cts.Token);
        await WaitActive(limiter, 1, cts.Token);
        var rep = await Socks.Reply("127.0.0.1", limiter.BoundPort, "127.0.0.1", echo.Port, cts.Token);
        if (rep != 6) throw new InvalidOperationException("排队超时应返回 TTL 6，实际 " + rep);
        var snapshot = string.Join(" | ", logs);
        if (!snapshot.Contains("WARNING queue timeout", StringComparison.Ordinal))
            throw new InvalidOperationException("限流日志里没有排队超时：" + snapshot);

        held.Dispose();
        cts.Cancel();
        try { await run.WaitAsync(TimeSpan.FromSeconds(2)); } catch (Exception ex) when (ex is OperationCanceledException or TimeoutException) { }
    }

    private static async Task WaitActive(SocksLimiter limiter, int expected, CancellationToken ct)
    {
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (limiter.Active != expected && DateTime.UtcNow < deadline)
            await Task.Delay(20, ct);
        if (limiter.Active != expected) throw new InvalidOperationException("活动连接数是 " + limiter.Active + "，期望 " + expected);
    }
}

static class Socks
{
    public static async Task<string> RoundTrip(string proxyHost, int proxyPort, string host, int port, string payload, CancellationToken ct)
    {
        using var tcp = await Open(proxyHost, proxyPort, host, port, ct);
        var stream = tcp.GetStream();
        var bytes = Encoding.ASCII.GetBytes(payload);
        await stream.WriteAsync(bytes, ct);
        var buf = new byte[bytes.Length];
        await Read(stream, buf, ct);
        return Encoding.ASCII.GetString(buf);
    }

    public static async Task<TcpClient> Open(string proxyHost, int proxyPort, string host, int port, CancellationToken ct)
    {
        var tcp = new TcpClient();
        await tcp.ConnectAsync(proxyHost, proxyPort, ct);
        var stream = tcp.GetStream();
        await stream.WriteAsync(new byte[] { 5, 1, 0 }, ct);
        var greet = new byte[2];
        await Read(stream, greet, ct);
        await stream.WriteAsync(Connect(host, port), ct);
        var reply = new byte[10];
        await Read(stream, reply, ct);
        if (reply[1] != 0)
        {
            tcp.Dispose();
            throw new InvalidOperationException("socks rep " + reply[1]);
        }
        return tcp;
    }

    public static async Task<int> Reply(string proxyHost, int proxyPort, string host, int port, CancellationToken ct)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(proxyHost, proxyPort, ct);
        var stream = tcp.GetStream();
        await stream.WriteAsync(new byte[] { 5, 1, 0 }, ct);
        await Read(stream, new byte[2], ct);
        await stream.WriteAsync(Connect(host, port), ct);
        var reply = new byte[10];
        await Read(stream, reply, ct);
        return reply[1];
    }

    private static byte[] Connect(string host, int port)
    {
        var ip = IPAddress.Parse(host).GetAddressBytes();
        var req = new byte[10];
        req[0] = 5;
        req[1] = 1;
        req[3] = 1;
        ip.CopyTo(req, 4);
        req[8] = (byte)(port >> 8);
        req[9] = (byte)port;
        return req;
    }

    private static async Task Read(NetworkStream stream, byte[] buf, CancellationToken ct)
    {
        var off = 0;
        while (off < buf.Length)
        {
            var read = stream.ReadAsync(buf.AsMemory(off, buf.Length - off)).AsTask();
            var done = await Task.WhenAny(read, Task.Delay(TimeSpan.FromSeconds(4), ct));
            if (done != read)
            {
                stream.Close();
                throw new TimeoutException("client read timed out");
            }
            var n = await read;
            if (n == 0) throw new EndOfStreamException("eof");
            off += n;
        }
    }
}

sealed class TinyServer : IAsyncDisposable
{
    private readonly TcpListener listener;
    private readonly CancellationTokenSource cts = new();
    private readonly List<Task> tasks = [];
    private readonly string? user;
    private readonly string? pass;
    private readonly bool echo;
    public int Port { get; }

    private TinyServer(bool echo, string? user, string? pass)
    {
        this.echo = echo;
        this.user = user;
        this.pass = pass;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    public static Task<TinyServer> Echo() => Start(true, null, null);
    public static Task<TinyServer> Socks(string? user, string? pass) => Start(false, user, pass);

    private static Task<TinyServer> Start(bool echo, string? user, string? pass)
    {
        var server = new TinyServer(echo, user, pass);
        server.tasks.Add(server.Accept());
        return Task.FromResult(server);
    }

    public async ValueTask DisposeAsync()
    {
        cts.Cancel();
        listener.Stop();
        try { await Task.WhenAll(tasks); } catch (Exception ex) when (ex is OperationCanceledException or IOException or SocketException or ObjectDisposedException) { }
    }

    private async Task Accept()
    {
        try
        {
            while (!cts.IsCancellationRequested)
            {
                var socket = await listener.AcceptSocketAsync(cts.Token);
                tasks.Add(Task.Run(() => Handle(socket), cts.Token));
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException or SocketException) { }
    }

    private async Task Handle(Socket socket)
    {
        using var stream = new NetworkStream(socket, ownsSocket: true);
        try
        {
            if (echo) await Echo(stream);
            else await Proxy(stream);
        }
        catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or EndOfStreamException or ObjectDisposedException) { }
    }

    private static async Task Echo(NetworkStream stream)
    {
        var buf = new byte[1024];
        var n = await stream.ReadAsync(buf);
        if (n > 0) await stream.WriteAsync(buf.AsMemory(0, n));
        while (await stream.ReadAsync(buf) > 0) { }
    }

    private async Task Proxy(NetworkStream stream)
    {
        var head = await Read(stream, 2);
        if (head[1] > 0) await Read(stream, head[1]);
        var requireAuth = !string.IsNullOrEmpty(user);
        await stream.WriteAsync(new byte[] { 5, (byte)(requireAuth ? 2 : 0) });
        if (requireAuth)
        {
            var ver = await Read(stream, 2);
            var name = await Read(stream, ver[1]);
            var plen = (await Read(stream, 1))[0];
            var password = await Read(stream, plen);
            var ok = Encoding.UTF8.GetString(name) == user && Encoding.UTF8.GetString(password) == pass;
            await stream.WriteAsync(new byte[] { 1, (byte)(ok ? 0 : 1) });
            if (!ok) return;
        }
        await Read(stream, 3);
        var (host, port) = await ReadAddr(stream);
        using var remote = new TcpClient();
        await remote.ConnectAsync(host, port);
        await stream.WriteAsync(new byte[] { 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
        var left = Pump(stream.Socket, remote.Client);
        var right = Pump(remote.Client, stream.Socket);
        await Task.WhenAll(left, right);
    }

    private static async Task Pump(Socket src, Socket dst)
    {
        var buf = new byte[8192];
        try
        {
            while (true)
            {
                var n = await src.ReceiveAsync(buf);
                if (n == 0) break;
                var sent = 0;
                while (sent < n)
                {
                    var wrote = await dst.SendAsync(buf.AsMemory(sent, n - sent));
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

    private static async Task<(string Host, int Port)> ReadAddr(NetworkStream stream)
    {
        var atyp = (await Read(stream, 1))[0];
        string host;
        if (atyp == 1) host = new IPAddress(await Read(stream, 4)).ToString();
        else if (atyp == 3) host = Encoding.ASCII.GetString(await Read(stream, (await Read(stream, 1))[0]));
        else if (atyp == 4) host = new IPAddress(await Read(stream, 16)).ToString();
        else throw new InvalidOperationException("bad atyp");
        var p = await Read(stream, 2);
        return (host, (p[0] << 8) | p[1]);
    }

    private static async Task<byte[]> Read(NetworkStream stream, int count)
    {
        var buf = new byte[count];
        var off = 0;
        while (off < count)
        {
            var n = await stream.ReadAsync(buf.AsMemory(off, count - off));
            if (n == 0) throw new EndOfStreamException();
            off += n;
        }
        return buf;
    }
}
