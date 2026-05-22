using System;
using System.Diagnostics;
using System.IO;
using Microsoft.Web.WebView2.Core;

namespace Summer2008;

/// <summary>
/// Navigation policy + popup gating. Windows equivalent of the macOS
/// NavigationHandler.swift.
///
/// Routes mirrored:
///   • agd-launch://&lt;swf-or-dcr&gt;     →  bundled projector via Process.Start
///   • &lt;path&gt;.swf navigation         →  bundled Flash Player
///   • &lt;path&gt;.dcr navigation         →  bundled Director projector
///   • http / https link clicks       →  user's default browser (Shell)
///   • mailto / tel / sms / facetime  →  default OS handler (Shell)
///   • scripted popups (window.open with explicit width/height)  →  suppress
/// </summary>
public sealed class NavHandler
{
    private readonly CoreWebView2 _webview;
    private readonly GameLauncher _games;
    private readonly string _mirrorRoot;

    public NavHandler(CoreWebView2 webview, GameLauncher games)
    {
        _webview = webview;
        _games   = games;
        _mirrorRoot = Path.Combine(App.AppBaseDir, "Resources", "mirror");
    }

    public void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs args)
    {
        Uri uri;
        try { uri = new Uri(args.Uri); }
        catch { args.Cancel = true; return; }

        var scheme = (uri.Scheme ?? "").ToLowerInvariant();
        var ext    = Path.GetExtension(uri.AbsolutePath).ToLowerInvariant();

        // 1. Explicit "open in projector" handoff. flash-bridge.js's FAB
        //    button constructs agd-launch://...swf URLs for this.
        if (scheme == "agd-launch")
        {
            args.Cancel = true;
            _games.Launch(new Uri("agd://" + uri.Authority + uri.PathAndQuery), _mirrorRoot);
            return;
        }

        // 2. Direct navigation to a .swf or .dcr inside the mirror. Route
        //    to the inline player (player.html for .swf) or the bundled
        //    projector (.dcr).
        if (scheme == "agd" && ext == ".swf")
        {
            // Route SWF clicks to the inline Ruffle player.html the way
            // the macOS shell does. This way "click a SWF link" plays it
            // inline rather than offering it as a download.
            args.Cancel = true;
            var encoded = Uri.EscapeDataString(uri.ToString());
            _webview.Navigate(
                $"agd://www.americangirl.com/__agd/player.html?swf={encoded}");
            return;
        }
        if (scheme == "agd" && ext == ".dcr")
        {
            args.Cancel = true;
            _games.Launch(uri, _mirrorRoot);
            return;
        }

        // 3. http/https — open in user's default browser, only for explicit
        //    link clicks (NewWindowRequested intercepts the popup-shaped
        //    invocations separately).
        if (scheme == "http" || scheme == "https")
        {
            args.Cancel = true;
            ShellOpen(uri.ToString());
            return;
        }

        // 4. mailto / tel / sms / facetime — hand to the OS so the user's
        //    Mail / Phone / etc. client takes over. Without this, WebView2
        //    would either no-op or error.
        if (scheme is "mailto" or "tel" or "sms" or "facetime")
        {
            args.Cancel = true;
            ShellOpen(uri.ToString());
            return;
        }

        // 5. agd / about / data / javascript / blob — let through.
        // Anything else — quietly cancel rather than letting the WebView
        // throw an uncaught navigation error.
        if (scheme is not ("agd" or "about" or "data" or "javascript" or "blob"))
        {
            args.Cancel = true;
        }
    }

    public void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        // The /fun.html autopoll is killed at source level by the patcher
        // (pollCanGo=false in autopoll.js), so we no longer use WindowFeatures
        // dimensions as a popup-suppress signal — which lets user-clicked
        // popups (wallpaper installer instructions, share dialogs, etc.) load
        // inline instead of getting blocked.
        try
        {
            var uri = new Uri(args.Uri);
            if (uri.Scheme is "http" or "https")
            {
                // External link → user's default browser
                ShellOpen(uri.ToString());
                args.Handled = true;
            }
            else
            {
                _webview.Navigate(args.Uri);
                args.Handled = true;
            }
        }
        catch
        {
            args.Handled = true;
        }
    }

    private static void ShellOpen(string target)
    {
        try
        {
            // UseShellExecute=true lets Windows resolve the default handler
            // for the URI scheme — browser for https, Mail for mailto, etc.
            Process.Start(new ProcessStartInfo
            {
                FileName        = target,
                UseShellExecute = true,
            });
        }
        catch { /* the user can copy the URL out of devtools if the OS shrugs */ }
    }
}
