using System.Diagnostics;

namespace CodexSwitch.Core;

public static class BrowserLogin
{
    public static string? FindCli()
    {
        var paths = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).ToList();
        paths.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Links"));
        paths.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"));
        foreach (var folder in paths.Where(Directory.Exists))
            foreach (var name in new[] { "codex.exe", "codex.cmd" })
                if (File.Exists(Path.Combine(folder, name))) return Path.Combine(folder, name);
        return null;
    }

    public static async Task RunAsync(AccountStore store, CancellationToken cancellationToken)
    {
        var cli = FindCli() ?? throw new InvalidOperationException("未找到 Codex CLI。请先安装 CLI，再点击登录新账号。");
        // Isolated login: cancellation/failure never clears the existing auth.json.
        var staging = Path.Combine(store.Store, ".login-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        using var process = new Process();
        var start = new ProcessStartInfo(cli) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true };
        if (cli.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            if (cli.IndexOfAny(['"', '%', '\r', '\n']) >= 0) throw new InvalidOperationException("CLI 路径包含不支持的字符。");
            start.FileName = Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe";
            start.Arguments = $"/d /s /c \"\"{cli}\" -c cli_auth_credentials_store='file' login\"";
        }
        else
        {
            start.ArgumentList.Add("-c");
            start.ArgumentList.Add("cli_auth_credentials_store='file'");
            start.ArgumentList.Add("login");
        }
        start.Environment["CODEX_HOME"] = staging;
        process.StartInfo = start;
        try
        {
            process.Start();
            using var registration = timeout.Token.Register(() =>
            {
                try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { }
            });
            // Drain without retaining/logging OAuth output or login secrets.
            var output = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null);
            var error = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
            await process.WaitForExitAsync(timeout.Token);
            await Task.WhenAll(output, error);
            timeout.Token.ThrowIfCancellationRequested();
            var auth = Path.Combine(staging, "auth.json");
            if (process.ExitCode != 0 || !File.Exists(auth)) throw new InvalidOperationException("登录未完成，原账号已保留。请重试并在浏览器完成登录。");
            store.ImportLogin(await File.ReadAllBytesAsync(auth, timeout.Token));
        }
        finally
        {
            try { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } } catch (InvalidOperationException) { }
            // Only the unique directory created by this operation is removed.
            try { Directory.Delete(staging, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
