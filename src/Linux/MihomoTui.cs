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
                    case "内核": await Kernel(); break;
                    case "Shell 命令": Pause(ShellSetup.Install()); break;
                    case "开机启动": Boot(settings); break;
                }
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
        var kernel = KernelLine(settings, status);
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

    private string KernelLine(ClashProxySettings settings, ClashProxyStatus status)
    {
        try
        {
            var path = MihomoKernel.Resolve(settings.MihomoPath);
            var line = "[grey]内核[/] [bold]" + Markup.Escape(VersionOf(path)) + "[/] [grey]" + KernelSource(settings, path) + "[/]";
            var running = RunningKernel(status, path);
            return running == null ? line : line + "   " + running;
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

    private async Task Kernel()
    {
        while (true)
        {
            var settings = local.Load();
            var status = local.Service.Status();
            var grid = new Grid().AddColumn(new GridColumn().NoWrap().PadRight(2)).AddColumn();
            void Row(string label, string value) => grid.AddRow(new Markup("[grey]" + label + "[/]"), new Markup(value));
            var version = "";
            try
            {
                var path = MihomoKernel.Resolve(settings.MihomoPath);
                MihomoKernel.EnsureExecutable(path);
                var line = VersionLine(path);
                version = MihomoKernel.ParseVersion(line);
                var build = version.Length == 0 ? line : line[(line.IndexOf(version, StringComparison.Ordinal) + version.Length)..].Trim();
                Row("版本", "[bold]" + Markup.Escape(version.Length == 0 ? "未知" : version) + "[/]  [grey]" + Markup.Escape(build) + "[/]");
                Row("来源", KernelSource(settings, path));
                Row("路径", Markup.Escape(path));
                Row("进程", RunningKernel(status, path) ?? "[grey]未运行[/]");
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
                    Row("流量", "↑ " + Size(up) + "  ↓ " + Size(down) + "  [grey]" + count + " 条连接[/]");
                }
                catch (Exception ex) when (ex is InvalidOperationException or HttpRequestException or TaskCanceledException or JsonException) { }
            }
            AnsiConsole.Clear();
            AnsiConsole.Write(new Panel(grid)
            {
                Header = new PanelHeader(" mihomo 内核 ", Justify.Left),
                Border = BoxBorder.Rounded,
                BorderStyle = new Style(Color.Grey),
                Padding = new Padding(1, 0, 1, 0)
            });
            AnsiConsole.WriteLine();
            var custom = !string.IsNullOrWhiteSpace(settings.MihomoPath);
            var actions = new List<string> { "检查配置", "在线更新", "指定内核文件" };
            if (custom) actions.Add("恢复内置内核");
            actions.Add("返回");
            var pick = AnsiConsole.Prompt(new SelectionPrompt<string>()
                .Title("[grey]内核[/]")
                .WrapAround()
                .HighlightStyle(new Style(foreground: Color.Black, background: Color.Yellow, decoration: Decoration.Bold))
                .AddChoices(actions));
            switch (pick)
            {
                case "返回": return;
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
            var text = "[grey]pid " + pid + " · " + Size(process.WorkingSet64) + " · " + Uptime(DateTime.Now - process.StartTime) + "[/]";
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
        if (!AnsiConsole.Confirm((current.Length == 0 ? "未知" : current) + " → " + tag + "，下载 " + asset + "？")) return;
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
