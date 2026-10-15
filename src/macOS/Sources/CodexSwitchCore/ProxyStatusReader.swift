import Foundation

public struct ProxyStatusSnapshot: Equatable, Sendable {
    public var state = ClashProxyStatus()
    public var systemProxy = false
    public var systemRecovery = false
    public var bootEnabled = false
    public var connections: ProxyConnections?
    public var traffic = TrafficSnapshot()
    public var liveRelay = ""
    public var liveExit = ""
    public var liveDevelopment = ""
    public var automaticDevelopment = ""
    public var routing = RoutingConfiguration()
    public var proxyOtherSites = false
    public var pace = ""
    public var socksConfiguration = SocksRuntimeConfiguration()
    public init() {}
}

/// File reads and connection decoding stay off the UI actor; publish one coherent result.
public actor ProxyStatusReader {
    private let runtime: ClashProxyRuntime
    private let system: MacSystemProxy
    private let store: ClashProxyStore
    private var tracker = ConnectionTracker()
    public init(runtime: ClashProxyRuntime, system: MacSystemProxy, store: ClashProxyStore) {
        self.runtime = runtime; self.system = system; self.store = store
    }
    public func clearTraffic() {
        tracker.clear()
    }
    public func read() async throws -> ProxyStatusSnapshot {
        var result = ProxyStatusSnapshot()
        result.state = try await runtime.status()
        let active = try await runtime.runningSettings()
        result.socksConfiguration = SocksRuntimeConfiguration(active)
        result.routing = active.routing; result.proxyOtherSites = active.proxyOtherSites
        result.systemRecovery = await system.hasBackup
        result.systemProxy = await system.isEnabled(port: active.httpPort)
        result.bootEnabled = await runtime.bootEnabled
        if result.state.running {
            let api = ClashAPI(controller: active.controller)
            async let relay = try? api.group(active.relayGroup)
            async let exit = try? api.group(active.exitGroup)
            async let development = try? api.group(DialerProxyBuilder.developmentGroup)
            async let automatic = try? api.group(DialerProxyBuilder.developmentAutomaticGroup)
            async let connections = try? api.connections()
            result.liveRelay = await relay?.now ?? ""
            result.liveExit = await exit?.now ?? ""
            result.liveDevelopment = await development?.now ?? ""
            result.automaticDevelopment = await automatic?.now ?? ""
            result.connections = await connections
            if let connections = await connections {
                result.traffic = tracker.ingest(connections, at: Date())
            }
            if let data = try? Data(contentsOf: store.limiterStateURL),
               let values = try? JSONDecoder().decode([String: Int].self, from: data) {
                result.pace = "活动 \(values["active"] ?? 0) · 排队 \(values["waiting"] ?? 0)"
            }
        } else {
            // Stopped: finalize live connections so the session totals keep their last bytes.
            tracker.markStopped()
            result.traffic = tracker.snapshot()
        }
        try Task.checkCancellation()
        return result
    }
}
