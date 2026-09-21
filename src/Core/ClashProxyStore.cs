using System.Text.Json;

namespace CodexSwitch.Core;

public sealed class ClashProxySettings
{
    public int HttpPort { get; set; } = 1990;
    public int SocksPort { get; set; } = 1991;
    public string Controller { get; set; } = "127.0.0.1:1993";
    public string LimiterListen { get; set; } = "127.0.0.1:1994";
    public string RelayGroup { get; set; } = "relay-group";
    public string TargetName { get; set; } = "target-socks5";
    public string RelayYaml { get; set; } = "";
    public string HomeServer { get; set; } = "";
    public string HomePort { get; set; } = "1080";
    public string HomeUsername { get; set; } = "";
    public string HomePassword { get; set; } = "";
    public int MaxConcurrent { get; set; } = 8;
    public int DialIntervalMs { get; set; } = 250;
    public int QueueWaitS { get; set; } = 8;
    public string MihomoPath { get; set; } = "";
    public string PythonPath { get; set; } = "";
}

public sealed class ClashProxyStore
{
    public string Home { get; }
    public string StoreDirectory => Path.Combine(Home, "codex-switch");
    public string SettingsPath => Path.Combine(StoreDirectory, "clash-proxy.json");
    public string WorkDirectory => Path.Combine(StoreDirectory, "clash");
    public string YamlPath => Path.Combine(WorkDirectory, "ai.yaml");
    public string LimiterJsonPath => Path.Combine(WorkDirectory, "socks-limiter.json");
    public string LimiterPythonPath => Path.Combine(WorkDirectory, "socks-limiter.py");
    public string MihomoLogPath => Path.Combine(WorkDirectory, "mihomo.log");
    public string LimiterLogPath => Path.Combine(WorkDirectory, "limiter.log");
    public string MihomoPidPath => Path.Combine(WorkDirectory, "mihomo.pid");
    public string LimiterPidPath => Path.Combine(WorkDirectory, "limiter.pid");

    public ClashProxyStore(string? home = null) => Home = Path.GetFullPath(home ??
        Environment.GetEnvironmentVariable("CODEX_HOME") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"));

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public ClashProxySettings Load()
    {
        if (!File.Exists(SettingsPath)) return new ClashProxySettings();
        try
        {
            return JsonSerializer.Deserialize<ClashProxySettings>(File.ReadAllText(SettingsPath), Json) ?? new ClashProxySettings();
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("双跳代理配置文件无效。");
        }
    }

    public void Save(ClashProxySettings settings)
    {
        System.IO.Directory.CreateDirectory(StoreDirectory);
        var json = JsonSerializer.Serialize(settings, Json);
        var temp = SettingsPath + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temp, json);
        File.Move(temp, SettingsPath, true);
        TryRestrict(SettingsPath);
    }

    public DialerProxyFiles Materialize(ClashProxySettings settings)
    {
        var files = DialerProxyBuilder.Build(ToInput(settings));
        Directory.CreateDirectory(WorkDirectory);
        Write(YamlPath, files.Yaml);
        Write(LimiterJsonPath, files.LimiterJson);
        Write(LimiterPythonPath, files.LimiterPython);
        TryRestrict(LimiterJsonPath);
        TryRestrict(LimiterPythonPath);
        return files;
    }

    public static DialerProxyInput ToInput(ClashProxySettings settings) => new(
        settings.RelayYaml,
        settings.HomeServer,
        settings.HomePort,
        settings.HomeUsername,
        settings.HomePassword,
        settings.RelayGroup,
        settings.TargetName,
        settings.HttpPort,
        settings.SocksPort,
        settings.Controller,
        settings.LimiterListen,
        settings.MaxConcurrent,
        1,
        settings.DialIntervalMs,
        settings.QueueWaitS);

    private static void Write(string path, string text)
    {
        var temp = path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temp, text);
        File.Move(temp, path, true);
    }

    private static void TryRestrict(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            try { File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
        }
    }
}
