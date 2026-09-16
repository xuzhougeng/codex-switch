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
    Console.WriteLine("All core integration checks passed. Only synthetic credentials were used.");
}
finally { Directory.Delete(root, true); }
