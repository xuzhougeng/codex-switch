import Foundation

public struct ProxyStatusSnapshot: Equatable, Sendable {
    public var state = ClashProxyStatus()
    public var systemProxy = false
    public var systemRecovery = false
    public var bootEnabled = false
    public var connections: ProxyConnections?
    public var liveRelay = ""
    public var liveExit = ""
    public var pace = ""
    public var socksConfiguration = SocksRuntimeConfiguration()
    public init() {}
}

/// File reads and connection decoding stay off the UI actor; publish one coherent result.
public actor ProxyStatusReader {
    private let runtime: ClashProxyRuntime
    private let system: MacSystemProxy
    private let store: ClashProxyStore
    public init(runtime: ClashProxyRuntime, system: MacSystemProxy, store: ClashProxyStore) {
        self.runtime = runtime; self.system = system; self.store = store
    }
    public func read() async throws -> ProxyStatusSnapshot {
        var result = ProxyStatusSnapshot()
        result.state = try await runtime.status()
        let active = try await runtime.runningSettings()
        result.socksConfiguration = SocksRuntimeConfiguration(active)
        result.systemRecovery = await system.hasBackup
        result.systemProxy = await system.isEnabled(port: active.httpPort)
        result.bootEnabled = await runtime.bootEnabled
        if result.state.running {
            let api = ClashAPI(controller: active.controller)
            async let relay = try? api.group(active.relayGroup)
            async let exit = try? api.group(active.exitGroup)
            async let connections = try? api.connections()
            result.liveRelay = await relay?.now ?? ""
            result.liveExit = await exit?.now ?? ""
            result.connections = await connections
            if let data = try? Data(contentsOf: store.limiterStateURL),
               let values = try? JSONDecoder().decode([String: Int].self, from: data) {
                result.pace = "活动 \(values["active"] ?? 0) · 排队 \(values["waiting"] ?? 0)"
            }
        }
        try Task.checkCancellation()
        return result
    }
}
