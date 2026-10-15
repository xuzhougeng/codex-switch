using System.Text;
using CodexSwitch.Core;
using Spectre.Console;

namespace CodexSwitch.Linux;

sealed partial class MihomoTui
{
    private async Task OutboundNodes(ClashProxySettings settings)
    {
        while (true)
        {
            AnsiConsole.Clear();
            var selected = Pick(["AI 工具       非香港单跳节点", "GitHub / 开发  自动回退或手动指定", "家宽中转      测完整双跳链路", "返回"], title: "[bold]出口节点[/]");
            if (selected < 0 || selected == 3) return;
            if (selected == 0) await SwitchExit(settings);
            else if (selected == 1) await SwitchDevelopment(settings);
            else if (!settings.HomeEnabled) Pause("先在「家宽 SOCKS5」启用家宽，再选择和测试中转节点。");
            else await SwitchRelay(settings);
        }
    }

    private async Task SwitchDevelopment(ClashProxySettings settings)
    {
        AnsiConsole.Clear();
        AnsiConsole.MarkupLine("[bold]GitHub / 开发出口[/]");
        AnsiConsole.WriteLine("自动模式优先可用香港节点，全部失效后使用 AI 单跳出口。");
        AnsiConsole.WriteLine("当前：" + (string.IsNullOrEmpty(settings.SelectedDevelopment) ? "自动回退" : settings.SelectedDevelopment));
        var selected = Pick(["使用自动回退", "手动选择节点（t 测当前，a 测全部）", "返回"]);
        if (selected < 0 || selected == 2) return;
        if (selected == 0)
        {
            settings.SelectedDevelopment = "";
            await ApplyDevelopment(settings);
            return;
        }
        var names = DialerProxyBuilder.ExtractRelayNames(settings.RelayYaml);
        if (names.Count == 0) throw new InvalidOperationException("请先导入订阅。");
        var picked = await PickAndProbe(names, settings.SelectedDevelopment, "选择开发出口 · 测试 github.com",
            () => ProbeSession.StartDevelopmentAsync(local.Store, settings));
        if (picked == null) return;
        settings.SelectedDevelopment = picked.Value.Name;
        await ApplyDevelopment(settings);
    }
    private async Task ApplyDevelopment(ClashProxySettings settings)
    {
        var running = local.Service.Status().Running;
        var active = running ? local.Store.RunningSettings() : settings;
        local.Store.Save(settings);
        if (!running) { Pause("开发出口已保存，启动后生效。"); return; }
        var target = settings.SelectedDevelopment.Length == 0 ? DialerProxyBuilder.HkAutomaticGroup : settings.SelectedDevelopment;
        var group = await ClashApi.GroupAsync(active.Controller, DialerProxyBuilder.HkGroup, CancellationToken.None);
        if (!group.All.Contains(target)) throw new InvalidOperationException("选择已保存；当前后台配置尚无此出口，请在「分流规则」保存并应用后使用。");
        await ClashApi.SelectAsync(active.Controller, DialerProxyBuilder.HkGroup, target, CancellationToken.None, "切换开发出口失败");
        Pause(target == DialerProxyBuilder.HkAutomaticGroup ? "开发出口已启用自动回退。" : "开发出口已切到 " + target);
    }

    private void ManageHome(ClashProxySettings settings)
    {
        var options = new[] { settings.HomeEnabled ? "停用家宽（Claude 改走 AI 出口）" : "启用已保存的家宽", "编辑 SOCKS5 配置并启用", "返回" };
        var selected = Pick(options, title: "[bold]家宽 SOCKS5 · 可选[/]");
        if (selected < 0 || selected == 2) return;
        if (selected == 1) { Home(settings); return; }
        if (!settings.HomeEnabled && string.IsNullOrWhiteSpace(settings.HomeServer)) { Home(settings); return; }
        settings.UseHomeProxy = !settings.HomeEnabled;
        settings.Routing.Validate(settings.HomeEnabled);
        Save(settings);
    }

