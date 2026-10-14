import Foundation

public struct ClashProxySettings: Codable, Sendable, Equatable {
    public var proxyOtherSites = true
    public var useHomeProxy = false
    public var subscriptionUrl = ""
    public var selectedRelay = ""
    public var selectedExit = ""
    public var exitGroup = "exit-group"
    public var httpPort = 1990
    public var socksPort = 1991
    public var controller = "127.0.0.1:1993"
    public var limiterListen = "127.0.0.1:1994"
    public var relayGroup = "relay-group"
    public var targetName = "target-socks5"
    public var relayYaml = ""
    public var socksProfiles: [SocksProxyProfile] = []
    public var selectedSocksProfileID: String?
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

    private enum CodingKeys: String, CodingKey { case socksProfiles, selectedSocksProfileID, proxyOtherSites, useHomeProxy, subscriptionUrl, selectedRelay, selectedExit, exitGroup, httpPort, socksPort, controller, limiterListen, relayGroup, targetName, relayYaml, homeServer, homePort, homeUsername, homePassword, maxConcurrent, dialIntervalMs, queueWaitS, mihomoPath, pythonPath }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionUrl = try values.decodeIfPresent(String.self, forKey: .subscriptionUrl) ?? subscriptionUrl
        selectedRelay = try values.decodeIfPresent(String.self, forKey: .selectedRelay) ?? selectedRelay
        selectedExit = try values.decodeIfPresent(String.self, forKey: .selectedExit) ?? selectedExit
        exitGroup = try values.decodeIfPresent(String.self, forKey: .exitGroup) ?? exitGroup
        httpPort = try values.decodeIfPresent(Int.self, forKey: .httpPort) ?? httpPort
        socksPort = try values.decodeIfPresent(Int.self, forKey: .socksPort) ?? socksPort
        controller = try values.decodeIfPresent(String.self, forKey: .controller) ?? controller
        limiterListen = try values.decodeIfPresent(String.self, forKey: .limiterListen) ?? limiterListen
        relayGroup = try values.decodeIfPresent(String.self, forKey: .relayGroup) ?? relayGroup
        targetName = try values.decodeIfPresent(String.self, forKey: .targetName) ?? targetName
        relayYaml = try values.decodeIfPresent(String.self, forKey: .relayYaml) ?? relayYaml
        homeServer = try values.decodeIfPresent(String.self, forKey: .homeServer) ?? homeServer
        homePort = try values.decodeIfPresent(String.self, forKey: .homePort) ?? homePort
        homeUsername = try values.decodeIfPresent(String.self, forKey: .homeUsername) ?? homeUsername
        homePassword = try values.decodeIfPresent(String.self, forKey: .homePassword) ?? homePassword
        maxConcurrent = try values.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? maxConcurrent
        dialIntervalMs = try values.decodeIfPresent(Int.self, forKey: .dialIntervalMs) ?? dialIntervalMs
        queueWaitS = try values.decodeIfPresent(Int.self, forKey: .queueWaitS) ?? queueWaitS
        mihomoPath = try values.decodeIfPresent(String.self, forKey: .mihomoPath) ?? mihomoPath
        proxyOtherSites = try values.decodeIfPresent(Bool.self, forKey: .proxyOtherSites) ?? false
        useHomeProxy = try values.decodeIfPresent(Bool.self, forKey: .useHomeProxy) ?? !homeServer.isEmpty
        pythonPath = try values.decodeIfPresent(String.self, forKey: .pythonPath) ?? pythonPath
        socksProfiles = try values.decodeIfPresent([SocksProxyProfile].self, forKey: .socksProfiles) ?? []
        selectedSocksProfileID = try values.decodeIfPresent(String.self, forKey: .selectedSocksProfileID)
        if socksProfiles.isEmpty && !homeServer.isEmpty {
            let migrated = SocksProxyProfile(id: "legacy-home-proxy", name: "家宽代理", server: homeServer,
                                             port: homePort, username: homeUsername, password: homePassword)
            socksProfiles = [migrated]; selectedSocksProfileID = migrated.id
        }
    }
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
    public nonisolated var serviceLogURL: URL { workDirectory.appendingPathComponent("service.log") }
    public nonisolated var readyURL: URL { workDirectory.appendingPathComponent("service.ready") }
    public nonisolated var servicePidURL: URL { workDirectory.appendingPathComponent("service.pid") }
    public nonisolated var runtimeSettingsURL: URL { workDirectory.appendingPathComponent("running.json") }
    public nonisolated var limiterStateURL: URL { workDirectory.appendingPathComponent("limiter-state.json") }
    public nonisolated var kernelDirectory: URL { directory.appendingPathComponent("kernel", isDirectory: true) }
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
        for url in [yamlURL, limiterJSONURL, limiterPythonURL] {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return files
    }

    public nonisolated func input(_ settings: ClashProxySettings) -> DialerProxyInput {
        DialerProxyInput(relayYaml: settings.relayYaml, homeServer: settings.homeServer, homePort: settings.homePort,
                         homeUsername: settings.homeUsername, homePassword: settings.homePassword,
                         relayGroup: settings.relayGroup, targetName: settings.targetName, httpPort: settings.httpPort,
                         socksPort: settings.socksPort, controller: settings.controller, limiterListen: settings.limiterListen,
                         maxConcurrent: settings.maxConcurrent, dialIntervalMs: settings.dialIntervalMs, queueWaitS: settings.queueWaitS, selectedRelay: settings.selectedRelay,
                         exitGroup: settings.exitGroup, selectedExit: settings.selectedExit, useHomeProxy: settings.useHomeProxy, proxyOtherSites: settings.proxyOtherSites)
    }
}
