import SwiftUI
import AppKit
import CodexSwitchCore

@MainActor
struct ProxyRulesView: View {
    @ObservedObject var model: ProxyModel
    let chooseNodes: (ProxyRoute) -> Void
    let configureHome: () -> Void
    @State private var editor: RuleEditorRequest?
    @State private var importing = false
    @State private var preview: String?
    private struct RuleEditorRequest: Identifiable {
        let rule: RoutingRule
        var id: String { rule.id }
    }
    private var input: DialerProxyInput { model.store.input(model.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("让不同用途走合适的出口").font(.system(size: 19, weight: .semibold))
                    Text("选择一套方案，再按需要调整分组和自定义规则。")
                        .font(.system(size: 12)).foregroundStyle(SwitchPalette.muted)
                }
                Spacer(minLength: 12)
                if model.rulesNeedApply { badge("有待应用的更改", icon: "circle.fill") }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140), spacing: 10), count: 3), spacing: 10) {
                ForEach(RoutingPreset.allCases) { preset in presetCard(preset) }
            }
            section("用途与出口", subtitle: "先匹配自定义规则，再按用途分流，最后使用默认出口。") {
                groupRow("AI 工具", icon: "sparkles", detail: "OpenAI · Gemini · Cursor · Copilot · xAI",
                         target: $model.settings.routing.ai, route: .exit)
                Divider().overlay(SwitchPalette.border)
                groupRow("GitHub 与开发网站", icon: "chevron.left.forwardslash.chevron.right", detail: "GitHub · API · 静态资源 · 下载 · Docker",
                         target: $model.settings.routing.development, route: .development)
                Divider().overlay(SwitchPalette.border)
                VStack(alignment: .leading, spacing: 10) {
                    groupRow("家宽中转", icon: "house", detail: "Claude · Anthropic · Claude 用户内容",
                             target: $model.settings.routing.anthropic, route: .relay, automaticHome: true)
                    HStack(spacing: 8) {
                        Image(systemName: model.settings.useHomeProxy ? "checkmark.circle.fill" : "info.circle")
                        Text(model.settings.useHomeProxy
                             ? "家宽已启用 · \(model.settings.selectedSocksProfile?.name ?? "SOCKS5 出口")"
                             : "家宽未启用，此组使用\(model.settings.routing.anthropicTarget(useHomeProxy: false).title)。")
                        Spacer(minLength: 6)
                        Button(model.settings.useHomeProxy ? "管理家宽" : "配置家宽") { configureHome() }
                            .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true))
                    }.font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
                        .padding(10).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                }
                Divider().overlay(SwitchPalette.border)
                HStack {
                    Label("其他网站", systemImage: "globe").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("默认出口", selection: $model.settings.proxyOtherSites) {
                        Text("直连").tag(false)
                        Text("AI 出口").tag(true)
                    }.labelsHidden().frame(width: 160)
                }
            }
            section("自定义规则", subtitle: "从上到下匹配，首条命中即生效。可覆盖内置分流。") {
                HStack {
                    badge("\(model.settings.routing.customRules.filter(\.enabled).count) 条启用", icon: "line.3.horizontal.decrease")
                    Spacer()
                    Button("导入 Clash 规则") { importing = true }.buttonStyle(SwitchButtonStyle(compact: true))
                    Button { editor = RuleEditorRequest(rule: RoutingRule()) } label: { Label("添加规则", systemImage: "plus") }
                        .buttonStyle(SwitchButtonStyle(kind: .primary, compact: true))
                }
                if model.settings.routing.customRules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 23, weight: .light)).foregroundStyle(SwitchPalette.accent)
                        Text("为网站、应用或网段指定出口").font(.system(size: 12, weight: .medium))
                        Text("例如：让 example.com 直连，或让某个应用走家宽。")
                            .font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
                    }.frame(maxWidth: .infinity).padding(22).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.settings.routing.customRules.enumerated()), id: \.element.id) { index, rule in
                            ruleRow(rule, index: index)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("保存规则") { model.saveRules(apply: false) }
                Button(model.state.running ? "保存并应用" : "保存并用于下次启动") { model.saveRules(apply: true) }
                    .buttonStyle(SwitchButtonStyle(kind: .primary))
                Spacer()
                Button("预览 Clash 规则") {
                    do {
                        let yaml = try DialerProxyBuilder.build(input).yaml
                        preview = "rules:\n" + (yaml.components(separatedBy: "\nrules:\n").last ?? "")
                    } catch { model.message = error.localizedDescription }
                }.buttonStyle(SwitchButtonStyle(kind: .quiet)).disabled(model.names.isEmpty)
            }
            Text(model.state.running ? "应用时校验并重新载入规则，系统代理与监听端口保持当前配置。" : "规则将保存在本机，启动代理时自动载入。")
                .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
        }
        .disabled(model.busy)
        .sheet(item: $editor) { request in
            RoutingRuleEditor(rule: request.rule, homeEnabled: model.settings.useHomeProxy) { rule in
                if let index = model.settings.routing.customRules.firstIndex(where: { $0.id == rule.id }) {
                    model.settings.routing.customRules[index] = rule
                } else { model.settings.routing.customRules.append(rule) }
            }
        }
        .sheet(isPresented: $importing) {
            ClashRulesImporter(input: input, homeEnabled: model.settings.useHomeProxy) { rules in
                model.settings.routing.customRules.append(contentsOf: rules)
            }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Clash 规则预览").font(.title2)
                Text("当前草稿生成的实际规则，包含自定义规则及最终默认出口。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    Text(preview ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("复制规则") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(preview ?? "", forType: .string) }
                    Spacer()
                    Button("完成") { preview = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 650, height: 480)
        }
    }
    private func presetCard(_ preset: RoutingPreset) -> some View {
        let selected = model.settings.routing.preset(proxyOtherSites: model.settings.proxyOtherSites) == preset
        return Button { model.applyPreset(preset) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: preset == .smart ? "arrow.triangle.branch" : preset == .aiOnly ? "sparkles" : "globe")
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").opacity(selected ? 1 : 0.35)
                }.font(.system(size: 16)).foregroundStyle(SwitchPalette.accent)
                Text(preset.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(preset.detail).font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(15).frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
                .background(selected ? SwitchPalette.selected : SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? SwitchPalette.accent.opacity(0.4) : SwitchPalette.border) }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func groupRow(_ title: String, icon: String, detail: String, target: Binding<RoutingTarget>, route: ProxyRoute,
                          automaticHome: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(SwitchPalette.accent)
                .frame(width: 36, height: 36).background(SwitchPalette.selected, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(SwitchPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Picker("\(title)出口", selection: target) {
                ForEach(RoutingTarget.allCases) { item in
                    Text(item == .residential && automaticHome ? "家宽（未启用时用 AI）" : item.title).tag(item)
                        .disabled(item == .residential && !automaticHome && !model.settings.useHomeProxy)
                }
            }.labelsHidden().frame(width: automaticHome ? 185 : 125)
            Button { chooseNodes(route) } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).help("选择\(title)节点").accessibilityLabel("选择\(title)节点")
        }.padding(.vertical, 3)
    }
    private func ruleRow(_ rule: RoutingRule, index: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("启用规则 \(rule.value)", isOn: Binding(get: { rule.enabled }, set: { value in
                if let position = model.settings.routing.customRules.firstIndex(where: { $0.id == rule.id }) {
                    model.settings.routing.customRules[position].enabled = value
                }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(SwitchPalette.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.value).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(rule.kind.rawValue + (rule.noResolve ? " · no-resolve" : ""))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(SwitchPalette.muted)
            }.opacity(rule.enabled ? 1 : 0.5)
            Spacer(minLength: 4)
            Text(rule.target.title).font(.system(size: 10, weight: .medium)).foregroundStyle(SwitchPalette.accent)
                .padding(.horizontal, 8).padding(.vertical, 5).background(SwitchPalette.selected, in: Capsule())
            smallButton("上移", icon: "arrow.up", disabled: index == 0) { moveRule(index, by: -1) }
            smallButton("下移", icon: "arrow.down", disabled: index + 1 == model.settings.routing.customRules.count) { moveRule(index, by: 1) }
            smallButton("编辑规则", icon: "pencil") { editor = RuleEditorRequest(rule: rule) }
            smallButton("删除规则", icon: "trash") { model.settings.routing.customRules.removeAll { $0.id == rule.id } }
        }.padding(11).background(SwitchPalette.inset, in: RoundedRectangle(cornerRadius: 9))
    }
    private func moveRule(_ index: Int, by offset: Int) {
        let other = index + offset
        guard model.settings.routing.customRules.indices.contains(index), model.settings.routing.customRules.indices.contains(other) else { return }
        model.settings.routing.customRules.swapAt(index, other)
    }
    private func smallButton(_ title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11)) }
            .buttonStyle(SwitchButtonStyle(kind: .quiet, compact: true)).help(title).accessibilityLabel(title).disabled(disabled)
    }
    private func badge(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(SwitchPalette.accent)
            .padding(.horizontal, 10).padding(.vertical, 7).background(SwitchPalette.selected, in: Capsule())
    }
    private func section<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(SwitchPalette.muted)
            }
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(SwitchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SwitchPalette.border) }
    }
}

