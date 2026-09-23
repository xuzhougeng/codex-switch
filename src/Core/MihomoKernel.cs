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
}
