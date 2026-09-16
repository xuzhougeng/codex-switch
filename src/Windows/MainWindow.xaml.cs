using CodexSwitch.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Windowing;

namespace CodexSwitch.Windows;
public sealed partial class MainWindow : Window
{
    private readonly AccountStore store = new();
    private IReadOnlyList<Account> accounts = [];
    private CancellationTokenSource? login;
    private bool busy;
    private bool closed;
    public MainWindow()
    {
        InitializeComponent();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "app-icon.ico"));
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1040, 820));
        AppWindow.Changed += (_, e) =>
        {
            var scale = Root.XamlRoot?.RasterizationScale ?? 1;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            var minimumWidth = Math.Min((int)(720 * scale), area.Width);
            var minimumHeight = Math.Min((int)(560 * scale), area.Height);
            if (e.DidSizeChange && AppWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Restored && (AppWindow.Size.Width < minimumWidth || AppWindow.Size.Height < minimumHeight))
                AppWindow.Resize(new global::Windows.Graphics.SizeInt32(Math.Max(minimumWidth, AppWindow.Size.Width), Math.Max(minimumHeight, AppWindow.Size.Height)));
        };
        Closed += (_, _) => { closed = true; login?.Cancel(); };
        Root.Loaded += async (_, _) =>
        {
            var scale = Root.XamlRoot.RasterizationScale;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            AppWindow.Resize(new global::Windows.Graphics.SizeInt32(Math.Min((int)(1040 * scale), area.Width), Math.Min((int)(820 * scale), area.Height)));
            await Run(Refresh, "账号已刷新");
            OverviewButton.Focus(FocusState.Programmatic);
        };
    }
    private async Task Refresh()
    {
        var state = await Task.Run(store.Read);
        if (closed) return;
        accounts = state.Accounts;
        CurrentEmail.Text = state.Current?.Email ?? "尚未登录";
        CurrentPlan.Text = state.Current?.Plan.ToUpperInvariant() ?? "添加账号以开始";
        SaveButton.IsEnabled = ClearButton.IsEnabled = state.Current != null;
        CountLabel.Text = accounts.Count.ToString();
        Filter();
    }
    private void Filter()
    {
        if (Search == null) return;
        var query = Search.Text.Trim();
        var filtered = accounts.Where(a => (a.Email + " " + a.Plan).Contains(query, StringComparison.OrdinalIgnoreCase)).Select(a => new AccountRow(a)).ToArray();
        AccountsList.ItemsSource = filtered;
        EmptyPanel.Visibility = filtered.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyLabel.Text = accounts.Count == 0 ? "还没有保存的账号。登录新账号，或保存当前登录即可开始。" : "没有匹配的账号，试试其他关键词。";
    }
    private async Task Run(Func<Task> action, string success)
    {
        if (busy) return;
        busy = true;
        Actions.IsHitTestVisible = false;
        ActionHost.IsEnabled = RefreshButton.IsEnabled = LoginButton.IsEnabled = HelpButton.IsEnabled = false;
        BusyRing.Visibility = Visibility.Visible;
        BusyRing.IsActive = true;
        Status.Text = "正在处理…";
        try { await action(); if (!closed) Status.Text = success; }
        catch (OperationCanceledException) { if (!closed) Status.Text = "登录已取消或超时，原账号已保留。"; }
        catch (Exception e) { if (!closed) Status.Text = "操作未完成：" + e.Message; }
        finally
        {
            busy = false;
            if (!closed)
            {
                Actions.IsHitTestVisible = true;
                ActionHost.IsEnabled = RefreshButton.IsEnabled = LoginButton.IsEnabled = HelpButton.IsEnabled = true;
                BusyRing.IsActive = false;
                BusyRing.Visibility = CancelButton.Visibility = Visibility.Collapsed;
            }
        }
    }
    private async Task Mutate(Action action) { await Task.Run(action); await Refresh(); }
    private async Task<bool> Confirm(string title, string content)
    {
        if (busy) return false;
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = content,
            PrimaryButtonText = "确认", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await Run(Refresh, "账号已刷新");
    private void Search_Changed(object sender, TextChangedEventArgs e) => Filter();
    private async void Save_Click(object sender, RoutedEventArgs e) => await Run(() => Mutate(store.SaveCurrent), "当前登录已保存");
    private async void Switch_Click(object sender, RoutedEventArgs e)
    {
        var key = (string)((FrameworkElement)sender).Tag;
        await Run(() => Mutate(() => store.Switch(key)), "账号文件已切换。请完全退出并重新打开 Codex。");
    }
    private async void Remove_Click(object sender, RoutedEventArgs e)
    {
        var key = (string)((FrameworkElement)sender).Tag;
        if (await Confirm("移除保存的账号？", $"{key}\n当前登录不受影响，快照会归档到本地备份。"))
            await Run(() => Mutate(() => store.Remove(key)), "已移除保存的账号，快照已备份");
    }
    private async void Clear_Click(object sender, RoutedEventArgs e)
    {
        if (await Confirm("清空当前登录？", "当前登录会先保存并备份。清空后，请完全退出并重新打开 Codex。"))
            await Run(() => Mutate(store.Clear), "当前登录已备份并清空。请重新打开 Codex。");
    }
    private async void Login_Click(object sender, RoutedEventArgs e)
    {
        if (busy) return;
        using var cancellation = new CancellationTokenSource();
        login = cancellation;
        await Run(async () =>
        {
            CancelButton.Visibility = Visibility.Visible;
            Status.Text = "请在浏览器中完成登录。原账号将在登录成功前保留。";
            await BrowserLogin.RunAsync(store, cancellation.Token);
            await Refresh();
        }, "登录成功，账号已自动保存。请重新打开 Codex。");
        login = null;
    }
    private void Cancel_Click(object sender, RoutedEventArgs e) => login?.Cancel();
    private void Overview_Click(object sender, RoutedEventArgs e) => ActionHost.ChangeView(null, 0, null);
    private async void Help_Click(object sender, RoutedEventArgs e)
    {
        if (busy) return;
        await new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "使用说明", CloseButtonText = "知道了",
            Content = new TextBlock { Text = "登录新账号会打开浏览器，成功后自动保存；取消时保留原登录。\n\n切换后，请完全退出并重新打开 Codex。\n\n登录和备份仅保存在本机，包含敏感凭据，请勿分享。\n\n额度暂未核验：本地会话记录无法可靠归属到当前账号。", TextWrapping = TextWrapping.Wrap }
        }.ShowAsync();
    }
}

public sealed class AccountRow(Account account)
{
    public string Key => account.Key;
    public string SwitchLabel => "切换到 " + account.Email;
    public string Email => account.Email;
    public string Plan => account.Plan.ToUpperInvariant();
    public string Initial => account.Initial;
    public Visibility CurrentVisibility => account.IsCurrent ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SwitchVisibility => account.IsCurrent ? Visibility.Collapsed : Visibility.Visible;
    public SolidColorBrush AvatarBrush
    {
        get
        {
            string[] colors = ["#DDEADD", "#ECE3D7", "#E0E4F1", "#DAE9EB"];
            var slot = account.Email.Aggregate(0, (hash, c) => (hash * 31 + c) & 0xFFFF) % colors.Length;
            var hex = colors[slot];
            return new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, Convert.ToByte(hex[1..3], 16), Convert.ToByte(hex[3..5], 16), Convert.ToByte(hex[5..7], 16)));
        }
    }
}
