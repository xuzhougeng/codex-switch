import Foundation

public struct SocksProxyProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var server: String
    public var port: String
    public var username: String
    public var password: String
    public init(id: String = UUID().uuidString, name: String = "", server: String = "", port: String = "1080",
                username: String = "", password: String = "") {
        self.id = id; self.name = name; self.server = server; self.port = port
        self.username = username; self.password = password
    }
    public var endpoint: String { (server.contains(":") ? "[\(server)]" : server) + ":" + port }
    public var usesAuthentication: Bool { !username.isEmpty || !password.isEmpty }

    public func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        result.port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty else { throw StoreError("请为这个代理填写名称，方便以后切换。") }
        guard !result.server.isEmpty else { throw StoreError("请填写服务器地址。") }
        guard !result.server.contains(where: { $0.isWhitespace }),
              result.server.rangeOfCharacter(from: CharacterSet(charactersIn: "/@?#\\").union(.controlCharacters)) == nil else {
            throw StoreError("服务器只需填写域名或 IP；完整链接请使用「导入链接」。")
        }
        guard !result.port.isEmpty, result.port.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(result.port), (1...65535).contains(port) else { throw StoreError("端口应为 1–65535 的整数，例如 1080。") }
        _ = try SocksEndpoint("socks5://" + result.endpoint)
        result.port = String(port)
        if usesAuthentication {
            guard !username.isEmpty, !password.isEmpty else { throw StoreError("启用认证时，请同时填写用户名与密码。") }
            guard username.utf8.count <= 255, password.utf8.count <= 255 else { throw StoreError("用户名与密码分别不能超过 255 字节。") }
        }
        return result
    }
    /// An imported endpoint replaces all credentials, including absent credentials.
    public mutating func importAddress(_ text: String) throws {
        let endpoint = try SocksEndpoint(text)
        server = endpoint.host; port = endpoint.port ?? "1080"
        username = endpoint.username ?? ""; password = endpoint.password ?? ""
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "SOCKS5 代理" }
    }
    public func apply(to settings: inout ClashProxySettings) {
        settings.homeServer = server; settings.homePort = port
        settings.homeUsername = username; settings.homePassword = password
    }
}

/// Only settings that require restarting the home SOCKS service participate in comparison.
public struct SocksRuntimeConfiguration: Equatable, Sendable {
    private let enabled: Bool
    private let server: String
    private let port: String
    private let username: String
    private let password: String
    public init(_ settings: ClashProxySettings = ClashProxySettings()) {
        enabled = settings.useHomeProxy
        server = enabled ? settings.homeServer : ""; port = enabled ? settings.homePort : ""
        username = enabled ? settings.homeUsername : ""; password = enabled ? settings.homePassword : ""
    }
}

extension ClashProxySettings {
    public var selectedSocksProfile: SocksProxyProfile? { socksProfiles.first { $0.id == selectedSocksProfileID } }
    public mutating func upsertSocksProfile(_ profile: SocksProxyProfile, select: Bool) throws {
        let profile = try profile.validated()
        if let index = socksProfiles.firstIndex(where: { $0.id == profile.id }) { socksProfiles[index] = profile }
        else { socksProfiles.append(profile) }
        if select || selectedSocksProfileID == profile.id {
            selectedSocksProfileID = profile.id; profile.apply(to: &self)
        }
        if select { useHomeProxy = true }
    }
    public mutating func selectSocksProfile(_ id: String) throws {
        guard let profile = socksProfiles.first(where: { $0.id == id }) else { throw StoreError("这个 SOCKS5 配置已不存在。") }
        try upsertSocksProfile(profile, select: true)
    }
    public mutating func removeSocksProfile(_ id: String) {
        socksProfiles.removeAll { $0.id == id }
        if selectedSocksProfileID == id {
            selectedSocksProfileID = nil; useHomeProxy = false
            homeServer = ""; homePort = "1080"; homeUsername = ""; homePassword = ""
        }
    }
}
