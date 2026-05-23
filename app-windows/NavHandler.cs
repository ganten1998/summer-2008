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
///   • http / https to allowlist      →  user's default browser (Shell)
///   • http / https everything else   →  cancel + toast (keep archive sealed)
///   • mailto / tel / sms / facetime  →  default OS handler (Shell)
///   • scripted popups (window.open with explicit width/height)  →  suppress
/// </summary>
public sealed class NavHandler
{
    private readonly CoreWebView2 _webview;
    private readonly GameLauncher _games;
    private readonly string _mirrorRoot;

    // Strict allowlist of hosts that are permitted to escape into the
    // user's default browser. Everything else — hardcoded 2008 links to
    // mattel.com, kitkittredge.com, etc. — gets canceled with a toast so
    // the archive stays sealed.
    private static readonly HashSet<string> AllowedExternalHosts =
        new(StringComparer.OrdinalIgnoreCase) { "ko-fi.com", "www.ko-fi.com" };

    public NavHandler(CoreWebView2 webview, GameLauncher games)
    {
        _webview = webview;
        _games   = games;
        _mirrorRoot = Path.Combine(App.AppBaseDir, "Resources", "mirror");
    }

    private void ShowExternalToast()
    {
        const string msg = "External link — not part of the 2008 archive";
        var safe = System.Text.Json.JsonSerializer.Serialize(msg);
        _ = _webview.ExecuteScriptAsync(
            $"window.__agd_showToast && window.__agd_showToast({safe})");
    }

    public void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs args)
    {
        Uri uri;
        try { uri = new Uri(args.Uri); }
        catch { args.Cancel = true; return; }

        var scheme = (uri.Scheme ?? "").ToLowerInvariant();
        var ext    = Path.GetExtension(uri.AbsolutePath).ToLowerInvariant();

        // Kill any running projector before the new page commits — the
        // Director window from the previous page would otherwise float on
        // top of the new one. No-op when nothing is running (initial
        // dashboard load, in-mirror nav to non-DCR pages, etc.). The
        // agd-launch:// relaunch path lands here too but TryFocusExisting
        // is irrelevant after the kill — we just spawn fresh, which is the
        // desired "Click to play again" behavior anyway.
        _games.TerminateAllProjectors();

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

        // 3. http/https — only allowlisted hosts (Ko-fi tip link) escape
        //    to the user's default browser. Everything else (the 2008 page's
        //    hardcoded links to kitkittredge.com, mattel.com careers, etc.)
        //    gets canceled with a toast so the user knows why nothing opened.
        if (scheme == "http" || scheme == "https")
        {
            args.Cancel = true;
            if (AllowedExternalHosts.Contains(uri.Host))
            {
                ShellOpen(uri.ToString());
            }
            else
            {
                ShowExternalToast();
            }
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
                // Same allowlist as OnNavigationStarting — target="_blank"
                // / window.open() popups for non-Ko-fi hosts get the same
                // canceled-with-toast treatment as inline clicks.
                if (AllowedExternalHosts.Contains(uri.Host))
                {
                    ShellOpen(uri.ToString());
                }
                else
                {
                    ShowExternalToast();
                }
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
