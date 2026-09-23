using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexSwitch.Core;

static byte[] Auth(string email, string refresh = "original", string? accountID = null)
{
    var claims = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
    { ["email"] = email, ["https://api.openai.com/auth"] = new { chatgpt_plan_type = "pro" } }))
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');
    return JsonSerializer.SerializeToUtf8Bytes(new { tokens = new { id_token = "test." + claims + ".not-a-real-token", access_token = "synthetic-only", account_id = accountID ?? email }, last_refresh = refresh });
}
static void Check(bool condition, string message) { if (!condition) throw new Exception(message); Console.WriteLine("PASS " + message); }
static void Reject(Action action, string message)
{
    try { action(); } catch (InvalidOperationException) { Console.WriteLine("PASS " + message); return; }
    throw new Exception("Expected rejection: " + message);
}

if (args.Length == 2 && args[0] == "--seed-demo")
{
    var demoPath = Path.GetFullPath(args[1]);
    if (Directory.Exists(demoPath)) throw new Exception("Demo destination must not already exist.");
    Directory.CreateDirectory(demoPath);
    var demo = new AccountStore(demoPath);
    demo.ImportLogin(Auth("research@example.com"));
    demo.ImportLogin(Auth("personal@example.com"));
    demo.ImportLogin(Auth("team@example.com"));
    Console.WriteLine("Created synthetic demo at " + demoPath);
    return;
}

