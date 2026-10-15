import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CodexSwitchCore

@MainActor
struct ProxyView: View {
    @ObservedObject var model: ProxyModel
    @State private var tab = Tab.nodes
    @State private var showYAML = false
    @State private var yaml = ""
    @State private var showSubscription = false
    @State private var trafficMode: TrafficMode = .connections
    @State private var trafficScope: TrafficScope = .all
    @State private var trafficSearch = ""
    @State private var trafficByBytes = false
    @State private var logSearch = ""
    private enum Tab: String, CaseIterable {
        case nodes = "出口节点", rules = "分流规则", settings = "设置", activity = "流量", logs = "日志"
        var icon: String {
            switch self { case .nodes: return "square.grid.2x2"; case .rules: return "arrow.triangle.branch"; case .settings: return "slider.horizontal.3"
                case .activity: return "waveform.path"; case .logs: return "terminal" }
        }
    }
    private enum TrafficMode: String, CaseIterable { case connections = "按连接", hosts = "按目标", exits = "按出口" }
    private enum TrafficScope: String, CaseIterable { case all = "全部", proxy = "代理", direct = "直连", rejected = "拦截" }
    private let accent = SwitchPalette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if tab == .rules { compactStatus } else { dashboard }
            pageTabs
            Group {
                switch tab {
                case .nodes: nodes
                case .rules: ProxyRulesView(model: model, chooseNodes: { route in model.route = route; tab = .nodes }, configureHome: { tab = .settings })
                case .settings: settings
                case .activity: activity
                case .logs: logs
                }
            }
        }
        .buttonStyle(SwitchButtonStyle())
        .textFieldStyle(SwitchFieldStyle())
        .task {
            await model.load()
            while !Task.isCancelled {
                // The traffic tab needs 1 s samples for live rates; other tabs poll calmly.
                do { try await Task.sleep(for: .seconds(tab == .activity && model.state.running ? 1 : 3)) } catch { break }
                if !model.busy {
                    await model.refreshStatus()
                    if tab == .logs { model.refreshLog() }
                }
            }
        }
        .sheet(isPresented: $showYAML) {
            VStack(alignment: .leading, spacing: 16) {
                Text("导入 Clash YAML").font(.title2)
                Text("粘贴完整订阅或 proxies 节点列表。").foregroundStyle(.secondary)
                TextEditor(text: $yaml).font(.system(.body, design: .monospaced)).frame(minHeight: 260)
                HStack {
                    Button("选择文件…") { importFile() }
                    Spacer()
                    Button("取消") { showYAML = false }
                    Button("导入") { model.importYAML(yaml); showYAML = false }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 600, height: 420)
        }
    }
    private var pageTabs: some View {
        HStack(spacing: 24) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.icon).font(.system(size: 12))
                        Text(item.rawValue).font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                    }.foregroundStyle(tab == item ? accent : SwitchPalette.muted)
                        .padding(.vertical, 13)
                        .overlay(alignment: .bottom) {
                            if tab == item { Capsule().fill(accent).frame(height: 2) }
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.overlay(alignment: .bottom) { Rectangle().fill(SwitchPalette.border).frame(height: 1).offset(y: 1) }
    }
    private var dashboard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.07))
                        RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.12))
                        Image(systemName: model.state.running ? "network" : "power")
                            .font(.system(size: 23, weight: .light)).foregroundStyle(SwitchPalette.mint)
                    }.frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.state.running ? "代理运行中" : "代理未启动")
                            .font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                        Text(model.state.running ? model.state.detail : model.names.isEmpty ? "导入订阅，开始配置你的网络。" : "节点已准备好，随时开启代理。")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 10)
                    VStack(spacing: 8) {
                        Button { model.state.running ? model.stop() : model.start() } label: {
                            Label(model.state.running ? "停止代理" : "启动代理", systemImage: model.state.running ? "stop.fill" : "power")
                        }.buttonStyle(SwitchButtonStyle(kind: .hero)).disabled(!model.state.running && model.names.isEmpty)
                        if model.state.running {
                            Button("重启代理") { model.restart() }.buttonStyle(SwitchButtonStyle(kind: .onDark, compact: true))
                        }
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(SwitchPalette.mint)
                    Text(model.systemProxy ? "系统代理已开启" : model.systemRecovery ? "系统代理待恢复" : "系统代理未开启")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 8)
                    Button(model.systemRecovery ? "恢复系统代理" : "开启系统代理") { model.toggleSystem() }
                        .buttonStyle(SwitchButtonStyle(kind: .onDark, compact: true))
                        .disabled(!model.state.running && !model.systemRecovery)
                }.padding(.top, 10).overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
                if model.systemProxy && !model.state.running {
                    Label("代理未运行，请启动或恢复系统代理以保持联网。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(SwitchPalette.mint)
                }
            }.padding(.horizontal, 22).padding(.vertical, 17).background(SwitchPalette.forest)
            HStack(spacing: 0) {
                metric("订阅节点", value: "\(model.names.count)", icon: "square.stack.3d.up")
                metric("上传", value: model.connections.map { bytes($0.uploadTotal) } ?? "—", icon: "arrow.up.right")
                metric("下载", value: model.connections.map { bytes($0.downloadTotal) } ?? "—", icon: "arrow.down.left")
                metric("活动连接", value: model.connections.map { "\($0.connections?.count ?? 0)" } ?? "—", icon: "link")
            }.padding(.vertical, 11).background(SwitchPalette.surface)
            if !model.pace.isEmpty { Text(model.pace).font(.caption).foregroundStyle(SwitchPalette.muted).padding(.bottom, 10) }
        }.background(SwitchPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(SwitchPalette.border.opacity(0.5)) }
            .disabled(model.busy)
    }
    private var compactStatus: some View {
        HStack(spacing: 10) {
            Circle().fill(model.state.running ? accent : SwitchPalette.muted).frame(width: 7, height: 7)
            Text(model.state.running ? "代理运行中" : "代理未启动").font(.system(size: 12, weight: .semibold))
            Text(model.systemProxy ? "系统代理已开启" : "系统代理未开启").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
            Spacer(minLength: 6)
            Text("\(model.names.count) 个订阅节点").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
            Button(model.state.running ? "停止代理" : "启动代理") { model.state.running ? model.stop() : model.start() }
                .buttonStyle(SwitchButtonStyle(compact: true)).disabled(model.busy || (!model.state.running && model.names.isEmpty))
        }.padding(14).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(SwitchPalette.border) }
    }
    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
            Text(value).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
    }
    private var nodes: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Image(systemName: "link").foregroundStyle(accent).frame(width: 32, height: 32)
                        .background(SwitchPalette.selected, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的订阅").font(.system(size: 12, weight: .semibold))
                        Text(model.names.isEmpty ? "添加 Clash 订阅或导入 YAML" : "已导入 \(model.names.count) 个节点")
                            .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                    }
                    Spacer(minLength: 6)
                    if !model.names.isEmpty {
                        Button { model.refreshSubscription() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(SwitchButtonStyle(kind: .quiet)).disabled(model.settings.subscriptionUrl.isEmpty)
                            .help("刷新订阅").accessibilityLabel("刷新订阅")
                    }
                    Button(showSubscription ? "收起" : "管理订阅") { showSubscription.toggle() }
                        .buttonStyle(SwitchButtonStyle(compact: true))
                }
                if showSubscription || model.names.isEmpty {
                    HStack {
                        SecureField("Clash 订阅 URL", text: $model.settings.subscriptionUrl)
                        Button(model.names.isEmpty ? "导入" : "更新") { model.refreshSubscription() }
                            .buttonStyle(SwitchButtonStyle(kind: .primary)).disabled(model.settings.subscriptionUrl.isEmpty)
                    }
                    HStack {
                        Text("支持 Clash YAML 订阅与本地文件").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                        Spacer()
                        Button("导入 YAML…") { yaml = model.settings.relayYaml; showYAML = true }
                            .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true))
                    }
                }
            }.padding(16).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }.disabled(model.busy)
            routeCards
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(routeTitle(model.route) + "节点").font(.system(size: 15, weight: .semibold))
                    Text("\(model.visibleNodes.count)").font(.system(size: 11, design: .rounded)).foregroundStyle(SwitchPalette.muted)
                    Spacer()
                    Button { model.probe() } label: { Label("测全部", systemImage: "speedometer") }
                        .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).disabled(model.busy || model.candidates.isEmpty)
                    Button("测速并选最快") { model.probe(selectFastest: true) }
                        .buttonStyle(SwitchButtonStyle(compact: true)).disabled(model.busy || model.candidates.isEmpty)
                }
                if model.route == .development {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动回退").font(.system(size: 12, weight: .semibold))
                            Text("优先可用香港节点，全部失效时使用 AI 出口。手动选择节点后固定使用该节点。")
                                .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                        }
                        Spacer(minLength: 6)
                        Button(model.settings.selectedDevelopment.isEmpty ? "自动已选" : "使用自动") {
                            model.select(DialerProxyBuilder.developmentAutomaticGroup, route: .development)
                        }.buttonStyle(SwitchButtonStyle(kind: model.settings.selectedDevelopment.isEmpty ? .quiet : .secondary, compact: true))
                            .disabled(model.busy || (model.settings.selectedDevelopment.isEmpty && !model.rulesNeedApply))
                    }.padding(12).background(SwitchPalette.selected, in: RoundedRectangle(cornerRadius: 9))
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SwitchPalette.muted)
                    TextField("搜索节点名称或地区", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(SwitchPalette.muted) }
                            .buttonStyle(.plain).accessibilityLabel("清空搜索")
                    }
                }.font(.system(size: 12)).padding(11).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 9))
                if model.candidates.isEmpty {
                    SwitchEmptyState(icon: "network", title: model.names.isEmpty ? "添加你的第一个订阅" : "没有可用节点",
                                     detail: model.names.isEmpty ? "导入订阅后，即可选择节点并连接。" : "当前用途需要非香港节点，请更新订阅。")
                } else if model.visibleNodes.isEmpty {
                    SwitchEmptyState(icon: "magnifyingglass", title: "没有匹配的节点", detail: "试试其他名称，或清空搜索条件。")
                } else {
                    ProxyNodeList(nodes: model.visibleNodes, delays: model.delays[model.route] ?? [:],
                                  selection: model.selection, liveSelection: model.liveSelection,
                                  running: model.state.running, busy: model.busy, model: model)
                        .equatable()
                }
                Label(model.route == .relay ? "测速包含中转与家宽的完整链路" : model.route == .development ? "用 GitHub 测试连接，支持香港与其他地区节点" : "AI 出口已排除香港节点", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
            }.padding(18).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
        }
    }
    private var routeCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按用途选择出口").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { tab = .rules } label: { Label("管理分流规则", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140), spacing: 10), count: 3), spacing: 10) {
                ForEach(ProxyRoute.allCases, id: \.self) { route in
                    Button {
                        if route == .relay && model.settings.socksProfiles.isEmpty { tab = .settings }
                        else { model.route = route }
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: route == .exit ? "sparkles" : route == .development ? "chevron.left.forwardslash.chevron.right" : "house")
                                Text(routeTitle(route)).font(.system(size: 12, weight: .semibold))
                                Spacer(minLength: 0)
                                if model.route == route { Image(systemName: "checkmark.circle.fill") }
                            }.foregroundStyle(accent)
                            Text(routeNode(route)).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                            Text(route == .exit ? "单跳 · 非香港节点" : route == .development
                                 ? (model.settings.selectedDevelopment.isEmpty ? "自动回退 · 香港优先" : "手动指定节点")
                                 : model.settings.useHomeProxy ? "中转 → 家宽 SOCKS5" : "可选 · 配置后启用")
                                .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                        }.padding(14).frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                            .background(model.route == route ? SwitchPalette.selected : SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 11))
                            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(model.route == route ? accent.opacity(0.35) : SwitchPalette.border) }
                            .contentShape(RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain).disabled(model.busy).accessibilityAddTraits(model.route == route ? .isSelected : [])
                }
            }
        }
    }
    private func routeTitle(_ route: ProxyRoute) -> String {
        switch route { case .exit: return "AI 工具"; case .development: return "GitHub / 开发"; case .relay: return "家宽中转" }
    }
    private func routeNode(_ route: ProxyRoute) -> String {
        let name: String
        switch route {
        case .exit: name = model.state.running ? model.liveExit : model.settings.selectedExit
        case .development: name = model.state.running ? model.liveDevelopment : model.settings.selectedDevelopment
        case .relay: name = model.state.running ? model.liveRelay : model.settings.selectedRelay
        }
        return name.isEmpty ? (route == .development ? "自动选择可用出口" : route == .relay ? "选择中转与家宽" : "选择一个节点") : name
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("分流方案") {
                HStack {
                    Text(model.settings.routing.preset(proxyOtherSites: model.settings.proxyOtherSites)?.title ?? "自定义方案")
                    Spacer()
                    Button("管理分流规则") { tab = .rules }
                }
                Text("AI 工具、开发网站、家宽中转与自定义规则统一在分流规则中管理。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            SocksProxySection(model: model) { model.route = .relay; tab = .nodes }
            card("内核") {
                Text(model.kernelVersion).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("下载 / 更新内核") { model.installKernel() }
                    Button("检查配置") { model.checkConfig() }
                    Button("选择内核…") { chooseKernel() }
                }
                DisclosureGroup("自定义路径") {
                    field("mihomo（留空自动查找）", text: $model.settings.mihomoPath)
                    field("Python 3（家宽双跳使用）", text: $model.settings.pythonPath)
                }
            }.disabled(model.busy)
            card("高级设置") {
                DisclosureGroup("端口与限流") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            number("HTTP 端口", value: $model.settings.httpPort)
                            number("SOCKS 端口", value: $model.settings.socksPort)
                        }
                        field("控制地址", text: $model.settings.controller)
                        field("限流监听", text: $model.settings.limiterListen)
                        HStack {
                            number("最大并发", value: $model.settings.maxConcurrent)
                            number("拨号间隔 ms", value: $model.settings.dialIntervalMs)
                            number("排队上限 s", value: $model.settings.queueWaitS)
                        }
                    }.padding(.top, 10)
                }
                HStack {
                    Button(model.bootEnabled ? "关闭登录自启动" : "开启登录自启动") { model.toggleBoot() }
                    Text(model.bootEnabled ? "已开启" : "已关闭").foregroundStyle(.secondary)
                }
                Text("登录后启动后台代理。系统代理需在 App 中单独开启；退出 App 后已启动的代理会继续运行。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("安装 Shell 命令") { model.installShell() }
                    Button("复制环境变量") { model.copyEnvironment() }
                }
                Text("安装后 codex / claude / gemini 命令会使用本 App 的 HTTP 代理。").font(.caption).foregroundStyle(.secondary)
                Button("打开配置目录") { NSWorkspace.shared.open(model.store.directory) }
            }.disabled(model.busy)
            HStack {
                Button("保存配置") { model.save() }.buttonStyle(SwitchButtonStyle(kind: .primary))
                if model.state.running { Button("保存并重启") { model.restart() } }
                Spacer()
            }
            .disabled(model.busy)
        }.textFieldStyle(SwitchFieldStyle()).toggleStyle(.switch).controlSize(.small)
    }
    private var activity: some View {
        let traffic = model.traffic
        let hasHistory = traffic.sessionUp > 0 || traffic.sessionDown > 0 || !traffic.byHost.isEmpty
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                metric("实时速率", value: "↓ \(speed(traffic.rateDown)) · ↑ \(speed(traffic.rateUp))", icon: "bolt.horizontal")
                metric("活动连接", value: "\(traffic.rows.count)", icon: "link")
                metric("会话累计", value: "↓ \(bytes(traffic.sessionDown)) · ↑ \(bytes(traffic.sessionUp))", icon: "chart.bar.doc.horizontal")
                if hasHistory {
                    Button { model.clearTrafficStats() } label: { Image(systemName: "trash") }
                        .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true))
                        .help("清空会话统计").accessibilityLabel("清空会话统计")
                        .padding(.trailing, 18)
                }
            }.padding(.vertical, 11).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
            if !model.state.running && hasHistory {
                Label("代理已停止，以下保留本次会话的累计流量。", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(SwitchPalette.muted)
            }
            if !traffic.byHost.isEmpty || !traffic.byProcess.isEmpty || !traffic.byExit.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Top 3 · 会话累计").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                    HStack(alignment: .top, spacing: 0) {
                        rankingColumn("网站", traffic.byHost.prefix(3).map { RankingItem(name: $0.host, up: $0.upload, down: $0.download) }, divider: true)
                        // The macOS kernel cannot attribute processes; keep the layout two-column until it can.
                        if !traffic.byProcess.isEmpty {
                            rankingColumn("进程", traffic.byProcess.prefix(3).map { RankingItem(name: $0.process, up: $0.upload, down: $0.download) }, divider: true)
                        }
                        rankingColumn("节点", traffic.byExit.prefix(3).map { RankingItem(name: exitName($0.exit), up: $0.upload, down: $0.download) })
                    }
                }
                .padding(.vertical, 13).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
            }
            HStack(spacing: 10) {
                Picker("视图", selection: $trafficMode) {
                    ForEach(TrafficMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 216)
                if trafficMode == .connections {
                    HStack(spacing: 3) {
                        ForEach(TrafficScope.allCases, id: \.self) { scope in
                            Button { trafficScope = scope } label: {
                                Text(scope.rawValue).font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .foregroundStyle(trafficScope == scope ? accent : SwitchPalette.muted)
                                    .background(trafficScope == scope ? SwitchPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityAddTraits(trafficScope == scope ? [.isSelected] : [])
                        }
                    }.padding(3).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                    Button { trafficByBytes.toggle() } label: {
                        Label(trafficByBytes ? "流量最大" : "最近活动", systemImage: "arrow.up.arrow.down")
                    }.buttonStyle(SwitchButtonStyle(compact: true))
                }
                Spacer(minLength: 8)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
                    TextField("搜索域名、规则或节点", text: $trafficSearch).textFieldStyle(.plain)
                    if !trafficSearch.isEmpty {
                        Button { trafficSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(SwitchPalette.muted) }
                            .buttonStyle(.plain).accessibilityLabel("清空搜索")
                    }
                }.font(.system(size: 12)).padding(9).frame(maxWidth: 280, alignment: .leading)
                    .background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 9))
            }
            card("运行详情") {
                Text("mihomo PID：\(model.state.mihomoPid.map(String.init) ?? "—") · 限流 PID：\(model.state.limiterPid.map(String.init) ?? "—")")
                    .font(.caption.monospaced()).foregroundStyle(SwitchPalette.muted).textSelection(.enabled)
                if filteredRows.isEmpty && filteredHosts.isEmpty && filteredExits.isEmpty {
                    SwitchEmptyState(icon: "waveform.path",
                                     title: hasHistory ? "没有匹配的记录" : "还没有活动连接",
                                     detail: hasHistory ? "换个关键词，或切换视图与过滤条件。"
                                     : model.state.running ? "应用开始使用代理后，每条连接的目的地、命中规则与出口都会显示在这里。"
                                     : "启动代理后，在这里查看实时连接、命中规则与流量去向。")
                } else if trafficMode == .connections {
                    LazyVStack(spacing: 6) { ForEach(trafficByBytes ? filteredRows.sorted { ($0.upload + $0.download) > ($1.upload + $1.download) } : filteredRows) { connectionRow($0) } }
                } else if trafficMode == .hosts {
                    LazyVStack(spacing: 6) { ForEach(filteredHosts) { hostRow($0) } }
                } else {
                    LazyVStack(spacing: 6) { ForEach(filteredExits) { exitRow($0) } }
                }
            }
        }
    }
    private var filteredRows: [ConnectionRow] {
        let query = trafficSearch.trimmingCharacters(in: .whitespaces)
        return model.traffic.rows.filter { row in
            let inScope: Bool
            switch trafficScope {
            case .all: inScope = true
            case .proxy: inScope = !row.isDirect && !row.isRejected
            case .direct: inScope = row.isDirect
            case .rejected: inScope = row.isRejected
            }
            guard inScope else { return false }
            guard !query.isEmpty else { return true }
            return [row.host, row.rule, row.exit, row.process].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private var filteredHosts: [HostAggregate] {
        let query = trafficSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.traffic.byHost }
        return model.traffic.byHost.filter { item in
            ([item.host, item.rule] + item.exits).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private var filteredExits: [ExitAggregate] {
        let query = trafficSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.traffic.byExit }
        return model.traffic.byExit.filter { item in
            ([item.exit] + item.hosts).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private func connectionRow(_ row: ConnectionRow) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.host + (row.destinationPort.isEmpty ? "" : ":" + row.destinationPort))
                        .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    if !row.network.isEmpty {
                        Text(row.network).font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2).foregroundStyle(SwitchPalette.muted)
                            .background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if !row.process.isEmpty {
                        Text(row.process).font(.system(size: 10)).foregroundStyle(SwitchPalette.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack(spacing: 5) {
                    if !row.rule.isEmpty { Text(row.rule) }
                    if !row.chains.isEmpty || !row.exit.isEmpty {
                        Text("·")
                        chainText(row.chains.isEmpty ? [row.exit] : row.chains)
                    }
                }.font(.caption2).foregroundStyle(SwitchPalette.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("↓ \(bytes(row.download))" + (row.rateDown > 0 ? " · \(speed(row.rateDown))" : ""))
                Text("↑ \(bytes(row.upload))" + (row.rateUp > 0 ? " · \(speed(row.rateUp))" : ""))
            }.font(.caption.monospacedDigit())
            Text(duration(row.age)).font(.caption2).foregroundStyle(SwitchPalette.muted)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(SwitchPalette.inset.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button { model.closeConnection(row.id) } label: { Label("关闭连接", systemImage: "xmark.circle") }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.host, forType: .string)
            } label: { Label("拷贝域名", systemImage: "doc.on.doc") }
        }
    }
    private func hostRow(_ item: HostAggregate) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.host).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                HStack(spacing: 5) {
                    if !item.rule.isEmpty { Text(item.rule) }
                    ForEach(item.exits.prefix(2), id: \.self) { exit in
                        Text(exitName(exit)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(exitTint(exit))
                    }
                    if item.exits.count > 2 { Text("+\(item.exits.count - 2)") }
                }.font(.caption2).foregroundStyle(SwitchPalette.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(item.opened) 条连接" + (item.active > 0 ? " · \(item.active) 活跃" : ""))
                    .font(.caption2).foregroundStyle(SwitchPalette.muted)
                Text("↓ \(bytes(item.download)) · ↑ \(bytes(item.upload))").font(.caption.monospacedDigit())
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(SwitchPalette.inset.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.host, forType: .string)
            } label: { Label("拷贝域名", systemImage: "doc.on.doc") }
        }
    }
    private func exitRow(_ item: ExitAggregate) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exitName(item.exit)).font(.system(size: 12, weight: .semibold)).foregroundStyle(exitTint(item.exit)).textSelection(.enabled)
                if !item.hosts.isEmpty {
                    Text(item.hosts.joined(separator: "、")).font(.caption2).foregroundStyle(SwitchPalette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(item.opened) 条连接" + (item.active > 0 ? " · \(item.active) 活跃" : ""))
                    .font(.caption2).foregroundStyle(SwitchPalette.muted)
                Text("↓ \(bytes(item.download)) · ↑ \(bytes(item.upload))").font(.caption.monospacedDigit())
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(SwitchPalette.inset.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }
    /// The whole chain reads as one line: group → … → node. mihomo reports innermost-first,
    /// so reversing puts the concrete exit (CN6, DIRECT…) last, where it is highlighted.
    @ViewBuilder
    private func chainText(_ chains: [String]) -> some View {
        let ordered = chains.reversed()
        if ordered.count > 1 {
            Text(ordered.dropLast().joined(separator: " → ") + " → ").foregroundColor(SwitchPalette.muted)
            Text(exitName(ordered.last!)).foregroundColor(exitTint(ordered.last!)).fontWeight(.semibold)
        } else if let exit = ordered.first {
            Text(exitName(exit)).foregroundColor(exitTint(exit)).fontWeight(.semibold)
        }
    }
    /// The home dual-hop leg shows up as its proxy name; say what it means.
    private func exitName(_ exit: String) -> String { exit == "target-socks5" ? "家宽双跳" : exit }
    private func exitTint(_ exit: String) -> Color {
        exit == "REJECT" ? .orange : exit == "DIRECT" ? SwitchPalette.muted : accent
    }
    private struct RankingItem: Identifiable {
        let name: String
        let up: Int64
        let down: Int64
        var id: String { name }
    }
    /// One ranked column of the Top 3 strip: name plus session traffic, biggest first.
    private func rankingColumn(_ title: String, _ items: [RankingItem], divider: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
            if items.isEmpty {
                Text("暂无数据").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted.opacity(0.7))
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { rank, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(rank + 1).  " + item.name).font(.system(size: 11, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text("↓ \(bytes(item.down)) · ↑ \(bytes(item.up))")
                            .font(.caption2).monospacedDigit().foregroundStyle(SwitchPalette.muted)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            .overlay(alignment: .trailing) {
                if divider { Rectangle().fill(SwitchPalette.border).frame(width: 1).padding(.vertical, 2) }
            }
    }
    private func speed(_ bytesPerSecond: Int) -> String { bytes(Int64(bytesPerSecond)) + "/s" }
    private func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))m"
    }
    private var logs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("运行日志").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(["mihomo", "服务", "限流"], id: \.self) { source in
                        Button {
                            model.logSource = source; model.refreshLog()
                        } label: {
                            Text(source).font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 7)
                                .foregroundStyle(model.logSource == source ? accent : SwitchPalette.muted)
                                .background(model.logSource == source ? SwitchPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.logSource == source ? .isSelected : [])
                    }
                }.padding(3).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                Button { model.refreshLog() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SwitchButtonStyle(compact: true)).help("刷新日志").accessibilityLabel("刷新日志")
            }
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "terminal").font(.system(size: 11))
                    Text(model.logURL.lastPathComponent).font(.system(size: 10, design: .monospaced))
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10))
                        TextField("筛选日志", text: $logSearch).textFieldStyle(.plain).frame(width: 120)
                        if !logSearch.isEmpty {
                            Button { logSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(SwitchPalette.muted).accessibilityLabel("清空筛选")
                        }
                    }
                    Toggle("仅警告与错误", isOn: $model.problemsOnly).font(.system(size: 10)).toggleStyle(.switch).controlSize(.mini)
                }.foregroundStyle(SwitchPalette.muted).padding(.horizontal, 14).padding(.vertical, 11)
                    .overlay(alignment: .bottom) { Rectangle().fill(SwitchPalette.border).frame(height: 1) }
                if filteredLogLines.isEmpty {
                    SwitchEmptyState(icon: model.problemsOnly || !logSearch.isEmpty ? "checkmark.shield" : "text.alignleft",
                                     title: model.problemsOnly ? "暂无警告或错误" : "等待第一条日志",
                                     detail: model.problemsOnly ? "当前日志中没有匹配的警告或错误。"
                                     : logSearch.isEmpty ? "服务运行后，日志会自动显示在这里。" : "没有包含该关键词的日志。",
                                     compact: true)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(filteredLogLines) { line in logRow(line) }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(height: 260)
                }
            }.background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(SwitchPalette.border) }
            HStack {
                Label(model.logURL.deletingLastPathComponent().path, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 12)
                Text("最近 500 行 · mihomo 行尾高亮命中出口").fixedSize()
            }.font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
        }.padding(20).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
            .onAppear { model.refreshLog() }
    }
    private var filteredLogLines: [LogLine] {
        let query = logSearch.trimmingCharacters(in: .whitespaces)
        return model.logLines.filter { line in
            if model.problemsOnly && line.level != "WARN" && line.level != "ERROR" { return false }
            if !query.isEmpty && !line.message.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }
    private func logRow(_ line: LogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !line.time.isEmpty {
                Text(line.time).frame(width: 54, alignment: .leading)
            }
            Text(line.level.isEmpty ? " " : line.level)
                .foregroundStyle(line.level == "ERROR" ? .red : line.level == "WARN" ? .orange : SwitchPalette.muted)
                .frame(width: 40, alignment: .leading)
            messageText(line).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.font(.system(size: 11, design: .monospaced))
    }
    /// mihomo connection lines end with "using 出口" — that exit is the routing answer, so highlight it.
    private func messageText(_ line: LogLine) -> Text {
        let message = line.message
        if let range = message.range(of: " using ", options: .backwards) {
            return Text(String(message[message.startIndex..<range.lowerBound])).foregroundColor(SwitchPalette.muted)
                + Text(message[range.lowerBound...]).foregroundColor(accent).fontWeight(.semibold)
        }
        return Text(message).foregroundColor(line.level == "ERROR" ? .red : line.level == "WARN" ? .orange : .primary)
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let icon: String = {
            switch title { case "分流方案": return "arrow.triangle.branch"; case "家宽双跳（可选）": return "point.3.connected.trianglepath.dotted"
            case "内核": return "cpu"; case "高级设置": return "slider.horizontal.3"; default: return "waveform.path" }
        }()
        return VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, text: text) }
    }
    private func number(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, value: value, format: .number.grouping(.never)) }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
    private func importFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { yaml = try await Task.detached { try String(contentsOf: url, encoding: .utf8) }.value }
                catch { model.message = error.localizedDescription }
            }
        }
    }
    private func chooseKernel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.settings.mihomoPath = url.path
            Task { await model.readKernel() }
        }
    }
}


