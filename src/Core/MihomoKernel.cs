using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexSwitch.Core;

public static class MihomoKernel
{
    public static string ArchFolder => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.X64 => "linux-x64",
        Architecture.Arm64 => "linux-arm64",
        Architecture.Arm => "linux-arm",
        _ => RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()
    };

    public static string? ReleaseAsset(string tag) => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.X64 => "mihomo-linux-amd64-compatible-" + tag + ".gz",
        Architecture.Arm64 => "mihomo-linux-arm64-" + tag + ".gz",
        Architecture.Arm => "mihomo-linux-armv7-" + tag + ".gz",
        _ => null
    };

    public static string? Bundled(string? appDirectory = null)
    {
        var roots = new List<string>();
        if (!string.IsNullOrWhiteSpace(appDirectory)) roots.Add(appDirectory);
        roots.Add(AppContext.BaseDirectory);
        var processDir = Path.GetDirectoryName(Environment.ProcessPath);
        if (!string.IsNullOrWhiteSpace(processDir)) roots.Add(processDir);
        foreach (var root in roots.Distinct(StringComparer.Ordinal))
        {
            foreach (var relative in new[] { Path.Combine("kernel", "mihomo"), Path.Combine("kernel", ArchFolder, "mihomo") })
            {
                var candidate = Path.Combine(root, relative);
                if (File.Exists(candidate)) return Path.GetFullPath(candidate);
            }
        }
        return null;
    }

    public static string Resolve(string? configured, string? appDirectory = null)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            var path = Environment.ExpandEnvironmentVariables(configured.Trim());
            if (File.Exists(path)) return Path.GetFullPath(path);
            throw new InvalidOperationException("找不到指定的 mihomo：" + path);
        }
        var bundled = Bundled(appDirectory);
        if (bundled != null) return bundled;
        return ClashProxyRuntime.ResolveMihomo(null);
    }

    public static void EnsureExecutable(string path)
    {
        if (OperatingSystem.IsWindows()) return;
        try
        {
            var mode = File.GetUnixFileMode(path);
            var next = mode | UnixFileMode.UserRead | UnixFileMode.UserExecute;
            if (next != mode) File.SetUnixFileMode(path, next);
        }
        catch (IOException) { }
    }

    public static string VersionLine(string path)
    {
        try
        {
            var info = new ProcessStartInfo(path, "-v") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            using var process = Process.Start(info);
            if (process == null) return "";
            if (!process.WaitForExit(3000)) { process.Kill(); return ""; }
            var text = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            return text.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or Win32Exception) { return ""; }
    }

    // "Mihomo Meta v1.19.31 linux amd64 with go1.26.8 ..." -> "v1.19.31"; alpha builds give "alpha-xxxx".
    public static string ParseVersion(string line)
    {
        var parts = (line ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var meta = Array.IndexOf(parts, "Meta");
        if (meta >= 0 && meta + 1 < parts.Length) return parts[meta + 1];
        return parts.FirstOrDefault(part => part.Length > 1 && part[0] == 'v' && char.IsDigit(part[1])) ?? "";
    }
}
