import AppKit
import SwiftUI
import CodexSwitchCore

@MainActor
final class ProxyModel: ObservableObject {
    @Published var settings = ClashProxySettings() {
        didSet { if oldValue.relayYaml != settings.relayYaml { rebuildCatalog() } }
    }
    @Published private(set) var snapshot = ProxyStatusSnapshot()
    var state: ClashProxyStatus {
        get { snapshot.state }
        set { if snapshot.state != newValue { snapshot.state = newValue } }
    }
    @Published var message = "导入订阅后即可启动代理。"
    @Published var busy = false
    @Published var cancellable = false
    var systemProxy: Bool { snapshot.systemProxy }
    var systemRecovery: Bool { snapshot.systemRecovery }
    var bootEnabled: Bool { snapshot.bootEnabled }
    @Published var kernelVersion = "尚未检查"
    var connections: ProxyConnections? { snapshot.connections }
    var liveRelay: String { snapshot.liveRelay }
    var liveExit: String { snapshot.liveExit }
    var liveDevelopment: String {
        let selected = snapshot.liveDevelopment == DialerProxyBuilder.developmentAutomaticGroup ? snapshot.automaticDevelopment : snapshot.liveDevelopment
        return selected == settings.exitGroup ? snapshot.liveExit : selected
    }
    var rulesNeedApply: Bool {
        state.running && (settings.routing != snapshot.routing || settings.proxyOtherSites != snapshot.proxyOtherSites
                          || snapshot.automaticDevelopment.isEmpty)
    }
    var pace: String { snapshot.pace }
    var traffic: TrafficSnapshot { snapshot.traffic }
    @Published var logSource = "mihomo"
    @Published var problemsOnly = false
    @Published var logLines: [LogLine] = []
    @Published var search = "" {
        didSet { if oldValue != search { updateVisibleNodes(debounce: true) } }
    }
    @Published var route: ProxyRoute = .exit {
        didSet { if oldValue != route { updateVisibleNodes() } }
    }
    @Published var delays: [ProxyRoute: [String: Int]] = [:] {
        didSet { updateVisibleNodes(debounce: true) }
    }
    @Published private(set) var visibleNodes: [String] = []
    @Published private var catalog = ProxyNodeCatalog()
    private var catalogTask: Task<Void, Never>?
    private var nodesTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshRevision = 0
    @Published private(set) var socksTests: [String: SocksTestRecord] = [:]
    struct SocksTestRecord {
        enum Outcome { case testing, success(Int), failure(String), cancelled }
        let profile: SocksProxyProfile
        let relay: String
        let yaml: String
        var outcome: Outcome
    }
    var socksNeedsRestart: Bool { state.running && SocksRuntimeConfiguration(settings) != snapshot.socksConfiguration }
    func socksTest(for profile: SocksProxyProfile) -> SocksTestRecord.Outcome? {
        guard let record = socksTests[profile.id], record.profile == profile,
              record.relay == settings.selectedRelay, record.yaml == settings.relayYaml else { return nil }
        return record.outcome
    }
    private var probeFinished = 0
    private var loaded = false
    private var operation: Task<Void, Never>?
    private var socksSaveTask: Task<Void, Error>?
    let store: ClashProxyStore
    let runtime: ClashProxyRuntime
    let system: MacSystemProxy
    private let statusReader: ProxyStatusReader
    init(store: ClashProxyStore = ClashProxyStore()) {
        self.store = store
        runtime = ClashProxyRuntime(store: store)
        system = MacSystemProxy(store: store)
        statusReader = ProxyStatusReader(runtime: runtime, system: system, store: store)
    }
    var names: [String] { catalog.names }
    var candidates: [String] { catalog.candidates(for: route) }