var root = Path.Combine(Path.GetTempPath(), "codex-switch-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    var store = new AccountStore(root);
    Check(store.Read().Current == null && store.Read().Accounts.Count == 0, "empty state");
    store.ImportLogin(Auth("first@example.com"));
    store.ImportLogin(Auth("second@example.com"));
    Check(store.Read().Accounts.Count == 2, "login imports and preserves prior account");
    File.WriteAllBytes(store.AuthPath, Auth("second@example.com", "refreshed"));
    store.Switch("first@example.com");
    Check(store.Read().Current?.Email == "first@example.com", "switch selects target");
    store.Switch("second@example.com");
    Check(Encoding.UTF8.GetString(File.ReadAllBytes(store.AuthPath)).Contains("refreshed"), "switch preserves refreshed token snapshot");
    Check(Directory.GetFiles(Path.Combine(store.Store, "backups")).Length >= 3, "backup before replacing current auth");
    var before = File.ReadAllBytes(store.AuthPath);
    Reject(() => store.ImportLogin(Encoding.UTF8.GetBytes("{}")), "malformed import rejected");
    Check(before.SequenceEqual(File.ReadAllBytes(store.AuthPath)), "failed import preserves current auth bytes");
    File.WriteAllBytes(Path.Combine(store.Store, "first@example.com", "auth.json"), Auth("wrong@example.com"));
    Reject(() => store.Switch("first@example.com"), "mismatched snapshot rejected");
    Check(before.SequenceEqual(File.ReadAllBytes(store.AuthPath)), "failed switch preserves current login");
    store.Remove("second@example.com");
    Check(before.SequenceEqual(File.ReadAllBytes(store.AuthPath)), "removing current saved account does not log out");
    Check(store.Read().Accounts.Count == 1, "removed account disappears from index");
    store.Clear();
    Check(!File.Exists(store.AuthPath), "clear removes active auth after saving");
    Check(store.Read().Accounts.Any(a => a.Email == "second@example.com"), "clear preserves account snapshot");
    var indexPath = Path.Combine(store.Store, "accounts.json");
    var originalIndex = File.ReadAllBytes(indexPath);
    File.WriteAllText(indexPath, "invalid json");
    Reject(store.SaveCurrent, "missing current cannot overwrite corrupt index");
    Reject(() => store.Read(), "corrupt index surfaced");
    Check(File.ReadAllText(indexPath) == "invalid json", "corrupt index not silently replaced");
    File.WriteAllBytes(indexPath, originalIndex);
    using (var held = new FileStream(Path.Combine(store.Store, ".native.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        Reject(store.Clear, "concurrent mutation blocked");
    var malicious = JsonNode.Parse(File.ReadAllText(indexPath))!.AsObject();
    malicious[".."] = new JsonObject { ["email"] = "escape@example.com" };
    File.WriteAllText(indexPath, malicious.ToJsonString());
    Reject(() => store.Switch(".."), "parent traversal rejected");
    File.WriteAllBytes(indexPath, originalIndex);
    store.ImportLogin(Auth("second@example.com"));
    before = File.ReadAllBytes(store.AuthPath);
    Reject(() => store.ImportLogin(Auth("second@example.com", accountID: "another-workspace")), "same email workspace collision rejected");
    Check(before.SequenceEqual(File.ReadAllBytes(store.AuthPath)), "workspace collision preserves login");

    if (OperatingSystem.IsWindows())
    {
        var cliFolder = Path.Combine(root, "fake CLI with spaces");
        Directory.CreateDirectory(cliFolder);
        var cli = Path.Combine(cliFolder, "codex.cmd");
        var fixture = Path.Combine(root, "fixture.json");
        File.WriteAllBytes(fixture, Auth("new@example.com"));
        var oldPath = Environment.GetEnvironmentVariable("PATH");
        var oldFixture = Environment.GetEnvironmentVariable("CODEX_SWITCH_TEST_AUTH");
        Environment.SetEnvironmentVariable("PATH", cliFolder);
        Environment.SetEnvironmentVariable("CODEX_SWITCH_TEST_AUTH", fixture);
        try
        {
            File.WriteAllText(cli, "@copy /y \"%CODEX_SWITCH_TEST_AUTH%\" \"%CODEX_HOME%\\auth.json\" >nul\r\n@exit /b 0\r\n");
            await BrowserLogin.RunAsync(store, CancellationToken.None);
            Check(store.Read().Current?.Email == "new@example.com", "isolated CLI login succeeds from path with spaces");
            before = File.ReadAllBytes(store.AuthPath);
            File.WriteAllText(cli, "@exit /b 1\r\n");
            try { await BrowserLogin.RunAsync(store, CancellationToken.None); throw new Exception("Expected failed CLI"); }
            catch (InvalidOperationException) { }
            Check(before.SequenceEqual(File.ReadAllBytes(store.AuthPath)), "failed CLI login preserves current login");
            File.WriteAllText(cli, "@\"%SystemRoot%\\System32\\ping.exe\" -n 30 127.0.0.1 >nul\r\n");
            using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(400));
            try { await BrowserLogin.RunAsync(store, cancel.Token); throw new Exception("Expected cancellation"); }
            catch (OperationCanceledException) { }
            Check(before.SequenceEqual(File.ReadAllBytes(store.AuthPath)), "cancelled CLI login preserves current login");
            Check(!Directory.EnumerateDirectories(store.Store, ".login-*").Any(), "login staging cleaned after success failure and cancellation");
        }
        finally { Environment.SetEnvironmentVariable("PATH", oldPath); Environment.SetEnvironmentVariable("CODEX_SWITCH_TEST_AUTH", oldFixture); }
    }
    var relay = """
          - name: "relay-hk-01"
            type: ss
            server: relay1.example.com
            port: 443
        """;
    var built = DialerProxyBuilder.Build(new DialerProxyInput(relay, "38.121.23.194", "33225", "user", "secret"));
    Check(built.Yaml.Contains("server: 127.0.0.1"), "generated yaml points at local limiter");
    Check(built.Yaml.Contains("port: 1994"), "generated yaml uses limiter port");
    Check(!built.Yaml.Contains("secret"), "home password stays out of clash yaml");
    Check(built.Yaml.Contains("IP-CIDR,38.121.23.194/32,relay-group,no-resolve"), "home IP uses first hop to avoid a loop");
    Check(built.Yaml.Contains("DOMAIN-SUFFIX,openai.com,target-socks5"), "openai goes through the limiter target");
    Check(built.Yaml.Contains("DOMAIN,api.github.com,relay-group"), "github bypasses residential SOCKS");
    Check(built.Yaml.Contains("allow-lan: true"), "desktop yaml keeps lan on by default");
    Check(!built.Yaml.Contains("bind-address:"), "desktop yaml does not pin the bind address");
    var plain = DialerProxyBuilder.Build(new DialerProxyInput("- name: relay-plain\n  type: ss\n  server: example.com\n  port: 443\n", "1.2.3.4", "1080", "", ""));
    Check(plain.Yaml.Contains("\n  - name: relay-plain\n    type: ss\n"), "an unindented relay list is nested under proxies");
    Check(built.LimiterJson.Contains("\"upstream\": \"38.121.23.194:33225\""), "limiter json keeps home SOCKS");
    Check(built.LimiterPython.Contains("max_concurrent"), "embedded limiter script is present");
    Reject(() => DialerProxyBuilder.Build(new DialerProxyInput("", "1.2.3.4", "1", "", "")), "empty relay rejected");

    var clashHome = Path.Combine(root, "clash-home");
    var clashStore = new ClashProxyStore(clashHome);
    var pythonStub = Path.Combine(root, OperatingSystem.IsWindows() ? "python.exe" : "python3");
    var mihomoStub = Path.Combine(root, OperatingSystem.IsWindows() ? "mihomo.exe" : "mihomo");
    File.WriteAllText(pythonStub, "");
    File.WriteAllText(mihomoStub, "");
    var settings = new ClashProxySettings
    {
        RelayYaml = relay, HomeServer = "home.example.com", HomePort = "1080", HomePassword = "pw",
        PythonPath = pythonStub, MihomoPath = mihomoStub
    };
    clashStore.Save(settings);
    var loaded = clashStore.Load();
    Check(loaded.HomeServer == "home.example.com" && loaded.HomePassword == "pw", "clash settings round-trip");
    clashStore.Materialize(loaded);
    Check(File.ReadAllText(clashStore.YamlPath).Contains("DOMAIN,home.example.com,relay-group"), "hostname loop-avoidance");
    Check(File.Exists(clashStore.LimiterPythonPath), "limiter script written next to yaml");

    var fake = new FakeProcessHost();
    var runtime = new ClashProxyRuntime(clashStore, fake) { RequireListen = false };
    var started = runtime.Start(settings);
    Check(started.Running, "runtime reports running when both ports listen");
    Check(fake.Starts.Count == 2, "runtime starts limiter then mihomo");
    Check(fake.Starts[0].File.Contains("python"), "first process is python limiter");
    Check(fake.Starts[1].Args.Contains("-f"), "second process is mihomo -f");
    runtime.Stop();
    Check(fake.Stopped.Count == 2, "stop kills limiter and mihomo");

    var managedHome = Path.Combine(root, "managed");
    var managedStore = new ClashProxyStore(managedHome);
    var managedFake = new FakeProcessHost();
    var managedExe = Path.Combine(root, "codex-switch-stub");
    File.WriteAllText(managedExe, "");
    var managed = new MihomoService(managedStore, managedFake) { RequireListen = false, Executable = managedExe };
    var managedSettings = new ClashProxySettings
    {
        RelayYaml = relay, HomeServer = "home.example.com", HomePort = "1080", HomePassword = "pw",
        HttpPort = 2000, SocksPort = 2001, Controller = "127.0.0.1:2003", LimiterListen = "127.0.0.1:2004"
    };
    var managedStatus = managed.Start(managedSettings);
    Check(managedStatus.Running, "managed service reports running without python");
    Check(managedFake.Starts.Count == 1 && managedFake.Starts[0].Args.Contains("serve --detach"), "managed start launches the in-process serve command");
    Check(!File.Exists(managedStore.LimiterPythonPath), "managed start does not write a limiter script");
    var managedYaml = File.ReadAllText(managedStore.YamlPath);
    Check(managedYaml.Contains("port: 2000") && managedYaml.Contains("socks-port: 2001") && managedYaml.Contains("port: 2004"), "managed yaml uses the configured ports");
    Check(managedYaml.Contains("allow-lan: false") && managedYaml.Contains("bind-address: 127.0.0.1"), "managed yaml listens on loopback");
    Check(File.ReadAllText(managedStore.LimiterJsonPath).Contains("\"via\": \"127.0.0.1:2001\""), "limiter reaches the first hop on the socks port");
    managed.Stop();
    Check(managedFake.Stopped.Count >= 1, "managed stop kills the service");
    Reject(() => managed.Start(new ClashProxySettings { RelayYaml = relay, HomeServer = "home.example.com", HomePort = "1080", HttpPort = 1990, SocksPort = 1990 }), "shared ports rejected");

    var extracted = RelayImport.ExtractProxies("mixed: true\nproxies:\n  - name: relay-a\n    type: ss\nproxy-groups:\n  - name: g\n");
    Check(extracted.Contains("name: relay-a") && !extracted.Contains("proxy-groups"), "subscription import keeps the proxy list");
    Check(RelayImport.ExtractProxies("# comment\n- name: relay-b\n  type: ss").Contains("name: relay-b"), "a bare proxy list is accepted");
    Reject(() => RelayImport.ExtractProxies("rules:\n  - MATCH,DIRECT\n"), "subscription without proxies is rejected");

    var kernelDir = Path.Combine(root, "kernel-app");
    var archDir = Path.Combine(kernelDir, "kernel", MihomoKernel.ArchFolder);
    Directory.CreateDirectory(archDir);
    var kernelFile = Path.Combine(archDir, "mihomo");
    File.WriteAllText(kernelFile, "");
    Check(MihomoKernel.Bundled(kernelDir) == Path.GetFullPath(kernelFile), "bundled kernel resolves from the app directory");
    Check(MihomoKernel.Resolve(null, kernelDir) == Path.GetFullPath(kernelFile), "resolve prefers the bundled kernel");

    await SocksLimiterChecks.Run();
    Console.WriteLine("PASS in-process limiter forwards through the first hop and times out the queue");

    Console.WriteLine("All core integration checks passed. Only synthetic credentials were used.");
}
finally { Directory.Delete(root, true); }

sealed class FakeProcessHost : IProcessHost
{
    public int NextPid = 1000;
    public List<(string File, string Args)> Starts { get; } = [];
    public List<int> Stopped { get; } = [];
    public HashSet<int> Alive { get; } = [];
    public HashSet<string> Listening { get; } = new(StringComparer.Ordinal);
    public int StartDetached(string fileName, IReadOnlyList<string> arguments, string workDirectory, string logPath)
    {
        var pid = NextPid++;
        Alive.Add(pid);
        Starts.Add((fileName, string.Join(' ', arguments)));
        return pid;
    }
    public void Stop(int pid) { Alive.Remove(pid); Stopped.Add(pid); }
    public bool IsRunning(int pid) => Alive.Contains(pid);
    public bool IsListening(string host, int port) => Listening.Contains(host + ":" + port);
}
