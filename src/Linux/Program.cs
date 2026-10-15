namespace CodexSwitch.Linux;

static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length == 0) return await new MihomoTui().RunAsync();
            return args[0] switch
            {
                "start" => Cli.Start(),
                "stop" => Cli.Stop(),
                "restart" => Cli.Restart(),
                "status" => Cli.Status(),
                "logs" => Cli.Logs(),
                "shell" => Cli.Shell(),
                "rules" => await Cli.Rules(args.Skip(1).ToArray()),
                "serve" => await MihomoDaemon.RunAsync(args),
                _ => Cli.Usage()
            };
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or HttpRequestException or TaskCanceledException or System.Text.Json.JsonException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }
}

static class Cli
{
    public static async Task<int> Rules(string[] args)
    {
        var local = new LocalService();
        var settings = local.Load();
        if (args.Length == 0 || args is ["show"])
        {
            Console.Write(RoutingWorkflow.Preview(settings));
            return 0;
        }
        if (args is ["check"])
        {
            Console.WriteLine(await RoutingWorkflow.CheckAsync(local.Store, settings)); return 0;
        }
        if (args is ["apply"])
        {
            Console.WriteLine(await RoutingWorkflow.ApplyAsync(local.Store, local.Service.Status().Running, settings)); return 0;
        }
        if (args is ["import", var path])
        {
            if (new FileInfo(path).Length > 2_000_000) throw new InvalidOperationException("规则文件超过 2 MB。");
            var rules = CodexSwitch.Core.RoutingRule.ImportClash(File.ReadAllText(path), CodexSwitch.Core.ClashProxyStore.ToInput(settings));
            settings.Routing.CustomRules.AddRange(rules);
            settings.Routing.Validate(settings.HomeEnabled);
            local.Store.Save(settings);
            Console.WriteLine($"已保存 {rules.Count} 条规则；运行中使用 rules apply 应用。"); return 0;
        }
        if (args is ["preset", var name])
        {
            CodexSwitch.Core.RoutingConfiguration.ApplyPreset(settings, name switch { "ai-only" => "aiOnly", "all-proxy" => "allProxy", _ => name });
            local.Store.Save(settings);
            Console.WriteLine("方案已保存；运行中使用 rules apply 应用。"); return 0;
        }
        Console.Error.WriteLine("codex-switch rules [show|check|apply|import FILE|preset smart|ai-only|all-proxy]");
        return 1;
    }
    public static int Start()
    {
        var local = new LocalService();
        var status = local.Start(local.Load());
        PrintReady(local, status);
        return 0;
    }

    public static int Restart()
    {
        var local = new LocalService();
        var status = local.Restart(local.Load());
        PrintReady(local, status);
        return 0;
    }

    public static int Stop()
    {
        new LocalService().Stop();
        Console.WriteLine("已停止");
        return 0;
    }

    public static int Status()
    {
        var local = new LocalService();
        var settings = local.Load();
        var status = local.Service.Status();
        Console.WriteLine(status.Detail);
        Console.WriteLine(MihomoTui.Chain(settings));
        try
        {
            var kernel = CodexSwitch.Core.MihomoKernel.Resolve(settings.MihomoPath);
            Console.WriteLine("内核 " + CodexSwitch.Core.MihomoKernel.ParseVersion(CodexSwitch.Core.MihomoKernel.VersionLine(kernel)) + "  " + kernel);
        }
        catch (InvalidOperationException) { }
        if (!status.Running) return 1;
        PrintExports(settings.HttpPort);
        return 0;
    }

    public static int Shell()
    {
        Console.WriteLine(ShellSetup.Install());
        return 0;
    }

    public static int Logs()
    {
        var store = new LocalService().Store;
        Print(store.LimiterLogPath);
        Print(store.MihomoLogPath);
        Print(store.ServiceLogPath);
        return 0;
    }

    public static int Usage()
    {
        Console.WriteLine("codex-switch            打开 mihomo 管理");
        Console.WriteLine("codex-switch start      按已保存的端口启动");
        Console.WriteLine("codex-switch stop");
        Console.WriteLine("codex-switch restart");
        Console.WriteLine("codex-switch status");
        Console.WriteLine("codex-switch logs");
        Console.WriteLine("codex-switch shell     写入 claude 和 codex 的代理函数");
        Console.WriteLine("codex-switch rules     预览 / 检查 / 应用 / 导入分流规则");
        return 1;
    }

    private static void PrintReady(LocalService local, CodexSwitch.Core.ClashProxyStatus status)
    {
        Console.WriteLine(status.Detail);
        Console.WriteLine(MihomoTui.Chain(local.Load()));
        PrintExports(local.Load().HttpPort);
    }

    private static void PrintExports(int port)
    {
        Console.WriteLine("export http_proxy=http://127.0.0.1:" + port);
        Console.WriteLine("export https_proxy=http://127.0.0.1:" + port);
    }

    private static void Print(string path)
    {
        Console.WriteLine("## " + path);
        if (!File.Exists(path)) { Console.WriteLine("(空)"); return; }
        foreach (var line in File.ReadAllLines(path).TakeLast(40)) Console.WriteLine(line);
    }
}
