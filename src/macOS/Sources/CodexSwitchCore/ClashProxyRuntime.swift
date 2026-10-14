import Foundation
import Darwin

public struct ClashProxyStatus: Equatable, Sendable {
    public var running: Bool
    public var detail: String
    public var mihomoPid: Int32?
    public var limiterPid: Int32?
    public init(running: Bool = false, detail: String = "未运行", mihomoPid: Int32? = nil, limiterPid: Int32? = nil) {
        self.running = running; self.detail = detail; self.mihomoPid = mihomoPid; self.limiterPid = limiterPid
    }
}

public actor ClashProxyRuntime {
    private let store: ClashProxyStore
    private let executable: String
    private let userHome: URL
    public init(store: ClashProxyStore, executable: String = CommandLine.arguments[0], userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.store = store; self.executable = URL(fileURLWithPath: executable).standardizedFileURL.path; self.userHome = userHome
    }
    public nonisolated var launchAgentURL: URL {
        userHome.appendingPathComponent("Library/LaunchAgents/local.codexswitch.proxy.plist")
    }
    public var bootEnabled: Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return false }
        return args.contains(store.home.path)
    }
    private var launchDomain: String { "gui/\(getuid())" }
    private var launchLabel: String { launchDomain + "/local.codexswitch.proxy" }

    public func runningSettings() async throws -> ClashProxySettings {
        if let data = try? Data(contentsOf: store.runtimeSettingsURL), let settings = try? JSONDecoder().decode(ClashProxySettings.self, from: data) { return settings }
        return try await store.load()
    }
    public func status() async throws -> ClashProxyStatus {
        let settings = try await runningSettings()
        let mihomo = await ownedPID(store.mihomoPidURL, marker: store.yamlURL.path)
        let limiter = await ownedPID(store.limiterPidURL, marker: store.limiterJSONURL.path)
        let ready = FileManager.default.fileExists(atPath: store.readyURL.path) && mihomo != nil && (!settings.useHomeProxy || limiter != nil) && ProxyProcess.listening(settings.httpPort)
            && (!settings.useHomeProxy || ProxyProcess.listening((try? LocalEndpoint(settings.limiterListen).port) ?? 1994))
        return ClashProxyStatus(running: ready, detail: ready ? "运行中 · HTTP 127.0.0.1:\(settings.httpPort)" :
            (mihomo != nil || limiter != nil ? "启动中或异常，请查看日志" : "未运行"), mihomoPid: mihomo, limiterPid: limiter)
    }
    private func ownedPID(_ url: URL, marker: String) async -> Int32? {
        guard let pid = ProxyProcess.readPID(url), await ProxyProcess.owns(pid, marker: marker) else { return nil }
        return pid
    }
    public func start(_ settings: ClashProxySettings) async throws -> ClashProxyStatus {
        if try await status().running { return try await status() }
        _ = try await MihomoKernel.check(settings, store: store)
        if settings.useHomeProxy { _ = try ProxyProcess.resolve(settings.pythonPath, names: ["python3"]) }
        try await stop()
        try await store.save(settings)
        _ = try await store.materialize(settings)
        if bootEnabled {
            _ = try await ProxyProcess.run("/bin/launchctl", ["bootstrap", launchDomain, launchAgentURL.path])
        } else {
            _ = try ProxyProcess.launch(executable, ["--proxy-service", "--home", store.home.path], cwd: store.workDirectory, log: store.serviceLogURL)
        }
        do {
            for _ in 0..<150 {
                try Task.checkCancellation()
                if try await status().running { return try await status() }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw StoreError("代理启动失败：\n" + ProxyLog.tail(store.serviceLogURL))
        } catch {
            try? await stop()
            throw error
        }
    }
    public func stop() async throws {
        // Bootout prevents launchd from respawning the daemon while the user stops it.
        if bootEnabled, (try? await ProxyProcess.run("/bin/launchctl", ["print", launchLabel], timeout: 3)) != nil {
            _ = try await ProxyProcess.run("/bin/launchctl", ["bootout", launchLabel], timeout: 5)
        }
        for (url, marker) in [(store.servicePidURL, "--proxy-service --home " + store.home.path),
                              (store.mihomoPidURL, store.yamlURL.path), (store.limiterPidURL, store.limiterJSONURL.path)] {
            if let pid = await ownedPID(url, marker: marker) {
                kill(pid, SIGTERM)
                for _ in 0..<30 {
                    if kill(pid, 0) != 0 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if kill(pid, 0) == 0, await ProxyProcess.owns(pid, marker: marker) { kill(pid, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: store.readyURL)
        try? FileManager.default.removeItem(at: store.runtimeSettingsURL)
        try? FileManager.default.removeItem(at: store.limiterStateURL)
    }
    public func restart(_ settings: ClashProxySettings) async throws -> ClashProxyStatus {
        // Validate before stopping a working proxy.
        _ = try await MihomoKernel.check(settings, store: store)
        try await stop()
        return try await start(settings)
    }
    public func select(_ settings: ClashProxySettings, name: String, route: ProxyRoute) async throws -> String {
        let names = DialerProxyBuilder.extractRelayNames(settings.relayYaml)
        guard names.contains(name), route != .exit || !DialerProxyBuilder.isHongKong(name) else { throw StoreError("不能选择这个节点。") }
        var updated = settings
        if route == .relay { updated.selectedRelay = name } else { updated.selectedExit = name }
        try await store.save(updated)
        guard try await status().running else { return "已保存，启动后生效。" }
        let active = try await runningSettings()
        do {
            let group = route == .relay ? active.relayGroup : active.exitGroup
            try await ClashAPI(controller: active.controller).select(group: group, name: name)
            return "已切换到 \(name)"
        } catch {
            throw StoreError("选择已保存，但未切换运行中的服务。请点击重启应用配置。\n" + error.localizedDescription)
        }
    }
    public static func launchAgentData(executable: String, store: ClashProxyStore) throws -> Data {
        let plist: [String: Any] = [
            "Label": "local.codexswitch.proxy", "ProgramArguments": [executable, "--proxy-service", "--home", store.home.path],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
            "WorkingDirectory": store.workDirectory.path, "StandardOutPath": store.serviceLogURL.path,
            "StandardErrorPath": store.serviceLogURL.path, "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
    public func setBootEnabled(_ enabled: Bool, settings: ClashProxySettings) async throws {
        if enabled {
            if FileManager.default.fileExists(atPath: launchAgentURL.path) && !bootEnabled {
                throw StoreError("已有另一份配置的登录自启动服务，请先关闭它。")
            }
            _ = try await MihomoKernel.check(settings, store: store)
            if settings.useHomeProxy { _ = try ProxyProcess.resolve(settings.pythonPath, names: ["python3"]) }
            try await stop()
            try await store.save(settings)
            _ = try await store.materialize(settings)
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.launchAgentData(executable: executable, store: store).write(to: launchAgentURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchAgentURL.path)
            _ = try await start(settings)
        } else {
            try await stop()
            if bootEnabled { try FileManager.default.removeItem(at: launchAgentURL) }
        }
    }

    /// Headless entry point used both by the app and its login LaunchAgent.
    public static func serve(home: URL) async -> Int32 {
        let store = ClashProxyStore(home: home)
        let fm = FileManager.default
        var children: [Process] = []
        var lockFD: Int32 = -1
        var ownsLock = false
        var sources: [DispatchSourceSignal] = []
        let stop = ServiceStop()
        defer {
            for source in sources { source.cancel() }
            if ownsLock {
                for url in [store.readyURL, store.servicePidURL, store.mihomoPidURL, store.limiterPidURL, store.runtimeSettingsURL, store.limiterStateURL] { try? fm.removeItem(at: url) }
            }
            if lockFD >= 0 { close(lockFD) }
        }
        do {
            try fm.createDirectory(at: store.workDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockFD = open(store.workDirectory.appendingPathComponent("service.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw StoreError("代理服务已在运行。") }
            ownsLock = true
            for (url, marker) in [(store.mihomoPidURL, store.yamlURL.path), (store.limiterPidURL, store.limiterJSONURL.path)] {
                if let pid = ProxyProcess.readPID(url), await ProxyProcess.owns(pid, marker: marker) {
                    kill(pid, SIGTERM)
                    for _ in 0..<20 {
                        if kill(pid, 0) != 0 { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if kill(pid, 0) == 0, await ProxyProcess.owns(pid, marker: marker) { kill(pid, SIGKILL) }
                }
            }
            try? fm.removeItem(at: store.readyURL)
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler { Task { await stop.request() } }
                source.resume(); sources.append(source)
            }
            let settings = try await store.load()
            let kernel = try MihomoKernel.resolve(settings, store: store)
            let python = settings.useHomeProxy ? try ProxyProcess.resolve(settings.pythonPath, names: ["python3"]) : ""
            _ = try await store.materialize(settings)
            _ = try await ProxyProcess.run(kernel, ["-d", store.workDirectory.path, "-f", store.yamlURL.path, "-t"], cwd: store.workDirectory)
            for port in [settings.httpPort, settings.socksPort, try LocalEndpoint(settings.controller).port, try LocalEndpoint(settings.limiterListen).port] {
                guard !ProxyProcess.listening(port) else { throw StoreError("端口 \(port) 已被占用，请停止其他代理或修改端口。") }
            }
            try String(getpid()).write(to: store.servicePidURL, atomically: true, encoding: .utf8)
            let snapshot = try JSONEncoder().encode(settings)
            try snapshot.write(to: store.runtimeSettingsURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.runtimeSettingsURL.path)
            if settings.useHomeProxy {
            let limiter = try ProxyProcess.launch(python, ["-u", store.limiterPythonURL.path, "-c", store.limiterJSONURL.path], cwd: store.workDirectory, log: store.limiterLogURL)
            children.append(limiter)
            try String(limiter.processIdentifier).write(to: store.limiterPidURL, atomically: true, encoding: .utf8)
            }
            let mihomo = try ProxyProcess.launch(kernel, ["-d", store.workDirectory.path, "-f", store.yamlURL.path], cwd: store.workDirectory, log: store.mihomoLogURL)
            children.append(mihomo)
            try String(mihomo.processIdentifier).write(to: store.mihomoPidURL, atomically: true, encoding: .utf8)
            let api = ClashAPI(controller: settings.controller)
            let deadline = Date().addingTimeInterval(12)
            while true {
                if await stop.requested { throw CancellationError() }
                guard children.allSatisfy(\.isRunning), Date() < deadline else { throw StoreError("代理内核或限流器未就绪，请查看日志。") }
                do {
                    _ = try await api.group(settings.relayGroup)
                    if !settings.useHomeProxy || ProxyProcess.listening((try? LocalEndpoint(settings.limiterListen).port) ?? 1994) { break }
                } catch { }
                try await Task.sleep(for: .milliseconds(100))
            }
            let names = DialerProxyBuilder.extractRelayNames(settings.relayYaml)
            let exits = DialerProxyBuilder.withoutHongKong(names)
            for (group, name) in [
                (settings.relayGroup, DialerProxyBuilder.preferred(names, settings.selectedRelay)),
                (settings.exitGroup, DialerProxyBuilder.preferred(exits.isEmpty ? names : exits, settings.selectedExit, settings.selectedRelay))
            ] { try await api.select(group: group, name: name) }
            let limiterPort = try LocalEndpoint(settings.limiterListen).port
            guard ProxyProcess.listening(settings.httpPort), !settings.useHomeProxy || ProxyProcess.listening(limiterPort) else {
                throw StoreError("代理入口未就绪。")
            }
            try Data().write(to: store.readyURL)
            print("INFO 代理服务已启动，HTTP 127.0.0.1:\(settings.httpPort)")
            while !(await stop.requested) {
                guard children.allSatisfy(\.isRunning) else { throw StoreError("mihomo 或限流进程意外退出。") }
                try await Task.sleep(for: .milliseconds(300))
            }
            for child in children.reversed() { await ProxyProcess.terminate(child) }
            return 0
        } catch {
            for child in children.reversed() { await ProxyProcess.terminate(child) }
            print("ERROR " + error.localizedDescription)
            return 1
        }
    }
}

private actor ServiceStop {
    var requested = false
    func request() { requested = true }
}
