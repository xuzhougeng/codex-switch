using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexSwitch.Linux;

public static class SystemdUnit
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
        File.WriteAllText(UnitPath, Render(executable, home, RuntimeRoot(executable)));
        RunChecked("systemctl", "--user", "daemon-reload");
        RunChecked("systemctl", "--user", "enable", Name);
    }

    // systemd does not inherit the shell's DOTNET_ROOT, so a framework-dependent apphost exits before Main.
    public static string Render(string executable, string home, string? dotnetRoot)
    {
        var environment = "";
        if (!string.IsNullOrWhiteSpace(dotnetRoot))
        {
            var quoted = Quote(dotnetRoot);
            environment = "Environment=DOTNET_ROOT=" + quoted + "\n" +
                          "Environment=DOTNET_ROOT_" + RuntimeToken() + "=" + quoted + "\n";
        }
        return "[Unit]\n" +
               "Description=Codex mihomo local dialer\n" +
               "After=network-online.target\n" +
               "StartLimitIntervalSec=30\n" +
               "StartLimitBurst=5\n\n" +
               "[Service]\n" +
               "Type=simple\n" +
               environment +
               "ExecStart=" + Quote(executable) + " serve --home " + Quote(home) + "\n" +
               "Restart=on-failure\n" +
               "RestartSec=2\n" +
               "NoNewPrivileges=true\n\n" +
               "[Install]\n" +
               "WantedBy=default.target\n";
    }

    public static bool NeedsFramework(string executable)
    {
        var full = Path.GetFullPath(executable);
        var dir = Path.GetDirectoryName(full);
        if (string.IsNullOrEmpty(dir)) return false;
        if (File.Exists(Path.Combine(dir, "libhostfxr.so"))) return false;
        return File.Exists(full + ".runtimeconfig.json");
    }

    public static string RuntimeToken() => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.Arm64 => "ARM64",
        Architecture.X86 => "X86",
        Architecture.Arm => "ARM",
        _ => "X64"
    };

    public static string? TryRuntimeRoot(string executable) => NeedsFramework(executable) ? FindRuntimeRoot() : null;

    public static string RecentLog()
    {
        if (!Available() || !File.Exists(UnitPath) || Which("journalctl") == null) return "";
        try
        {
            var result = Capture("journalctl", "--user", "-u", Name, "-n", "12", "--no-pager", "-o", "cat");
            return result.Code == 0 ? result.Text.Trim() : "";
        }
        catch (InvalidOperationException) { return ""; }
    }

    private static string? RuntimeRoot(string executable)
    {
        if (!NeedsFramework(executable)) return null;
        return FindRuntimeRoot() ?? throw new InvalidOperationException(
            "开机服务启动不了：这个程序依赖本机 .NET，但没有找到运行时。把 DOTNET_ROOT 指到含有 dotnet 的目录后再开启。");
    }

    private static string? FindRuntimeRoot()
    {
        foreach (var key in new[] { "DOTNET_ROOT_" + RuntimeToken(), "DOTNET_ROOT" })
        {
            if (IsRuntimeRoot(Environment.GetEnvironmentVariable(key)) is { } fromEnv) return fromEnv;
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var candidate in new[] { Path.Combine(home, ".dotnet"), "/usr/share/dotnet", "/usr/lib/dotnet" })
        {
            if (IsRuntimeRoot(candidate) is { } found) return found;
        }
        var dotnet = Which("dotnet");
        return dotnet == null ? null : IsRuntimeRoot(Path.GetDirectoryName(dotnet));
    }

    private static string? IsRuntimeRoot(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        var full = Path.GetFullPath(path);
        if (!File.Exists(Path.Combine(full, "dotnet"))) return null;
        if (!Directory.Exists(Path.Combine(full, "host", "fxr"))) return null;
        return full;
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

    public static void Start()
    {
        Run("systemctl", "--user", "reset-failed", Name);
        RunChecked("systemctl", "--user", "start", Name);
    }

    public static void Restart()
    {
        Run("systemctl", "--user", "reset-failed", Name);
        RunChecked("systemctl", "--user", "restart", Name);
    }

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
