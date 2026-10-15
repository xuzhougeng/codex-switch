import Foundation

public struct DialerProxyInput: Sendable {
    public var routing: RoutingConfiguration
    public var selectedDevelopment: String
    public var proxyOtherSites: Bool
    public var useHomeProxy: Bool
    public var selectedRelay: String
    public var selectedExit: String
    public var exitGroup: String
    public var relayYaml: String
    public var homeServer: String
    public var homePort: String
    public var homeUsername: String
    public var homePassword: String
    public var relayGroup: String
    public var targetName: String
    public var httpPort: Int
    public var socksPort: Int
    public var controller: String
    public var limiterListen: String
    public var maxConcurrent: Int
    public var dialIntervalMs: Int
    public var queueWaitS: Int
    public init(relayYaml: String, homeServer: String, homePort: String, homeUsername: String = "", homePassword: String = "",
                relayGroup: String = "relay-group", targetName: String = "target-socks5", httpPort: Int = 1990, socksPort: Int = 1991,
                controller: String = "127.0.0.1:1993", limiterListen: String = "127.0.0.1:1994", maxConcurrent: Int = 8,
                dialIntervalMs: Int = 250, queueWaitS: Int = 8, selectedRelay: String = "",
                exitGroup: String = "exit-group", selectedExit: String = "", useHomeProxy: Bool = true, proxyOtherSites: Bool = false,
                routing: RoutingConfiguration = RoutingConfiguration(), selectedDevelopment: String = "") {
        self.routing = routing; self.selectedDevelopment = selectedDevelopment
        self.proxyOtherSites = proxyOtherSites
        self.useHomeProxy = useHomeProxy
        self.selectedRelay = selectedRelay; self.selectedExit = selectedExit; self.exitGroup = exitGroup
        self.relayYaml = relayYaml; self.homeServer = homeServer; self.homePort = homePort
        self.homeUsername = homeUsername; self.homePassword = homePassword
        self.relayGroup = relayGroup; self.targetName = targetName
        self.httpPort = httpPort; self.socksPort = socksPort; self.controller = controller
        self.limiterListen = limiterListen; self.maxConcurrent = maxConcurrent
        self.dialIntervalMs = dialIntervalMs; self.queueWaitS = queueWaitS
    }
}

public struct DialerProxyFiles: Sendable {
    public let yaml: String
    public let limiterJSON: String
    public let limiterPython: String
}

