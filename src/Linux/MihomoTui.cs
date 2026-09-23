using System.Diagnostics;
using CodexSwitch.Core;
using Spectre.Console;

namespace CodexSwitch.Linux;

sealed class MihomoTui
{
    private readonly LocalService local = new();
    private string? kernelVersion;

    public async Task<int> RunAsync()
    {
        if (!AnsiConsole.Profile.Capabilities.Interactive)
        {
            Console.WriteLine("当前不是交互终端。可执行 codex-switch status");
            return 1;
        }
        while (true)
        {
            var settings = local.Load();
            var status = local.Service.Status();
            AnsiConsole.Clear();
            Render(settings, status);
            var choice = AnsiConsole.Prompt(new SelectionPrompt<string>()
                .Title("管理")
                .AddChoices("启动", "停止", "重启", "节点", "家宽 SOCKS5", "端口与限流", "切换第一跳", "运行详情", "日志", "内核", "开机启动", "退出"));
            if (choice == "退出") return 0;
            try
            {
                switch (choice)
                {
                    case "启动": Start(settings, status); break;
                    case "停止": local.Stop(); Pause("已停止"); break;
                    case "重启": Pause(local.Restart(settings).Detail); break;
                    case "节点": await Nodes(settings); break;
                    case "家宽 SOCKS5": Home(settings); break;
                    case "端口与限流": Ports(settings); break;
                    case "切换第一跳": await SelectRelay(settings, status); break;
                    case "运行详情": await Details(settings, status); break;
                    case "日志": Logs(); break;
                    case "内核": await Kernel(settings); break;
                    case "开机启动": Boot(settings); break;
                }
            }
            catch (Exception ex) when (ex is InvalidOperationException or IOException or HttpRequestException or TaskCanceledException)
            {
                Pause(ex.Message);
            }
        }
    }

    public static string Chain(ClashProxySettings settings)
    {
        var home = string.IsNullOrWhiteSpace(settings.HomeServer) ? "家宽未填写" : settings.HomeServer + ":" + settings.HomePort;
        return "Codex / Claude → http://127.0.0.1:" + settings.HttpPort
            + " → 限流 " + settings.LimiterListen
            + " → 一跳 127.0.0.1:" + settings.SocksPort
            + " → " + home;
    }

    private void Render(ClashProxySettings settings, ClashProxyStatus status)
    {
        AnsiConsole.Write(new Rule("mihomo").LeftJustified());
        AnsiConsole.MarkupLine(status.Running ? "[green]运行中[/]" : "[yellow]未运行[/]");
        AnsiConsole.WriteLine(status.Detail);
        AnsiConsole.WriteLine(Chain(settings));
        AnsiConsole.MarkupLine("[grey]客户端只使用 HTTP 端口。一跳和限流端口由本机链路占用。[/]");
        AnsiConsole.WriteLine("端口  HTTP " + settings.HttpPort + "   一跳 " + settings.SocksPort + "   控制 " + settings.Controller + "   限流 " + settings.LimiterListen);
        AnsiConsole.WriteLine("限流  同时 " + settings.MaxConcurrent + "   间隔 " + settings.DialIntervalMs + " ms   排队 " + settings.QueueWaitS + " s");
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        AnsiConsole.WriteLine(names.Count == 0 ? "节点  未配置" : "节点  " + string.Join("、", names.Take(4)) + (names.Count > 4 ? " 等 " + names.Count + " 个" : ""));
        AnsiConsole.WriteLine("内核  " + KernelLabel(settings));
        var boot = SystemdUnit.Available() ? (SystemdUnit.IsEnabled() ? "开机启动  已启用" : "开机启动  未启用") : "开机启动  无 systemd";
        AnsiConsole.WriteLine(boot);
        AnsiConsole.WriteLine();
    }

    private void Start(ClashProxySettings settings, ClashProxyStatus status)
    {
        if (status.Running) { Pause("已在运行。修改配置后选重启。"); return; }
        var started = local.Start(settings);
        Pause(started.Detail + "\n\nexport http_proxy=http://127.0.0.1:" + settings.HttpPort + "\nexport https_proxy=http://127.0.0.1:" + settings.HttpPort);
    }

