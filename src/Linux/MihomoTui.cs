using System.ComponentModel;
using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Text.Json;
using CodexSwitch.Core;
using Spectre.Console;

namespace CodexSwitch.Linux;

sealed class MihomoTui
{
    private readonly LocalService local = new();
    private (string Path, DateTime Stamp, string Line)? versionCache;

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
            var menu = new List<(string Label, string Hint)>();
            if (status.Running) menu.AddRange([("重启", "应用改过的配置"), ("停止", "")]);
            else menu.Add(("启动", "后台运行 mihomo 和限流"));
            menu.AddRange([("节点", "填写 · 刷新订阅"), ("切换第一跳", "自动测速 · 手动指定"), ("家宽 SOCKS5", "出口主机与账号"), ("端口与限流", "端口 · 并发 · 间隔")]);
            if (status.Running) menu.Add(("运行详情", "进程与当前连接"));
            menu.AddRange([("日志", "服务 · 限流 · mihomo"), ("内核", "版本 · 在线更新 · 检查配置"), ("Shell 命令", "写入 claude / codex 代理函数"),
                ("开机启动", "systemd 用户服务"), ("退出", "")]);
            var labels = menu.Select(item => Markup.Escape(item.Label)
                + new string(' ', Math.Max(0, 14 - item.Label.GetCellWidth())) + "[grey62]" + item.Hint + "[/]").ToList();
            var index = Pick(labels, pageSize: labels.Count, wrap: true, back: false);
            if (index < 0) continue;
            var choice = menu[index].Label;
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
                    case "切换第一跳": await SwitchRelay(settings); break;
                    case "运行详情": await Details(settings, status); break;
                    case "日志": Logs(); break;
                    case "内核": await Kernel(); break;
                    case "Shell 命令": Pause(ShellSetup.Install()); break;
                    case "开机启动": Boot(settings); break;
                }
            }
            catch (Back)
            {
            }
            catch (Exception ex) when (ex is InvalidOperationException or IOException or HttpRequestException or TaskCanceledException
                or JsonException or Win32Exception or UnauthorizedAccessException)
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

    // One row per hop in chain order, so the dashboard reads top to bottom and fits an 80-column terminal.
    private void Render(ClashProxySettings settings, ClashProxyStatus status)
    {
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        var current = names.Contains(settings.SelectedRelay) ? settings.SelectedRelay : names.FirstOrDefault() ?? "";
        var boot = !SystemdUnit.Available() ? "无 systemd" : SystemdUnit.IsEnabled() ? "[green]开[/]" : "关";
        var pace = ReadPace(status);
        var grid = new Grid()
            .AddColumn(new GridColumn().NoWrap().PadRight(3))
            .AddColumn(new GridColumn().NoWrap().PadRight(3))
            .AddColumn();
        void Row(string label, string value, string detail) =>
            grid.AddRow(new Markup(label, Muted), new Markup(value), new Markup(detail, Muted));

        Row("状态", status.Running ? "[bold green]● 运行中[/]" : "[bold yellow]○ 未运行[/]",
            (pace == null ? "" : pace + " · ") + "开机自启 " + boot);
        grid.AddEmptyRow();
        Row("入口", Markup.Escape("127.0.0.1:" + settings.HttpPort), "Codex / Claude 的 HTTP 代理");
        Row("限流", Markup.Escape(settings.LimiterListen),
            "并发 " + settings.MaxConcurrent + " · 间隔 " + settings.DialIntervalMs + " ms · 排队 " + settings.QueueWaitS + " s");
        Row("一跳", Markup.Escape("127.0.0.1:" + settings.SocksPort), names.Count == 0
            ? "[yellow]先填订阅[/]"
            : "[bold default]" + Markup.Escape(Plain(current)) + "[/] · 订阅 " + names.Count + " 个");
        Row("家宽", string.IsNullOrWhiteSpace(settings.HomeServer)
            ? "[yellow]未填写[/]"
            : Markup.Escape(settings.HomeServer + ":" + settings.HomePort), "SOCKS5");
        grid.AddEmptyRow();
        try
        {
            var path = MihomoKernel.Resolve(settings.MihomoPath);
            Row("内核", "[bold]" + Markup.Escape(VersionOf(path)) + "[/] [grey62]" + KernelSource(settings, path) + "[/]", RunningKernel(status, path) ?? "");
        }
        catch (InvalidOperationException ex)
        {
            Row("内核", "[yellow]未找到[/]", Markup.Escape(ex.Message));
        }
        Row("控制", Markup.Escape(settings.Controller), "mihomo API");
        AnsiConsole.Write(new Panel(grid)
        {
            Header = new PanelHeader("[bold yellow] mihomo [/]", Justify.Left),
            Border = BoxBorder.Rounded,
            BorderStyle = new Style(Color.Grey42),
            Padding = new Padding(2, 1, 2, 1)
        });
        AnsiConsole.WriteLine();
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
            return "活动 " + root.GetProperty("active").GetInt32() + " · 等待 " + root.GetProperty("waiting").GetInt32();
        }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return null;
        }
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
        AnsiConsole.MarkupLine("[grey62]{0}[/]", Markup.Escape(url));
        var options = new[] { "填写订阅", "刷新订阅", "返回" };
        var index = Pick(options, title: "[grey62]订阅[/]");
        if (index < 0 || options[index] == "返回") return;
        if (options[index] == "填写订阅") await ReplaceSubscription(settings);
        else await RefreshSubscription(settings);
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
            Pause("订阅已保存，共 " + names.Count + " 个节点。填好家宽后，在「切换第一跳」里自动测速。");
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
        var bestName = "";
        var bestDelay = int.MaxValue;
        var finished = 0;
        // Rank by the whole chain, not the first hop: a relay close to me can still be far from the US home.
        await AnsiConsole.Status().StartAsync("测整条链路：本机 → 中转 → 家宽", async ctx =>
        {
            await MihomoDaemon.ProbeChainsAsync(local.Store, settings, 5000, (name, delay) =>
            {
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
        if (bestName.Length == 0) throw new InvalidOperationException("没有节点在 5 秒内走通 本机 → 中转 → 家宽。订阅已经保存，先检查家宽地址和账号。");
        settings.SelectedRelay = bestName;
        local.Store.Save(settings);
        var status = local.Service.Status();
        if (status.Running) local.Restart(settings);
        else local.Start(settings);
        Pause(bestName + "  整条链路 " + bestDelay + " ms，已保存并生效。");
    }

    private async Task SwitchRelay(ClashProxySettings settings)
    {
        var actions = new[] { "自动", "手动", "返回" };
        while (true)
        {
            AnsiConsole.Clear();
            var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
            var current = names.Contains(settings.SelectedRelay) ? settings.SelectedRelay : names.FirstOrDefault() ?? "未选择";
            AnsiConsole.MarkupLine("当前 [bold]{0}[/]", Markup.Escape(current));
            string Row(string label, string hint) => Markup.Escape(label) + new string(' ', Math.Max(1, 8 - label.GetCellWidth())) + "[grey62]" + hint + "[/]";
            var index = Pick(new[] { Row("自动", "测整条链路，留下最快的"), Row("手动", "从订阅里指定一个"), "返回" }, title: "[grey62]切换第一跳[/]");
            if (index < 0 || actions[index] == "返回") return;
            if (actions[index] == "自动") await ProbeAndSelect(settings);
            else await ChooseRelay(settings);
        }
    }

    private async Task ChooseRelay(ClashProxySettings settings)
    {
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        if (names.Count == 0) throw new InvalidOperationException("订阅里没有节点。");
        if (names.Count == 1)
        {
            await ApplyRelay(settings, names[0]);
            return;
        }
        var options = names.Append("返回").ToList();
        var index = Pick(options.Select(Markup.Escape).ToList(), title: "选择第一跳",
            pageSize: Math.Min(12, options.Count), more: "[grey62]↑↓ 还有节点[/]");
        if (index < 0 || options[index] == "返回") return;
        await ApplyRelay(settings, options[index]);
    }

    // A running service switches live. A stopped one only stores the name for the next start.
    private async Task ApplyRelay(ClashProxySettings settings, string name)
    {
        settings.SelectedRelay = name;
        local.Store.Save(settings);
        var status = local.Service.Status();
        if (!status.Running)
        {
            Pause("已保存，启动后生效");
            return;
        }
        var group = string.IsNullOrWhiteSpace(settings.RelayGroup) ? "relay-group" : settings.RelayGroup;
        try
        {
            await ClashApi.SelectAsync(settings.Controller, group, name, CancellationToken.None);
            Pause("第一跳已切到 " + name);
        }
        catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException or TaskCanceledException)
        {
            if (Confirm("没有切到运行中的服务。现在重启？")) Pause(local.Restart(settings).Detail);
            else Pause("已保存，重启后生效");
        }
    }

    private void Home(ClashProxySettings settings)
    {
        AnsiConsole.Write(new Panel(new Markup(
            "[grey62]填供应商给的 SOCKS5，不是街道地址。[/]\n" +
            "整行粘贴  [bold]socks5://用户:密码@203.0.113.10:1080[/]\n" +
            "或只填主机  [bold]203.0.113.10[/]，再补端口和账号"))
        {
            Header = new PanelHeader(" 美国家宽 ", Justify.Left),
            Border = BoxBorder.Rounded,
            BorderStyle = new Style(Color.Grey42),
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
            settings.HomePassword = AskSecret("密码，没有就回车");
        else if (Confirm("更换已保存的密码？", false))
            settings.HomePassword = AskSecret("新密码，回车则清空");
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
        Save(settings);
    }

    private async Task Details(ClashProxySettings settings, ClashProxyStatus status)
    {
        AnsiConsole.WriteLine(ProcessLine(status.MihomoPid ?? status.LimiterPid));
        if (!status.Running) { Pause("服务未运行。"); return; }
        AnsiConsole.WriteLine(await ClashApi.ConnectionsAsync(settings.Controller, CancellationToken.None));
        Pause("");
    }

    // One log per tab, newest at the bottom, trimmed to the window so the tabs and keys never scroll away.
    private void Logs()
    {
        var sources = new[] { ("服务", local.Store.ServiceLogPath), ("限流", local.Store.LimiterLogPath), ("mihomo", local.Store.MihomoLogPath) };
        var tab = 0;
        var problemsOnly = false;
        while (true)
        {
            var (_, path) = sources[tab];
            var entries = File.Exists(path) ? LogTail.Parse(LogTail.ReadLines(path)) : [];
            var problems = entries.Where(e => e.Level is "WARN" or "ERROR").ToList();
            AnsiConsole.Clear();
            AnsiConsole.MarkupLine(string.Join(" ", sources.Select((s, i) => i == tab ? "[black on yellow bold] " + s.Item1 + " [/]" : "[grey62] " + s.Item1 + " [/]"))
                + "  [grey42]" + Markup.Escape(Tilde(path)) + "[/]");
            AnsiConsole.Write(new Rule().RuleStyle(Color.Grey42));
            AnsiConsole.Write(LogGrid(problemsOnly ? problems : entries, Math.Max(5, Console.WindowHeight - 5), problemsOnly));
            AnsiConsole.Write(new Rule().RuleStyle(Color.Grey42));
            AnsiConsole.MarkupLine("[grey62]←→ 切换   w " + (problemsOnly ? "显示全部" : "只看警告和错误（" + problems.Count + "）") + "   r 刷新   q 返回[/]");
            switch (Console.ReadKey(true).Key)
            {
                case ConsoleKey.LeftArrow: tab = (tab + sources.Length - 1) % sources.Length; break;
                case ConsoleKey.RightArrow or ConsoleKey.Tab: tab = (tab + 1) % sources.Length; break;
                case ConsoleKey.W: problemsOnly = !problemsOnly; break;
                case ConsoleKey.Q or ConsoleKey.Escape or ConsoleKey.Enter: return;
            }
        }
    }

    private static Spectre.Console.Rendering.IRenderable LogGrid(List<LogEntry> entries, int rows, bool problemsOnly)
    {
        if (entries.Count == 0) return new Markup(problemsOnly ? "[green]最近没有警告或错误[/]" : "[grey62](空)[/]");
        Grid Build(int skip)
        {
            var grid = new Grid()
                .AddColumn(new GridColumn().NoWrap().PadRight(1))
                .AddColumn(new GridColumn().NoWrap().PadRight(1))
                .AddColumn();
            foreach (var entry in entries.Skip(skip))
                grid.AddRow(
                    new Text(entry.Time, Muted),
                    new Markup(entry.Level switch { "ERROR" => "[bold red]ERROR[/]", "WARN" => "[yellow]WARN[/]", var level => "[grey62]" + Markup.Escape(level) + "[/]" }),
                    new Text(Tidy(entry.Message), entry.Level == "ERROR" ? new Style(Color.Red) : Style.Plain));
            return grid;
        }
        var skip = Math.Max(0, entries.Count - rows);
        var shown = Build(skip);
        // Long messages wrap onto extra rows; drop the oldest until the page fits.
        while (skip < entries.Count - 1 && shown.GetSegments(AnsiConsole.Console).Sum(s => s.Text.Count(c => c == '\n')) > rows)
            shown = Build(++skip);
        return shown;
    }

    // Display only: drop the loopback client port mihomo prints on every line, flags, and the home prefix.
    private static string Tidy(string message) =>
        Plain(Tilde(System.Text.RegularExpressions.Regex.Replace(message, @"127\.0\.0\.1:\d+ --> ", "")));

    private static string Tilde(string path)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return path.Replace(home + "/", "~/");
    }

    // Regional-indicator flags render as stray letters in many terminals and break column widths.
    private static string Plain(string name) =>
        System.Text.RegularExpressions.Regex.Replace(name, @"(\uD83C[\uDDE6-\uDDFF])+\s*", "").Trim();

    private static readonly Style Muted = new(Color.Grey62);
    private static readonly Style Highlight = new(foreground: Color.Black, background: Color.Yellow, decoration: Decoration.Bold);

    private async Task Kernel()
    {
        while (true)
        {
            var settings = local.Load();
            var status = local.Service.Status();
            var grid = new Grid().AddColumn(new GridColumn().NoWrap().PadRight(2)).AddColumn();
            void Row(string label, string value) => grid.AddRow(new Markup("[grey62]" + label + "[/]"), new Markup(value));
            var version = "";
            try
            {
                var path = MihomoKernel.Resolve(settings.MihomoPath);
                MihomoKernel.EnsureExecutable(path);
                var line = VersionLine(path);
                version = MihomoKernel.ParseVersion(line);
                var build = version.Length == 0 ? line : line[(line.IndexOf(version, StringComparison.Ordinal) + version.Length)..].Trim();
                Row("版本", "[bold]" + Markup.Escape(version.Length == 0 ? "未知" : version) + "[/]  [grey62]" + Markup.Escape(build) + "[/]");
                Row("来源", KernelSource(settings, path));
                Row("路径", Markup.Escape(path));
                Row("进程", RunningKernel(status, path) ?? "[grey62]未运行[/]");
            }
            catch (InvalidOperationException ex)
            {
                Row("路径", "[yellow]" + Markup.Escape(ex.Message) + "[/]");
            }
            if (status.Running)
            {
                try
                {
                    var (up, down, count) = await ClashApi.TrafficAsync(settings.Controller, CancellationToken.None);
                    Row("流量", "↑ " + Size(up) + "  ↓ " + Size(down) + "  [grey62]" + count + " 条连接[/]");
                }
                catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException or TaskCanceledException or JsonException) { }
            }
            AnsiConsole.Clear();
            AnsiConsole.Write(new Panel(grid)
            {
                Header = new PanelHeader(" mihomo 内核 ", Justify.Left),
                Border = BoxBorder.Rounded,
                BorderStyle = new Style(Color.Grey42),
                Padding = new Padding(1, 0, 1, 0)
            });
            AnsiConsole.WriteLine();
            var custom = !string.IsNullOrWhiteSpace(settings.MihomoPath);
            var actions = new List<string> { "检查配置", "在线更新", "指定内核文件" };
            if (custom) actions.Add("恢复内置内核");
            actions.Add("返回");
            var index = Pick(actions, title: "[grey62]内核[/]", wrap: true);
            if (index < 0 || actions[index] == "返回") return;
            try
            {
                switch (actions[index])
                {
                    case "检查配置":
                        local.Service.Prepare(settings);
                        Pause(await ConfigCheck.RunAsync(MihomoKernel.Resolve(settings.MihomoPath), local.Store));
                        break;
                    case "在线更新": await UpdateKernel(settings, status, version); break;
                    case "指定内核文件": PickKernel(settings); break;
                    case "恢复内置内核":
                        settings.MihomoPath = "";
                        if (File.Exists(DownloadedKernel)) File.Delete(DownloadedKernel);
                        Save(settings);
                        break;
                }
            }
            catch (Back)
            {
            }
        }
    }

    private string DownloadedKernel => Path.Combine(local.Store.StoreDirectory, "kernel", "mihomo");

    private string KernelSource(ClashProxySettings settings, string path)
    {
        if (string.IsNullOrWhiteSpace(settings.MihomoPath)) return path == MihomoKernel.Bundled() ? "内置" : "PATH";
        return path == DownloadedKernel ? "在线更新" : "自定义";
    }

    // Markup for the live kernel process, or null when the service is down.
    private static string? RunningKernel(ClashProxyStatus status, string configured)
    {
        if (!status.Running || status.MihomoPid is not int pid) return null;
        try
        {
            using var process = Process.GetProcessById(pid);
            var text = "[grey62]pid " + pid + " · " + Size(process.WorkingSet64) + " · " + Uptime(DateTime.Now - process.StartTime) + "[/]";
            return Runs(pid, configured) ? text : text + "  [yellow]重启后换内核[/]";
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { return null; }
    }

    // /proc/self/fd gives the canonical path, so symlinked folders still match; a replaced binary reads "… (deleted)".
    private static bool Runs(int pid, string path)
    {
        try
        {
            using var file = File.OpenHandle(path);
            return File.ResolveLinkTarget("/proc/" + pid + "/exe", false)?.FullName
                == File.ResolveLinkTarget("/proc/self/fd/" + file.DangerousGetHandle(), false)?.FullName;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return true; }
    }

    private void PickKernel(ClashProxySettings settings)
    {
        var path = Environment.ExpandEnvironmentVariables(Ask("mihomo 文件的绝对路径", settings.MihomoPath).Trim());
        if (path.Length == 0 || path == settings.MihomoPath) return;
        if (!File.Exists(path)) throw new InvalidOperationException("找不到 " + path);
        MihomoKernel.EnsureExecutable(path);
        var version = MihomoKernel.ParseVersion(MihomoKernel.VersionLine(path));
        if (version.Length == 0) throw new InvalidOperationException(path + " 没有输出 mihomo 版本，没有保存。");
        settings.MihomoPath = Path.GetFullPath(path);
        AnsiConsole.MarkupLine("内核 [bold]{0}[/]", Markup.Escape(version));
        Save(settings);
    }

    private async Task UpdateKernel(ClashProxySettings settings, ClashProxyStatus status, string current)
    {
        // Through our own HTTP port when it is up: the generated rules send GitHub via the relay group.
        using var handler = status.Running ? new HttpClientHandler { Proxy = new WebProxy("http://127.0.0.1:" + settings.HttpPort) } : new HttpClientHandler();
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(5) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("codex-switch");
        var tag = "";
        await AnsiConsole.Status().StartAsync("查询 MetaCubeX/mihomo 最新版本", async _ =>
        {
            using var doc = JsonDocument.Parse(await http.GetStringAsync("https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"));
            tag = doc.RootElement.TryGetProperty("tag_name", out var name) ? name.GetString() ?? "" : "";
        });
        if (tag.Length == 0) throw new InvalidOperationException("GitHub 没有返回最新版本号。");
        if (tag == current) { Pause("已是最新 " + tag); return; }
        var asset = MihomoKernel.ReleaseAsset(tag) ?? throw new InvalidOperationException("没有适合当前架构的 mihomo 发布包。");
        if (!Confirm((current.Length == 0 ? "未知" : current) + " → " + tag + "，下载 " + asset + "？")) return;
        var target = DownloadedKernel;
        var temp = target + ".download";
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        await AnsiConsole.Status().StartAsync("下载 " + asset, async ctx =>
        {
            using var response = await http.GetAsync("https://github.com/MetaCubeX/mihomo/releases/download/" + tag + "/" + asset, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength;
            await using var source = await response.Content.ReadAsStreamAsync();
            using var packed = new MemoryStream();
            var chunk = new byte[81920];
            int n;
            while ((n = await source.ReadAsync(chunk)) > 0)
            {
                packed.Write(chunk, 0, n);
                ctx.Status("下载 " + asset + "  " + Size(packed.Length) + (total is long all ? " / " + Size(all) : ""));
            }
            packed.Position = 0;
            await using var gzip = new GZipStream(packed, CompressionMode.Decompress);
            await using var file = File.Create(temp);
            await gzip.CopyToAsync(file);
        });
        MihomoKernel.EnsureExecutable(temp);
        var got = MihomoKernel.ParseVersion(MihomoKernel.VersionLine(temp));
        if (got != tag)
        {
            File.Delete(temp);
            throw new InvalidOperationException("下载的内核报告版本「" + got + "」，不是 " + tag + "，没有替换。");
        }
        // Rename over the old file: a running kernel keeps its inode, so this never hits ETXTBSY.
        File.Move(temp, target, true);
        settings.MihomoPath = target;
        AnsiConsole.MarkupLine("内核已更新到 [bold]{0}[/]", Markup.Escape(tag));
        Save(settings);
    }

    private void Boot(ClashProxySettings settings)
    {
        if (!SystemdUnit.Available()) throw new InvalidOperationException("没有找到 systemctl。");
        if (SystemdUnit.IsEnabled())
        {
            if (!Confirm("取消开机启动并停止服务？")) return;
            SystemdUnit.Remove();
            local.Service.Stop();
            Pause("已取消开机启动");
            return;
        }
        if (!Confirm("写入用户级 systemd 并现在启动？")) return;
        local.Service.Check(settings);
        local.InstallBoot();
        Pause("已启用 " + SystemdUnit.Name);
    }

    private void Save(ClashProxySettings settings)
    {
        local.Store.Save(settings);
        if (local.Service.Status().Running && Confirm("配置已保存。现在重启？"))
            Pause(local.Restart(settings).Detail);
        else Pause("已保存");
    }

    private string VersionLine(string path)
    {
        var stamp = File.GetLastWriteTimeUtc(path);
        if (versionCache is { } cached && cached.Path == path && cached.Stamp == stamp) return cached.Line;
        var line = MihomoKernel.VersionLine(path);
        versionCache = (path, stamp, line);
        return line;
    }

    private string VersionOf(string path)
    {
        var version = MihomoKernel.ParseVersion(VersionLine(path));
        return version.Length == 0 ? "未知" : version;
    }

    private static string Size(long bytes) => bytes >= 1L << 30
        ? (bytes / (double)(1L << 30)).ToString("0.00") + " GB"
        : (bytes / (double)(1L << 20)).ToString("0.0") + " MB";

    private static string Uptime(TimeSpan span) =>
        span.TotalDays >= 1 ? (int)span.TotalDays + "d" + span.Hours + "h"
        : span.TotalHours >= 1 ? span.Hours + "h" + span.Minutes + "m"
        : span.Minutes + "m" + span.Seconds + "s";

    private static string ProcessLine(int? pid)
    {
        if (pid is not int value) return "没有进程号。";
        try
        {
            using var process = Process.GetProcessById(value);
            return "pid " + value + "  内存 " + Size(process.WorkingSet64) + "  已运行 " + Uptime(DateTime.Now - process.StartTime);
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { return "进程已退出。"; }
    }

    private const string BackHint = "[grey42]esc 返回[/]";

    // Escape cancels the whole form. Callers reload settings, so fields already typed are not saved.
    private sealed class Back : Exception { }

    private static string Ask(string label, string current)
    {
        var hasDefault = !string.IsNullOrEmpty(current);
        WritePrompt(label, hasDefault ? current : null);
        var input = ReadLine();
        if (input is null) throw new Back();
        if (string.IsNullOrWhiteSpace(input))
        {
            if (hasDefault) AnsiConsole.Write(current);
            AnsiConsole.WriteLine();
            return hasDefault ? current : "";
        }
        AnsiConsole.WriteLine();
        return input;
    }

    private static string AskSecret(string label)
    {
        AnsiConsole.Markup(BackHint + "  " + Markup.Escape(label.TrimEnd()) + " ");
        var input = ReadLine(secret: true);
        if (input is null) throw new Back();
        AnsiConsole.WriteLine();
        return input;
    }

    private static int AskInt(string label, int current)
    {
        while (true)
        {
            WritePrompt(label, current.ToString());
            var input = ReadLine();
            if (input is null) throw new Back();
            if (string.IsNullOrWhiteSpace(input))
            {
                AnsiConsole.Write(current.ToString());
                AnsiConsole.WriteLine();
                return current;
            }
            AnsiConsole.WriteLine();
            if (int.TryParse(input.Trim(), out var value) && value is >= 0 and <= 65535) return value;
            AnsiConsole.MarkupLine("0-65535");
        }
    }

    private static bool Confirm(string message, bool yes = true)
    {
        while (true)
        {
            AnsiConsole.Markup(Markup.Escape(message.TrimEnd()) + " [blue][[y/n]][/] [green](" + (yes ? "y" : "n") + ")[/]: ");
            var input = ReadLine();
            if (input is null) return false;
            AnsiConsole.WriteLine();
            if (string.IsNullOrWhiteSpace(input)) return yes;
            if (input.Equals("y", StringComparison.OrdinalIgnoreCase)) return true;
            if (input.Equals("n", StringComparison.OrdinalIgnoreCase)) return false;
            AnsiConsole.MarkupLine("请输入 y 或 n");
        }
    }

    private static void WritePrompt(string label, string? current)
    {
        var text = BackHint + "  " + Markup.Escape(label.TrimEnd());
        if (!string.IsNullOrEmpty(current)) text += " [green](" + Markup.Escape(current) + ")[/]:";
        AnsiConsole.Markup(text + " ");
    }

    // null means Escape. A pasted line arrives as a burst of keys, same as Spectre's reader.
    private static string? ReadLine(bool secret = false)
    {
        var text = "";
        while (true)
        {
            var key = Console.ReadKey(true);
            if (key.Key == ConsoleKey.Escape)
            {
                AnsiConsole.WriteLine();
                return null;
            }
            if (key.Key == ConsoleKey.Enter) return text;
            if (key.Key == ConsoleKey.Backspace)
            {
                if (text.Length == 0) continue;
                var cut = text.Length >= 2 && char.IsSurrogatePair(text, text.Length - 2) ? 2 : 1;
                var width = Math.Max(1, text[^cut..].GetCellWidth());
                text = text[..^cut];
                AnsiConsole.Write(new string('\b', width) + new string(' ', width) + new string('\b', width));
                continue;
            }
            if (char.IsControl(key.KeyChar)) continue;
            text += key.KeyChar;
            AnsiConsole.Write(secret ? "*" : key.KeyChar.ToString());
        }
    }

    // Choices are markup. The highlighted row is plain, black on yellow, matching the old selection prompt.
    private static int Pick(IReadOnlyList<string> choices, string? title = null, int pageSize = 10, bool wrap = false, string? more = null, bool back = true)
    {
        var size = pageSize <= 0 ? choices.Count : Math.Min(pageSize, choices.Count);
        var cursor = 0;
        var window = 0;
        return AnsiConsole.Live(Menu(choices, cursor, window, size, title, more, back))
            .AutoClear(true)
            .Overflow(VerticalOverflow.Visible)
            .Start(ctx =>
            {
                ctx.Refresh();
                while (true)
                {
                    var key = Console.ReadKey(true);
                    if (back && key.Key == ConsoleKey.Escape) return -1;
                    if (key.Key is ConsoleKey.Enter or ConsoleKey.Spacebar or ConsoleKey.Packet) return cursor;
                    var next = key.Key switch
                    {
                        ConsoleKey.UpArrow => cursor == 0 ? (wrap ? choices.Count - 1 : 0) : cursor - 1,
                        ConsoleKey.DownArrow => cursor == choices.Count - 1 ? (wrap ? 0 : cursor) : cursor + 1,
                        _ => -1
                    };
                    if (next < 0 || next == cursor) continue;
                    cursor = next;
                    if (cursor < window) window = cursor;
                    else if (cursor >= window + size) window = cursor - size + 1;
                    ctx.UpdateTarget(Menu(choices, cursor, window, size, title, more, back));
                }
            });
    }

    private static Spectre.Console.Rendering.IRenderable Menu(IReadOnlyList<string> choices, int cursor, int window, int size, string? title, string? more, bool back)
    {
        var rows = new List<Spectre.Console.Rendering.IRenderable>();
        if (title != null) rows.Add(new Markup(title));
        var grid = new Grid();
        grid.AddColumn(new GridColumn().Padding(0, 0, 1, 0).NoWrap());
        if (title != null) grid.AddEmptyRow();
        for (var i = 0; i < size; i++)
        {
            var index = window + i;
            var current = index == cursor;
            var text = current ? choices[index].RemoveMarkup().EscapeMarkup() : choices[index];
            grid.AddRow(new Markup((current ? ">" : " ") + " " + text, current ? Highlight : Style.Plain));
        }
        rows.Add(grid);
        if (choices.Count > size)
        {
            rows.Add(Text.Empty);
            rows.Add(new Markup(more ?? "[grey](Move up and down to reveal more choices)[/]"));
        }
        if (back) rows.Add(new Markup(BackHint));
        return new Rows(rows);
    }

    private static void Pause(string message)
    {
        if (message.Length > 0) AnsiConsole.WriteLine(message.Length > 2000 ? message[..2000] : message);
        AnsiConsole.MarkupLine("[grey62]回车继续 · esc 返回[/]");
        while (Console.ReadKey(true).Key is not (ConsoleKey.Enter or ConsoleKey.Escape)) { }
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
