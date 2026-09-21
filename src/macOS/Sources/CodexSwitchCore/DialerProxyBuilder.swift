import Foundation

public struct DialerProxyInput: Sendable {
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
                dialIntervalMs: Int = 250, queueWaitS: Int = 8) {
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
    public static func extractRelayNames(_ yaml: String) -> [String] {
        var names: [String] = []
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- name:") || trimmed.hasPrefix("-name:") else { continue }
            var value = trimmed.replacingOccurrences(of: "- name:", with: "").replacingOccurrences(of: "-name:", with: "")
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'")))
            if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
            if !value.isEmpty, !names.contains(value) { names.append(value) }
        }
        return names
    }

    public static func build(_ input: DialerProxyInput) throws -> DialerProxyFiles {
        var relay = input.relayYaml.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if relay.hasPrefix("proxies:"), let nl = relay.firstIndex(of: "\n") {
            relay = String(relay[relay.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let names = extractRelayNames(relay)
        guard !names.isEmpty else { throw StoreError("请粘贴至少一个中转节点（需要 `- name:`）。") }
        let homeServer = input.homeServer.trimmingCharacters(in: .whitespaces)
        let homePort = input.homePort.trimmingCharacters(in: .whitespaces)
        guard !homeServer.isEmpty, !homePort.isEmpty else { throw StoreError("请填写美国家宽 SOCKS5 的地址和端口。") }
        let listen = splitHostPort(input.limiterListen, "127.0.0.1", "1994")
        let group = input.relayGroup.isEmpty ? "relay-group" : input.relayGroup
        let target = input.targetName.isEmpty ? "target-socks5" : input.targetName
        let ipv4 = homeServer.range(of: #"^(?:\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil
        let loop = ipv4 ? "IP-CIDR,\(homeServer)/32,\(group),no-resolve" : "DOMAIN,\(homeServer),\(group)"
        var yaml = ""
        yaml += "port: \(input.httpPort)\nsocks-port: \(input.socksPort)\nallow-lan: true\nmode: rule\nlog-level: info\n"
        yaml += "external-controller: \(scalar(input.controller))\nipv6: false\ntcp-concurrent: false\nkeep-alive-idle: 15\nkeep-alive-interval: 15\nproxies:\n"
        yaml += indent(relay) + "\n"
        yaml += "  - name: \(scalar(target))\n    type: socks5\n    server: \(listen.host)\n    port: \(listen.port)\n    udp: false\n    ip-version: ipv4\n"
        yaml += "proxy-groups:\n  - name: \(scalar(group))\n    type: select\n    proxies:\n"
        for name in names { yaml += "      - \(scalar(name))\n" }
        yaml += "  - name: Proxy\n    type: select\n    proxies:\n"
        for name in names { yaml += "      - \(scalar(name))\n" }
        yaml += "      - \(scalar(target))\nrules:\n  - \(loop)\n"
        for rule in ["DOMAIN-SUFFIX,docker.io", "DOMAIN,api.github.com"] { yaml += "  - \(rule),\(group)\n" }
        for rule in ["DOMAIN-SUFFIX,openai.com", "DOMAIN-SUFFIX,chatgpt.com", "DOMAIN-SUFFIX,anthropic.com",
                     "DOMAIN-SUFFIX,claude.ai", "DOMAIN-SUFFIX,x.ai", "DOMAIN-SUFFIX,grok.com"] {
            yaml += "  - \(rule),\(target)\n"
        }
        yaml += "  - MATCH,DIRECT\n"
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
        guard let url = Bundle.module.url(forResource: "socks-limiter", withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private static func indent(_ relay: String) -> String {
        relay.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if line.isEmpty { return "" }
            return line.first == " " || line.first == "\t" ? String(line) : "  " + line
        }.joined(separator: "\n")
    }
    private static func scalar(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func splitHostPort(_ value: String, _ host: String, _ port: String) -> (host: String, port: String) {
        guard let idx = value.lastIndex(of: ":"), idx > value.startIndex else { return (host, port) }
        return (String(value[..<idx]), String(value[value.index(after: idx)...]))
    }
}
