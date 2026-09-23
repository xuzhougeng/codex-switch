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
                "serve" => await MihomoDaemon.RunAsync(args),
                _ => Cli.Usage()
            };
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }
}

static class Cli
{
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
