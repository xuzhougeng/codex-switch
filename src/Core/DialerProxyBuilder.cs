using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CodexSwitch.Core;

public sealed record DialerProxyInput(
    string RelayYaml,
    string HomeServer,
    string HomePort,
    string HomeUsername,
    string HomePassword,
    string RelayGroup = "relay-group",
    string TargetName = "target-socks5",
    int HttpPort = 1990,
    int SocksPort = 1991,
    string Controller = "127.0.0.1:1993",
    string LimiterListen = "127.0.0.1:1994",
    int MaxConcurrent = 8,
    int MaxInflightDials = 1,
    int DialIntervalMs = 250,
    int QueueWaitS = 8,
    bool AllowLan = true,
    string SelectedRelay = "",
    string ExitGroup = "exit-group",
    string SelectedExit = "");

public sealed record DialerProxyFiles(string Yaml, string LimiterJson, string LimiterPython);

public static class DialerProxyBuilder
{
    private static readonly Regex RelayName = new(@"^\s*-\s*name:\s*(.+?)\s*$", RegexOptions.Multiline);
    private static readonly Regex IPv4 = new(@"^(?:\d{1,3}\.){3}\d{1,3}$");

    public static IReadOnlyList<string> ExtractRelayNames(string relayYaml)
    {
        var names = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (Match match in RelayName.Matches(relayYaml ?? ""))
        {
            var name = CleanRelayName(match.Groups[1].Value);
            if (name.Length == 0 || !seen.Add(name)) continue;
            names.Add(name);
        }
        return names;
    }

    public static string CleanRelayName(string raw)
    {
        var text = (raw ?? "").Trim().TrimEnd('\r');
        if (text.Length >= 2 && (text[0] == '"' || text[0] == '\''))
        {
            var end = text.LastIndexOf(text[0]);
            if (end > 0) text = text[1..end];
        }
        var hash = text.IndexOf(" #", StringComparison.Ordinal);
        if (hash >= 0) text = text[..hash];
        return text.Trim();
    }

    public static string NormalizeRelayYaml(string relayYaml)
    {
        var text = (relayYaml ?? "").Replace("\r\n", "\n").Trim('\r', '\n');
        if (text.TrimStart().StartsWith("proxies:", StringComparison.Ordinal))
        {
            var nl = text.IndexOf('\n');
            text = nl < 0 ? "" : text[(nl + 1)..].TrimStart('\r', '\n');
        }
        return text.TrimEnd();
    }

