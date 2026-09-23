using System.Text;

namespace CodexSwitch.Linux;

static class ShellSetup
{
    public static string Install()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var bin = Path.Combine(home, ".local", "bin");
        Directory.CreateDirectory(bin);
        var target = Path.Combine(bin, "function.sh");
        File.WriteAllText(target, ReadScript());
        if (OperatingSystem.IsLinux())
        {
            try { File.SetUnixFileMode(target, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); }
            catch (IOException) { }
        }
        var sourced = new List<string>();
        foreach (var rc in new[] { ".zshrc", ".bashrc" })
        {
            var path = Path.Combine(home, rc);
            if (EnsureSource(path)) sourced.Add(rc);
        }
        var where = sourced.Count == 0 ? "shell 配置里已经有 source" : "已写入 " + string.Join("、", sourced);
        return "已更新 ~/.local/bin/function.sh。claude 和 codex 会使用 127.0.0.1 上的 HTTP 端口。"
            + where
            + "。当前终端执行：source ~/.local/bin/function.sh";
    }

    private static string ReadScript()
    {
        var name = typeof(ShellSetup).Assembly.GetManifestResourceNames().FirstOrDefault(item => item.EndsWith("function.sh", StringComparison.Ordinal));
        if (name == null) throw new InvalidOperationException("缺少内置 function.sh。");
        using var stream = typeof(ShellSetup).Assembly.GetManifestResourceStream(name) ?? throw new InvalidOperationException("无法读取 function.sh。");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private static bool EnsureSource(string path)
    {
        var line = "source \"$HOME/.local/bin/function.sh\"";
        var existing = File.Exists(path) ? File.ReadAllText(path) : "";
        if (existing.Contains("function.sh", StringComparison.Ordinal)) return false;
        var prefix = existing.Length == 0 || existing.EndsWith('\n') ? "" : "\n";
        File.AppendAllText(path, prefix + "\n# codex-switch\n" + line + "\n");
        return true;
    }
}
