using System.Text;
using System.Text.Json.Nodes;

namespace CodexSwitch.Core;

public sealed record Account(string Key, string Email, string Plan, string AccountId, bool IsCurrent)
{
    public string Subtitle => Plan + (IsCurrent ? "  ·  当前使用中" : "  ·  已保存到本机");
    public bool CanSwitch => !IsCurrent;
    public string Initial => string.IsNullOrEmpty(Email) ? "?" : Email[..1].ToUpperInvariant();
}
public sealed record StoreState(Account? Current, IReadOnlyList<Account> Accounts);

// Same on-disk format as the original PowerShell tool. Never log auth contents.
public sealed class AccountStore
{
    public string Home { get; }
    public string Store => Path.Combine(Home, "codex-switch");
    public string AuthPath => Path.Combine(Home, "auth.json");
    private string Index => Path.Combine(Store, "accounts.json");

    public AccountStore(string? home = null) => Home = Path.GetFullPath(home ??
        Environment.GetEnvironmentVariable("CODEX_HOME") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"));

    private FileStream Lock()
    {
        Directory.CreateDirectory(Store);
        try { return new FileStream(Path.Combine(Store, ".native.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new InvalidOperationException("另一个账号操作正在进行，请稍后刷新。"); }
    }

    private static JsonObject ReadObject(string path)
    {
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? throw new FormatException(); }
        catch (Exception e) when (e is System.Text.Json.JsonException or FormatException)
        { throw new InvalidOperationException("账号文件格式无效，请从备份恢复后重试。"); }
    }

    public static Account ParseAuth(byte[] data)
    {
        try
        {
            var auth = JsonNode.Parse(Encoding.UTF8.GetString(data).TrimStart('\uFEFF'))!;
            var tokens = auth["tokens"]!;
            var payload = tokens["id_token"]!.GetValue<string>().Split('.')[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
            var claims = JsonNode.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(payload)))!;
            var email = claims["email"]!.GetValue<string>();
            if (string.IsNullOrWhiteSpace(email) || string.IsNullOrWhiteSpace(tokens["access_token"]?.GetValue<string>()))
                throw new FormatException();
            return new(email, email, claims["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.GetValue<string>() ?? "unknown",
                tokens["account_id"]?.GetValue<string>() ?? "", true);
        }
        catch { throw new InvalidOperationException("无法读取 ChatGPT 登录信息。请使用 Codex CLI 登录，并使用文件凭据存储。"); }
    }

    private Account? Current() => File.Exists(AuthPath) ? ParseAuth(File.ReadAllBytes(AuthPath)) : null;
    private static bool Same(Account a, Account b) => a.Email.Equals(b.Email, StringComparison.OrdinalIgnoreCase) &&
        (a.AccountId.Length == 0 || b.AccountId.Length == 0 || a.AccountId == b.AccountId);

    private JsonObject Load()
    {
        if (File.Exists(Index)) return ReadObject(Index);
        var legacy = Path.Combine(Home, "codex-switch-app", "config", "accounts.json");
        if (File.Exists(legacy)) return ReadObject(legacy);
        var index = new JsonObject();
        if (Directory.Exists(Store))
            foreach (var dir in Directory.EnumerateDirectories(Store).Where(p => Path.GetFileName(p).Contains('@')))
            {
                var path = Path.Combine(dir, "auth.json");
                if (!File.Exists(path)) continue;
                var account = ParseAuth(File.ReadAllBytes(path));
                index[Path.GetFileName(dir)] = Metadata(account, File.ReadAllBytes(path));
            }
        return index;
    }

    private static Account Row(string key, JsonNode row) => new(key, row["email"]?.GetValue<string>() ?? key,
        row["plan"]?.GetValue<string>() ?? "unknown", row["account_id"]?.GetValue<string>() ?? "", false);

    public StoreState Read()
    {
        using var guard = Lock();
        var current = Current();
        var rows = Load().Select(p => Row(p.Key, p.Value ?? throw new InvalidOperationException("账号索引包含空记录。")))
            .Select(a => a with { IsCurrent = current != null && Same(a, current) })
            .OrderByDescending(a => a.IsCurrent).ThenBy(a => a.Email).ToArray();
        return new(current, rows);
    }

    private string AccountDirectory(string name)
    {
        var safe = string.Concat(name.Select(c => "<>:\"/\\|?*".Contains(c) || char.IsControl(c) ? '_' : c));
        if (string.IsNullOrWhiteSpace(safe) || safe.TrimEnd(' ', '.') != safe || safe is "." or ".." ||
            safe.Equals("backups", StringComparison.OrdinalIgnoreCase) || safe.StartsWith('.'))
            throw new InvalidOperationException("账号目录名称无效。");
        var path = Path.GetFullPath(Path.Combine(Store, safe));
        if (Path.GetDirectoryName(path) != Path.GetFullPath(Store)) throw new InvalidOperationException("账号路径无效。");
        if (Directory.Exists(path) && File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint))
            throw new InvalidOperationException("账号目录不能是符号链接。");
        return path;
    }

    private string Snapshot(string key, JsonNode row)
    {
        var names = new List<string> { key, row["email"]?.GetValue<string>() ?? key };
        if (row["legacy_names"] is JsonArray legacy) names.AddRange(legacy.Select(n => n?.GetValue<string>() ?? ""));
        foreach (var name in names.Where(n => n.Length > 0).Distinct())
        {
            var path = Path.Combine(AccountDirectory(name), "auth.json");
            if (File.Exists(path)) return path;
        }
        throw new InvalidOperationException("已保存的登录文件不存在，请重新登录该账号。");
    }

    private static void Atomic(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try { File.WriteAllBytes(temp, data); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    private void WriteIndex(JsonObject index) => Atomic(Index, Encoding.UTF8.GetBytes(index.ToJsonString()));
    private static JsonObject Metadata(Account a, byte[] data) => new()
    {
        ["email"] = a.Email, ["plan"] = a.Plan, ["account_id"] = a.AccountId,
        ["last_refresh"] = JsonNode.Parse(Encoding.UTF8.GetString(data).TrimStart('\uFEFF'))?["last_refresh"]?.DeepClone(),
        ["saved_at"] = DateTimeOffset.Now.ToString("O"), ["legacy_names"] = new JsonArray()
    };

    private void Save(JsonObject index, byte[] data)
    {
        var account = ParseAuth(data);
        var key = index.FirstOrDefault(p => p.Value != null && Same(Row(p.Key, p.Value), account)).Key ?? account.Email;
        if (index[key] is JsonNode existing && !Same(Row(key, existing), account))
            throw new InvalidOperationException("同一邮箱存在不同工作区的登录，请先移除旧快照再保存。");
        var row = Metadata(account, data);
        if (index[key]?["legacy_names"] is JsonNode legacy) row["legacy_names"] = legacy.DeepClone();
        var path = Path.Combine(AccountDirectory(key), "auth.json");
        Atomic(path, data);
        index[key] = row;
        WriteIndex(index);
    }

    public void SaveCurrent()
    {
        using var guard = Lock();
        if (!File.Exists(AuthPath)) throw new InvalidOperationException("未找到文件登录，请先登录新账号。");
        Save(Load(), File.ReadAllBytes(AuthPath));
    }

    private void Backup(string reason)
    {
        if (File.Exists(AuthPath)) Atomic(Path.Combine(Store, "backups", $"auth-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}-{reason}.json"), File.ReadAllBytes(AuthPath));
    }

    private void PreserveCurrent(JsonObject index)
    {
        if (File.Exists(AuthPath)) Save(index, File.ReadAllBytes(AuthPath));
    }

    public void Switch(string key)
    {
        using var guard = Lock();
        var index = Load();
        var row = index[key] ?? throw new InvalidOperationException("未找到账号，请刷新。");
        var data = File.ReadAllBytes(Snapshot(key, row));
        var target = ParseAuth(data);
        if (!Same(target, Row(key, row))) throw new InvalidOperationException("登录快照与账号索引不一致，请重新保存。");
        if (Current() is Account current && Same(current, target)) return;
        PreserveCurrent(index);
        Backup("switch");
        Atomic(AuthPath, data);
    }

    public void ImportLogin(byte[] data)
    {
        ParseAuth(data);
        using var guard = Lock();
        var index = Load();
        PreserveCurrent(index);
        Backup("login");
        Save(index, data);
        Atomic(AuthPath, data);
    }

    public void Clear()
    {
        using var guard = Lock();
        var index = Load();
        PreserveCurrent(index);
        Backup("clear");
        File.Delete(AuthPath);
    }

    public void Remove(string key)
    {
        using var guard = Lock();
        var index = Load();
        var row = index[key] ?? throw new InvalidOperationException("未找到账号，请刷新。");
        // Archive instead of recursively deleting credential directories. Current login is untouched.
        string? snapshot = null;
        try { snapshot = Snapshot(key, row); } catch (InvalidOperationException) { }
        if (snapshot != null)
        {
            Atomic(Path.Combine(Store, "backups", $"removed-{Guid.NewGuid():N}.json"), File.ReadAllBytes(snapshot));
            File.Delete(snapshot);
        }
        index.Remove(key);
        WriteIndex(index);
    }
}
