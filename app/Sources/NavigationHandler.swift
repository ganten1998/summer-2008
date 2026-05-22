import AppKit
import WebKit

/// Intercepts navigation in the WKWebView:
///   * .swf clicks         -> redirect into the inline Ruffle player so the
///                            game plays in the WebView itself (works whether
///                            the click came from the dashboard tiles or from
///                            mid-mirror navigation)
///   * .dcr clicks         -> hand off to the bundled Shockwave projector
///                            (Ruffle can't render Director content)
///   * agd-launch://       -> explicit "open in external projector" scheme,
///                            used as a fallback link inside the inline player
///                            and by patched wrapper pages
///   * http / https        -> open in Safari (keep launcher self-contained)
///   * unknown schemes     -> cancel silently (prevents web-content-process crash)
final class NavigationHandler: NSObject, WKNavigationDelegate, WKUIDelegate {

    /// Wrap a SWF URL in the inline Ruffle player page so the game plays
    /// inside the WebView. Returns nil if the URL can't be wrapped.
    ///
    /// We serve the player from the SWF's OWN HOST via the scheme handler's
    /// `/__agd/` synthetic path. This puts the player and the SWF in the
    /// same origin so Ruffle's fetch() doesn't trip a cross-origin check
    /// and render the orange error square instead of the game.
    private func inlinePlayerURL(for swfURL: URL) -> URL? {
        let host = swfURL.host?.lowercased() ?? "www.americangirl.com"
        guard var comps = URLComponents(string: "agd://\(host)/__agd/player.html") else { return nil }
        var items = [URLQueryItem(name: "swf", value: swfURL.absoluteString)]
        let stem = swfURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if !stem.isEmpty {
            items.append(URLQueryItem(name: "title", value: stem.capitalized))
        }
        comps.queryItems = items
        return comps.url
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // Explicit "open in external projector" scheme — only reachable when
        // the user clicks the inline player's fallback link, so it really
        // should go to the projector.
        if scheme == "agd-launch" {
            GameLauncher.shared.launch(originalURL: url)
            decisionHandler(.cancel)
            return
        }

        // SWF clicks: route into the inline Ruffle player. Translate the
        // agd-launch:// scheme back to agd:// first if needed so the player's
        // <ruffle-player> can fetch the SWF through our scheme handler.
        let ext = url.pathExtension.lowercased()
        if ext == "swf" {
            var swfURL = url
            if scheme == "agd-launch" {
                if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.scheme = "agd"
                    swfURL = comps.url ?? url
                }
            }
            if let playerURL = inlinePlayerURL(for: swfURL) {
                decisionHandler(.cancel)
                DispatchQueue.main.async {
                    webView.load(URLRequest(url: playerURL))
                }
                return
            }
            // Couldn't build a player URL — fall back to external projector.
            GameLauncher.shared.launch(originalURL: url)
            decisionHandler(.cancel)
            return
        }

        // .dcr (Shockwave Director) — Ruffle can't render these, so still
        // hand off to the external projector path. GameLauncher itself shows
        // a friendly alert when no projector is bundled.
        if ext == "dcr" {
            GameLauncher.shared.launch(originalURL: url)
            decisionHandler(.cancel)
            return
        }

        // External http/https: only open in Safari for explicit user link clicks.
        // Script-initiated navigations (trackers, JS redirects, beacons) are
        // cancelled silently — they should never escape into the user's browser.
        if scheme == "http" || scheme == "https" {
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }

        // Hand off mailto/tel/sms/facetime to macOS so the OS opens Mail.app
        // (or whatever the default handler is). Without this, the WebView
        // tries to load mailto: as a regular URL, can't, and crashes the
        // content process — which the user sees as the app vanishing the
        // instant they click "Open in Mail to send" on the ecard wizard.
        if scheme == "mailto" || scheme == "tel" || scheme == "sms" || scheme == "facetime" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // Schemes WKWebView can handle natively.
        let safeSchemes: Set<String> = ["agd", "about", "data", "javascript", "blob"]
        if safeSchemes.contains(scheme) {
            // 2008-era AG pages plaster `target='_parent'`, `target='_blank'`,
            // and even URL-shaped `target='agd://...'` on every other anchor.
            // When the click lands in our single top frame, WKWebView sees
            // `targetFrame == nil` and tries to open a new browsing context
            // — which routes through createWebViewWith. Empirically WKWebView
            // sometimes treats our `webView.load(...)` in that callback as
            // popup-blocked and the navigation never happens at all.
            //
            // Safer: intercept here, redirect the request into the current
            // webView ourselves, and cancel the original. This is the same
            // pattern recommended in Apple's WKWebView samples.
            if navigationAction.targetFrame == nil,
               navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                DispatchQueue.main.async {
                    webView.load(URLRequest(url: url))
                }
                return
            }
            decisionHandler(.allow)
            return
        }

        // Anything else (file://, mailto:, weird Flash callbacks, etc.) —
        // cancel silently rather than letting WebKit crash the content process.
        NSLog("AGD: cancelling unhandled scheme '\(scheme)' – \(url.absoluteString)")
        decisionHandler(.cancel)
    }

    /// Handle popups (`target=_blank`, `window.open(...)`). The 2008 AG site
    /// used pop-ups heavily for chrome we don't want — e.g. fun.html runs an
    /// autopoll script that pops the "Poll of the Day" window the moment
    /// the page loads, which would clobber the user's current view.
    ///
    /// Rule: only follow popups initiated by a real user click. Script-
    /// initiated `window.open` (the autopoll, ad-style popups) is silently
    /// suppressed, matching how every modern browser blocks popups by
    /// default.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // We used to suppress popups that supplied explicit width/height,
        // because /fun.html's autopoll.js opened the Weekly Poll that way
        // and the poll's Flash banner failed in Ruffle. That was collateral
        // damage — useful user-clicked popups (wallpaper installer
        // instructions on /coconut/wallpapers.html, the "share this card"
        // dialogs, etc.) also have explicit dimensions and were getting
        // killed.
        //
        // The autopoll is now disarmed at source level by the patcher
        // (sets pollCanGo=false in autopoll.js), so popups with dimensions
        // are no longer an autopoll-risk signal. Let user-clicked popups
        // through; load them in the current webView since this is a
        // single-window app.
        guard let url = navigationAction.request.url else {
            return nil
        }
        if navigationAction.navigationType != .linkActivated {
            return nil    // script-initiated, no user gesture → block
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        } else {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    /// If the web content process crashes, reload the last URL rather than
    /// leaving the user with a blank white window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("AGD: web content process terminated — reloading")
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("AGD nav failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("AGD provisional nav failed: \(error.localizedDescription)")
    }
}
