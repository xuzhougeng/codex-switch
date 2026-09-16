using Microsoft.UI.Xaml;

namespace CodexSwitch.Windows;
public partial class App : Application
{
    private Window? window;
    public App() => InitializeComponent();
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            window = new MainWindow();
            window.Activate();
        }
        catch (Exception e)
        {
            var diagnostics = Environment.GetEnvironmentVariable("CODEX_SWITCH_DIAGNOSTICS_PATH");
            if (!string.IsNullOrWhiteSpace(diagnostics)) File.WriteAllText(diagnostics, e.ToString());
            throw;
        }
    }
}
