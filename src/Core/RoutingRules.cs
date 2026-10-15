using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexSwitch.Core;

// String values intentionally match the macOS configuration protocol.
public sealed class RoutingConfiguration
{
    public string Ai { get; set; } = "ai";
    public string Development { get; set; } = "development";
    public string Anthropic { get; set; } = "residential";
    public List<RoutingRule> CustomRules { get; set; } = [];

    public string Preset(bool proxyOtherSites) => Ai == "ai" && Anthropic == "residential"
        ? Development == "direct" && !proxyOtherSites ? "aiOnly"
        : Development == "development" ? proxyOtherSites ? "allProxy" : "smart" : "custom" : "custom";

    public void Validate(bool homeEnabled)
    {
        foreach (var target in new[] { Ai, Development, Anthropic }) RoutingTargets.Validate(target);
        if (!homeEnabled && (Ai == "residential" || Development == "residential"))
            throw new InvalidOperationException("请先启用家宽 SOCKS5，再将流量交给家宽双跳。");
        if (CustomRules == null || CustomRules.Any(rule => rule == null) || CustomRules.Select(rule => rule.Id).Distinct().Count() != CustomRules.Count)
            throw new InvalidOperationException("自定义规则为空或标识重复，请重新导入。");
        foreach (var rule in CustomRules)
        {
            rule.Validated();
            if (rule.Enabled && rule.Target == "residential" && !homeEnabled)
                throw new InvalidOperationException($"规则「{rule.Value}」使用家宽双跳，请先启用家宽 SOCKS5。");
        }
    }
    public string AnthropicTarget(bool homeEnabled) => Anthropic == "residential" && !homeEnabled ? Ai : Anthropic;
    public static void ApplyPreset(ClashProxySettings settings, string preset)
    {
        if (!new[] { "smart", "aiOnly", "allProxy" }.Contains(preset)) throw new InvalidOperationException("未知分流方案。");
        settings.Routing.Ai = "ai"; settings.Routing.Anthropic = "residential";
        settings.Routing.Development = preset == "aiOnly" ? "direct" : "development";
        settings.ProxyOtherSites = preset == "allProxy";
    }
    public static string PresetTitle(string preset) => preset switch
    {
        "smart" => "智能分流", "aiOnly" => "仅 AI 代理", "allProxy" => "全站代理", _ => "自定义方案"
    };
}

public static class RoutingTargets
{
    public static readonly string[] All = ["ai", "development", "residential", "direct", "reject"];
    public static string Title(string target) => target switch
    {
        "ai" => "AI 出口", "development" => "开发出口", "residential" => "家宽双跳", "direct" => "直连", "reject" => "拦截", _ => target
    };
    public static void Validate(string target)
    {
        if (!All.Contains(target)) throw new InvalidOperationException("未知规则出口：" + target);
    }
    public static string Policy(string target, DialerProxyInput input) => target switch
    {
        "ai" => input.ExitGroup, "development" => DialerProxyBuilder.HkGroup,
        "residential" => input.TargetName, "direct" => "DIRECT", "reject" => "REJECT",
        _ => throw new InvalidOperationException("未知规则出口：" + target)
    };
}