@MainActor
private struct RoutingRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: RoutingRule
    let homeEnabled: Bool
    let save: (RoutingRule) -> Void
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(rule.value.isEmpty ? "添加自定义规则" : "编辑自定义规则").font(.title2)
            Text("命中后使用指定出口，自定义规则优先于内置方案。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("匹配方式", selection: $rule.kind) {
                ForEach(RoutingRuleKind.allCases) { kind in Text("\(kind.title) · \(kind.rawValue)").tag(kind) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("匹配内容").font(.caption).foregroundStyle(.secondary)
                TextField(rule.kind.example, text: $rule.value).textFieldStyle(SwitchFieldStyle())
            }
            Picker("使用出口", selection: $rule.target) {
                ForEach(RoutingTarget.allCases) { target in Text(target.title).tag(target).disabled(target == .residential && !homeEnabled) }
            }
            if rule.kind.isIP { Toggle("不触发域名解析（no-resolve）", isOn: $rule.noResolve).font(.caption) }
            Toggle("启用这条规则", isOn: $rule.enabled).font(.caption)
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("完成") {
                    do {
                        var checked = rule
                        if !checked.kind.isIP { checked.noResolve = false }
                        checked = try checked.validated()
                        guard !checked.enabled || checked.target != .residential || homeEnabled else { throw StoreError("请先配置并启用家宽出口。") }
                        save(checked); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(SwitchButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 530).buttonStyle(SwitchButtonStyle())
    }
}

@MainActor
private struct ClashRulesImporter: View {
    @Environment(\.dismiss) private var dismiss
    let input: DialerProxyInput
    let homeEnabled: Bool
    let save: ([RoutingRule]) -> Void
    @State private var text = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("导入 Clash 规则").font(.title2)
            Text("粘贴规则列表，将按原顺序追加到自定义规则末尾。")
                .font(.caption).foregroundStyle(.secondary)
            Text("AI：\(input.exitGroup)  ·  开发：\(DialerProxyBuilder.developmentGroup)  ·  家宽：\(input.targetName)\n直连：DIRECT  ·  拦截：REJECT")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(SwitchPalette.accent)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minHeight: 200)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SwitchPalette.border) }
            Text("示例：DOMAIN-SUFFIX,example.com,DIRECT\n支持域名、IP-CIDR、进程、目标端口、TCP / UDP；规则集与逻辑组合请先展开为上述规则。")
                .font(.system(size: 10)).foregroundStyle(SwitchPalette.muted)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") {
                    do {
                        let rules = try RoutingRule.importClash(text, input: input)
                        guard homeEnabled || !rules.contains(where: { $0.target == .residential }) else { throw StoreError("导入规则使用了家宽双跳，请先启用家宽出口。") }
                        save(rules); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(SwitchButtonStyle(kind: .primary)).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 640, height: 470).buttonStyle(SwitchButtonStyle())
    }
}