    public static DialerProxyFiles Build(DialerProxyInput input)
    {
        var relay = NormalizeRelayYaml(input.RelayYaml);
        var names = ExtractRelayNames(relay);
        if (names.Count == 0) throw new InvalidOperationException("还没有中转节点。请先导入订阅，再从订阅里选择。");
        var ordered = Prefer(names, input.SelectedRelay);
        var overseas = WithoutHongKong(names);
        var aiCandidates = overseas.Count > 0 ? overseas : new List<string>(names);
        var exits = Prefer(aiCandidates, Preferred(aiCandidates, input.SelectedExit, input.SelectedRelay));
        var hk = new List<string>();
        foreach (var name in names)
            if (IsHongKong(name)) hk.Add(name);
        hk.Add("DIRECT");
        var homeServer = (input.HomeServer ?? "").Trim();
        var homePort = (input.HomePort ?? "").Trim();
        if (homeServer.Length == 0 || homePort.Length == 0)
            throw new InvalidOperationException("请填写美国家宽 SOCKS5 的地址和端口。");

        var listen = SplitHostPort(input.LimiterListen, "127.0.0.1", "1994");
        var via = $"127.0.0.1:{input.SocksPort}";
        var group = string.IsNullOrWhiteSpace(input.RelayGroup) ? "relay-group" : input.RelayGroup.Trim();
        var exit = string.IsNullOrWhiteSpace(input.ExitGroup) ? "exit-group" : input.ExitGroup.Trim();
        var target = string.IsNullOrWhiteSpace(input.TargetName) ? "target-socks5" : input.TargetName.Trim();
        var loop = IPv4.IsMatch(homeServer)
            ? $"IP-CIDR,{homeServer}/32,{group},no-resolve"
            : $"DOMAIN,{homeServer},{group}";

        var yaml = new StringBuilder();
        yaml.AppendLine($"port: {input.HttpPort}");
        yaml.AppendLine($"socks-port: {input.SocksPort}");
        yaml.AppendLine("mode: rule");
        yaml.AppendLine("log-level: info");
        yaml.AppendLine($"external-controller: {YamlScalar(input.Controller)}");
        yaml.AppendLine($"allow-lan: {(input.AllowLan ? "true" : "false")}");
        if (!input.AllowLan) yaml.AppendLine("bind-address: 127.0.0.1");
        yaml.AppendLine("ipv6: false");
        yaml.AppendLine("tcp-concurrent: false");
        yaml.AppendLine("keep-alive-idle: 15");
        yaml.AppendLine("keep-alive-interval: 15");
        yaml.AppendLine("proxies:");
        yaml.AppendLine(IndentRelay(relay));
        yaml.AppendLine($"  - name: {YamlScalar(target)}");
        yaml.AppendLine("    type: socks5");
        yaml.AppendLine($"    server: {listen.Host}");
        yaml.AppendLine($"    port: {listen.Port}");
        yaml.AppendLine("    udp: false");
        yaml.AppendLine("    ip-version: ipv4");
        yaml.AppendLine("proxy-groups:");
        yaml.AppendLine($"  - name: {YamlScalar(group)}");
        yaml.AppendLine("    type: select");
        yaml.AppendLine("    proxies:");
        foreach (var name in ordered) yaml.AppendLine($"      - {YamlScalar(name)}");
        yaml.AppendLine($"  - name: {YamlScalar(exit)}");
        yaml.AppendLine("    type: select");
        yaml.AppendLine("    proxies:");
        foreach (var name in exits) yaml.AppendLine($"      - {YamlScalar(name)}");
        yaml.AppendLine($"  - name: {HkGroup}");
        yaml.AppendLine("    type: select");
        yaml.AppendLine("    proxies:");
        foreach (var name in hk) yaml.AppendLine($"      - {YamlScalar(name)}");
        yaml.AppendLine("rules:");
        yaml.AppendLine($"  - {loop}");
        foreach (var rule in ExitHosts) yaml.AppendLine($"  - {rule},{exit}");
        foreach (var rule in AnthropicHome) yaml.AppendLine($"  - {rule},{target}");
        foreach (var rule in OtherAi) yaml.AppendLine($"  - {rule},{exit}");
        foreach (var rule in HongKongOk) yaml.AppendLine($"  - {rule},{HkGroup}");
        foreach (var rule in BypassDirect) yaml.AppendLine($"  - {rule},DIRECT");
        yaml.AppendLine("  - MATCH,DIRECT");

        var limiter = new Dictionary<string, object>
        {
            ["listen"] = $"{listen.Host}:{listen.Port}",
            ["via"] = via,
            ["upstream"] = $"{homeServer}:{homePort}",
            ["username"] = input.HomeUsername ?? "",
            ["password"] = input.HomePassword ?? "",
            ["max_concurrent"] = input.MaxConcurrent,
            ["max_inflight_dials"] = input.MaxInflightDials,
            ["dial_interval_ms"] = input.DialIntervalMs,
            ["queue_wait_s"] = input.QueueWaitS,
            ["handshake_timeout_s"] = 20,
            ["idle_timeout_s"] = 60
        };

        return new DialerProxyFiles(yaml.ToString(), JsonSerializer.Serialize(limiter, Json) + "\n", LimiterPython());
    }

    // Config for a throwaway mihomo that only serves the delay API: one home SOCKS per relay, dialed through that relay,
    // so a delay test times the whole chain me -> relay -> home -> URL. Proxy i reaches the home via relay names[i].
    // Kept out of ai.yaml so the home password stays with the limiter.
    public static string BuildProbe(DialerProxyInput input, string controller)
    {
        var relay = NormalizeRelayYaml(input.RelayYaml);
        var names = ExtractRelayNames(relay);
        if (names.Count == 0) throw new InvalidOperationException("订阅里没有节点。");
        var homeServer = (input.HomeServer ?? "").Trim();
        if (homeServer.Length == 0 || !int.TryParse((input.HomePort ?? "").Trim(), out var homePort) || homePort is < 1 or > 65535)
            throw new InvalidOperationException("请填写美国家宽 SOCKS5 的地址和端口。");
        var yaml = new StringBuilder();
        yaml.AppendLine("log-level: warning");
        yaml.AppendLine($"external-controller: {YamlScalar(controller)}");
        yaml.AppendLine("ipv6: false");
        yaml.AppendLine("proxies:");
        yaml.AppendLine(IndentRelay(relay));
        for (var i = 0; i < names.Count; i++)
        {
            yaml.AppendLine($"  - name: {ProbeName(i)}");
            yaml.AppendLine("    type: socks5");
            yaml.AppendLine($"    server: {YamlScalar(homeServer)}");
            yaml.AppendLine($"    port: {homePort}");
            if (!string.IsNullOrEmpty(input.HomeUsername))
            {
                yaml.AppendLine($"    username: {Quoted(input.HomeUsername)}");
                yaml.AppendLine($"    password: {Quoted(input.HomePassword ?? "")}");
            }
            yaml.AppendLine("    udp: false");
            yaml.AppendLine($"    dialer-proxy: {YamlScalar(names[i])}");
        }
        yaml.AppendLine("rules:");
        yaml.AppendLine("  - MATCH,DIRECT");
        return yaml.ToString();
    }

