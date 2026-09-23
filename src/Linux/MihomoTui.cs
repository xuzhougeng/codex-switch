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
            var choices = new[] { "启动", "停止", "重启", "节点", "家宽 SOCKS5", "端口与限流", "切换第一跳", "运行详情", "日志", "内核", "Shell 命令", "开机启动", "退出" };
            var choice = AnsiConsole.Prompt(new SelectionPrompt<string>()
                .Title("[grey]选择[/]")
                .PageSize(choices.Length)
                .WrapAround()
                .HighlightStyle(new Style(foreground: Color.Black, background: Color.Yellow, decoration: Decoration.Bold))
                .MoreChoicesText("[grey]↑↓ 还有选项[/]")
                .AddChoices(choices));
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
                    case "Shell 命令": Pause(ShellSetup.Install()); break;
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
        var home = string.IsNullOrWhiteSpace(settings.HomeServer)
            ? "[grey]未填写[/]"
            : "[bold]" + Markup.Escape(settings.HomeServer + ":" + settings.HomePort) + "[/]";
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        var current = names.Contains(settings.SelectedRelay) ? settings.SelectedRelay : names.FirstOrDefault() ?? "";
        var nodes = names.Count == 0
            ? "[grey]先填订阅[/]"
            : "[bold]" + Markup.Escape(current) + "[/]  [grey]订阅共 " + names.Count + " 个[/]";
        var boot = !SystemdUnit.Available() ? "无 systemd" : SystemdUnit.IsEnabled() ? "[green]开[/]" : "[grey]关[/]";
        var state = status.Running ? "[green]●[/] 运行中" : "[yellow]○[/] 未运行";
        var kernel = KernelLine(settings);
        var pace = ReadPace(status);

        var hops = new Table().Border(TableBorder.None).HideHeaders().Expand();
        hops.AddColumns(new TableColumn(""), new TableColumn(""), new TableColumn(""), new TableColumn(""));
        hops.AddRow(
            new Markup("[grey]客户端[/]"),
            new Markup("[grey]限流[/]"),
            new Markup("[grey]一跳[/]"),
            new Markup("[grey]家宽[/]"));
        hops.AddRow(
            new Markup("[bold]" + Markup.Escape("127.0.0.1:" + settings.HttpPort) + "[/]"),
            new Markup("[bold]" + Markup.Escape(settings.LimiterListen) + "[/]"),
            new Markup("[bold]" + Markup.Escape("127.0.0.1:" + settings.SocksPort) + "[/]"),
            new Markup(home));

        var meta = "[grey]并发[/] " + settings.MaxConcurrent
            + "   [grey]间隔[/] " + settings.DialIntervalMs + " ms"
            + "   [grey]排队[/] " + settings.QueueWaitS + " s"
            + "   [grey]控制[/] " + Markup.Escape(settings.Controller)
            + (pace == null ? "" : "   " + pace);
        var body = new Rows(
            new Markup(state + "    [grey]开机[/] " + boot),
            hops,
            new Markup(meta),
            new Markup("[grey]节点[/] " + nodes),
            new Markup(kernel));
        AnsiConsole.Write(new Panel(body)
        {
            Header = new PanelHeader(" mihomo ", Justify.Left),
            Border = BoxBorder.Rounded,
            BorderStyle = new Style(Color.Grey),
            Padding = new Padding(1, 0, 1, 0)
        });
        AnsiConsole.WriteLine();
    }

    private string KernelLine(ClashProxySettings settings)
    {
        try
        {
            var path = MihomoKernel.Resolve(settings.MihomoPath);
            var version = ShortVersion(Version(path));
            return "[grey]内核[/] [bold]" + Markup.Escape(version) + "[/]  [grey]" + Markup.Escape(TailPath(path, 48)) + "[/]";
        }
        catch (InvalidOperationException ex)
        {
            return "[yellow]" + Markup.Escape(ex.Message) + "[/]";
        }
    }

    private string? ReadPace(ClashProxyStatus status)
    {
        if (!status.Running) return null;
        try
        {
            var path = local.Store.LimiterStatePath;
            if (!File.Exists(path)) return null;
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            return "[grey]活动[/] " + root.GetProperty("active").GetInt32() + "   [grey]等待[/] " + root.GetProperty("waiting").GetInt32();
        }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return null;
        }
    }

    private static string ShortVersion(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "未知";
        var start = raw.IndexOf(" v", StringComparison.Ordinal);
        start = start < 0 ? raw.IndexOf('v') : start + 1;
        if (start < 0) return raw.Trim();
        var end = raw.IndexOf(' ', start);
        return end < 0 ? raw[start..].Trim() : raw[start..end];
    }

    private static string TailPath(string path, int max)
    {
        var parts = path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        var shown = parts.Length <= 3 ? string.Join('/', parts) : "…/" + string.Join('/', parts[^3..]);
        return shown.Length <= max ? shown : "…" + shown[^(max - 1)..];
    }

    private void Start(ClashProxySettings settings, ClashProxyStatus status)
    {
        if (status.Running) { Pause("已在运行。修改配置后选重启。"); return; }
        var started = local.Start(settings);
        Pause(started.Detail + "\n\nexport http_proxy=http://127.0.0.1:" + settings.HttpPort + "\nexport https_proxy=http://127.0.0.1:" + settings.HttpPort);
    }

    private async Task Nodes(ClashProxySettings settings)
    {
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        if (string.IsNullOrWhiteSpace(settings.SubscriptionUrl) && names.Count == 0)
        {
            await ReplaceSubscription(settings);
            return;
        }
        var current = names.Contains(settings.SelectedRelay) ? settings.SelectedRelay : names.FirstOrDefault() ?? "未选择";
        var url = string.IsNullOrWhiteSpace(settings.SubscriptionUrl) ? "未填写" : settings.SubscriptionUrl;
        AnsiConsole.MarkupLine("当前 [bold]{0}[/]", Markup.Escape(current));
        AnsiConsole.MarkupLine("[grey]{0}[/]", Markup.Escape(url));
        var choice = AnsiConsole.Prompt(new SelectionPrompt<string>()
            .Title("[grey]订阅里的节点[/]")
            .AddChoices("测速选择第一跳", "填写订阅", "刷新订阅", "手动选择", "返回"));
        if (choice == "返回") return;
        if (choice == "填写订阅") await ReplaceSubscription(settings);
        else if (choice == "刷新订阅") await RefreshSubscription(settings);
        else if (choice == "手动选择") ChooseRelay(settings);
        else await ProbeAndSelect(settings);
    }

    private async Task ReplaceSubscription(ClashProxySettings settings)
    {
        var url = Ask("订阅 URL", settings.SubscriptionUrl);
        settings.SubscriptionUrl = url.Trim();
        await RefreshSubscription(settings);
    }

    private async Task RefreshSubscription(ClashProxySettings settings)
    {
        if (string.IsNullOrWhiteSpace(settings.SubscriptionUrl))
            throw new InvalidOperationException("还没有订阅 URL。");
        settings.RelayYaml = await RelayImport.FromUrlAsync(settings.SubscriptionUrl);
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        if (!names.Contains(settings.SelectedRelay)) settings.SelectedRelay = names[0];
        local.Store.Save(settings);
        if (string.IsNullOrWhiteSpace(settings.HomeServer))
        {
            Pause("订阅已保存，共 " + names.Count + " 个节点。填好家宽后可以测速选择第一跳。");
            return;
        }
        await ProbeAndSelect(settings);
    }

    private async Task ProbeAndSelect(ClashProxySettings settings)
    {
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        if (names.Count == 0) throw new InvalidOperationException("订阅里没有节点。");
        if (string.IsNullOrWhiteSpace(settings.HomeServer))
            throw new InvalidOperationException("先填写家宽，再测第一跳。");
        if (!names.Contains(settings.SelectedRelay)) settings.SelectedRelay = names[0];
        local.Store.Save(settings);
        var status = local.Service.Status();
        if (status.Running) local.Restart(settings);
        else local.Start(settings);
        var bestName = "";
        var bestDelay = int.MaxValue;
        var finished = 0;
        await AnsiConsole.Status().StartAsync("测第一跳延迟", async ctx =>
        {
            await Parallel.ForEachAsync(names, new ParallelOptions { MaxDegreeOfParallelism = 6 }, async (name, token) =>
            {
                var delay = await ClashApi.DelayAsync(settings.Controller, name, 2500, token);
                lock (names)
                {
                    finished++;
                    if (delay >= 0 && delay < bestDelay)
                    {
                        bestDelay = delay;
                        bestName = name;
                    }
                    ctx.Status("已测 " + finished + "/" + names.Count + (bestName.Length == 0 ? "" : "  最快 " + bestDelay + " ms"));
                }
            });
        });
        if (bestName.Length == 0) throw new InvalidOperationException("没有节点在 2.5 秒内测通。订阅已经保存。");
        settings.SelectedRelay = bestName;
        local.Store.Save(settings);
        var group = string.IsNullOrWhiteSpace(settings.RelayGroup) ? "relay-group" : settings.RelayGroup;
        try { await ClashApi.SelectAsync(settings.Controller, group, bestName, CancellationToken.None); }
        catch (InvalidOperationException) { }
        Pause(bestName + "  " + bestDelay + " ms，已保存。下次启动会直接用它。");
    }

    private void ChooseRelay(ClashProxySettings settings)
    {
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        if (names.Count == 0) throw new InvalidOperationException("订阅里没有节点。");
        if (names.Count == 1)
        {
            settings.SelectedRelay = names[0];
            Save(settings);
            return;
        }
        var choice = AnsiConsole.Prompt(new SelectionPrompt<string>()
            .Title("选择第一跳")
            .PageSize(Math.Min(12, names.Count + 1))
            .MoreChoicesText("[grey]↑↓ 还有节点[/]")
            .AddChoices(names.Append("返回")));
        if (choice == "返回") return;
        settings.SelectedRelay = choice;
        Save(settings);
    }

    private void Home(ClashProxySettings settings)
    {
        AnsiConsole.Write(new Panel(new Markup(
            "[grey]填供应商给的 SOCKS5，不是街道地址。[/]\n" +
            "整行粘贴  [bold]socks5://用户:密码@203.0.113.10:1080[/]\n" +
            "或只填主机  [bold]203.0.113.10[/]，再补端口和账号"))
        {
            Header = new PanelHeader(" 美国家宽 ", Justify.Left),
            Border = BoxBorder.Rounded,
            BorderStyle = new Style(Color.Grey),
            Padding = new Padding(1, 0, 1, 0)
        });
        var typed = Ask("主机，或整行 socks5://…", settings.HomeServer);
        if (!SocksEndpoint.TryParse(typed, out var endpoint))
            throw new InvalidOperationException("没有认出主机。示例：socks5://user:pass@203.0.113.10:1080");
        settings.HomeServer = endpoint.Host;
        if (endpoint.Port != null) settings.HomePort = endpoint.Port;
        else settings.HomePort = Ask("端口，例如 1080", string.IsNullOrWhiteSpace(settings.HomePort) ? "1080" : settings.HomePort);
        if (endpoint.Username != null) settings.HomeUsername = endpoint.Username;
        else settings.HomeUsername = Ask("用户名，没有就回车", settings.HomeUsername);
        if (endpoint.Password != null) settings.HomePassword = endpoint.Password;
        else if (string.IsNullOrEmpty(settings.HomePassword))
            settings.HomePassword = AnsiConsole.Prompt(new TextPrompt<string>("密码，没有就回车").Secret().AllowEmpty());
        else if (AnsiConsole.Confirm("更换已保存的密码？", false))
            settings.HomePassword = AnsiConsole.Prompt(new TextPrompt<string>("新密码，回车则清空").Secret().AllowEmpty());
        if (!int.TryParse(settings.HomePort, out var port) || port is < 1 or > 65535)
            throw new InvalidOperationException("端口需要是 1 到 65535 的数字。");
        var userShown = string.IsNullOrEmpty(settings.HomeUsername) ? "无" : settings.HomeUsername;
        AnsiConsole.MarkupLine(
            "主机 [bold]{0}[/]  端口 [bold]{1}[/]  用户 [bold]{2}[/]",
            Markup.Escape(settings.HomeServer),
            Markup.Escape(settings.HomePort),
            Markup.Escape(userShown));
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
        local.Store.Save(settings);
        if (local.Service.Status().Running && AnsiConsole.Confirm("配置已保存。现在重启？"))
            Pause(local.Restart(settings).Detail);
        else Pause("已保存");
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

    private static string Ask(string label, string current)
    {
        var prompt = new TextPrompt<string>(label).AllowEmpty();
        if (!string.IsNullOrEmpty(current)) prompt.DefaultValue(current);
        return AnsiConsole.Prompt(prompt);
    }

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
