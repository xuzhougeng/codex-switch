import SwiftUI
import AppKit
import CodexSwitchCore

@main
enum CodexSwitchMain {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--proxy-service"), let index = args.firstIndex(of: "--home"), args.indices.contains(index + 1) {
            let code = await ClashProxyRuntime.serve(home: URL(fileURLWithPath: args[index + 1], isDirectory: true))
            exit(code)
        }
        if args.contains("--system-proxy") {
            do { try SystemProxyPreferences.runHelper(arguments: args); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        CodexSwitchApp.main()
    }
}

@MainActor
struct CodexSwitchApp: App {
    @NSApplicationDelegateAdaptor(SwitchAppDelegate.self) private var appDelegate
    @StateObject private var model = AccountModel()
    @StateObject private var proxyModel = ProxyModel()
    var body: some Scene {
        WindowGroup("Codex Switch", id: "main") {
            ContentView(model: model, proxyModel: proxyModel)
                .frame(minWidth: 760, minHeight: 580)
                .task { await model.refresh() }
                .onAppear { appDelegate.model = model; appDelegate.proxyModel = proxyModel }
        }
        .defaultSize(width: 940, height: 740)
        .commands {
            CommandGroup(after: .newItem) {
                Button("登录新账号") { model.login() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy)
                Button("刷新账号") { model.perform("账号已刷新") { } }.keyboardShortcut("r").disabled(model.busy)
            }
        }
        MenuBarExtra("Codex Switch", systemImage: proxyModel.state.running ? "network" : "network.slash") {
            ProxyMenu(model: proxyModel)
        }
    }
}

@MainActor
private struct ProxyMenu: View {
    @ObservedObject var model: ProxyModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.state.detail)
        Button("打开 Codex Switch") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(model.state.running ? "停止代理" : "启动代理") { if model.state.running { model.stop() } else { model.start() } }
            .disabled(model.busy)
        Button(model.systemRecovery ? "恢复系统代理" : "开启系统代理") { model.toggleSystem() }
            .disabled(model.busy || (!model.state.running && !model.systemRecovery))
        Divider()
        Button("退出 App（代理继续运行）") { NSApp.terminate(nil) }
    }
}

