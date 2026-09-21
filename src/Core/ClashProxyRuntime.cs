using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;

namespace CodexSwitch.Core;

public sealed record ClashProxyStatus(bool Running, string Detail, int? MihomoPid, int? LimiterPid);

public interface IProcessHost
{
    int StartDetached(string fileName, IReadOnlyList<string> arguments, string workDirectory, string logPath);
    void Stop(int pid);
    bool IsRunning(int pid);
    bool IsListening(string host, int port);
}

public sealed class SystemProcessHost : IProcessHost
{
    public int StartDetached(string fileName, IReadOnlyList<string> arguments, string workDirectory, string logPath)
    {
        Directory.CreateDirectory(workDirectory);
        Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
        var info = new ProcessStartInfo(fileName)
        {
            WorkingDirectory = workDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        var process = new Process { StartInfo = info };
        process.Start();
        _ = Drain(process.StandardOutput.BaseStream, logPath);
        _ = Drain(process.StandardError.BaseStream, logPath);
        return process.Id;
    }

    public void Stop(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            if (!process.HasExited) process.Kill(true);
        }
        catch (ArgumentException) { }
        catch (InvalidOperationException) { }
    }

    public bool IsRunning(int pid)
    {
        try { using var process = Process.GetProcessById(pid); return !process.HasExited; }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    public bool IsListening(string host, int port)
    {
        try
        {
            using var client = new TcpClient();
            var task = client.ConnectAsync(host, port);
            return task.Wait(TimeSpan.FromMilliseconds(250)) && client.Connected;
        }
        catch { return false; }
    }

    private static async Task Drain(Stream source, string logPath)
    {
        try
        {
            using var output = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
            await source.CopyToAsync(output);
        }
        catch (IOException) { }
    }
}

public sealed class ClashProxyRuntime
{
    private readonly ClashProxyStore store;
    private readonly IProcessHost host;
    public bool RequireListen { get; init; } = true;

    public ClashProxyRuntime(ClashProxyStore store, IProcessHost? host = null)
    {
        this.store = store;
        this.host = host ?? new SystemProcessHost();
    }

    public ClashProxyStatus Status()
    {
        var settings = File.Exists(store.SettingsPath) ? store.Load() : new ClashProxySettings();
        var limiterPid = ReadPid(store.LimiterPidPath);
        var mihomoPid = ReadPid(store.MihomoPidPath);
        var limiterUp = limiterPid is int lp && host.IsRunning(lp);
        var mihomoUp = mihomoPid is int mp && host.IsRunning(mp);
        var httpUp = host.IsListening("127.0.0.1", settings.HttpPort);
        var limiterPort = ParsePort(settings.LimiterListen, 1994);
        var limiterListen = host.IsListening("127.0.0.1", limiterPort);
        if (limiterUp && mihomoUp && (!RequireListen || (httpUp && limiterListen)))
            return new(true, $"运行中  HTTP 127.0.0.1:{settings.HttpPort}  限流 :{limiterPort}", mihomoPid, limiterPid);
        if (mihomoUp || limiterUp)
            return new(false, "进程在，端口未就绪。查看 clash 目录下的日志。", mihomoPid, limiterPid);
        if (httpUp)
            return new(false, $"127.0.0.1:{settings.HttpPort} 已被占用。先停止现有 mihomo，或改端口。", null, null);
        return new(false, "未运行", null, null);
    }

    public ClashProxyStatus Start(ClashProxySettings settings)
    {
        store.Save(settings);
        store.Materialize(settings);
        var current = Status();
        if (current.Running) return current;

        Stop();
        var python = ResolvePython(settings.PythonPath);
        var mihomo = ResolveMihomo(settings.MihomoPath);
        var limiterPid = host.StartDetached(python, ["-u", store.LimiterPythonPath, "-c", store.LimiterJsonPath], store.WorkDirectory, store.LimiterLogPath);
        WritePid(store.LimiterPidPath, limiterPid);
        WaitListen("127.0.0.1", ParsePort(settings.LimiterListen, 1994), "本机限流器");
        var mihomoPid = host.StartDetached(mihomo, ["-f", store.YamlPath], store.WorkDirectory, store.MihomoLogPath);
        WritePid(store.MihomoPidPath, mihomoPid);
        WaitListen("127.0.0.1", settings.HttpPort, "mihomo");
        return Status();
    }

    public void Stop()
    {
        foreach (var path in new[] { store.MihomoPidPath, store.LimiterPidPath })
        {
            var pid = ReadPid(path);
            if (pid is int value) host.Stop(value);
            try { File.Delete(path); } catch (IOException) { }
        }
    }

    private void WaitListen(string hostName, int port, string label)
    {
        if (!RequireListen) return;
        var deadline = DateTime.UtcNow.AddSeconds(8);
        while (DateTime.UtcNow < deadline)
        {
            if (host.IsListening(hostName, port)) return;
            Thread.Sleep(120);
        }
        Stop();
        throw new InvalidOperationException($"{label} 未能监听 {hostName}:{port}。请确认 mihomo / python 已安装，并查看 {store.WorkDirectory} 日志。");
    }

    public static string ResolveMihomo(string? configured) => ResolveBinary(configured, OperatingSystem.IsWindows() ? ["mihomo.exe", "clash.exe"] : ["mihomo", "clash"]);
    public static string ResolvePython(string? configured) => ResolveBinary(configured, OperatingSystem.IsWindows() ? ["python.exe", "python3.exe"] : ["python3", "python"]);

    private static string ResolveBinary(string? configured, IReadOnlyList<string> names)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            var path = Environment.ExpandEnvironmentVariables(configured.Trim());
            if (File.Exists(path)) return path;
            throw new InvalidOperationException("找不到指定的可执行文件：" + path);
        }
        var folders = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator);
        foreach (var folder in folders)
        {
            if (string.IsNullOrWhiteSpace(folder) || !Directory.Exists(folder)) continue;
            foreach (var name in names)
            {
                var candidate = Path.Combine(folder, name);
                if (File.Exists(candidate)) return candidate;
            }
        }
        throw new InvalidOperationException("未在 PATH 中找到 " + names[0] + "。请安装后重试，或在配置里填写绝对路径。");
    }

    private static int? ReadPid(string path)
    {
        if (!File.Exists(path)) return null;
        return int.TryParse(File.ReadAllText(path).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid) ? pid : null;
    }

    private static void WritePid(string path, int pid) => File.WriteAllText(path, pid.ToString(CultureInfo.InvariantCulture));

    private static int ParsePort(string listen, int fallback)
    {
        var text = listen ?? "";
        var idx = text.LastIndexOf(':');
        if (idx < 0) return fallback;
        return int.TryParse(text[(idx + 1)..], out var parsed) ? parsed : fallback;
    }
}
