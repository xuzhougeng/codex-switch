using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using CodexSwitch.Core;

namespace CodexSwitch.Linux;

static class MihomoDaemon
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (!OperatingSystem.IsLinux())
        {
            Console.Error.WriteLine("serve 只在 Linux 上运行。");
            return 1;
        }
        var detach = args.Contains("--detach");
        if (detach && setsid() < 0)
            Console.Error.WriteLine("setsid 失败，服务仍留在当前会话。");
        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
        using var term = PosixSignalRegistration.Create(PosixSignal.SIGTERM, _ => cts.Cancel());
        using var sigint = PosixSignalRegistration.Create(PosixSignal.SIGINT, _ => cts.Cancel());
        using var hup = detach ? PosixSignalRegistration.Create(PosixSignal.SIGHUP, ctx => ctx.Cancel = true) : null;
        var home = Option(args, "--home");
        var store = string.IsNullOrWhiteSpace(home) ? ClashProxyStore.CreateLinux() : new ClashProxyStore(home);
        var settings = store.Load();
        var service = new MihomoService(store) { AllowLan = false };
        try
        {
            service.Prepare(settings);
            WritePid(store.ServicePidPath, Environment.ProcessId);
            var json = await File.ReadAllTextAsync(store.LimiterJsonPath);
            var config = SocksLimiterConfig.Parse(json);
            await using var limiter = new SocksLimiter(config, line => Log(store.LimiterLogPath, line), (active, waiting) => WriteState(store.LimiterStatePath, active, waiting));
            var run = limiter.RunAsync(cts.Token);
            await WaitBound(limiter, run, cts.Token);
            var kernel = MihomoKernel.Resolve(settings.MihomoPath);
            MihomoKernel.EnsureExecutable(kernel);
            var test = await RunMihomo(kernel, store, ["-f", store.YamlPath, "-t"], cts.Token);
            if (test.Code != 0)
            {
                Log(store.ServiceLogPath, "ERROR mihomo -t\n" + test.Text);
                return 1;
            }
            var mihomo = StartMihomo(kernel, store);
            WritePid(store.MihomoPidPath, mihomo.Id);
            Log(store.ServiceLogPath, $"INFO mihomo pid {mihomo.Id} http {settings.HttpPort} kernel {kernel}");
            try
            {
                var exit = WaitExit(mihomo, cts.Token);
                var done = await Task.WhenAny(run, exit);
                if (done == exit && !cts.IsCancellationRequested && mihomo.HasExited)
                {
                    Log(store.ServiceLogPath, "ERROR mihomo 退出 " + mihomo.ExitCode.ToString(CultureInfo.InvariantCulture));
                    return 1;
                }
                if (run.IsFaulted)
                {
                    Log(store.ServiceLogPath, "ERROR limiter " + run.Exception?.GetBaseException().Message);
                    return 1;
                }
                return 0;
            }
            finally
            {
                cts.Cancel();
                try { if (!mihomo.HasExited) mihomo.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                try { await run.WaitAsync(TimeSpan.FromSeconds(2)); } catch (Exception) { }
                mihomo.Dispose();
                DeleteOwn(store.MihomoPidPath);
            }
        }
        catch (Exception ex)
        {
            Log(store.ServiceLogPath, "ERROR " + ex.Message);
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
        finally
        {
            DeleteOwn(store.ServicePidPath);
        }
    }

    private static async Task WaitBound(SocksLimiter limiter, Task run, CancellationToken ct)
    {
        var finished = await Task.WhenAny(limiter.Started, run);
        if (finished == run)
        {
            await run;
            throw new InvalidOperationException("本机限流没有监听成功。");
        }
        await limiter.Started.WaitAsync(ct);
    }

    private static Process StartMihomo(string kernel, ClashProxyStore store)
    {
        var proc = Build(kernel, store, "-f", store.YamlPath);
        proc.EnableRaisingEvents = true;
        proc.Start();
        _ = Drain(proc.StandardOutput.BaseStream, store.MihomoLogPath);
        _ = Drain(proc.StandardError.BaseStream, store.MihomoLogPath);
        return proc;
    }

    private static async Task<(int Code, string Text)> RunMihomo(string kernel, ClashProxyStore store, IReadOnlyList<string> args, CancellationToken ct)
    {
        var proc = Build(kernel, store, args.ToArray());
        proc.Start();
        var stdout = proc.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var stderr = proc.StandardError.ReadToEndAsync(CancellationToken.None);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try { await proc.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            try { if (!proc.HasExited) proc.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw new InvalidOperationException("mihomo -t 超时。");
        }
        var text = ((await stdout) + (await stderr)).Trim();
        return (proc.ExitCode, text);
    }

    private static Process Build(string kernel, ClashProxyStore store, params string[] args)
    {
        var info = new ProcessStartInfo(kernel)
        {
            WorkingDirectory = store.WorkDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        foreach (var key in new[] { "http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY" })
            info.Environment.Remove(key);
        return new Process { StartInfo = info };
    }

    private static async Task WaitExit(Process proc, CancellationToken ct)
    {
        try { await proc.WaitForExitAsync(ct); }
        catch (OperationCanceledException) { }
    }

    private static async Task Drain(Stream source, string logPath)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
            await using var output = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
            await source.CopyToAsync(output);
        }
        catch (IOException) { }
    }

    private static void WriteState(string path, int active, int waiting)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var json = JsonSerializer.Serialize(new { active, waiting });
            var temp = path + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, path, true);
        }
        catch (IOException) { }
    }

    private static readonly object LogLock = new();

    // Limiter connections log from many tasks; unlocked appends seek to the same end and overwrite each other.
    private static void Log(string path, string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            lock (LogLock) File.AppendAllText(path, DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + " " + line + "\n");
        }
        catch (IOException) { }
    }

    private static void WritePid(string path, int pid)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, pid.ToString(CultureInfo.InvariantCulture));
    }

    private static void DeleteOwn(string path)
    {
        try
        {
            if (File.Exists(path) && int.TryParse(File.ReadAllText(path).Trim(), out var pid) && pid == Environment.ProcessId)
                File.Delete(path);
            else if (path.EndsWith("mihomo.pid", StringComparison.Ordinal))
                File.Delete(path);
        }
        catch (IOException) { }
    }

    private static string? Option(string[] args, string name)
    {
        for (var i = 0; i < args.Length - 1; i++)
            if (args[i] == name) return args[i + 1];
        return null;
    }

    [DllImport("libc", SetLastError = true)]
    private static extern int setsid();
}
