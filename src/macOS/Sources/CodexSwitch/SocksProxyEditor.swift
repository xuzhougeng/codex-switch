import SwiftUI
import AppKit
import CodexSwitchCore

@MainActor
struct SocksProxyEditor: View {
    @ObservedObject var model: ProxyModel
    let selectOnSave: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SocksProxyProfile
    @State private var authenticate: Bool
    @State private var revealPassword = false
    @State private var mode: EntryMode
    @State private var address = ""
    @State private var error = ""
    private enum EntryMode: String, CaseIterable { case link = "导入链接", manual = "手动填写" }
    init(model: ProxyModel, profile: SocksProxyProfile, selectOnSave: Bool) {
        self.model = model; self.selectOnSave = selectOnSave
        _draft = State(initialValue: profile)
        _authenticate = State(initialValue: profile.usesAuthentication)
        _mode = State(initialValue: profile.server.isEmpty ? .link : .manual)
    }
    private var prepared: SocksProxyProfile {
        var result = draft
        if !authenticate { result.username = ""; result.password = "" }
        return result
    }
    private var testProfile: SocksProxyProfile { (try? prepared.validated()) ?? prepared }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "server.rack").font(.system(size: 23, weight: .light)).foregroundStyle(SwitchPalette.accent)
                    .frame(width: 48, height: 48).background(SwitchPalette.selected, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectOnSave ? "添加 SOCKS5 代理" : "编辑 SOCKS5 代理").font(.system(size: 19, weight: .semibold))
                    Text("给每个出口命名，保存后随时切换。")
                        .font(.system(size: 12)).foregroundStyle(SwitchPalette.muted)
                }
                Spacer()
            }.padding(24)
            Divider().overlay(SwitchPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 4) {
                        ForEach(EntryMode.allCases, id: \.self) { value in
                            Button { mode = value; error = "" } label: {
                                Label(value.rawValue, systemImage: value == .link ? "link" : "slider.horizontal.3")
                                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .foregroundStyle(mode == value ? SwitchPalette.accent : SwitchPalette.muted)
                                    .background(mode == value ? SwitchPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? .isSelected : [])
                        }
                    }.padding(4).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
                    entry("配置名称", placeholder: "例如：美国住宅 · 工作", text: $draft.name)
                    if mode == .link { linkEntry } else { manualEntry }
                }.padding(24).disabled(model.busy)
            }.frame(height: 400)
            Divider().overlay(SwitchPalette.border)
            VStack(alignment: .leading, spacing: 12) {
                if !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if mode == .manual {
                    if error.isEmpty { SocksTestStatus(outcome: model.socksTest(for: testProfile)) }
                    Text(model.settings.selectedRelay.isEmpty ? "先在节点页选择中转，再测试双跳链路。" : "中转：\(model.settings.selectedRelay) · 测试不改变现有连接")
                        .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted).lineLimit(1)
                        .help("通过当前中转及 SOCKS5 出口访问 http://www.gstatic.com/generate_204")
                } else {
                    Label("解析后可核对信息，再测试或保存。", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
                }
                HStack(spacing: 10) {
                    if model.busy && model.cancellable {
                        Button("取消测试") { model.cancel() }
                    } else {
                        Button { test() } label: { Label("测试连接", systemImage: "bolt.horizontal") }
                            .disabled(model.busy || mode == .link)
                    }
                    Spacer()
                    Button("取消") { dismiss() }.disabled(model.busy).keyboardShortcut(.cancelAction)
                    Button(selectOnSave ? "保存并选用" : "保存更改") { save() }
                        .buttonStyle(SwitchButtonStyle(kind: .primary)).disabled(model.busy || mode == .link)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(20)

        }.frame(width: 570).background(SwitchPalette.surface)
            .buttonStyle(SwitchButtonStyle()).textFieldStyle(SwitchFieldStyle()).tint(SwitchPalette.accent)
            .interactiveDismissDisabled(model.busy)
            .onChange(of: draft) { _ in error = "" }
            .onChange(of: authenticate) { _ in error = "" }
    }
    private var linkEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SOCKS5 链接").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { pasteAddress() } label: { Label("从剪贴板粘贴", systemImage: "doc.on.clipboard") }
                    .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true))
            }
            SecureField("粘贴服务商提供的完整代理地址", text: $address)
                .accessibilityLabel("SOCKS5 链接").onSubmit { importAddress() }
            VStack(alignment: .leading, spacing: 6) {
                Text("支持以下格式").font(.system(size: 11, weight: .medium))
                Text("socks5://用户名:密码@服务器:1080\n服务器:1080:用户名:密码")
                    .font(.system(size: 11, design: .monospaced)).lineSpacing(5)
                Text("无需认证时可直接填写 服务器:端口。")
                    .font(.system(size: 11))
            }.foregroundStyle(SwitchPalette.muted).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 9))
            Button { importAddress() } label: { Label("解析并填写", systemImage: "arrow.down.to.line") }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                entry("服务器地址", placeholder: "域名或 IP，例如 proxy.example.com", text: $draft.server)
                entry("端口", placeholder: "1080", text: $draft.port).frame(width: 95)
            }
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("身份认证").font(.system(size: 12, weight: .medium))
                        Text("服务商要求账号密码时开启").font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
                    }
                    Spacer()
                    Toggle("身份认证", isOn: $authenticate).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if authenticate {
                    HStack(alignment: .top, spacing: 14) {
                        entry("用户名", placeholder: "服务商提供的用户名", text: $draft.username)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("密码").font(.system(size: 12, weight: .medium))
                            HStack(spacing: 6) {
                                Group {
                                    if revealPassword { TextField("密码", text: $draft.password) }
                                    else { SecureField("密码", text: $draft.password) }
                                }.textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("SOCKS5 密码")
                                Button { revealPassword.toggle() } label: { Image(systemName: revealPassword ? "eye.slash" : "eye") }
                                    .buttonStyle(.plain).foregroundStyle(SwitchPalette.muted)
                                    .accessibilityLabel(revealPassword ? "隐藏密码" : "显示密码")
                            }.padding(.horizontal, 11).padding(.vertical, 9)
                                .background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SwitchPalette.border.opacity(0.7)) }
                        }.frame(maxWidth: .infinity)
                    }
                }
            }.padding(16).overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(SwitchPalette.border) }
        }
    }
    private func entry(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: text).accessibilityLabel(label)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func pasteAddress() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { error = "剪贴板中没有文本。"; return }
        address = text; importAddress()
    }
    private func importAddress() {
        do {
            try draft.importAddress(address)
            authenticate = draft.usesAuthentication; revealPassword = false
            address = ""; error = ""; mode = .manual
        } catch { self.error = error.localizedDescription }
    }
    private func test() {
        do { let profile = try prepared.validated(); error = ""; model.testSocksProfile(profile) }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            let profile = try prepared.validated()
            error = ""
            Task {
                do { try await model.saveSocksProfile(profile, select: selectOnSave); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
