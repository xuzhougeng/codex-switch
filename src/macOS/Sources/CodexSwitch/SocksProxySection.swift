import SwiftUI
import CodexSwitchCore

@MainActor
struct SocksProxySection: View {
    @ObservedObject var model: ProxyModel
    let chooseRelay: () -> Void
    @State private var editor: EditorRequest?
    @State private var removing: SocksProxyProfile?
    @State private var showRemoval = false
    private struct EditorRequest: Identifiable {
        let profile: SocksProxyProfile
        let selectOnSave: Bool
        var id: String { profile.id }
    }
    private func addProfile() {
        editor = EditorRequest(profile: SocksProxyProfile(name: "家宽代理 \(model.settings.socksProfiles.count + 1)"), selectOnSave: true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.system(size: 20, weight: .light))
                    .foregroundStyle(SwitchPalette.accent).frame(width: 42, height: 42)
                    .background(SwitchPalette.selected, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("SOCKS5 出口").font(.system(size: 15, weight: .semibold))
                    Text("Claude / Anthropic 通过家宽双跳访问").font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
                }
                Spacer(minLength: 8)
                Toggle("启用 SOCKS5 家宽出口", isOn: Binding(get: { model.settings.useHomeProxy }, set: { enabled in
                    if enabled && model.settings.selectedSocksProfile == nil { addProfile() }
                    else { model.setSocksEnabled(enabled) }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("启用 SOCKS5 家宽出口").disabled(model.busy)
            }
            if model.settings.socksProfiles.isEmpty {
                VStack(spacing: 10) {
                    Text("添加一个 SOCKS5 代理").font(.system(size: 13, weight: .medium))
                    Text("支持链接导入，也可以填写服务器与认证信息。")
                        .font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
                    Button { addProfile() } label: { Label("添加配置", systemImage: "plus") }
                        .buttonStyle(SwitchButtonStyle(kind: .primary)).disabled(model.busy)
                }.frame(maxWidth: .infinity).padding(24)
                    .background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 10) {
                    ForEach(model.settings.socksProfiles) { profile in profileRow(profile) }
                }
                HStack {
                    Button { addProfile() } label: { Label("新增配置", systemImage: "plus") }
                        .buttonStyle(SwitchButtonStyle(compact: true)).disabled(model.busy)
                    Spacer()
                    Text("\(model.settings.socksProfiles.count) 个已保存配置").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                }
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(SwitchPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("中转节点").font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                        Text(model.settings.selectedRelay.isEmpty ? "尚未选择" : model.settings.selectedRelay)
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("更改") { chooseRelay() }.buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).disabled(model.busy)
                }.padding(12).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 9))
            }
            if model.socksNeedsRestart {
                HStack(spacing: 10) {
                    Label("配置已保存，重启代理后生效。", systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 11)).foregroundStyle(SwitchPalette.accent)
                    Spacer(minLength: 8)
                    Button("重启代理") { model.restart() }.buttonStyle(SwitchButtonStyle(kind: .primary, compact: true)).disabled(model.busy)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
            .sheet(item: $editor) { request in
                SocksProxyEditor(model: model, profile: request.profile, selectOnSave: request.selectOnSave)
            }
            .confirmationDialog("删除这个 SOCKS5 配置？", isPresented: $showRemoval, titleVisibility: .visible) {
                Button("删除配置", role: .destructive) {
                    if let profile = removing { model.removeSocksProfile(profile.id) }
                    removing = nil
                }
                Button("取消", role: .cancel) { removing = nil }
            } message: {
                Text(removing?.id == model.settings.selectedSocksProfileID
                     ? "删除当前配置会关闭家宽双跳；运行中的代理需重启后生效。" : "将移除此配置及保存的认证信息。")
            }
    }
    private func profileRow(_ profile: SocksProxyProfile) -> some View {
        let selected = model.settings.selectedSocksProfileID == profile.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "server.rack")
                    .font(.system(size: 17)).foregroundStyle(selected ? SwitchPalette.accent : SwitchPalette.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.system(size: 13, weight: .semibold))
                    Text(profile.endpoint).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SwitchPalette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if selected {
                    Text("当前配置").font(.system(size: 10, weight: .medium)).foregroundStyle(SwitchPalette.accent)
                } else {
                    Button("选用") { model.selectSocksProfile(profile.id) }.buttonStyle(SwitchButtonStyle(compact: true)).disabled(model.busy)
                }
                Button("编辑") { editor = EditorRequest(profile: profile, selectOnSave: false) }
                    .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).disabled(model.busy)
                Menu {
                    Button("删除配置…", role: .destructive) { removing = profile; showRemoval = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                    .accessibilityLabel("\(profile.name) 的更多操作").disabled(model.busy)
            }
            HStack(spacing: 8) {
                SocksTestStatus(outcome: model.socksTest(for: profile))
                Spacer(minLength: 8)
                Label(profile.usesAuthentication ? "账号认证" : "无需认证", systemImage: profile.usesAuthentication ? "lock" : "lock.open")
                    .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                Button("测试连接") { model.testSocksProfile(profile) }
                    .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).disabled(model.busy)
            }
        }.padding(14).background(selected ? SwitchPalette.selected : SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? SwitchPalette.accent.opacity(0.25) : SwitchPalette.border) }
    }
}

struct SocksTestStatus: View {
    let outcome: ProxyModel.SocksTestRecord.Outcome?
    var body: some View {
        Group {
            switch outcome {
            case .none: Label("尚未测试", systemImage: "circle.dotted").foregroundStyle(SwitchPalette.muted)
            case .testing: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("测试中…") }
            case .success(let delay): Label("链路正常 · \(delay) ms", systemImage: "checkmark.circle.fill").foregroundStyle(SwitchPalette.accent)
            case .failure(let message): Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange).lineLimit(2).help(message)
            case .cancelled: Label("测试已取消", systemImage: "minus.circle").foregroundStyle(SwitchPalette.muted)
            }
        }.font(.system(size: 11))
    }
}