    private func rebuildCatalog() {
        catalogTask?.cancel()
        nodesTask?.cancel()
        let yaml = settings.relayYaml
        catalogTask = Task {
            let parsed = await Task.detached(priority: .userInitiated) { ProxyNodeCatalog(yaml: yaml) }.value
            guard !Task.isCancelled else { return }
            catalog = parsed
            updateVisibleNodes()
        }
    }
    private func updateVisibleNodes(debounce: Bool = false) {
        nodesTask?.cancel()
        let catalog = catalog, route = route, search = search, delays = delays[route] ?? [:]
        nodesTask = Task {
            if debounce {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let nodes = await Task.detached(priority: .userInitiated) {
                catalog.visibleNodes(route: route, search: search, delays: delays)
            }.value
            guard !Task.isCancelled else { return }
            if visibleNodes != nodes { visibleNodes = nodes }
        }
    }
    var selection: String {
        switch route { case .relay: return settings.selectedRelay; case .exit: return settings.selectedExit; case .development: return settings.selectedDevelopment }
    }
    var liveSelection: String {
        switch route { case .relay: return liveRelay; case .exit: return liveExit; case .development: return liveDevelopment }
    }
    func applyPreset(_ preset: RoutingPreset) {
        var routing = settings.routing, otherSites = settings.proxyOtherSites
        routing.apply(preset, proxyOtherSites: &otherSites)
        settings.routing = routing; settings.proxyOtherSites = otherSites
        message = "已选择「\(preset.title)」，点击保存并应用后生效。"
    }
    func saveRules(apply: Bool) {
        run { [self] in
            try settings.routing.validate(useHomeProxy: settings.useHomeProxy)
            if apply { return try await runtime.applyRules(settings) }
            try await store.save(settings)
            return state.running ? "规则已保存，点击应用使其生效。" : "规则已保存，启动代理后生效。"
        }
    }
    var logURL: URL {
        switch logSource { case "服务": return store.serviceLogURL; case "限流": return store.limiterLogURL; default: return store.mihomoLogURL }
    }
    func load() async {
        guard !loaded else { return }
        do {
            settings = try await store.load()
            await catalogTask?.value
            loaded = true
            await refreshStatus()
            await readKernel()
        } catch { message = error.localizedDescription }
    }
    func refreshStatus() async {
        guard !busy else { return }
        if let refreshTask { await refreshTask.value; return }
        let revision = refreshRevision
        let task = Task { [self] in
            defer { if revision == refreshRevision { refreshTask = nil } }
            do {
                let updated = try await statusReader.read()
                guard !Task.isCancelled, revision == refreshRevision else { return }
                if snapshot != updated { snapshot = updated }
            } catch is CancellationError {
                // A foreground operation invalidates the older poll.
            } catch {
                if !Task.isCancelled, revision == refreshRevision { message = error.localizedDescription }
            }
        }
        refreshTask = task
        await task.value
    }
    func run(cancellable: Bool = false, _ work: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        refreshRevision += 1
        refreshTask?.cancel(); refreshTask = nil
        busy = true; self.cancellable = cancellable; message = "正在处理…"
        operation = Task {
            do { message = try await work() }
            catch is CancellationError { message = "操作已取消。" }
            catch { message = error.localizedDescription }
            // Background status requests must not keep action buttons locked.
            busy = false; self.cancellable = false; operation = nil
            Task { await refreshStatus() }
        }
    }
    func cancel() { if cancellable { operation?.cancel() } }
    func finishBeforeQuit() async {
        cancel()
        await operation?.value
        try? await socksSaveTask?.value
    }
    func save() {
        run { [self] in
            // Partial setup can be saved before a subscription or home address is supplied.
            if !names.isEmpty && (!settings.useHomeProxy || !settings.homeServer.isEmpty) {
                let snapshot = settings, store = store
                _ = try await Task.detached { try DialerProxyBuilder.build(store.input(snapshot)) }.value
            }
            try await store.save(settings)
            return state.running ? "配置已保存。点击重启应用更改。" : "配置已保存。"
        }
    }
    func start() {
        run { [self] in
            state = try await runtime.start(settings)
            return "代理已启动。开启系统代理后，浏览器即可使用。"
        }
    }
    func stop() {
        run { [self] in
            try await system.disable()
            try await runtime.stop()
            return "代理已停止，原系统代理设置已恢复。"
        }
    }
    func restart() {
        run { [self] in
            // Validate before restoring system settings or interrupting the old service.
            _ = try await MihomoKernel.check(settings, store: store)
            let restoreSystem = await system.hasBackup
            if restoreSystem { try await system.disable() }
            state = try await runtime.restart(settings)
            if restoreSystem { try await system.enable(port: settings.httpPort) }
            return "已重启并应用配置。"
        }
    }
    func toggleSystem() {
        run { [self] in
            if await system.hasBackup { try await system.disable(); return "已恢复原系统代理设置。" }
            guard state.running else { throw StoreError("请先启动代理。") }
            let active = try await runtime.runningSettings()
            try await system.enable(port: active.httpPort)
            return "系统代理已开启，浏览器将使用本 App 的代理。"
        }
    }
    func refreshSubscription() {
        run(cancellable: true) { [self] in
            message = "正在下载订阅…"
            let yaml = try await RelayImport.fromURL(settings.subscriptionUrl)
            settings.relayYaml = yaml
            await catalogTask?.value
            normalizeSelections()
            delays = [:]
            try await store.save(settings)
            return "已导入 \(names.count) 个节点。" + (state.running ? "重启后应用新订阅。" : "可以选择节点并启动。")
        }
    }
    func importYAML(_ text: String) {
        run { [self] in
            settings.relayYaml = try await Task.detached { try RelayImport.extractProxies(text) }.value
            await catalogTask?.value
            normalizeSelections(); delays = [:]
            try await store.save(settings)
            return "已导入 \(names.count) 个节点。" + (state.running ? "重启后应用。" : "")
        }
    }
    private func normalizeSelections() {
        settings.selectedRelay = DialerProxyBuilder.preferred(names, settings.selectedRelay)
        settings.selectedExit = DialerProxyBuilder.preferred(catalog.exitNames, settings.selectedExit, settings.selectedRelay)
        if !names.contains(settings.selectedDevelopment) { settings.selectedDevelopment = "" }
    }
    func select(_ name: String, route: ProxyRoute? = nil) {
        let route = route ?? self.route
        run { [self] in
            switch route {
            case .relay: settings.selectedRelay = name
            case .exit: settings.selectedExit = name
            case .development: settings.selectedDevelopment = name == DialerProxyBuilder.developmentAutomaticGroup ? "" : name
            }
            return try await runtime.select(settings, name: name, route: route)
        }
    }
    func probe(only: String? = nil, selectFastest: Bool = false) {
        let route = self.route
        let snapshot = settings
        run(cancellable: true) { [self] in
            probeFinished = 0
            let count = only == nil ? candidates.count : 1
            message = "准备测速…"
            let results = try await ProxyProbe.run(store: store, settings: snapshot, route: route, only: only) { [self] name, delay in
                await MainActor.run {
                    self.delays[route, default: [:]][name] = delay
                    // Only one progress update enters the main actor at a time.
                    self.probeFinished += 1
                    self.message = "已测 \(self.probeFinished)/\(count) · \(name) · " + (delay < 0 ? "超时" : "\(delay) ms")
                }
            }
            guard selectFastest else { return "测速完成。点击节点可切换。" }
            guard let best = results.filter({ $0.value >= 0 }).min(by: { $0.value < $1.value }) else { throw StoreError("没有节点在 5 秒内走通。请检查订阅" + (route == .relay ? "和家宽配置。" : "。")) }
            switch route {
            case .relay: settings.selectedRelay = best.key
            case .exit: settings.selectedExit = best.key
            case .development: settings.selectedDevelopment = best.key
            }
            let result = try await runtime.select(settings, name: best.key, route: route)
            return "最快 \(best.value) ms · " + result
        }
    }
    func saveSocksProfile(_ profile: SocksProxyProfile, select: Bool) async throws {
        var updated = settings
        try updated.upsertSocksProfile(profile, select: select)
        try await persistSocksSettings(updated)
    }
    func selectSocksProfile(_ id: String) {
        Task {
            do {
                var updated = settings; try updated.selectSocksProfile(id)
                try await persistSocksSettings(updated)
            } catch { message = error.localizedDescription }
        }
    }
    func removeSocksProfile(_ id: String) {
        Task {
            do {
                var updated = settings; updated.removeSocksProfile(id)
                try await persistSocksSettings(updated)
                socksTests[id] = nil
            } catch { message = error.localizedDescription }
        }
    }
    func setSocksEnabled(_ enabled: Bool) {
        Task {
            do {
                var updated = settings
                if enabled {
                    guard let profile = updated.selectedSocksProfile else { throw StoreError("请先添加一个 SOCKS5 配置。") }
                    try updated.upsertSocksProfile(profile, select: true)
                } else { updated.useHomeProxy = false }
                try await persistSocksSettings(updated)
                if !enabled { route = .exit }
            } catch { message = error.localizedDescription }
        }
    }
    private func persistSocksSettings(_ updated: ClashProxySettings) async throws {
        guard !busy else { throw StoreError("请等待当前操作完成。") }
        busy = true
        defer { busy = false; socksSaveTask = nil }
        refreshRevision += 1; refreshTask?.cancel(); refreshTask = nil
        let store = store
        let saveTask = Task { try await store.save(updated) }
        socksSaveTask = saveTask
        try await saveTask.value
        settings = updated
        message = socksNeedsRestart ? "SOCKS5 配置已保存，重启代理后应用更改。" : "SOCKS5 配置已保存。"
    }
    func testSocksProfile(_ profile: SocksProxyProfile) {
        guard !busy else { return }
        let base = settings
        let record = SocksTestRecord(profile: profile, relay: base.selectedRelay, yaml: base.relayYaml, outcome: .testing)
        socksTests[profile.id] = record
        run(cancellable: true) { [self] in
            do {
                let checked = try profile.validated()
                guard !base.selectedRelay.isEmpty, names.contains(base.selectedRelay) else {
                    throw StoreError("请先导入订阅并选择中转节点，再测试完整双跳链路。")
                }
                var probeSettings = base
                checked.apply(to: &probeSettings); probeSettings.useHomeProxy = true
                message = "正在测试 SOCKS5 双跳链路…"
                let result = try await ProxyProbe.run(store: store, settings: probeSettings, route: .relay,
                                                      only: base.selectedRelay) { _, _ in }
                guard let delay = result[base.selectedRelay], delay >= 0 else {
                    throw StoreError("链路未连通。请检查服务器、认证信息或更换中转节点后重试。")
                }
                socksTests[profile.id]?.outcome = .success(delay)
                return "SOCKS5 链路测试成功 · \(delay) ms。"
            } catch is CancellationError {
                socksTests[profile.id]?.outcome = .cancelled
                throw CancellationError()
            } catch {
                socksTests[profile.id]?.outcome = .failure(error.localizedDescription)
                throw error
            }
        }
    }
    func closeConnection(_ id: String) {
        run { [self] in
            try await ClashAPI(controller: settings.controller).closeConnection(id: id)
            return "连接已关闭。"
        }
    }
    func clearTrafficStats() {
        Task { [self] in
            await statusReader.clearTraffic()
            await refreshStatus()
        }
    }
    func refreshLog() {
        logTask?.cancel()
        let url = logURL
        logTask = Task {
            let lines = await Task.detached(priority: .utility) { ProxyLog.entries(url) }.value
            guard !Task.isCancelled else { return }
            if logLines != lines { logLines = lines }
        }
    }
    func readKernel() async {
        do { kernelVersion = try await MihomoKernel.version(settings, store: store) }
        catch { kernelVersion = "未找到内核，请点击下载 / 更新内核。" }
    }
    func installKernel() {
        run(cancellable: true) { [self] in
            message = "正在下载官方 mihomo 内核…"
            kernelVersion = try await MihomoKernel.installLatest(store: store)
            settings.mihomoPath = store.kernelDirectory.appendingPathComponent("mihomo").path
            try await store.save(settings)
            return "内核已安装。" + (state.running ? "重启代理后生效。" : "可以启动代理。")
        }
    }
    func checkConfig() {
        run(cancellable: true) { [self] in try await MihomoKernel.check(settings, store: store) }
    }
    func installShell() {
        run { [self] in
            try await store.save(settings)
            let store = store
            return try await Task.detached { try ProxyShell.install(store: store) }.value
        }
    }
    func toggleBoot() {
        run { [self] in
            let enabled = await runtime.bootEnabled
            let restoreSystem = await system.hasBackup
            if restoreSystem { try await system.disable() }
            try await runtime.setBootEnabled(!enabled, settings: settings)
            if !enabled && restoreSystem { try await system.enable(port: settings.httpPort) }
            return enabled ? "已关闭登录自启动并停止代理。" : "已启用登录自启动。退出 App 后代理仍会运行。"
        }
    }
    func copyEnvironment() {
        let text = "export http_proxy=http://127.0.0.1:\(settings.httpPort)\nexport https_proxy=http://127.0.0.1:\(settings.httpPort)"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        message = "代理环境变量已复制。"
    }
}