    // Throwaway config that times each subscription node as its own exit. No home SOCKS, so this delay is not the 中转 chain.
    public static string BuildExitProbe(DialerProxyInput input, string controller)
    {
        var relay = NormalizeRelayYaml(input.RelayYaml);
        if (ExtractRelayNames(relay).Count == 0) throw new InvalidOperationException("订阅里没有节点。");
        var yaml = new StringBuilder();
        yaml.AppendLine("log-level: warning");
        yaml.AppendLine($"external-controller: {YamlScalar(controller)}");
        yaml.AppendLine("ipv6: false");
        yaml.AppendLine("proxies:");
        yaml.AppendLine(IndentRelay(relay));
        yaml.AppendLine("rules:");
        yaml.AppendLine("  - MATCH,DIRECT");
        return yaml.ToString();
    }

    public const string ExitTestUrl = "https://downloads.claude.ai";
    public const string HkGroup = "hk-group";

    // Hong Kong is not on the OpenAI or Anthropic supported lists, and Gemini's API list omits it too.
    // A node is Hong Kong when its label says so. "HK" must be its own token, so a name like "checkpoint" is left alone.
    public static bool IsHongKong(string? name)
    {
        var text = name ?? "";
        if (text.Contains("🇭🇰") || text.Contains("香港")) return true;
        if (text.Contains("Hong Kong", StringComparison.OrdinalIgnoreCase)) return true;
        if (text.Contains("HongKong", StringComparison.OrdinalIgnoreCase)) return true;
        return HongKongCode.IsMatch(text);
    }

    public static List<string> WithoutHongKong(IReadOnlyList<string> names)
    {
        var list = new List<string>();
        foreach (var name in names)
            if (!IsHongKong(name)) list.Add(name);
        return list;
    }

    // First choice that is actually in the candidate list, otherwise the first candidate.
    public static string Preferred(IReadOnlyList<string> candidates, string? first, string? second)
    {
        var primary = (first ?? "").Trim();
        if (primary.Length > 0 && candidates.Contains(primary)) return primary;
        var fallback = (second ?? "").Trim();
        if (fallback.Length > 0 && candidates.Contains(fallback)) return fallback;
        return candidates.Count > 0 ? candidates[0] : "";
    }

    public static string ProbeName(int index) => "codex-switch-chain-" + index;

