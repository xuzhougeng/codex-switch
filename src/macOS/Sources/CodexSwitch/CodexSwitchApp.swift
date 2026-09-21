import SwiftUI
import AppKit
import CodexSwitchCore

@main
@MainActor
struct CodexSwitchApp: App {
    @NSApplicationDelegateAdaptor(SwitchAppDelegate.self) private var appDelegate
    @StateObject private var model = AccountModel()
    var body: some Scene {
        WindowGroup("Codex Switch") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 580)
                .task { await model.refresh() }
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 940, height: 740)
        .commands {
            CommandGroup(after: .newItem) {
                Button("登录新账号") { model.login() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.busy)
                Button("刷新账号") { model.perform("账号已刷新") { } }.keyboardShortcut("r").disabled(model.busy)
            }
        }
    }
}

@MainActor
final class SwitchAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AccountModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        Task { await model.finishBeforeQuit(); sender.reply(toApplicationShouldTerminate: true) }
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
    @Published var page: Page = .accounts
    @Published var proxy = ClashProxySettings()
    @Published var proxyStatus = "未运行"
    let store = AccountStore()
    let clashStore = ClashProxyStore()
    let clashRuntime: ClashProxyRuntime
    private var operation: Task<Void, Never>?
    enum Page { case accounts, proxy, help }
    init() { clashRuntime = ClashProxyRuntime(store: clashStore) }

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
    func loadProxy() {
        Task {
            do {
                proxy = try await clashStore.load()
                proxyStatus = try await clashRuntime.status().detail
            } catch { status = "读取双跳配置失败：" + error.localizedDescription }
        }
    }
    func saveProxy() {
        perform("双跳配置已保存") { [self] in
            try await clashStore.save(proxy)
            _ = try await clashStore.materialize(proxy)
            proxyStatus = try await clashRuntime.status().detail
        }
    }
    func startProxy() {
        perform("双跳代理已启动。Codex 使用 http://127.0.0.1:1990") { [self] in
            let result = try await clashRuntime.start(proxy)
            proxyStatus = result.detail
        }
    }
    func stopProxy() {
        perform("双跳代理已停止") { [self] in
            try await clashRuntime.stop()
            proxyStatus = try await clashRuntime.status().detail
        }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: AccountModel
    @Environment(\.colorScheme) private var scheme
    @State private var pendingRemoval: Account?
    @State private var showRemoval = false
    @State private var showClear = false
    @State private var showHelp = false
    private let forest = Color(red: 0.098, green: 0.247, blue: 0.208)
    private let mint = Color(red: 0.82, green: 0.918, blue: 0.859)
    private var accent: Color { scheme == .dark ? mint : Color(red: 0.14, green: 0.42, blue: 0.325) }
    private var canvas: Color { scheme == .dark ? Color(red: 0.09, green: 0.114, blue: 0.106) : Color(red: 0.97, green: 0.975, blue: 0.98) }
    private var surface: Color { scheme == .dark ? Color(red: 0.125, green: 0.157, blue: 0.141) : .white }
    private var line: Color { scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.07) }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 44, height: 44).accessibilityLabel("Codex Switch")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Codex").font(.system(size: 20, weight: .semibold))
                        Text("Switch").font(.system(size: 13)).tracking(2).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 44)
                Text("工作空间").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 10).padding(.bottom, 12)
                navigationButton("账号总览", icon: "person.2", selected: model.page == .accounts) { model.page = .accounts }
                navigationButton("双跳代理", icon: "network", selected: model.page == .proxy) {
                    model.page = .proxy
                    model.loadProxy()
                }.padding(.top, 6)
                navigationButton("使用说明", icon: "info.circle", selected: model.page == .help) { model.page = .help }.padding(.top, 6)
                Spacer()
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(accent).frame(width: 6, height: 6).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本机存储").font(.system(size: 12))
                        Text("Codex Switch  /  2.0").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(.leading, 10)
            }.padding(.horizontal, 20).padding(.vertical, 28)
                .navigationSplitViewColumnWidth(min: 175, ideal: 196, max: 220)
        } detail: {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ACCOUNTS").font(.system(size: 10, weight: .medium)).tracking(2.2).foregroundStyle(.secondary)
                        Text(model.page == .help ? "使用说明" : model.page == .proxy ? "双跳代理" : "账号总览").font(.system(size: 28, weight: .semibold))
                        Text(model.page == .proxy ? "中转 + 美国家宽，带本机限流。" : "你的账号，一处管理。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.perform("账号已刷新") { } } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                        .buttonStyle(.borderless).help("刷新账号")
                    if model.page == .accounts {
                        Button { model.login() } label: { Label("添加账号", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 5) }
                            .buttonStyle(.borderedProminent).tint(Color(red: 0.14, green: 0.42, blue: 0.325))
                    }
                }.padding(.bottom, 26).disabled(model.busy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if model.page == .help { help } else if model.page == .proxy { proxyContent } else { accountContent }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                }.disabled(model.busy)
                HStack(spacing: 9) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if model.loggingIn { Button("取消登录") { model.cancel() } }
                }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
            }.padding(.horizontal, 32).padding(.top, 26).background(canvas)
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
            Label(label, systemImage: icon).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                .foregroundStyle(selected ? accent : .secondary)
                .background(selected ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
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

    private var proxyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("状态").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.proxyStatus).font(.system(size: 16, weight: .semibold))
                    Text("Codex 走 http://127.0.0.1:1990。先保存配置再启动。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("启动") { model.startProxy() }.buttonStyle(.borderedProminent).tint(Color(red: 0.14, green: 0.42, blue: 0.325))
                Button("停止") { model.stopProxy() }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(surface, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 10) {
                Text("第一跳 · 中转节点 YAML").font(.system(size: 13, weight: .semibold))
                TextEditor(text: $model.proxy.relayYaml).font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 150).padding(8)
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(line, lineWidth: 1) }
            }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 10) {
                Text("第二跳 · 美国家宽 SOCKS5").font(.system(size: 13, weight: .semibold))
                HStack {
                    TextField("地址", text: $model.proxy.homeServer)
                    TextField("端口", text: $model.proxy.homePort).frame(width: 90)
                }
                HStack {
                    TextField("用户名（可选）", text: $model.proxy.homeUsername)
                    SecureField("密码", text: $model.proxy.homePassword)
                }
                HStack {
                    TextField("同时最多", value: $model.proxy.maxConcurrent, format: .number)
                    TextField("间隔毫秒", value: $model.proxy.dialIntervalMs, format: .number)
                }
                TextField("mihomo 路径（可留空）", text: $model.proxy.mihomoPath)
                Button("保存配置") { model.saveProxy() }
            }.textFieldStyle(.roundedBorder).padding(18).background(surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("轻松切换，妥善保存。").font(.system(size: 22, weight: .semibold))
            Text("登录新账号会通过 Codex CLI 打开浏览器。成功后自动保存；取消或超时会保留原账号。")
            Text("切换会先保存并备份当前登录。使用 Command-Q 完全退出 Codex 后重新打开，以加载新的登录。")
            Text("双跳代理会启动 mihomo 和本机限流。Codex 走 http://127.0.0.1:1990，请自行设置 http_proxy。")
            Text("本工具管理文件登录，不会自动改写 macOS 钥匙串。使用系统凭据存储时，需要先确认 Codex 配置为文件存储。")
            Text("本地快照和备份包含登录凭据，请勿分享或上传。额度尚未核验，本地会话记录不作为实时额度展示。")
            Text(model.store.directory.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(26)
            .frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 16))
    }
}