    private async Task Rules(ClashProxySettings settings)
    {
        var draft = settings.Copy();
        var dirty = false;
        while (true)
        {
            AnsiConsole.Clear();
            AnsiConsole.MarkupLine("[bold yellow]分流规则[/]  " + Markup.Escape(RoutingConfiguration.PresetTitle(draft.Routing.Preset(draft.ProxyOtherSites)))
                + (dirty ? "  [yellow]草稿未保存[/]" : ""));
            AnsiConsole.WriteLine("AI 工具   → " + RoutingTargets.Title(draft.Routing.Ai));
            AnsiConsole.WriteLine("GitHub    → " + RoutingTargets.Title(draft.Routing.Development));
            AnsiConsole.WriteLine("Claude    → " + RoutingTargets.Title(draft.Routing.AnthropicTarget(draft.HomeEnabled)));
            AnsiConsole.WriteLine("其他网站  → " + (draft.ProxyOtherSites ? "AI 出口" : "直连"));
            AnsiConsole.WriteLine("自定义规则 " + draft.Routing.CustomRules.Count(r => r.Enabled) + "/" + draft.Routing.CustomRules.Count + " 条启用，按列表顺序优先匹配。");
            var options = new[] { "选择预设方案", "用途与出口", "自定义规则", "预览 / 导出 Clash 规则", "保存规则", "保存并应用", dirty ? "返回（放弃未保存草稿）" : "返回" };
            var index = Pick(options, pageSize: options.Length);
            if (index < 0 || index == 6) return;
            try
            {
                switch (index)
                {
                    case 0:
                        var preset = Pick(["智能分流    AI 与开发网站走代理，其他直连", "仅 AI 代理  AI 走代理，开发网站与其他直连", "全站代理    按用途选择出口，其余也走代理"]);
                        if (preset >= 0) { RoutingConfiguration.ApplyPreset(draft, new[] { "smart", "aiOnly", "allProxy" }[preset]); dirty = true; }
                        break;
                    case 1: ConfigureTargets(draft); dirty = true; break;
                    case 2: CustomRules(draft); dirty = true; break;
                    case 3: PreviewRules(draft); break;
                    case 4:
                        draft.Routing.Validate(draft.HomeEnabled); local.Store.Save(draft); dirty = false;
                        Pause("规则已保存。运行中的服务需选择「保存并应用」使其生效。"); break;
                    case 5:
                        Pause(await RoutingWorkflow.ApplyAsync(local.Store, local.Service.Status().Running, draft)); dirty = false; break;
                }
            }
            catch (Back) { }
            catch (Exception ex) when (ex is InvalidOperationException or IOException or HttpRequestException or TaskCanceledException)
            { Pause(ex.Message); }
        }
    }

    private static string ChooseTarget(string current, bool homeEnabled, bool automaticHome = false)
    {
        var targets = RoutingTargets.All.Where(t => t != "residential" || homeEnabled || automaticHome).ToArray();
        var selected = Pick(targets.Select(t => Markup.Escape(RoutingTargets.Title(t))
            + (t == "residential" && automaticHome ? "（未启用时使用 AI 出口）" : "") + (t == current ? "  [green]当前[/]" : "")).ToArray(), title: "[grey62]选择出口[/]");
        if (selected < 0) throw new Back();
        return targets[selected];
    }

    private static void ConfigureTargets(ClashProxySettings draft)
    {
        var selected = Pick(["AI 工具", "GitHub / 开发网站", "Claude / 家宽中转", "其他网站", "返回"]);
        switch (selected)
        {
            case 0: draft.Routing.Ai = ChooseTarget(draft.Routing.Ai, draft.HomeEnabled); break;
            case 1: draft.Routing.Development = ChooseTarget(draft.Routing.Development, draft.HomeEnabled); break;
            case 2: draft.Routing.Anthropic = ChooseTarget(draft.Routing.Anthropic, draft.HomeEnabled, true); break;
            case 3:
                var index = Pick(["直连", "AI 出口"]);
                if (index >= 0) draft.ProxyOtherSites = index == 1;
                break;
        }
    }

