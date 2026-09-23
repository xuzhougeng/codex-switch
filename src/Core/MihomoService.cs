using System.Globalization;

namespace CodexSwitch.Core;

public sealed class MihomoService
{
    private readonly ClashProxyStore store;
    private readonly IProcessHost host;
    public bool RequireListen { get; init; } = true;
    public bool AllowLan { get; init; }
    public string? Executable { get; init; }

    public MihomoService(ClashProxyStore store, IProcessHost? host = null)
    {
        this.store = store;
        this.host = host ?? new SystemProcessHost();
    }

    public void Check(ClashProxySettings settings)
    {
        ValidatePorts(settings);
        DialerProxyBuilder.Build(ClashProxyStore.ToInput(settings, AllowLan));
    }

    public void Prepare(ClashProxySettings settings)
    {
        Check(settings);
        store.Save(settings);
        store.WriteRuntime(settings, AllowLan);
    }

    public ClashProxyStatus Start(ClashProxySettings settings)
    {
        if (Status().Running) return Status();
        Prepare(settings);
        Stop();
        var exe = string.IsNullOrWhiteSpace(Executable) ? Environment.ProcessPath : Executable;
        if (string.IsNullOrWhiteSpace(exe) || !File.Exists(exe))
            throw new InvalidOperationException("找不到当前程序，无法在后台启动 mihomo。");
        var pid = host.StartDetached(exe, ["serve", "--detach", "--home", store.Home], store.WorkDirectory, store.ServiceLogPath);
        WritePid(store.ServicePidPath, pid);
        if (RequireListen)
        {
            try
            {
                WaitListen(LimiterPort(settings), "本机限流", pid);
                WaitListen(settings.HttpPort, "mihomo", pid);
            }
            catch
            {
                Stop();
                throw;
            }
        }
        return Status();
    }

    public void Stop()
    {
        foreach (var path in new[] { store.ServicePidPath, store.MihomoPidPath, store.LimiterPidPath })
        {
            var pid = ReadPid(path);
            if (pid is int value) host.Stop(value);
            try { File.Delete(path); } catch (IOException) { }
        }
    }

    public ClashProxyStatus Status()
    {
        var settings = File.Exists(store.SettingsPath) ? store.Load() : new ClashProxySettings();
        var servicePid = ReadPid(store.ServicePidPath);
        var mihomoPid = ReadPid(store.MihomoPidPath);
        var serviceUp = servicePid is int sp && host.IsRunning(sp);
        var mihomoUp = mihomoPid is int mp && host.IsRunning(mp);
        var httpUp = host.IsListening("127.0.0.1", settings.HttpPort);
        var limiterPort = LimiterPort(settings);
        var limiterUp = host.IsListening("127.0.0.1", limiterPort);
        var state = ReadState();
        var stateText = state is null ? "" : $"  活动 {state.Value.Active}  等待 {state.Value.Waiting}";
        if (serviceUp && (!RequireListen || (httpUp && limiterUp)))
            return new(true, $"运行中  HTTP 127.0.0.1:{settings.HttpPort}  限流 127.0.0.1:{limiterPort}  一跳 :{settings.SocksPort}{stateText}", mihomoPid, servicePid);
        if (serviceUp || mihomoUp)
            return new(false, "进程在，端口未就绪。查看 " + store.WorkDirectory + " 里的日志。" + stateText, mihomoPid, servicePid);
        if (httpUp)
            return new(false, $"127.0.0.1:{settings.HttpPort} 已被占用。先停止现有 mihomo，或改端口。", null, null);
        return new(false, "未运行", null, null);
    }

    public static int LimiterPort(ClashProxySettings settings)
    {
        var text = settings.LimiterListen ?? "";
        var idx = text.LastIndexOf(':');
        if (idx < 0 || !int.TryParse(text[(idx + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var port)) return 1994;
        return port;
    }

    private void WaitListen(int port, string label, int servicePid)
    {
        var deadline = DateTime.UtcNow.AddSeconds(label == "mihomo" ? 15 : 8);
        while (DateTime.UtcNow < deadline)
        {
            if (host.IsListening("127.0.0.1", port)) return;
            if (!host.IsRunning(servicePid))
                throw new InvalidOperationException($"{label} 已退出。\n{Tail(store.ServiceLogPath)}\n{Tail(store.MihomoLogPath)}\n{Tail(store.LimiterLogPath)}");
            Thread.Sleep(120);
        }
        throw new InvalidOperationException($"{label} 未能监听 127.0.0.1:{port}。\n{Tail(store.ServiceLogPath)}\n{Tail(store.MihomoLogPath)}\n{Tail(store.LimiterLogPath)}");
    }

    private (int Active, int Waiting)? ReadState()
    {
        try
        {
            if (!File.Exists(store.LimiterStatePath)) return null;
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(store.LimiterStatePath));
            var root = doc.RootElement;
            return (root.GetProperty("active").GetInt32(), root.GetProperty("waiting").GetInt32());
        }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    private static void ValidatePorts(ClashProxySettings settings)
    {
        static void Port(int value, string label)
        {
            if (value is < 1 or > 65535) throw new InvalidOperationException(label + " 端口需要在 1 到 65535 之间。");
        }
        Port(settings.HttpPort, "HTTP");
        Port(settings.SocksPort, "SOCKS");
        var limiter = Split(settings.LimiterListen, "限流监听");
        var controller = Split(settings.Controller, "外部控制");
        var ports = new[] { settings.HttpPort, settings.SocksPort, limiter, controller };
        if (ports.Distinct().Count() != ports.Length)
            throw new InvalidOperationException("HTTP、一跳 SOCKS、限流和外部控制端口需要彼此不同。");
        if (settings.MaxConcurrent < 1) throw new InvalidOperationException("同时连接数至少为 1。");
        if (settings.DialIntervalMs < 0) throw new InvalidOperationException("新建间隔不能为负数。");
        if (settings.QueueWaitS is < 1 or > 30) throw new InvalidOperationException("排队等待需要在 1 到 30 秒之间。");
    }

    private static int Split(string value, string label)
    {
        var text = (value ?? "").Trim();
        var idx = text.LastIndexOf(':');
        if (idx <= 0 || !int.TryParse(text[(idx + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535)
            throw new InvalidOperationException(label + " 需要写成 host:port。");
        return port;
    }

    private static string Tail(string path)
    {
        try
        {
            if (!File.Exists(path)) return "";
            var lines = File.ReadAllLines(path);
            return string.Join('\n', lines.TakeLast(8));
        }
        catch (IOException) { return ""; }
    }

    private static int? ReadPid(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return int.TryParse(File.ReadAllText(path).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid) ? pid : null;
        }
        catch (IOException) { return null; }
    }

    private static void WritePid(string path, int pid)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, pid.ToString(CultureInfo.InvariantCulture));
    }
}
