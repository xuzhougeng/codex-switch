import Foundation

public struct ClashProxySettings: Codable, Sendable, Equatable {
    public var httpPort = 1990
    public var socksPort = 1991
    public var controller = "127.0.0.1:1993"
    public var limiterListen = "127.0.0.1:1994"
    public var relayGroup = "relay-group"
    public var targetName = "target-socks5"
    public var relayYaml = ""
    public var homeServer = ""
    public var homePort = "1080"
    public var homeUsername = ""
    public var homePassword = ""
    public var maxConcurrent = 8
    public var dialIntervalMs = 250
    public var queueWaitS = 8
    public var mihomoPath = ""
    public var pythonPath = ""
    public init() {}
}

public actor ClashProxyStore {
    public nonisolated let home: URL
    public nonisolated var directory: URL { home.appendingPathComponent("codex-switch", isDirectory: true) }
    public nonisolated var settingsURL: URL { directory.appendingPathComponent("clash-proxy.json") }
    public nonisolated var workDirectory: URL { directory.appendingPathComponent("clash", isDirectory: true) }
    public nonisolated var yamlURL: URL { workDirectory.appendingPathComponent("ai.yaml") }
    public nonisolated var limiterJSONURL: URL { workDirectory.appendingPathComponent("socks-limiter.json") }
    public nonisolated var limiterPythonURL: URL { workDirectory.appendingPathComponent("socks-limiter.py") }
    public nonisolated var mihomoLogURL: URL { workDirectory.appendingPathComponent("mihomo.log") }
    public nonisolated var limiterLogURL: URL { workDirectory.appendingPathComponent("limiter.log") }
    public nonisolated var mihomoPidURL: URL { workDirectory.appendingPathComponent("mihomo.pid") }
    public nonisolated var limiterPidURL: URL { workDirectory.appendingPathComponent("limiter.pid") }
    private let fm = FileManager.default

    public init(home: URL? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public func load() throws -> ClashProxySettings {
        guard fm.fileExists(atPath: settingsURL.path) else { return ClashProxySettings() }
        do { return try JSONDecoder().decode(ClashProxySettings.self, from: Data(contentsOf: settingsURL)) }
        catch { throw StoreError("双跳代理配置文件无效。") }
    }

    public func save(_ settings: ClashProxySettings) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    public func materialize(_ settings: ClashProxySettings) throws -> DialerProxyFiles {
        let files = try DialerProxyBuilder.build(input(settings))
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        try files.limiterJSON.write(to: limiterJSONURL, atomically: true, encoding: .utf8)
        try files.limiterPython.write(to: limiterPythonURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: limiterJSONURL.path)
        return files
    }

    public func input(_ settings: ClashProxySettings) -> DialerProxyInput {
        DialerProxyInput(relayYaml: settings.relayYaml, homeServer: settings.homeServer, homePort: settings.homePort,
                         homeUsername: settings.homeUsername, homePassword: settings.homePassword,
                         relayGroup: settings.relayGroup, targetName: settings.targetName, httpPort: settings.httpPort,
                         socksPort: settings.socksPort, controller: settings.controller, limiterListen: settings.limiterListen,
                         maxConcurrent: settings.maxConcurrent, dialIntervalMs: settings.dialIntervalMs, queueWaitS: settings.queueWaitS)
    }
}
