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
    private enum Tab: String, CaseIterable {
        case nodes = "节点", settings = "设置", activity = "连接", logs = "日志"
        var icon: String {
            switch self { case .nodes: return "square.grid.2x2"; case .settings: return "slider.horizontal.3"
            case .activity: return "waveform.path"; case .logs: return "terminal" }
        }
    }
    private let accent = SwitchPalette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dashboard
            pageTabs
            Group {
                switch tab {
                case .nodes: nodes
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
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
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
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("代理节点").font(.system(size: 15, weight: .semibold))
                    Text("\(model.visibleNodes.count)").font(.system(size: 11, design: .rounded)).foregroundStyle(SwitchPalette.muted)
                    Spacer()
                    Button { model.probe() } label: { Label("测全部", systemImage: "speedometer") }
                        .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).disabled(model.busy || model.candidates.isEmpty)
                    Button("自动选最快") { model.probe(selectFastest: true) }
                        .buttonStyle(SwitchButtonStyle(compact: true)).disabled(model.busy || model.candidates.isEmpty)
                }
                if model.settings.useHomeProxy || !model.settings.socksProfiles.isEmpty {
                    Picker("选择用途", selection: $model.route) {
                        Text("第一代理 · 其他 AI").tag(ProxyRoute.exit)
                        Text("第一跳 · 家宽中转").tag(ProxyRoute.relay)
                    }.pickerStyle(.segmented).labelsHidden()
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
                Label(model.route == .relay ? "测速包含中转与家宽的完整链路" : "此列表用于 AI 代理，已排除香港节点", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
            }.padding(18).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            card("代理范围") {
                Toggle("其他网站也使用代理节点", isOn: $model.settings.proxyOtherSites)
                Text("AI 网站使用所选节点；GitHub / Docker 使用香港节点或直连。关闭此项后，其余网站默认直连。修改后保存并重启生效。")
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
        card("运行详情") {
            Text("mihomo PID：\(model.state.mihomoPid.map(String.init) ?? "—") · 限流 PID：\(model.state.limiterPid.map(String.init) ?? "—")")
                .font(.caption.monospaced()).textSelection(.enabled)
            if let connections = model.connections?.connections, !connections.isEmpty {
                ForEach(connections.prefix(100)) { connection in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.destination).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                            Text((connection.chains ?? []).joined(separator: " → ")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("↑ \(bytes(connection.upload ?? 0))  ↓ \(bytes(connection.download ?? 0))").font(.caption.monospacedDigit())
                    }.padding(.vertical, 6)
                }
            } else {
                SwitchEmptyState(icon: "waveform.path", title: "还没有活动连接", detail: model.state.running
                    ? "应用开始使用代理后，连接会显示在这里。" : "启动代理后，在这里查看实时连接与流量。")
            }
        }
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
                    Toggle("仅警告与错误", isOn: $model.problemsOnly).font(.system(size: 10)).toggleStyle(.switch).controlSize(.mini)
                        .onChange(of: model.problemsOnly) { _ in model.refreshLog() }
                }.foregroundStyle(SwitchPalette.muted).padding(.horizontal, 14).padding(.vertical, 11)
                    .overlay(alignment: .bottom) { Rectangle().fill(SwitchPalette.border).frame(height: 1) }
                if model.logText.hasPrefix("暂无") {
                    SwitchEmptyState(icon: model.problemsOnly ? "checkmark.shield" : "text.alignleft",
                                     title: model.problemsOnly ? "暂无警告或错误" : "等待第一条日志",
                                     detail: model.problemsOnly ? "当前日志中没有匹配的警告或错误。" : "服务运行后，日志会自动显示在这里。", compact: true)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(model.logText).font(.system(size: 11, design: .monospaced)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
                    }.frame(height: 240)
                }
            }.background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(SwitchPalette.border) }
            HStack {
                Label(model.logURL.deletingLastPathComponent().path, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 12)
                Text("最近 300 行").fixedSize()
            }.font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
        }.padding(20).background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
            .onAppear { model.refreshLog() }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let icon: String = {
            switch title { case "代理范围": return "globe"; case "家宽双跳（可选）": return "point.3.connected.trianglepath.dotted"
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