    public static string LimiterPython()
    {
        using var stream = typeof(DialerProxyBuilder).Assembly.GetManifestResourceStream("CodexSwitch.Core.socks-limiter.py")
            ?? throw new InvalidOperationException("缺少内置 socks-limiter.py。");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    // Claude's update CDN is a large download. It stays above the claude.ai suffix so it does not enter the residential hop.
    private static readonly string[] ExitHosts = ["DOMAIN,downloads.claude.ai"];
    // Anthropic blocks Hong Kong and treats datacenter exits as a ban risk. Only these domains take the US residential hop.
    private static readonly string[] AnthropicHome =
    [
        "DOMAIN-SUFFIX,anthropic.com",
        "DOMAIN-SUFFIX,claude.ai",
        "DOMAIN-SUFFIX,claude.com",
        "DOMAIN-SUFFIX,claudeusercontent.com"
    ];
    // OpenAI, Gemini API, xAI, Cursor, and Copilot block or omit Hong Kong, and a normal node is enough.
    // google.com and googleapis.com are not listed: Gmail and the rest of Google are not AI exits.
    // The Copilot proxy host is exact so it wins over the githubusercontent.com suffix below.
    private static readonly string[] OtherAi =
    [
        "DOMAIN-SUFFIX,openai.com",
        "DOMAIN-SUFFIX,chatgpt.com",
        "DOMAIN-SUFFIX,oaistatic.com",
        "DOMAIN-SUFFIX,oaiusercontent.com",
        "DOMAIN-SUFFIX,sora.com",
        "DOMAIN-SUFFIX,chat.com",
        "DOMAIN-SUFFIX,ai.com",
        "DOMAIN-SUFFIX,gemini.google.com",
        "DOMAIN-SUFFIX,generativelanguage.googleapis.com",
        "DOMAIN-SUFFIX,ai.google.dev",
        "DOMAIN-SUFFIX,aistudio.google.com",
        "DOMAIN-SUFFIX,makersuite.google.com",
        "DOMAIN-SUFFIX,alkalimakersuite-pa.clients6.google.com",
        "DOMAIN-SUFFIX,deepmind.google",
        "DOMAIN-SUFFIX,notebooklm.google.com",
        "DOMAIN-SUFFIX,notebooklm.google",
        "DOMAIN-SUFFIX,bard.google.com",
        "DOMAIN-SUFFIX,x.ai",
        "DOMAIN-SUFFIX,grok.com",
        "DOMAIN-SUFFIX,cursor.sh",
        "DOMAIN-SUFFIX,cursor.com",
        "DOMAIN-SUFFIX,cursorapi.com",
        "DOMAIN,copilot-proxy.githubusercontent.com",
        "DOMAIN-SUFFIX,githubcopilot.com"
    ];
    // Not an AI exit. Hong Kong or a direct connection are both acceptable.
    private static readonly string[] HongKongOk =
    [
        "DOMAIN-SUFFIX,docker.io",
        "DOMAIN,api.github.com",
        "DOMAIN-SUFFIX,github.com",
        "DOMAIN-SUFFIX,githubusercontent.com",
        "DOMAIN-SUFFIX,github.io"
    ];
    private static readonly string[] BypassDirect =
    [
        "DOMAIN-SUFFIX,apple-relay.apple.com",
        "DOMAIN-SUFFIX,apple-relay.fastly-edge.com",
        "DOMAIN-SUFFIX,apple-relay.cloudflare.com",
        "DOMAIN-SUFFIX,guzzoni.apple.com"
    ];
    private static readonly Regex HongKongCode = new(@"(^|[^A-Za-z])HK\d*([^A-Za-z]|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    // mihomo remembers the last selector in cache.db and ignores YAML order after a restart.
    // These are the group/name pairs serve must push once the controller is up.
    public static IReadOnlyList<(string Group, string Name)> LiveSelections(ClashProxySettings settings)
    {
        var relayGroup = string.IsNullOrWhiteSpace(settings.RelayGroup) ? "relay-group" : settings.RelayGroup.Trim();
        var exitGroup = string.IsNullOrWhiteSpace(settings.ExitGroup) ? "exit-group" : settings.ExitGroup.Trim();
        var relay = (settings.SelectedRelay ?? "").Trim();
        var exit = (settings.SelectedExit ?? "").Trim();
        if (exit.Length == 0 || IsHongKong(exit)) exit = IsHongKong(relay) ? "" : relay;
        var list = new List<(string Group, string Name)>();
        if (relay.Length > 0) list.Add((relayGroup, relay));
        if (exit.Length > 0) list.Add((exitGroup, exit));
        return list;
    }

    private static List<string> Prefer(IReadOnlyList<string> names, string? selected)
    {
        var ordered = new List<string>(names);
        var picked = (selected ?? "").Trim();
        var at = ordered.FindIndex(name => name == picked);
        if (at > 0)
        {
            ordered.RemoveAt(at);
            ordered.Insert(0, picked);
        }
        return ordered;
    }

    private static (string Host, string Port) SplitHostPort(string value, string host, string port)
    {
        var text = (value ?? "").Trim();
        if (text.Length == 0) return (host, port);
        var idx = text.LastIndexOf(':');
        if (idx <= 0) return (text, port);
        return (text[..idx], text[(idx + 1)..]);
    }

    private static string IndentRelay(string relay)
    {
        var lines = relay.Split('\n');
        var needsIndent = false;
        foreach (var line in lines)
        {
            if (line.Length > 0 && line[0] != ' ' && line[0] != '\t') { needsIndent = true; break; }
        }
        var built = new StringBuilder();
        foreach (var line in lines)
        {
            if (line.Length == 0) { built.AppendLine(); continue; }
            built.AppendLine(needsIndent ? "  " + line : line);
        }
        return built.ToString().TrimEnd();
    }

    private static string YamlScalar(string value)
    {
        if (value.Length == 0) return "\"\"";
        if (Regex.IsMatch(value, @"^[A-Za-z0-9_./-]+$") && !Regex.IsMatch(value, "^(true|false|null)$", RegexOptions.IgnoreCase))
            return value;
        return Quoted(value);
    }

    // Credentials are always quoted: a numeric password would otherwise load as a YAML number.
    private static string Quoted(string value) => "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
}
