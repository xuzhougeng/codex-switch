using System.Diagnostics;

namespace CodexSwitch.Linux;

static class SystemdUnit
{
    public const string Name = "codex-mihomo.service";

    public static string UnitPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".config", "systemd", "user", Name);

    public static bool Available() => Which("systemctl") != null;

    public static bool IsEnabled() => Available() && Run("systemctl", "--user", "is-enabled", Name) == 0;

    public static bool IsActive() => Available() && Run("systemctl", "--user", "is-active", Name) == 0;

    public static void Install(string executable, string home)
    {
        if (!Available()) throw new InvalidOperationException("没有找到 systemctl，不能安装用户级开机启动。");
        Directory.CreateDirectory(Path.GetDirectoryName(UnitPath)!);
        var unit = "[Unit]\n" +
                   "Description=Codex mihomo local dialer\n" +
                   "After=network-online.target\n\n" +
                   "[Service]\n" +
                   "Type=simple\n" +
                   "ExecStart=" + Quote(executable) + " serve --home " + Quote(home) + "\n" +
                   "Restart=on-failure\n" +
                   "RestartSec=2\n" +
                   "NoNewPrivileges=true\n\n" +
                   "[Install]\n" +
                   "WantedBy=default.target\n";
        File.WriteAllText(UnitPath, unit);
        RunChecked("systemctl", "--user", "daemon-reload");
        RunChecked("systemctl", "--user", "enable", Name);
    }

    public static void Remove()
    {
        if (Available())
        {
            Run("systemctl", "--user", "disable", "--now", Name);
            Run("systemctl", "--user", "daemon-reload");
        }
        try { File.Delete(UnitPath); } catch (IOException) { }
    }

    public static void Start() => RunChecked("systemctl", "--user", "start", Name);

    public static void Restart() => RunChecked("systemctl", "--user", "restart", Name);

    public static void Stop() => RunChecked("systemctl", "--user", "stop", Name);

    private static void RunChecked(string file, params string[] args)
    {
        var result = Capture(file, args);
        if (result.Code != 0)
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(result.Text) ? file + " 失败。" : result.Text.Trim());
    }

    private static int Run(string file, params string[] args) => Capture(file, args).Code;

    private static (int Code, string Text) Capture(string file, params string[] args)
    {
        var info = new ProcessStartInfo(file)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("无法执行 " + file);
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(8000))
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw new InvalidOperationException(file + " 超时。");
        }
        return (process.ExitCode, (stdout.GetAwaiter().GetResult() + stderr.GetAwaiter().GetResult()).Trim());
    }

    private static string Quote(string value) => "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    private static string? Which(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var folder in path.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(folder)) continue;
            var candidate = Path.Combine(folder, name);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