public sealed class RoutingRule
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public bool Enabled { get; set; } = true;
    public string Kind { get; set; } = "DOMAIN-SUFFIX";
    public string Value { get; set; } = "";
    public string Target { get; set; } = "ai";
    public bool NoResolve { get; set; }
    public static readonly string[] Kinds = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "PROCESS-NAME", "PROCESS-PATH", "DST-PORT", "NETWORK"];
    [JsonIgnore] public bool IsIP => Kind is "IP-CIDR" or "IP-CIDR6";
    public RoutingRule Validated()
    {
        var result = (RoutingRule)MemberwiseClone();
        result.Value = (Value ?? "").Trim();
        if (string.IsNullOrWhiteSpace(Id) || string.IsNullOrEmpty(result.Value) || result.Value.Contains(',') || result.Value.Any(char.IsControl))
            throw new InvalidOperationException("规则内容不能为空，也不能包含逗号或换行。");
        if (!Kinds.Contains(Kind)) throw new InvalidOperationException("不支持的规则类型：" + Kind);
        RoutingTargets.Validate(Target);
        var text = result.Value;
        switch (Kind)
        {
            case "DOMAIN": case "DOMAIN-SUFFIX": case "DOMAIN-KEYWORD":
                if (text.Any(char.IsWhiteSpace) || text.IndexOfAny([':', '/', '*']) >= 0)
                    throw new InvalidOperationException("请填写域名或关键词，例如 example.com，不要包含网址前缀或通配符。");
                break;
            case "IP-CIDR": case "IP-CIDR6":
                var parts = text.Split('/');
                var ipv4 = Kind == "IP-CIDR";
                if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var address) ||
                    address.AddressFamily != (ipv4 ? AddressFamily.InterNetwork : AddressFamily.InterNetworkV6) ||
                    !int.TryParse(parts[1], out var prefix) || prefix < 0 || prefix > (ipv4 ? 32 : 128))
                    throw new InvalidOperationException("请填写有效的 CIDR 网段。");
                break;
            case "DST-PORT":
                var range = text.Split('-');
                if (range.Length is < 1 or > 2 || range.Any(p => !int.TryParse(p, out var port) || port is < 1 or > 65535) ||
                    int.Parse(range[0]) > int.Parse(range[^1])) throw new InvalidOperationException("端口需为 1–65535，或从小到大的端口范围。");
                break;
            case "NETWORK":
                result.Value = text.ToUpperInvariant();
                if (result.Value is not ("TCP" or "UDP")) throw new InvalidOperationException("网络协议只能填写 TCP 或 UDP。");
                break;
        }
        if (NoResolve && !IsIP) throw new InvalidOperationException("no-resolve 只适用于 IP 网段规则。");
        return result;
    }
    public string ClashLine(DialerProxyInput input) => $"{Kind},{Value},{RoutingTargets.Policy(Target, input)}" + (NoResolve ? ",no-resolve" : "");
    public static List<RoutingRule> ImportClash(string text, DialerProxyInput input)
    {
        var rules = new List<RoutingRule>();
        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim();
            if (line.Length == 0 || line.StartsWith('#') || line == "rules:") continue;
            try
            {
                if (line.StartsWith("- ", StringComparison.Ordinal)) line = line[2..].Trim();
                if (line.StartsWith('"')) line = JsonSerializer.Deserialize<string>(line) ?? "";
                else if (line.StartsWith('\'') && line.EndsWith('\'')) line = line[1..^1].Replace("''", "'");
                var fields = line.Split(',').Select(s => s.Trim()).ToArray();
                if (fields.Length is < 3 or > 4) throw new InvalidOperationException("请使用 类型,内容,出口 格式；规则集与逻辑组合暂不支持。");
                var target = RoutingTargets.All.FirstOrDefault(t => RoutingTargets.Policy(t, input) == fields[2] || RoutingTargets.Title(t) == fields[2]);
                if (target == null || (fields.Length == 4 && fields[3] != "no-resolve"))
                    throw new InvalidOperationException($"出口需为 {input.ExitGroup}、{DialerProxyBuilder.HkGroup}、{input.TargetName}、DIRECT 或 REJECT。");
                rules.Add(new RoutingRule { Kind = fields[0].ToUpperInvariant(), Value = fields[1], Target = target, NoResolve = fields.Length == 4 }.Validated());
            }
            catch (Exception ex) when (ex is InvalidOperationException or JsonException)
            { throw new InvalidOperationException($"第 {i + 1} 行：{ex.Message}"); }
        }
        if (rules.Count == 0) throw new InvalidOperationException("没有读到可导入的规则。");
        return rules;
    }
}