/// Traffic counters and progress messages do not invalidate the node list.
@MainActor
private struct ProxyNodeList: View, Equatable {
    let nodes: [String]
    let delays: [String: Int]
    let selection: String
    let liveSelection: String
    let running: Bool
    let busy: Bool
    let model: ProxyModel
    private let accent = SwitchPalette.accent

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.nodes == rhs.nodes && lhs.delays == rhs.delays && lhs.selection == rhs.selection
            && lhs.liveSelection == rhs.liveSelection && lhs.running == rhs.running && lhs.busy == rhs.busy
    }
    var body: some View {
        LazyVStack(spacing: 6) {
            ForEach(nodes, id: \.self) { name in
                HStack(spacing: 11) {
                    Image(systemName: selection == name ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .light)).foregroundStyle(selection == name ? accent : SwitchPalette.border)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 12, weight: selection == name ? .semibold : .medium)).lineLimit(2)
                        if liveSelection == name && running {
                            Text("正在使用").font(.system(size: 9, weight: .medium)).foregroundStyle(accent)
                        } else if selection == name { Text("已选择").font(.system(size: 9)).foregroundStyle(SwitchPalette.muted) }
                    }
                    Spacer(minLength: 8)
                    if let delay = delays[name] {
                        HStack(spacing: 4) {
                            Circle().fill(delay < 0 ? Color.orange : accent).frame(width: 4, height: 4)
                            Text(delay < 0 ? "超时" : "\(delay) ms").monospacedDigit()
                        }.font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                    } else { Text("未测速").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted.opacity(0.7)) }
                    Button { model.probe(only: name) } label: { Image(systemName: "speedometer") }
                        .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).disabled(busy)
                        .help("测速").accessibilityLabel("测速 \(name)")
                    Button(selection == name ? "已选" : "使用") { model.select(name) }
                        .buttonStyle(SwitchButtonStyle(kind: selection == name ? .quiet : .secondary, compact: true))
                        .disabled(busy || (liveSelection == name && selection == name))
                }.padding(.vertical, 11).padding(.horizontal, 12)
                    .background(selection == name ? SwitchPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selection == name ? accent.opacity(0.2) : SwitchPalette.border.opacity(0.6)) }
            }
        }
    }
}
