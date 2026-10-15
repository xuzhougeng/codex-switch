using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using CodexSwitch.Core;
using CodexSwitch.Linux;

static class RoutingChecks
{
    public static async Task Run(string root, Action<bool, string> check, Action<Action, string> reject)
    {
        var store = new ClashProxyStore(Path.Combine(root, "routing"));
        new MihomoService(new ClashProxyStore(Path.Combine(root, "never-started")), new RoutingFakeHost()).Stop();
        check(true, "stopping a never-started service needs no configuration directory");
        Directory.CreateDirectory(store.StoreDirectory);
        File.WriteAllText(store.SettingsPath, """{"homeServer":"home.example","homePassword":"old-secret","socksProfiles":[{"id":"keep-me"}]}""");
        var legacy = store.Load();
        check(legacy.HomeEnabled && !legacy.ProxyOtherSites && legacy.Routing.Development == "development", "legacy routing and enabled residential settings migrate");
        store.Save(legacy);
        using (var doc = JsonDocument.Parse(File.ReadAllText(store.SettingsPath)))
            check(doc.RootElement.GetProperty("socksProfiles")[0].GetProperty("id").GetString() == "keep-me", "unknown macOS settings survive TUI saves");
        var settings = new ClashProxySettings
        {
            RelayYaml = "- name: HK-broken\n  type: socks5\n  server: 127.0.0.1\n  port: 1\n- name: Japan\n  type: socks5\n  server: 127.0.0.1\n  port: 1\n",
            SelectedExit = "Japan", SelectedRelay = "HK-broken", UseHomeProxy = false
        };
        var yaml = DialerProxyBuilder.Build(ClashProxyStore.ToInput(settings, false)).Yaml.Replace("\r\n", "\n");
        check(!yaml.Contains("name: target-socks5") && yaml.Contains("DOMAIN-SUFFIX,claude.ai,exit-group"), "single-hop configuration needs neither residential host nor limiter");
        check(yaml.Contains("type: fallback") && yaml.Contains("DOMAIN-SUFFIX,githubassets.com,hk-group"), "development traffic has fallback and GitHub assets rules");
        var imported = RoutingRule.ImportClash("rules:\n  - DOMAIN-SUFFIX,github.com,DIRECT\n  - \"IP-CIDR,192.168.0.0/16,exit-group,no-resolve\"\n  - NETWORK,tcp,REJECT", ClashProxyStore.ToInput(settings));
        check(imported.Count == 3 && imported[1].NoResolve && imported[2].Value == "TCP", "Clash rules import in order and normalize protocol values");
        settings.Routing.CustomRules = imported;
        settings.Routing.CustomRules.Add(new RoutingRule { Value = "disabled.example", Target = "reject", Enabled = false });
        yaml = DialerProxyBuilder.Build(ClashProxyStore.ToInput(settings)).Yaml;
        check(yaml.IndexOf("DOMAIN-SUFFIX,github.com,DIRECT", StringComparison.Ordinal) < yaml.IndexOf("DOMAIN-SUFFIX,github.com,hk-group", StringComparison.Ordinal) && !yaml.Contains("disabled.example"), "custom overrides win and disabled rules are omitted");
        foreach (var preset in new[] { "smart", "aiOnly", "allProxy" })
        {
            RoutingConfiguration.ApplyPreset(settings, preset);
            yaml = DialerProxyBuilder.Build(ClashProxyStore.ToInput(settings)).Yaml;
            check(settings.Routing.CustomRules.Count == 4 && settings.Routing.Preset(settings.ProxyOtherSites) == preset &&
                yaml.Contains("MATCH," + (preset == "allProxy" ? "exit-group" : "DIRECT")), "preset " + preset + " keeps overrides and sets final policy");
        }
        foreach (var bad in new[] { "MATCH,DIRECT", "RULE-SET,test,DIRECT", "IP-CIDR,999.0.0.0/32,DIRECT", "IP-CIDR6,::1/129,DIRECT", "DOMAIN,example.com,DIRECT,no-resolve", "DST-PORT,9000-8000,DIRECT", "NETWORK,ICMP,DIRECT", "DOMAIN,example.com,missing" })
            reject(() => RoutingRule.ImportClash(bad, ClashProxyStore.ToInput(settings)), "invalid import rejected: " + bad);
        reject(() => new RoutingRule { Value = "example.com\nrules:" }.Validated(), "rule newline injection rejected");
        var homeRule = new RoutingRule { Value = "home-only.example", Target = "residential" };
        settings.Routing.CustomRules.Add(homeRule);
        reject(() => DialerProxyBuilder.Build(ClashProxyStore.ToInput(settings)), "enabled custom residential rule requires the home service");
        homeRule.Enabled = false;
        store.Save(settings);
        var loaded = store.Load();
        check(loaded.Routing.CustomRules.Count == 5 && !loaded.HomeEnabled, "routing rules and explicit home disable round-trip");
        var preview = RoutingWorkflow.Preview(loaded);
        check(preview.StartsWith("rules:\n  - ") && preview.Contains("MATCH,exit-group") && !preview.Contains("proxies:"), "preview exports only the complete rule list");
        var selections = DialerProxyBuilder.LiveSelections(settings);
        check(selections.Contains((DialerProxyBuilder.HkGroup, DialerProxyBuilder.HkAutomaticGroup)), "startup restores development automatic mode");
        settings.SelectedDevelopment = "Japan";
        check(DialerProxyBuilder.LiveSelections(settings).Contains((DialerProxyBuilder.HkGroup, "Japan")), "startup restores a manual development exit");
        await RoutingWorkflow.ApplyAsync(store, false, settings);
        check(store.Load().SelectedDevelopment == "Japan", "stopped service saves routing without launching anything");
        var fake = new RoutingFakeHost();
        var service = new MihomoService(store, fake) { RequireListen = true };
        store.SaveRunning(settings);
        File.WriteAllText(store.ServicePidPath, "10");
        check(service.Status().Running, "single-hop readiness does not require a limiter port");
        var draft = settings.Copy(); draft.HttpPort = 29999; store.Save(draft);
        check(service.Status().Running, "readiness uses active ports rather than saved pending changes");
        var kernel = Environment.GetEnvironmentVariable("CODEX_SWITCH_TEST_KERNEL");
        if (!string.IsNullOrWhiteSpace(kernel)) await KernelCheck(root, settings, kernel, check);
        else Console.WriteLine("SKIP real-kernel routing checks: set CODEX_SWITCH_TEST_KERNEL");
    }