    private async Task Nodes(ClashProxySettings settings)
    {
        var choice = AnsiConsole.Prompt(new SelectionPrompt<string>().Title("节点").AddChoices("从文件导入", "从订阅导入", "编辑", "返回"));
        if (choice == "返回") return;
        string text;
        if (choice == "从文件导入")
        {
            var path = AnsiConsole.Prompt(new TextPrompt<string>("YAML 路径"));
            text = await File.ReadAllTextAsync(path);
        }
        else if (choice == "从订阅导入")
        {
            var url = AnsiConsole.Prompt(new TextPrompt<string>("订阅 URL"));
            text = await RelayImport.FromUrlAsync(url);
        }
        else text = Edit(settings.RelayYaml);
        settings.RelayYaml = RelayImport.ExtractProxies(text);
        Save(settings);
    }

    private void Home(ClashProxySettings settings)
    {
        settings.HomeServer = Ask("家宽地址", settings.HomeServer);
        settings.HomePort = Ask("家宽端口", settings.HomePort);
        settings.HomeUsername = Ask("用户名，可留空", settings.HomeUsername);
        if (AnsiConsole.Confirm("修改密码？", false))
            settings.HomePassword = AnsiConsole.Prompt(new TextPrompt<string>("密码").Secret().AllowEmpty());
        Save(settings);
    }

    private void Ports(ClashProxySettings settings)
    {
        settings.HttpPort = AskInt("HTTP 端口，Codex / Claude 入口", settings.HttpPort);
        settings.SocksPort = AskInt("一跳 SOCKS 端口", settings.SocksPort);
        settings.Controller = Ask("外部控制", settings.Controller);
        settings.LimiterListen = Ask("限流监听", settings.LimiterListen);
        settings.MaxConcurrent = AskInt("同时打到家宽的连接数", settings.MaxConcurrent);
        settings.DialIntervalMs = AskInt("两条新建之间的间隔（毫秒）", settings.DialIntervalMs);
        settings.QueueWaitS = AskInt("排队上限（秒）", settings.QueueWaitS);
        settings.MihomoPath = Ask("mihomo 路径，留空使用内置内核", settings.MihomoPath);
        Save(settings);
    }

    private async Task SelectRelay(ClashProxySettings settings, ClashProxyStatus status)
    {
        if (!status.Running) throw new InvalidOperationException("先启动服务，再切换第一跳。");
        var group = string.IsNullOrWhiteSpace(settings.RelayGroup) ? "relay-group" : settings.RelayGroup;
        var info = await ClashApi.GroupAsync(settings.Controller, group, CancellationToken.None);
        if (info.All.Count == 0) throw new InvalidOperationException("控制端口没有返回可选节点。");
        var pick = AnsiConsole.Prompt(new SelectionPrompt<string>()
            .Title("当前 " + info.Now)
            .AddChoices(info.All.Append("返回")));
        if (pick == "返回") return;
        await ClashApi.SelectAsync(settings.Controller, group, pick, CancellationToken.None);
        Pause("第一跳已切到 " + pick);
    }

    private async Task Details(ClashProxySettings settings, ClashProxyStatus status)
    {
        AnsiConsole.WriteLine(ProcessLine(status.MihomoPid ?? status.LimiterPid));
        if (!status.Running) { Pause("服务未运行。"); return; }
        AnsiConsole.WriteLine(await ClashApi.ConnectionsAsync(settings.Controller, CancellationToken.None));
        Pause("");
    }

    private void Logs()
    {
        foreach (var path in new[] { local.Store.LimiterLogPath, local.Store.MihomoLogPath, local.Store.ServiceLogPath })
        {
            AnsiConsole.MarkupLine("[grey]" + Markup.Escape(path) + "[/]");
            if (!File.Exists(path)) { AnsiConsole.WriteLine("(空)"); continue; }
            foreach (var line in File.ReadAllLines(path).TakeLast(25)) AnsiConsole.WriteLine(line);
            AnsiConsole.WriteLine();
        }
        Pause("");
    }

