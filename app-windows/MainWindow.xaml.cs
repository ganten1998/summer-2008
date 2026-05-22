using System;
using System.IO;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace Summer2008;

public partial class MainWindow : Window
{
    private MirrorHandler? _mirror;
    private NavHandler?    _nav;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var resources = Path.Combine(App.AppBaseDir, "Resources");
        var prefs     = new PrefsStore(Path.Combine(App.UserDataPath, "prefs.json"));
        var games     = new GameLauncher(Path.Combine(App.AppBaseDir, "projector"));

        // Initialise WebView2 with a user-data folder under %LOCALAPPDATA% so
        // localStorage (welcome-modal flag, volume cache) and cookies persist
        // across launches — equivalent to WKWebView's default behaviour on macOS.
        var env = await CoreWebView2Environment.CreateAsync(
            browserExecutableFolder: null,
            userDataFolder:          App.UserDataPath);

        await Browser.EnsureCoreWebView2Async(env);

        _mirror = new MirrorHandler(resources, prefs);
        _nav    = new NavHandler(Browser.CoreWebView2, games);

        Browser.CoreWebView2.AddWebResourceRequestedFilter(
            "agd://*", CoreWebView2WebResourceContext.All);
        Browser.CoreWebView2.WebResourceRequested += _mirror.OnWebResourceRequested;
        Browser.CoreWebView2.NavigationStarting   += _nav.OnNavigationStarting;
        Browser.CoreWebView2.NewWindowRequested   += _nav.OnNewWindowRequested;

        // Quality-of-life tweaks that match the macOS shell.
        var settings = Browser.CoreWebView2.Settings;
        settings.AreDevToolsEnabled                = true;   // F12 opens devtools
        settings.AreDefaultContextMenusEnabled     = true;
        settings.IsBuiltInErrorPageEnabled         = false;  // we serve our own 404
        settings.IsStatusBarEnabled                = false;  // no Chrome-style status bar
        settings.AreBrowserAcceleratorKeysEnabled  = true;   // Cmd+R, etc.
        settings.IsZoomControlEnabled              = true;
        settings.IsSwipeNavigationEnabled          = false;  // gestures stay inside content

        Browser.CoreWebView2.Navigate("agd://dashboard/index.html");
    }
}
