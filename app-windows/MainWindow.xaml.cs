using System;
using System.Collections.Generic;
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
        // notify: surface launch failures as a transient JS toast inside the
        // WebView instead of silently doing nothing — used when the bundled
        // projector exe is missing (dev runs that skipped fetch-projector-windows)
        // or the clicked SWF/DCR isn't in the mirror.
        var games     = new GameLauncher(
            Path.Combine(App.AppBaseDir, "projector"),
            notify: msg => Dispatcher.BeginInvoke(new Action(() =>
            {
                if (Browser?.CoreWebView2 is null) return;
                var safe = System.Text.Json.JsonSerializer.Serialize(msg);
                _ = Browser.CoreWebView2.ExecuteScriptAsync(
                    $"window.__agd_showToast && window.__agd_showToast({safe})");
            })));

        // Initialise WebView2 with a user-data folder under %LOCALAPPDATA% so
        // localStorage (welcome-modal flag, volume cache) and cookies persist
        // across launches — equivalent to WKWebView's default behaviour on macOS.
        //
        // agd:// + agd-launch:// must be declared as custom schemes at
        // environment-creation time, otherwise Chromium rejects them as
        // unknown protocols before WebResourceRequested can fire and the
        // WebView shows blank. The macOS WKWebView path doesn't need this
        // because WKURLSchemeHandler registration on the configuration is
        // enough there.
        // CoreWebView2EnvironmentOptions() has no real no-arg ctor — the
        // only public ctor takes customSchemeRegistrations explicitly. Calling
        // the parameterless form leaves the backing field null, so a later
        // options.CustomSchemeRegistrations.Add(...) NREs. Pass the list in.
        var agd = new CoreWebView2CustomSchemeRegistration("agd")
        {
            TreatAsSecure         = true,
            HasAuthorityComponent = true,
        };
        agd.AllowedOrigins.Add("agd://*");

        var options = new CoreWebView2EnvironmentOptions(
            additionalBrowserArguments:               null,
            language:                                 null,
            targetCompatibleBrowserVersion:           null,
            allowSingleSignOnUsingOSPrimaryAccount:   false,
            customSchemeRegistrations:                new List<CoreWebView2CustomSchemeRegistration>
            {
                agd,
                new CoreWebView2CustomSchemeRegistration("agd-launch")
                {
                    HasAuthorityComponent = true,
                },
            });

        var env = await CoreWebView2Environment.CreateAsync(
            browserExecutableFolder: null,
            userDataFolder:          App.UserDataPath,
            options:                 options);

        await Browser.EnsureCoreWebView2Async(env);

        _mirror = new MirrorHandler(resources, App.UserDataPath, prefs);
        _nav    = new NavHandler(Browser.CoreWebView2, games);

        Browser.CoreWebView2.AddWebResourceRequestedFilter(
            "agd://*", CoreWebView2WebResourceContext.All);
        Browser.CoreWebView2.WebResourceRequested += _mirror.OnWebResourceRequested;
        Browser.CoreWebView2.NavigationStarting   += _nav.OnNavigationStarting;
        Browser.CoreWebView2.NewWindowRequested   += _nav.OnNewWindowRequested;

        // Inject the Dashboard nav bar on every mirrored site page — same UX
        // as the macOS shell's WKUserScript at AppDelegate.swift:47. Without
        // it the user can land on a 2008 page (e.g. agcn/addy/menu.php) with
        // no way back to the dashboard short of editing the URL bar. Skipped
        // on dashboard/runtime hosts so the dashboard's own topnav stays clean.
        // Back/forward post via chrome.webview.postMessage; WebMessageReceived
        // routes them to CoreWebView2.GoBack/GoForward (WebView2 equivalents
        // of WKWebView.goBack/goForward).
        var mirrorRoot = Path.Combine(App.AppBaseDir, "Resources", "mirror");
        Browser.CoreWebView2.WebMessageReceived += (_, args) =>
        {
            var msg = args.TryGetWebMessageAsString();
            if (msg == "back"    && Browser.CoreWebView2.CanGoBack)    Browser.CoreWebView2.GoBack();
            else if (msg == "forward" && Browser.CoreWebView2.CanGoForward) Browser.CoreWebView2.GoForward();
            // flash-bridge.js auto-launch uses chrome.webview.postMessage instead
            // of navigating to agd-launch://, because scripted navigation to a
            // custom scheme requires user activation in WebView2 — a setTimeout
            // from page load has none, so the nav is silently dropped.
            else if (msg != null && msg.StartsWith("launchDCR:", StringComparison.Ordinal))
            {
                try { games.Launch(new Uri(msg.Substring("launchDCR:".Length)), mirrorRoot); }
                catch { /* malformed URL — JS will hide loading via the 8s safety */ }
            }
        };
        await Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(NavBarJs);
        // Toast helper used by GameLauncher's notify callback. Registered once
        // per document so __agd_showToast is available on every page — including
        // the dashboard, where a failure-to-launch could plausibly happen if
        // the user clicks a game tile that resolves to a missing asset.
        await Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(ToastJs);

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

    // Mirror-page Dashboard nav bar. Ported verbatim from the macOS shell's
    // WKUserScript (AppDelegate.swift:47) with two adaptations:
    //   • webkit.messageHandlers.agdNav.postMessage  →  chrome.webview.postMessage
    //   • injected on DOMContentLoaded rather than at .atDocumentEnd, because
    //     AddScriptToExecuteOnDocumentCreatedAsync fires before <body> exists.
    private const string NavBarJs = """
    (function () {
      function inject() {
        var h = location.hostname;
        if (h === 'dashboard' || h === 'runtime') return;
        if (!document.body) return;
        if (document.getElementById('agd-navbar')) return;

        var bar = document.createElement('div');
        bar.id = 'agd-navbar';
        bar.style.cssText = [
          'position:fixed','top:0','left:0','right:0','height:40px',
          'background:#A6192E','z-index:2147483647',
          'display:flex','align-items:center','justify-content:flex-end',
          'padding:0 14px','gap:4px',
          'box-shadow:0 2px 8px rgba(0,0,0,.25)'
        ].join(';');

        var btnStyle = [
          'color:#FBF6EB','background:rgba(255,246,235,0.15)',
          'border:none','border-radius:6px',
          "font:600 15px/1 -apple-system,'Segoe UI',sans-serif",
          'padding:5px 10px','cursor:pointer',
          'opacity:.85','transition:opacity .15s',
          'text-decoration:none','display:inline-flex','align-items:center'
        ].join(';');

        var backBtn = document.createElement('button');
        backBtn.textContent = '←';
        backBtn.title = 'Back';
        backBtn.style.cssText = btnStyle;
        backBtn.onmouseenter = function () { backBtn.style.opacity = '1';    };
        backBtn.onmouseleave = function () { backBtn.style.opacity = '0.85'; };
        backBtn.onclick      = function () { window.chrome.webview.postMessage('back'); };

        var fwdBtn = document.createElement('button');
        fwdBtn.textContent = '→';
        fwdBtn.title = 'Forward';
        fwdBtn.style.cssText = btnStyle;
        fwdBtn.style.marginLeft = '4px';
        fwdBtn.onmouseenter = function () { fwdBtn.style.opacity = '1';    };
        fwdBtn.onmouseleave = function () { fwdBtn.style.opacity = '0.85'; };
        fwdBtn.onclick      = function () { window.chrome.webview.postMessage('forward'); };

        var dashLink = document.createElement('a');
        dashLink.href = 'agd://dashboard/index.html';
        dashLink.textContent = '⌂  Dashboard';
        dashLink.style.cssText = [
          'color:#FBF6EB','text-decoration:none',
          "font:600 11px/1 -apple-system,'Segoe UI',sans-serif",
          'letter-spacing:.18em','text-transform:uppercase',
          'opacity:.9','transition:opacity .15s',
          'margin-left:6px'
        ].join(';');
        dashLink.onmouseenter = function () { dashLink.style.opacity = '1';   };
        dashLink.onmouseleave = function () { dashLink.style.opacity = '0.9'; };

        bar.appendChild(backBtn);
        bar.appendChild(fwdBtn);
        bar.appendChild(dashLink);
        document.body.insertBefore(bar, document.body.firstChild);

        var current = parseInt(getComputedStyle(document.body).paddingTop) || 0;
        document.body.style.paddingTop = (current + 40) + 'px';
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', inject);
      } else {
        inject();
      }
    })();
    """;

    // Transient toast surface for host-originated messages (currently:
    // GameLauncher reporting missing projector exe or missing mirror asset).
    // Bottom-center pill, autodismisses after ~4.5s. Re-entrant — stacks
    // multiple toasts vertically if more than one fires close together.
    private const string ToastJs = """
    (function () {
      if (window.__agd_showToast) return;
      window.__agd_showToast = function (msg) {
        var run = function () {
          var stackId = '__agd_toast_stack';
          var stack = document.getElementById(stackId);
          if (!stack) {
            stack = document.createElement('div');
            stack.id = stackId;
            stack.style.cssText = [
              'position:fixed','left:50%','bottom:24px','transform:translateX(-50%)',
              'z-index:2147483647','display:flex','flex-direction:column','gap:8px',
              'align-items:center','pointer-events:none'
            ].join(';');
            (document.body || document.documentElement).appendChild(stack);
          }
          var t = document.createElement('div');
          t.textContent = String(msg);
          t.style.cssText = [
            'padding:11px 20px','background:#3B0F0F','color:#FBF6EB',
            "font:13.5px/1.4 -apple-system,'Segoe UI',sans-serif",
            'border-radius:8px','box-shadow:0 6px 22px rgba(0,0,0,.32)',
            'max-width:80vw','text-align:center','pointer-events:auto',
            'opacity:0','transform:translateY(8px)',
            'transition:opacity .2s, transform .2s'
          ].join(';');
          stack.appendChild(t);
          requestAnimationFrame(function () {
            t.style.opacity = '1';
            t.style.transform = 'translateY(0)';
          });
          setTimeout(function () {
            t.style.opacity = '0';
            t.style.transform = 'translateY(8px)';
            setTimeout(function () {
              if (t.parentNode) t.parentNode.removeChild(t);
            }, 250);
          }, 4500);
        };
        if (document.body) run();
        else document.addEventListener('DOMContentLoaded', run, { once: true });
      };
    })();
    """;
}