@MainActor
final class SwitchAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AccountModel?
    weak var proxyModel: ProxyModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.busy == true || proxyModel?.busy == true else { return .terminateNow }
        Task { await model?.finishBeforeQuit(); await proxyModel?.finishBeforeQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@MainActor
final class AccountModel: ObservableObject {
    @Published var current: Account?
    @Published var accounts: [Account] = []
    @Published var status = "就绪"
    @Published var busy = false
    @Published var loggingIn = false
    @Published var search = ""
    @Published var page: Page = .proxy
    let store = AccountStore()
    private var operation: Task<Void, Never>?
    enum Page { case accounts, proxy, help }

    var filtered: [Account] {
        accounts.filter { search.isEmpty || ($0.email + " " + $0.plan).localizedCaseInsensitiveContains(search) }
    }
    func refresh() async {
        do { try await reload() } catch { status = "读取失败：" + error.localizedDescription }
    }
    private func reload() async throws {
        let state = try await store.read()
        current = state.current
        accounts = state.accounts
    }
    func perform(_ success: String, work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        status = "正在处理…"
        operation = Task {
            defer { busy = false; loggingIn = false; operation = nil }
            do {
                try await work()
                try await reload()
                status = success
            } catch is CancellationError { status = "登录已取消，原账号已保留。" }
            catch { status = "操作未完成：" + error.localizedDescription }
        }
    }
    func login() {
        guard !busy else { return }
        perform("登录成功，账号已自动保存。请重新打开 Codex。") { [self] in
            loggingIn = true
            status = "请在浏览器中完成登录。原账号将在登录成功前保留。"
            try await BrowserLogin.run(store: store)
        }
    }
    func cancel() { operation?.cancel() }
    func finishBeforeQuit() async { operation?.cancel(); await operation?.value }

}

@MainActor
struct ContentView: View {
    @ObservedObject var model: AccountModel
    let proxyModel: ProxyModel
    @Environment(\.colorScheme) private var scheme
    @State private var pendingRemoval: Account?
    @State private var showRemoval = false
    @State private var showClear = false
    @State private var showHelp = false
    private let forest = Color(red: 0.098, green: 0.247, blue: 0.208)
    private let mint = Color(red: 0.82, green: 0.918, blue: 0.859)
    private var accent: Color { SwitchPalette.accent }
    private var canvas: Color { SwitchPalette.canvas }
    private var surface: Color { SwitchPalette.surface }
    private var line: Color { SwitchPalette.border }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 36, height: 36).accessibilityLabel("Codex Switch")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Codex").font(.system(size: 17, weight: .semibold))
                        Text("Switch").font(.system(size: 11)).tracking(1.8).foregroundStyle(SwitchPalette.muted)
                    }
                }.padding(.bottom, 32)
                Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(SwitchPalette.muted).padding(.leading, 12).padding(.bottom, 10)
                navigationButton("账号总览", icon: "person.2", selected: model.page == .accounts) { model.page = .accounts }
                navigationButton("网络代理", icon: "network", selected: model.page == .proxy) {
                    model.page = .proxy
                }.padding(.top, 6)
                navigationButton("使用说明", icon: "info.circle", selected: model.page == .help) { model.page = .help }.padding(.top, 6)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive").font(.system(size: 13)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地运行").font(.system(size: 11, weight: .medium))
                        Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"))
                            .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(SwitchPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }.padding(.horizontal, 16).padding(.vertical, 24)
                .background(SwitchPalette.inset.opacity(0.7))
                .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.page == .proxy ? "工作空间  /  网络代理" : model.page == .help ? "工作空间  /  使用说明" : "工作空间  /  账号总览")
                            .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                        Text(model.page == .help ? "使用说明" : model.page == .proxy ? "网络代理" : "账号总览").font(.system(size: 24, weight: .semibold))
                        if model.page != .proxy { Text(model.page == .help ? "关于你的本地工作空间。" : "你的账号，一处管理。")
                            .font(.system(size: 12)).foregroundStyle(SwitchPalette.muted) }
                    }
                    Spacer()
                    Button { if model.page == .proxy { Task { await proxyModel.refreshStatus() } } else { model.perform("账号已刷新") { } } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(SwitchButtonStyle()).help("刷新状态").accessibilityLabel("刷新状态")
                    if model.page == .accounts {
                        Button { model.login() } label: { Label("添加账号", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 5) }
                            .buttonStyle(.borderedProminent).tint(Color(red: 0.14, green: 0.42, blue: 0.325))
                    }
                }.padding(.bottom, 20).disabled(model.busy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if model.page == .help { help } else if model.page == .proxy { ProxyView(model: proxyModel) } else { accountContent }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                }.disabled(model.busy)
                StatusFooter(model: model, proxyModel: proxyModel)
                    .padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
            }.padding(.horizontal, 26).padding(.top, 22).background(canvas)
        }
        .tint(accent)
        .confirmationDialog("移除保存的账号？", isPresented: $showRemoval, titleVisibility: .visible) {
            Button("移除账号", role: .destructive) {
                guard let account = pendingRemoval else { return }
                model.perform("已移除保存的账号，快照已备份") { try await model.store.remove(account.id) }
            }
        } message: { Text("\(pendingRemoval?.email ?? "")\n当前登录不受影响，快照会归档到本地备份。") }
        .confirmationDialog("清空当前登录？", isPresented: $showClear, titleVisibility: .visible) {
            Button("备份并清空", role: .destructive) {
                model.perform("当前登录已备份并清空。请重新打开 Codex。") { try await model.store.clear() }
            }
        } message: { Text("当前登录会先保存并备份。清空后，请完全退出并重新打开 Codex。") }
    }

    private func navigationButton(_ label: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 19)
                Text(label).font(.system(size: 12, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if selected { Circle().fill(accent).frame(width: 5, height: 5) }
            }.padding(.horizontal, 12).padding(.vertical, 12)
                .foregroundStyle(selected ? accent : SwitchPalette.muted)
                .background(selected ? SwitchPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? accent.opacity(0.12) : .clear) }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Label { Text("当前账号").tracking(0.7) } icon: { Circle().fill(mint).frame(width: 6, height: 6) }
                    .font(.system(size: 12)).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.current?.email ?? "尚未登录").font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(model.current?.plan.uppercased() ?? "添加账号以开始").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .padding(.horizontal, 8).padding(.vertical, 4).foregroundStyle(mint)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
                HStack {
                    Button { model.perform("当前登录已保存") { try await model.store.saveCurrent() } } label: {
                        Label("保存当前登录", systemImage: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 9).foregroundStyle(forest)
                            .background(mint, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).disabled(model.current == nil)
                    Spacer()
                    Menu {
                        Button("清空当前登录…", role: .destructive) { showClear = true }.disabled(model.current == nil)
                    } label: { Image(systemName: "ellipsis").foregroundStyle(mint) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).accessibilityLabel("当前账号的更多操作")
                }.padding(.top, 8)
                HStack {
                    Text("额度待核验").help("本地会话日志不能可靠归属到当前账号，不作为实时额度展示。")
                    Spacer()
                    Text("仅在本机保存")
                }.font(.system(size: 11)).foregroundStyle(mint.opacity(0.8)).padding(.top, 13)
                    .overlay(alignment: .top) { Rectangle().fill(mint.opacity(0.18)).frame(height: 1) }
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topTrailing) {
                    ZStack {
                        ForEach([64.0, 104.0, 144.0], id: \.self) { size in Circle().stroke(mint.opacity(0.14), lineWidth: 1).frame(width: size, height: size) }
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(mint.opacity(0.2)).font(.system(size: 18))
                    }.frame(width: 154, height: 154).padding(18).allowsHitTesting(false).accessibilityHidden(true)
                }
                .background(forest, in: RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 14) {
                HStack(spacing: 9) {
                    Text("账号库").font(.system(size: 17, weight: .semibold))
                    Text("\(model.accounts.count)").font(.system(size: 11)).foregroundStyle(accent)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                    TextField("搜索账号…", text: $model.search).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .frame(width: 185).accessibilityLabel("搜索邮箱或订阅")
                }
                VStack(spacing: 0) {
                    if model.filtered.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 28))
                            Text(model.accounts.isEmpty ? "登录新账号，或保存当前登录即可开始。" : "没有匹配的账号，试试其他关键词。")
                        }.font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                    }
                    ForEach(model.filtered) { account in
                        accountRow(account)
                        if account.id != model.filtered.last?.id { Divider().overlay(line) }
                    }
                }.background(surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(line, lineWidth: 1) }
            }
            Label("切换后，重新打开 Codex 以应用新的登录。", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func avatarColor(_ email: String) -> Color {
        let slot = email.utf16.reduce(0) { ($0 * 31 + Int($1)) & 0xFFFF } % 4
        let colors = [Color(red: 0.867, green: 0.918, blue: 0.867), Color(red: 0.925, green: 0.89, blue: 0.843),
                      Color(red: 0.878, green: 0.894, blue: 0.945), Color(red: 0.855, green: 0.914, blue: 0.922)]
        return colors[slot]
    }
    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 13) {
            Text(String(account.email.prefix(1)).uppercased()).font(.system(size: 15, weight: .semibold)).foregroundStyle(forest)
                .frame(width: 38, height: 38).background(avatarColor(account.email), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(account.plan.uppercased()).tracking(0.6).foregroundStyle(.secondary)
                    if account.isCurrent { Text("· 当前使用中").foregroundStyle(accent) }
                }.font(.system(size: 10, weight: .medium))
                Text(account.email).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(account.email)
            }
            Spacer(minLength: 8)
            if account.isCurrent { Image(systemName: "checkmark").font(.system(size: 14, weight: .medium)).foregroundStyle(accent).padding(.horizontal, 10).accessibilityLabel("当前使用中") }
            else {
                Button { model.perform("账号文件已切换。请完全退出并重新打开 Codex。") { try await model.store.switchAccount(account.id) } } label: {
                    HStack(spacing: 7) { Text("切换"); Image(systemName: "arrow.right") }.font(.system(size: 12)).foregroundStyle(accent).padding(8)
                }.buttonStyle(.plain)
            }
            Menu {
                Button("移除保存的账号…", role: .destructive) { pendingRemoval = account; showRemoval = true }
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("\(account.email) 的更多操作")
        }.padding(.horizontal, 18).padding(.vertical, 16)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("轻松切换，妥善保存。").font(.system(size: 22, weight: .semibold))
            Text("登录新账号会通过 Codex CLI 打开浏览器。成功后自动保存；取消或超时会保留原账号。")
            Text("切换会先保存并备份当前登录。使用 Command-Q 完全退出 Codex 后重新打开，以加载新的登录。")
            Text("代理页可直接管理 mihomo。先下载内核、导入订阅，再启动并开启系统代理。家宽双跳可在设置里启用。")
            Text("出口节点按 AI 工具、GitHub / 开发、家宽中转分别选择。分流规则提供三种预设，支持自定义规则和 Clash 规则列表导入；自定义规则从上到下优先匹配。保存并应用后立即生效，端口与家宽配置变更需要重启代理。")
            Text("本工具管理文件登录，不会自动改写 macOS 钥匙串。使用系统凭据存储时，需要先确认 Codex 配置为文件存储。")
            Text("本地快照和备份包含登录凭据，请勿分享或上传。额度尚未核验，本地会话记录不作为实时额度展示。")
            Text(model.store.directory.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(26)
            .frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 16))
    }
}


@MainActor
private struct StatusFooter: View {
    @ObservedObject var model: AccountModel
    @ObservedObject var proxyModel: ProxyModel
    var body: some View {
        HStack(spacing: 9) {
            if model.busy || proxyModel.busy { ProgressView().controlSize(.small) }
            else { Circle().fill(SwitchPalette.accent.opacity(0.65)).frame(width: 5, height: 5) }
            Text(model.page == .proxy ? (proxyModel.message == "导入订阅后即可启动代理。" && !proxyModel.names.isEmpty
                ? "已载入 \(proxyModel.names.count) 个节点" : proxyModel.message) : model.status)
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
            if model.loggingIn { Button("取消登录") { model.cancel() } }
            if proxyModel.cancellable { Button("取消") { proxyModel.cancel() } }
        }
    }
}
