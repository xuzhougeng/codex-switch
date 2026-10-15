import Foundation
import Darwin

public enum RoutingTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case ai, development, residential, direct, reject
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ai: return "AI 出口"
        case .development: return "开发出口"
        case .residential: return "家宽双跳"
        case .direct: return "直连"
        case .reject: return "拦截"
        }
    }
    public func policy(_ input: DialerProxyInput) -> String {
        switch self {
        case .ai: return input.exitGroup
        case .development: return DialerProxyBuilder.developmentGroup
        case .residential: return input.targetName
        case .direct: return "DIRECT"
        case .reject: return "REJECT"
        }
    }
}

public enum RoutingPreset: String, CaseIterable, Identifiable, Sendable {
    case smart, aiOnly, allProxy
    public var id: String { rawValue }
    public var title: String {
        switch self { case .smart: return "智能分流"; case .aiOnly: return "仅 AI 代理"; case .allProxy: return "全站代理" }
    }
    public var detail: String {
        switch self {
        case .smart: return "AI 与开发网站走代理，其他直连"
        case .aiOnly: return "AI 走代理，开发网站与其他直连"
        case .allProxy: return "按用途选择出口，其余也走代理"
        }
    }
}

public struct RoutingConfiguration: Codable, Equatable, Sendable {
    public var ai: RoutingTarget = .ai
    public var development: RoutingTarget = .development
    public var anthropic: RoutingTarget = .residential
    public var customRules: [RoutingRule] = []
    public init() {}
    public func preset(proxyOtherSites: Bool) -> RoutingPreset? {
        guard ai == .ai, anthropic == .residential else { return nil }
        if development == .direct && !proxyOtherSites { return .aiOnly }
        guard development == .development else { return nil }
        return proxyOtherSites ? .allProxy : .smart
    }
    public mutating func apply(_ preset: RoutingPreset, proxyOtherSites: inout Bool) {
        ai = .ai; anthropic = .residential
        development = preset == .aiOnly ? .direct : .development
        proxyOtherSites = preset == .allProxy
    }
    public func anthropicTarget(useHomeProxy: Bool) -> RoutingTarget {
        anthropic == .residential && !useHomeProxy ? ai : anthropic
    }
    public func validate(useHomeProxy: Bool) throws {
        guard useHomeProxy || (ai != .residential && development != .residential) else {
            throw StoreError("请先在设置中启用 SOCKS5 家宽出口，再将流量交给家宽双跳。")
        }
        guard Set(customRules.map(\.id)).count == customRules.count else { throw StoreError("自定义规则标识重复，请重新导入。") }
        for rule in customRules {
            _ = try rule.validated()
            if rule.enabled && rule.target == .residential && !useHomeProxy {
                throw StoreError("规则「\(rule.value)」使用家宽双跳，请先启用 SOCKS5 家宽出口。")
            }
        }
    }
}

public enum RoutingRuleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case domain = "DOMAIN", suffix = "DOMAIN-SUFFIX", keyword = "DOMAIN-KEYWORD"
    case ipv4 = "IP-CIDR", ipv6 = "IP-CIDR6", process = "PROCESS-NAME", processPath = "PROCESS-PATH"
    case port = "DST-PORT", network = "NETWORK"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .domain: return "完整域名"; case .suffix: return "域名及子域名"; case .keyword: return "域名关键词"
        case .ipv4: return "IPv4 网段"; case .ipv6: return "IPv6 网段"; case .process: return "进程名称"
        case .processPath: return "进程路径"; case .port: return "目标端口"; case .network: return "网络协议"
        }
    }
    public var example: String {
        switch self {
        case .domain, .suffix: return "example.com"; case .keyword: return "example"
        case .ipv4: return "192.168.0.0/16"; case .ipv6: return "2001:db8::/32"
        case .process: return "Example"; case .processPath: return "/Applications/Example.app/Contents/MacOS/Example"
        case .port: return "443 或 8000-9000"; case .network: return "TCP 或 UDP"
        }
    }
    public var isIP: Bool { self == .ipv4 || self == .ipv6 }
}

public struct RoutingRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var enabled: Bool
    public var kind: RoutingRuleKind
    public var value: String
    public var target: RoutingTarget
    public var noResolve: Bool
    public init(id: String = UUID().uuidString, enabled: Bool = true, kind: RoutingRuleKind = .suffix,
                value: String = "", target: RoutingTarget = .ai, noResolve: Bool = false) {
        self.id = id; self.enabled = enabled; self.kind = kind; self.value = value; self.target = target; self.noResolve = noResolve
    }
    public func validated() throws -> Self {
        var result = self
        result.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.value.isEmpty, !result.value.contains(","),
              result.value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw StoreError("匹配内容不能为空，也不能包含逗号或换行。")
        }
        let text = result.value
        switch kind {
        case .domain, .suffix, .keyword:
            guard !text.contains(where: \.isWhitespace), !text.contains(":"), !text.contains("/"), !text.contains("*") else {
                throw StoreError("请填写域名或关键词，例如 example.com，不要包含网址前缀或通配符。")
            }
        case .ipv4, .ipv6:
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            var buffer = in6_addr()
            guard parts.count == 2, let prefix = Int(parts[1]), (0...(kind == .ipv4 ? 32 : 128)).contains(prefix),
                  String(parts[0]).withCString({ inet_pton(kind == .ipv4 ? AF_INET : AF_INET6, $0, &buffer) }) == 1 else {
                throw StoreError("请填写有效的 CIDR 网段，例如 \(kind.example)。")
            }
        case .port:
            let values = text.split(separator: "-", omittingEmptySubsequences: false)
            let ports = values.compactMap { Int($0) }
            guard (1...2).contains(values.count), ports.count == values.count,
                  ports.allSatisfy({ (1...65535).contains($0) }), ports.first! <= ports.last! else {
                throw StoreError("目标端口需为 1–65535，或从小到大的端口范围。")
            }
        case .network:
            result.value = text.uppercased()
            guard ["TCP", "UDP"].contains(result.value) else { throw StoreError("网络协议只能填写 TCP 或 UDP。") }
        case .process, .processPath: break
        }
        guard !noResolve || kind.isIP else { throw StoreError("no-resolve 只适用于 IP 网段规则。") }
        return result
    }
    public func clashLine(_ input: DialerProxyInput) -> String {
        "\(kind.rawValue),\(value),\(target.policy(input))" + (noResolve ? ",no-resolve" : "")
    }
    public static func importClash(_ text: String, input: DialerProxyInput) throws -> [Self] {
        var result: [Self] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "rules:" { continue }
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(line.utf8)) { line = decoded }
            else if line.first == "'", line.last == "'" { line = String(line.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            let fields = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            do {
                guard (3...4).contains(fields.count), let kind = RoutingRuleKind(rawValue: fields[0].uppercased()) else {
                    throw StoreError("支持域名、IP 网段、进程、端口和协议规则；请使用 类型,内容,出口 格式。")
                }
                guard let target = RoutingTarget.allCases.first(where: { $0.policy(input) == fields[2] || $0.title == fields[2] }),
                      fields.count == 3 || fields[3] == "no-resolve" else {
                    throw StoreError("出口需为 \(input.exitGroup)、\(DialerProxyBuilder.developmentGroup)、\(input.targetName)、DIRECT 或 REJECT。")
                }
                result.append(try RoutingRule(kind: kind, value: fields[1], target: target, noResolve: fields.count == 4).validated())
            } catch { throw StoreError("第 \(index + 1) 行：\(error.localizedDescription)") }
        }
        guard !result.isEmpty else { throw StoreError("没有读到可导入的规则。") }
        return result
    }
}
