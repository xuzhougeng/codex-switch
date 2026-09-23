using CodexSwitch.Core;

namespace CodexSwitch.Linux;

sealed class LocalService
{
    public ClashProxyStore Store { get; } = ClashProxyStore.CreateLinux();
    public MihomoService Service { get; }

    public LocalService()
    {
        Service = new MihomoService(Store);
        RetargetLegacyUnit();
    }

    private void RetargetLegacyUnit()
    {
        if (!SystemdUnit.Available() || !File.Exists(SystemdUnit.UnitPath)) return;
        var text = File.ReadAllText(SystemdUnit.UnitPath);
        if (!text.Contains("/.codex", StringComparison.Ordinal)) return;
        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable)) return;
        SystemdUnit.Install(executable, Store.Home);
    }

    public ClashProxySettings Load() => File.Exists(Store.SettingsPath) ? Store.Load() : new ClashProxySettings();

    public ClashProxyStatus Start(ClashProxySettings settings)
    {
        if (SystemdUnit.IsEnabled())
        {
            Service.Prepare(settings);
            if (SystemdUnit.IsActive()) SystemdUnit.Restart();
            else SystemdUnit.Start();
            return WaitReady();
        }
        return Service.Start(settings);
    }

    public ClashProxyStatus Restart(ClashProxySettings settings)
    {
        Stop();
        return Start(settings);
    }

    public void Stop()
    {
        if (SystemdUnit.IsActive()) SystemdUnit.Stop();
        Service.Stop();
    }

    public void InstallBoot()
    {
        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) || !File.Exists(executable))
            throw new InvalidOperationException("找不到当前程序路径，不能写入开机启动。");
        Service.Stop();
        SystemdUnit.Install(executable, Store.Home);
        SystemdUnit.Start();
        WaitReady();
    }

    public ClashProxyStatus WaitReady()
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        var status = Service.Status();
        while (DateTime.UtcNow < deadline && !status.Running)
        {
            Thread.Sleep(150);
            status = Service.Status();
        }
        if (!status.Running)
            throw new InvalidOperationException(status.Detail + "\n" + Tail(Store.ServiceLogPath) + "\n" + Tail(Store.MihomoLogPath));
        return status;
    }

    private static string Tail(string path)
    {
        try
        {
            if (!File.Exists(path)) return "";
            return string.Join('\n', File.ReadAllLines(path).TakeLast(12));
        }
        catch (IOException) { return ""; }
    }
}