    private static void CustomRules(ClashProxySettings draft)
    {
        while (true)
        {
            AnsiConsole.Clear();
            var rules = draft.Routing.CustomRules;
            var labels = new List<string> { "+ 添加规则", "导入 Clash 规则（粘贴 / 文件）" };
            labels.AddRange(rules.Select((r, i) => Markup.Escape($"{i + 1:00} {(r.Enabled ? "●" : "○")} {r.Kind} {ClipRule(r.Value)} → {RoutingTargets.Title(r.Target)}")));
            labels.Add("返回");
            var selected = Pick(labels, title: "[bold]自定义规则[/]  [grey62]从上到下，首条命中生效[/]");
            if (selected < 0 || selected == labels.Count - 1) return;
            try
            {
                if (selected == 0) { rules.Add(EditRule(new RoutingRule(), draft.HomeEnabled)); continue; }
                if (selected == 1) { rules.AddRange(ImportRules(draft)); continue; }
                var at = selected - 2;
                var rule = rules[at];
                var action = Pick(["编辑", rule.Enabled ? "停用" : "启用", "上移", "下移", "删除", "返回"], title: Markup.Escape(rule.Value));
                switch (action)
                {
                    case 0: rules[at] = EditRule(rule, draft.HomeEnabled); break;
                    case 1:
                        if (!rule.Enabled && rule.Target == "residential" && !draft.HomeEnabled) throw new InvalidOperationException("请先启用家宽出口。");
                        rule.Enabled = !rule.Enabled; break;
                    case 2: if (at > 0) (rules[at - 1], rules[at]) = (rules[at], rules[at - 1]); break;
                    case 3: if (at + 1 < rules.Count) (rules[at + 1], rules[at]) = (rules[at], rules[at + 1]); break;
                    case 4: rules.RemoveAt(at); break;
                }
            }
            catch (Back) { }
            catch (Exception ex) when (ex is InvalidOperationException or IOException) { Pause(ex.Message); }
        }
    }

    private static RoutingRule EditRule(RoutingRule original, bool homeEnabled)
    {
        var selected = Pick(RoutingRule.Kinds, title: "[grey62]匹配方式[/]");
        if (selected < 0) throw new Back();
        var rule = new RoutingRule { Id = original.Id, Enabled = original.Enabled, Kind = RoutingRule.Kinds[selected], Value = original.Value, Target = original.Target };
        rule.Value = Ask("匹配内容（域名、网段、进程、端口或 TCP / UDP）", rule.Value);
        rule.Target = ChooseTarget(rule.Target, homeEnabled);
        if (rule.IsIP) rule.NoResolve = Confirm("不触发域名解析 no-resolve？", original.NoResolve);
        return rule.Validated();
    }

    private static List<RoutingRule> ImportRules(ClashProxySettings draft)
    {
        var selected = Pick(["粘贴多行", "从文件导入", "返回"]);
        if (selected < 0 || selected == 2) throw new Back();
        AnsiConsole.WriteLine($"可用出口：{draft.ExitGroup} / {DialerProxyBuilder.HkGroup} / {draft.TargetName} / DIRECT / REJECT");
        string text;
        if (selected == 1)
        {
            var path = Ask("规则文件路径", "");
            if (new FileInfo(path).Length > 2_000_000) throw new InvalidOperationException("规则文件超过 2 MB。");
            text = File.ReadAllText(path);
        }
        else
        {
            AnsiConsole.WriteLine("粘贴规则，单独一行 . 结束；Esc 取消。示例：DOMAIN-SUFFIX,example.com,DIRECT");
            var builder = new StringBuilder();
            while (true)
            {
                var line = ReadLine();
                if (line == null) throw new Back();
                AnsiConsole.WriteLine();
                if (line.Trim() == ".") break;
                builder.AppendLine(line);
                if (builder.Length > 2_000_000) throw new InvalidOperationException("规则文本超过 2 MB。");
            }
            text = builder.ToString();
        }
        var imported = RoutingRule.ImportClash(text, ClashProxyStore.ToInput(draft));
        if (!draft.HomeEnabled && imported.Any(r => r.Target == "residential")) throw new InvalidOperationException("导入规则使用家宽双跳，请先启用家宽。");
        return imported;
    }

    private static void PreviewRules(ClashProxySettings draft)
    {
        var text = RoutingWorkflow.Preview(draft);
        var selected = Pick(["查看实际生成的规则", "导出到文件", "返回"]);
        if (selected == 0) { AnsiConsole.WriteLine(text); Pause(""); }
        else if (selected == 1)
        {
            var path = Ask("导出文件路径", "");
            if (File.Exists(path) && !Confirm("文件已存在，覆盖？", false)) return;
            File.WriteAllText(path, text);
            Pause("已导出 " + path);
        }
    }
    private static string ClipRule(string text) => text.Length > 28 ? text[..25] + "…" : text;
}