    private async Task Kernel(ClashProxySettings settings)
    {
        var kernel = MihomoKernel.Resolve(settings.MihomoPath);
        MihomoKernel.EnsureExecutable(kernel);
        AnsiConsole.WriteLine(kernel);
        AnsiConsole.WriteLine(Version(kernel));
        AnsiConsole.WriteLine(File.Exists(Path.Combine(AppContext.BaseDirectory, "kernel", "SOURCE.txt"))
            ? await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "kernel", "SOURCE.txt"))
            : "内置内核来源见 src/Linux/kernel/SOURCE.txt");
        if (AnsiConsole.Confirm("用当前配置做 mihomo -t？", true))
        {
            local.Service.Prepare(local.Load());
            AnsiConsole.WriteLine(await ConfigCheck.RunAsync(kernel, local.Store));
        }
        Pause("");
    }

    private void Boot(ClashProxySettings settings)
    {
        if (!SystemdUnit.Available()) throw new InvalidOperationException("没有找到 systemctl。");
        if (SystemdUnit.IsEnabled())
        {
            if (!AnsiConsole.Confirm("取消开机启动并停止服务？")) return;
            SystemdUnit.Remove();
            local.Service.Stop();
            Pause("已取消开机启动");
            return;
        }
        if (!AnsiConsole.Confirm("写入用户级 systemd 并现在启动？")) return;
        local.Service.Check(settings);
        local.InstallBoot();
        Pause("已启用 " + SystemdUnit.Name);
    }

    private void Save(ClashProxySettings settings)
    {
        local.Service.Check(settings);
        local.Store.Save(settings);
        if (local.Service.Status().Running && AnsiConsole.Confirm("配置已保存。现在重启？"))
            Pause(local.Restart(settings).Detail);
        else Pause("配置已保存");
    }

    private string Edit(string current)
    {
        Directory.CreateDirectory(local.Store.WorkDirectory);
        var path = Path.Combine(local.Store.WorkDirectory, "relay.edit.yaml");
        var seed = string.IsNullOrWhiteSpace(current)
            ? "- name: relay-example\n  type: ss\n  server: example.com\n  port: 443\n  cipher: aes-256-gcm\n  password: replace-me\n"
            : current;
        File.WriteAllText(path, seed);
        if (OperatingSystem.IsLinux())
        {
            try { File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch (IOException) { }
        }
        var editor = Environment.GetEnvironmentVariable("EDITOR");
        if (string.IsNullOrWhiteSpace(editor)) editor = File.Exists("/usr/bin/nano") ? "nano" : "vi";
        var info = new ProcessStartInfo("/bin/sh") { UseShellExecute = false };
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add(editor + " '" + path.Replace("'", "'\\''") + "'");
        using var process = Process.Start(info) ?? throw new InvalidOperationException("无法打开编辑器。");
        process.WaitForExit();
        return File.ReadAllText(path);
    }

    private string KernelLabel(ClashProxySettings settings)
    {
        try
        {
            var path = MihomoKernel.Resolve(settings.MihomoPath);
            return path + "  " + Version(path);
        }
        catch (InvalidOperationException ex) { return ex.Message; }
    }

    private string Version(string kernel)
    {
        if (kernelVersion != null) return kernelVersion;
        try
        {
            var info = new ProcessStartInfo(kernel, "-v")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using var process = Process.Start(info);
            if (process == null) return kernelVersion = "";
            if (!process.WaitForExit(3000)) return kernelVersion = "";
            var line = (process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd()).Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            return kernelVersion = line ?? "";
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException) { return kernelVersion = ""; }
    }

    private static string ProcessLine(int? pid)
    {
        if (pid is not int value) return "没有进程号。";
        try
        {
            using var process = Process.GetProcessById(value);
            var mb = process.WorkingSet64 / 1024d / 1024d;
            var up = DateTime.Now - process.StartTime;
            return "pid " + value + "  内存 " + mb.ToString("0.0") + " MB  已运行 " + up.ToString(@"hh\:mm\:ss");
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { return "进程已退出。"; }
    }

    private static string Ask(string label, string current) =>
        AnsiConsole.Prompt(new TextPrompt<string>(label).DefaultValue(current ?? "").AllowEmpty());

    private static int AskInt(string label, int current) =>
        AnsiConsole.Prompt(new TextPrompt<int>(label).DefaultValue(current)
            .Validate(value => value is >= 0 and <= 65535 ? ValidationResult.Success() : ValidationResult.Error("0-65535")));

    private static void Pause(string message)
    {
        if (message.Length > 0) AnsiConsole.WriteLine(message.Length > 2000 ? message[..2000] : message);
        AnsiConsole.MarkupLine("[grey]回车继续[/]");
        Console.ReadLine();
    }
}

static class ConfigCheck
{
    public static async Task<string> RunAsync(string kernel, ClashProxyStore store)
    {
        var info = new ProcessStartInfo(kernel)
        {
            WorkingDirectory = store.WorkDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        info.ArgumentList.Add("-f");
        info.ArgumentList.Add(store.YamlPath);
        info.ArgumentList.Add("-t");
        foreach (var key in new[] { "http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY" })
            info.Environment.Remove(key);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("无法执行 mihomo。");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(20000))
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw new InvalidOperationException("mihomo -t 超时。");
        }
        var text = ((await stdout) + (await stderr)).Trim();
        if (process.ExitCode != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(text) ? "配置检查失败。" : text);
        return string.IsNullOrWhiteSpace(text) ? "配置检查通过。" : text;
    }
}
