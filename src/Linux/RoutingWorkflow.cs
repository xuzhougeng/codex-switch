using CodexSwitch.Core;

namespace CodexSwitch.Linux;

public static class RoutingWorkflow
{
    public static async Task<string> ApplyAsync(ClashProxyStore store, bool running, ClashProxySettings draft)
    {
        draft.Routing.Validate(draft.HomeEnabled);
        if (!running)
        {
            if (DialerProxyBuilder.ExtractRelayNames(draft.RelayYaml).Count > 0)
                DialerProxyBuilder.Build(ClashProxyStore.ToInput(draft, false));
            store.Save(draft);
            return "规则已保存，启动代理后生效。";
        }
        var active = store.RunningSettings().Copy();
        if (active.HomeEnabled != draft.HomeEnabled || (active.HomeEnabled &&
            (active.HomeServer != draft.HomeServer || active.HomePort != draft.HomePort || active.HomeUsername != draft.HomeUsername || active.HomePassword != draft.HomePassword)))
            throw new InvalidOperationException("家宽配置已更改，请先重启服务，再应用分流规则。");
        active.Routing = draft.Routing;
        active.ProxyOtherSites = draft.ProxyOtherSites;
        active.SelectedDevelopment = draft.SelectedDevelopment;
        var relay = await ClashApi.GroupAsync(active.Controller, active.RelayGroup, CancellationToken.None);
        var exit = await ClashApi.GroupAsync(active.Controller, active.ExitGroup, CancellationToken.None);
        active.SelectedRelay = relay.Now;
        active.SelectedExit = exit.Now;
        var names = DialerProxyBuilder.ExtractRelayNames(active.RelayYaml);
        if (!names.Contains(active.SelectedDevelopment)) active.SelectedDevelopment = "";
        var files = DialerProxyBuilder.Build(ClashProxyStore.ToInput(active, false));
        await CheckAsync(store, active);
        store.Save(draft);
        await ClashApi.ReloadAsync(active.Controller, files.Yaml, CancellationToken.None);
        store.WriteRuntime(active, false);
        store.SaveRunning(active);
        foreach (var (group, name) in DialerProxyBuilder.LiveSelections(active))
            await ClashApi.SelectAsync(active.Controller, group, name, CancellationToken.None, "恢复出口选择失败");
        return "分流规则已保存并应用，无需重启服务。";
    }

    public static async Task<string> CheckAsync(ClashProxyStore store, ClashProxySettings settings)
    {
        var directory = Path.Combine(Path.GetTempPath(), "codex-switch-rules-" + Guid.NewGuid().ToString("N"));
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
        else Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try
        {
            var temporary = new ClashProxyStore(directory);
            temporary.WriteRuntime(settings, false);
            return await ConfigCheck.RunAsync(MihomoKernel.Resolve(settings.MihomoPath), temporary);
        }
        finally { Directory.Delete(directory, true); }
    }
    public static string Preview(ClashProxySettings settings)
    {
        var yaml = DialerProxyBuilder.Build(ClashProxyStore.ToInput(settings, false)).Yaml.Replace("\r\n", "\n");
        return "rules:\n" + yaml[(yaml.IndexOf("\nrules:\n", StringComparison.Ordinal) + 8)..];
    }
}
