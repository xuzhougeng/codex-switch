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
    int QueueWaitS = 8);

public sealed record DialerProxyFiles(string Yaml, string LimiterJson, string LimiterPython);

public static class DialerProxyBuilder
{
    private static readonly Regex RelayName = new(@"^\s*-\s*name:\s*[""']?([^""'\s#]+)", RegexOptions.Multiline);
    private static readonly Regex IPv4 = new(@"^(?:\d{1,3}\.){3}\d{1,3}$");

    public static IReadOnlyList<string> ExtractRelayNames(string relayYaml)
    {
        var names = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (Match match in RelayName.Matches(relayYaml ?? ""))
        {
            var name = match.Groups[1].Value.Trim();
            if (name.Length == 0 || !seen.Add(name)) continue;
            names.Add(name);
        }
        return names;
    }

    public static string NormalizeRelayYaml(string relayYaml)
    {
        var text = (relayYaml ?? "").Replace("\r\n", "\n").Trim();
        if (text.StartsWith("proxies:", StringComparison.Ordinal))
        {
            var nl = text.IndexOf('\n');
            text = nl < 0 ? "" : text[(nl + 1)..].Trim();
        }
        return text;
    }

    public static DialerProxyFiles Build(DialerProxyInput input)
    {
        var relay = NormalizeRelayYaml(input.RelayYaml);
        var names = ExtractRelayNames(relay);
        if (names.Count == 0) throw new InvalidOperationException("请粘贴至少一个中转节点（需要 `- name:`）。");
        var homeServer = (input.HomeServer ?? "").Trim();
        var homePort = (input.HomePort ?? "").Trim();
        if (homeServer.Length == 0 || homePort.Length == 0)
            throw new InvalidOperationException("请填写美国家宽 SOCKS5 的地址和端口。");

        var listen = SplitHostPort(input.LimiterListen, "127.0.0.1", "1994");
        var via = $"127.0.0.1:{input.SocksPort}";
        var group = string.IsNullOrWhiteSpace(input.RelayGroup) ? "relay-group" : input.RelayGroup.Trim();
        var target = string.IsNullOrWhiteSpace(input.TargetName) ? "target-socks5" : input.TargetName.Trim();
        var loop = IPv4.IsMatch(homeServer)
            ? $"IP-CIDR,{homeServer}/32,{group},no-resolve"
            : $"DOMAIN,{homeServer},{group}";

        var yaml = new StringBuilder();
        yaml.AppendLine($"port: {input.HttpPort}");
        yaml.AppendLine($"socks-port: {input.SocksPort}");
        yaml.AppendLine("allow-lan: true");
        yaml.AppendLine("mode: rule");
        yaml.AppendLine("log-level: info");
        yaml.AppendLine($"external-controller: {YamlScalar(input.Controller)}");
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
        foreach (var name in names) yaml.AppendLine($"      - {YamlScalar(name)}");
        yaml.AppendLine("  - name: Proxy");
        yaml.AppendLine("    type: select");
        yaml.AppendLine("    proxies:");
        foreach (var name in names) yaml.AppendLine($"      - {YamlScalar(name)}");
        yaml.AppendLine($"      - {YamlScalar(target)}");
        yaml.AppendLine("rules:");
        yaml.AppendLine($"  - {loop}");
        foreach (var rule in BypassRelay) yaml.AppendLine($"  - {rule},{group}");
        foreach (var rule in BypassDirect) yaml.AppendLine($"  - {rule},DIRECT");
        foreach (var rule in AiRelay) yaml.AppendLine($"  - {rule},{target}");
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
            ["handshake_timeout_s"] = 20
        };

        return new DialerProxyFiles(yaml.ToString(), JsonSerializer.Serialize(limiter, Json) + "\n", LimiterPython());
    }

    public static string LimiterPython()
    {
        using var stream = typeof(DialerProxyBuilder).Assembly.GetManifestResourceStream("CodexSwitch.Core.socks-limiter.py")
            ?? throw new InvalidOperationException("缺少内置 socks-limiter.py。");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private static readonly string[] BypassRelay =
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
    private static readonly string[] AiRelay =
    [
        "DOMAIN-SUFFIX,openai.com",
        "DOMAIN-SUFFIX,chatgpt.com",
        "DOMAIN-SUFFIX,ai.com",
        "DOMAIN-SUFFIX,anthropic.com",
        "DOMAIN-SUFFIX,claude.ai",
        "DOMAIN-SUFFIX,claude.com",
        "DOMAIN-SUFFIX,x.ai",
        "DOMAIN-SUFFIX,grok.com",
        "DOMAIN-SUFFIX,googleapis.com",
        "DOMAIN-SUFFIX,google.com",
        "DOMAIN-SUFFIX,gemini.google.com",
        "DOMAIN-SUFFIX,cursor.sh",
        "DOMAIN-SUFFIX,githubcopilot.com"
    ];

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

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
        var built = new StringBuilder();
        foreach (var line in lines)
        {
            if (line.Length == 0) { built.AppendLine(); continue; }
            built.AppendLine(line.StartsWith(' ') || line.StartsWith('\t') ? line : "  " + line);
        }
        return built.ToString().TrimEnd();
    }

    private static string YamlScalar(string value)
    {
        if (value.Length == 0) return "\"\"";
        if (Regex.IsMatch(value, @"^[A-Za-z0-9_./-]+$") && !Regex.IsMatch(value, "^(true|false|null)$", RegexOptions.IgnoreCase))
            return value;
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
}
