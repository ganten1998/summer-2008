using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace Summer2008;

public partial class App : Application
{
    /// <summary>
    /// Where the user's runtime data lives:
    ///   %LOCALAPPDATA%\Summer 2008
    /// This holds the prefs file (volume slider state) and the WebView2
    /// user-data folder (cookies, localStorage including the welcome-modal
    /// suppress flag).
    /// </summary>
    public static string UserDataPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Summer 2008");

    /// <summary>
    /// Where bundled resources live next to the EXE — Resources\dashboard\,
    /// Resources\mirror-runtime\, Resources\mirror\, and projector\.
    /// </summary>
    public static string AppBaseDir { get; } = AppContext.BaseDirectory;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Directory.CreateDirectory(UserDataPath);

        // Reap any projector exes that survived a previous force-close /
        // crash. Without this, last session's Director window persists as
        // a floating top-level window when the user reopens the launcher.
        // Same approach as the macOS shell's startup pkill on wine-preloader.
        GameLauncher.ReapOrphanProjectors();

        // Surface unhandled exceptions instead of silently crashing the
        // content process. Mirrors the macOS NSLog error trail.
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(
                $"{args.Exception.Message}\n\n{args.Exception.StackTrace}",
                "Summer 2008 — unexpected error",
                MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };
    }
}