public enum DialerProxyBuilder {
    public static let developmentGroup = "hk-group"
    public static let developmentAutomaticGroup = "hk-auto"
    public static let developmentTestURL = "https://github.com"
    public static func extractRelayNames(_ yaml: String) -> [String] {
        let lines = yaml.components(separatedBy: "\n")
        let listIndent = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        var names: [String] = []
        var seen = Set<String>()
        for line in lines {
            let indent = line.prefix(while: { $0 == " " }).count
            var text = line.trimmingCharacters(in: .whitespaces)
            if indent == listIndent && text.hasPrefix("- ") {
                text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("{") {
                    text = (flowFields(String(text.dropFirst())).first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:") } ?? "").trimmingCharacters(in: .whitespaces)
                }
            } else if indent != listIndent + 2 { continue }
            guard text.hasPrefix("name:") else { continue }
            let name = cleanName(String(text.dropFirst(5)))
            if !name.isEmpty, seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    // Split only the top level of a YAML flow mapping; nested options and quoted commas are preserved.
    private static func flowFields(_ value: String) -> [String] {
        var fields: [String] = [], current = ""
        var quote: Character?, escaped = false, depth = 0
        for character in value {
            if let active = quote {
                current.append(character)
                if escaped { escaped = false }
                else if character == "\\" && active == "\"" { escaped = true }
                else if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character; current.append(character)
            } else if character == "{" || character == "[" {
                depth += 1; current.append(character)
            } else if character == "}" && depth == 0 {
                fields.append(current); return fields
            } else if character == "}" || character == "]" {
                depth -= 1; current.append(character)
            } else if character == "," && depth == 0 {
                fields.append(current); current = ""
            } else { current.append(character) }
        }
        fields.append(current)
        return fields
    }

    private static func cleanName(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "\"", let end = text.dropFirst().lastIndex(of: "\"") {
            let quoted = String(text[...end])
            if let data = quoted.data(using: .utf8), let value = try? JSONDecoder().decode(String.self, from: data) { return value }
        }
        if text.first == "'", let end = text.dropFirst().lastIndex(of: "'") {
            return String(text[text.index(after: text.startIndex)..<end]).replacingOccurrences(of: "''", with: "'")
        }
        return text.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
    }

    public static func build(_ input: DialerProxyInput) throws -> DialerProxyFiles {
        try validate(input)
        let relay = try RelayImport.extractProxies(input.relayYaml)
        let names = extractRelayNames(relay)
        guard !names.isEmpty else { throw StoreError("请粘贴至少一个中转节点（需要 `- name:`）。") }
        let homeServer = input.homeServer.trimmingCharacters(in: .whitespaces)
        let homePort = input.homePort.trimmingCharacters(in: .whitespaces)
        guard !input.useHomeProxy || (!homeServer.isEmpty && !homePort.isEmpty) else { throw StoreError("请填写美国家宽 SOCKS5 的地址和端口。") }
        let listen = splitHostPort(input.limiterListen, "127.0.0.1", "1994")
        let group = input.relayGroup.isEmpty ? "relay-group" : input.relayGroup
        let target = input.targetName.isEmpty ? "target-socks5" : input.targetName
        let ipv4 = homeServer.range(of: #"^(?:\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil
        let loop = ipv4 ? "IP-CIDR,\(homeServer)/32,\(group),no-resolve" : "DOMAIN,\(homeServer),\(group)"
        var yaml = ""
        yaml += "port: \(input.httpPort)\nsocks-port: \(input.socksPort)\nallow-lan: false\nbind-address: 127.0.0.1\nmode: rule\nlog-level: info\n"
        yaml += "external-controller: \(scalar(input.controller))\nipv6: false\ntcp-concurrent: false\nkeep-alive-idle: 15\nkeep-alive-interval: 15\nproxies:\n"
        yaml += indent(relay) + "\n"
        if input.useHomeProxy { yaml += "  - name: \(scalar(target))\n    type: socks5\n    server: \(listen.host)\n    port: \(listen.port)\n    udp: false\n    ip-version: ipv4\n" }
        let overseas = names.filter { !isHongKong($0) }
        let ai = overseas.isEmpty ? names : overseas
        let hk = names.filter { isHongKong($0) }
        yaml += "proxy-groups:\n  - name: \(scalar(group))\n    type: select\n    proxies:\n"
        for name in prefer(names, input.selectedRelay) { yaml += "      - \(scalar(name))\n" }
        yaml += "  - name: \(scalar(input.exitGroup))\n    type: select\n    proxies:\n"
        for name in prefer(ai, preferred(ai, input.selectedExit, input.selectedRelay)) { yaml += "      - \(scalar(name))\n" }
        // GitHub must not stay pinned to the first imported Hong Kong node when it fails.
        // Keep Hong Kong preferred, then fall back to the user's selected single-hop exit.
        yaml += "  - name: \(developmentAutomaticGroup)\n    type: fallback\n    url: \(developmentTestURL)\n    interval: 300\n    timeout: 5000\n    max-failed-times: 1\n    proxies:\n"
        for name in hk { yaml += "      - \(scalar(name))\n" }
        yaml += "      - \(scalar(input.exitGroup))\n"
        yaml += "  - name: \(developmentGroup)\n    type: select\n    proxies:\n"
        for name in prefer([developmentAutomaticGroup] + names, input.selectedDevelopment) { yaml += "      - \(scalar(name))\n" }
        yaml += "rules:\n"
        if input.useHomeProxy { yaml += "  - \(loop)\n" }
        for rule in input.routing.customRules where rule.enabled {
            yaml += "  - \(quoted(try rule.validated().clashLine(input)))\n"
        }
        let aiTarget = input.routing.ai.policy(input)
        let anthropicTarget = input.routing.anthropicTarget(useHomeProxy: input.useHomeProxy).policy(input)
        let developmentTarget = input.routing.development.policy(input)
        yaml += "  - DOMAIN,downloads.claude.ai,\(aiTarget)\n"
        for rule in ["DOMAIN-SUFFIX,anthropic.com", "DOMAIN-SUFFIX,claude.ai", "DOMAIN-SUFFIX,claude.com", "DOMAIN-SUFFIX,claudeusercontent.com"] {
            yaml += "  - \(rule),\(anthropicTarget)\n"
        }
        for rule in ["DOMAIN-SUFFIX,openai.com", "DOMAIN-SUFFIX,chatgpt.com", "DOMAIN-SUFFIX,oaistatic.com", "DOMAIN-SUFFIX,oaiusercontent.com",
                     "DOMAIN-SUFFIX,sora.com", "DOMAIN-SUFFIX,chat.com", "DOMAIN-SUFFIX,ai.com", "DOMAIN-SUFFIX,gemini.google.com",
                     "DOMAIN-SUFFIX,generativelanguage.googleapis.com", "DOMAIN-SUFFIX,ai.google.dev", "DOMAIN-SUFFIX,aistudio.google.com",
                     "DOMAIN-SUFFIX,makersuite.google.com", "DOMAIN-SUFFIX,alkalimakersuite-pa.clients6.google.com", "DOMAIN-SUFFIX,deepmind.google",
                     "DOMAIN-SUFFIX,notebooklm.google.com", "DOMAIN-SUFFIX,notebooklm.google", "DOMAIN-SUFFIX,bard.google.com",
                     "DOMAIN-SUFFIX,x.ai", "DOMAIN-SUFFIX,grok.com", "DOMAIN-SUFFIX,cursor.sh", "DOMAIN-SUFFIX,cursor.com", "DOMAIN-SUFFIX,cursorapi.com",
                     "DOMAIN,copilot-proxy.githubusercontent.com", "DOMAIN-SUFFIX,githubcopilot.com"] {
            yaml += "  - \(rule),\(aiTarget)\n"
        }
        for rule in ["DOMAIN-SUFFIX,docker.io", "DOMAIN,api.github.com", "DOMAIN-SUFFIX,github.com", "DOMAIN-SUFFIX,githubusercontent.com", "DOMAIN-SUFFIX,githubassets.com", "DOMAIN-SUFFIX,github.io"] {
            yaml += "  - \(rule),\(developmentTarget)\n"
        }
        for rule in ["DOMAIN-SUFFIX,apple-relay.apple.com", "DOMAIN-SUFFIX,apple-relay.fastly-edge.com", "DOMAIN-SUFFIX,apple-relay.cloudflare.com", "DOMAIN-SUFFIX,guzzoni.apple.com"] {
            yaml += "  - \(rule),DIRECT\n"
        }
        yaml += "  - MATCH,\(input.proxyOtherSites ? input.exitGroup : "DIRECT")\n"
        let limiter: [String: Any] = [
            "listen": "\(listen.host):\(listen.port)", "via": "127.0.0.1:\(input.socksPort)",
            "upstream": "\(homeServer):\(homePort)", "username": input.homeUsername, "password": input.homePassword,
            "max_concurrent": input.maxConcurrent, "max_inflight_dials": 1, "dial_interval_ms": input.dialIntervalMs,
            "queue_wait_s": input.queueWaitS, "handshake_timeout_s": 20
        ]
        let json = try JSONSerialization.data(withJSONObject: limiter, options: [.prettyPrinted, .sortedKeys])
        return DialerProxyFiles(yaml: yaml, limiterJSON: String(data: json, encoding: .utf8)! + "\n", limiterPython: limiterPython())
    }

    public static func limiterPython() -> String {
        let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("CodexSwitch_CodexSwitchCore.bundle")) }
        guard let url = (packaged ?? Bundle.module).url(forResource: "socks-limiter", withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    // Same label rule as DialerProxyBuilder.cs. HK must be its own token.
    public static func isHongKong(_ name: String) -> Bool {
        if name.contains("🇭🇰") || name.contains("香港") || name.localizedCaseInsensitiveContains("Hong Kong") || name.localizedCaseInsensitiveContains("HongKong") {
            return true
        }
        return name.range(of: #"(^|[^A-Za-z])HK\d*([^A-Za-z]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func withoutHongKong(_ names: [String]) -> [String] { names.filter { !isHongKong($0) } }

    public static func preferred(_ names: [String], _ first: String, _ second: String = "") -> String {
        if names.contains(first) { return first }
        if names.contains(second) { return second }
        return names.first ?? ""
    }

    private static func prefer(_ names: [String], _ selection: String) -> [String] {
        guard names.contains(selection) else { return names }
        return [selection] + names.filter { $0 != selection }
    }

    public static let exitTestURL = "https://downloads.claude.ai"
    public static func probeName(_ index: Int) -> String { "codex-switch-chain-\(index)" }

    public static func buildProbe(_ input: DialerProxyInput, controller: String, chain: Bool) throws -> String {
        let relay = try RelayImport.extractProxies(input.relayYaml)
        let names = extractRelayNames(relay)
        var yaml = "log-level: warning\nexternal-controller: \(scalar(controller))\nipv6: false\nproxies:\n" + indent(relay) + "\n"
        if chain {
            guard !input.homeServer.isEmpty, let port = Int(input.homePort), (1...65535).contains(port) else {
                throw StoreError("请填写家宽 SOCKS5 的地址和有效端口。")
            }
            for (index, name) in names.enumerated() {
                guard !names.contains(probeName(index)) else { throw StoreError("订阅节点名与测速节点保留名称冲突。") }
                yaml += "  - name: \(probeName(index))\n    type: socks5\n    server: \(scalar(input.homeServer))\n    port: \(port)\n"
                if !input.homeUsername.isEmpty {
                    yaml += "    username: \(quoted(input.homeUsername))\n    password: \(quoted(input.homePassword))\n"
                }
                yaml += "    udp: false\n    dialer-proxy: \(scalar(name))\n"
            }
        }
        return yaml + "rules:\n  - MATCH,DIRECT\n"
    }

    public static func validate(_ input: DialerProxyInput) throws {
        try input.routing.validate(useHomeProxy: input.useHomeProxy)
        guard (1...65535).contains(input.httpPort), (1...65535).contains(input.socksPort),
              ( !input.useHomeProxy || Int(input.homePort).map { (1...65535).contains($0) } == true ) else {
            throw StoreError("端口需要是 1 到 65535 的数字。")
        }
        let controller = try LocalEndpoint(input.controller)
        let limiter = try LocalEndpoint(input.limiterListen)
        guard Set([input.httpPort, input.socksPort, controller.port, limiter.port]).count == 4 else {
            throw StoreError("HTTP、SOCKS、控制和限流端口不能重复。")
        }
        guard input.maxConcurrent > 0, input.dialIntervalMs >= 0, input.queueWaitS > 0 else {
            throw StoreError("并发数和排队秒数必须大于 0，拨号间隔不能为负。")
        }
        let names = extractRelayNames(input.relayYaml)
        let reserved = [input.relayGroup, input.exitGroup, input.targetName, developmentGroup, developmentAutomaticGroup]
        guard Set(reserved).count == reserved.count, reserved.allSatisfy({ !$0.isEmpty && !$0.contains(",") && !$0.contains("\n") }),
              !names.contains(where: { reserved.contains($0) || ["DIRECT", "REJECT"].contains($0) }) else {
            throw StoreError("代理组名称为空、重复或与订阅节点冲突。")
        }
    }

    private static func indent(_ relay: String) -> String {
        let lines = relay.components(separatedBy: "\n")
        let padding = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        return lines.map { "  " + $0.dropFirst(min(padding, $0.count)) }.joined(separator: "\n")
    }
    static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
    private static func scalar(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z_][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil,
           !["true", "false", "null", "yes", "no", "on", "off"].contains(value.lowercased()) { return value }
        return quoted(value)
    }
    private static func splitHostPort(_ value: String, _ host: String, _ port: String) -> (host: String, port: String) {
        guard let idx = value.lastIndex(of: ":"), idx > value.startIndex else { return (host, port) }
        return (String(value[..<idx]), String(value[value.index(after: idx)...]))
    }
}