    private static async Task KernelCheck(string root, ClashProxySettings original, string kernel, Action<bool, string> check)
    {
        var store = new ClashProxyStore(Path.Combine(root, "routing-kernel"));
        var settings = original.Copy(); settings.MihomoPath = kernel;
        var ports = new HashSet<int>();
        while (ports.Count < 4)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            ports.Add(((IPEndPoint)listener.LocalEndpoint).Port); listener.Stop();
        }
        var allocated = ports.ToArray();
        settings.HttpPort = allocated[0]; settings.SocksPort = allocated[1];
        settings.Controller = "127.0.0.1:" + allocated[2]; settings.LimiterListen = "127.0.0.1:" + allocated[3];
        await RoutingWorkflow.CheckAsync(store, settings);
        store.Save(settings); store.WriteRuntime(settings); store.SaveRunning(settings);
        var info = new ProcessStartInfo(kernel) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "-d", store.WorkDirectory, "-f", store.YamlPath }) info.ArgumentList.Add(arg);
        using var process = Process.Start(info)!;
        var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
        using var http = new HttpClient(new HttpClientHandler { UseProxy = false });
        var url = "http://" + settings.Controller;
        try
        {
            var ready = false;
            for (var i = 0; i < 100; i++)
            {
                // The controller starts before mihomo finishes installing proxy groups.
                try
                {
                    using var response = await http.GetAsync(url + "/proxies");
                    if (response.IsSuccessStatusCode)
                    {
                        using var proxies = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                        var groups = proxies.RootElement.GetProperty("proxies");
                        ready = groups.TryGetProperty(settings.RelayGroup, out _) && groups.TryGetProperty(settings.ExitGroup, out _);
                        if (ready) break;
                    }
                }
                catch (HttpRequestException) { }
                if (process.HasExited) throw new InvalidOperationException("Test kernel exited during startup: " + await stderr);
                await Task.Delay(50);
            }
            if (!ready) throw new TimeoutException("Test kernel did not finish loading proxy groups.");
            var draft = settings.Copy();
            draft.Routing.CustomRules = [new RoutingRule { Value = "example.com", Target = "reject" }];
            await RoutingWorkflow.ApplyAsync(store, true, draft);
            using var rules = JsonDocument.Parse(await http.GetStringAsync(url + "/rules"));
            check(rules.RootElement.GetProperty("rules")[0].GetProperty("proxy").GetString() == "REJECT" && !process.HasExited, "real mihomo applies custom rules without restarting");
            var before = File.ReadAllText(store.SettingsPath);
            draft.Routing.CustomRules[0].Value = "bad\nrule";
            try { await RoutingWorkflow.ApplyAsync(store, true, draft); throw new Exception("Invalid rule accepted"); }
            catch (InvalidOperationException) { }
            check(!process.HasExited && File.ReadAllText(store.SettingsPath) == before, "invalid draft keeps the running kernel and saved settings intact");
        }
        finally
        {
            if (!process.HasExited) process.Kill(true);
            await process.WaitForExitAsync(); await stdout; await stderr;
        }
    }
    private sealed class RoutingFakeHost : IProcessHost
    {
        public bool IsRunning(int pid) => pid == 10;
        public bool IsListening(string host, int port) => port == 1990;
        public int StartDetached(string file, IReadOnlyList<string> args, string cwd, string log) => throw new Exception("Unexpected start");
        public void Stop(int pid) { }
    }
}
