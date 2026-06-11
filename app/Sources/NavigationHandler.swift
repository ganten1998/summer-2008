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
///   * http / https → allowlist (Ko-fi) → Safari; everything else → toast
///   * unknown schemes     -> cancel silently (prevents web-content-process crash)
final class NavigationHandler: NSObject, WKNavigationDelegate, WKUIDelegate {

    /// Strict allowlist of hosts permitted to open in the user's default
    /// browser. Everything else (kitkittredge.com, mattel.com careers, etc.)
    /// is canceled with an in-page toast so the user knows why nothing opened.
    private static let allowedExternalHosts: Set<String> = ["ko-fi.com", "www.ko-fi.com"]

    private func showExternalToast(in webView: WKWebView) {
        let msg = "External link — not part of the 2008 archive"
        let escaped = msg.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        // Self-contained — builds the toast div directly instead of
        // relying on a pre-injected window.__agd_showToast. Eliminates
        // any uncertainty about user-script timing or content-world
        // mismatch.
        let js = """
        (function() {
          var run = function() {
            var stackId = '__agd_toast_stack';
            var stack = document.getElementById(stackId);
            if (!stack) {
              stack = document.createElement('div');
              stack.id = stackId;
              stack.style.cssText = 'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:2147483647;display:flex;flex-direction:column;gap:8px;align-items:center;pointer-events:none';
              (document.body || document.documentElement).appendChild(stack);
            }
            var t = document.createElement('div');
            t.textContent = "\(escaped)";
            t.style.cssText = 'padding:11px 20px;background:#3B0F0F;color:#FBF6EB;font:13.5px/1.4 -apple-system,sans-serif;border-radius:8px;box-shadow:0 6px 22px rgba(0,0,0,.32);max-width:80vw;text-align:center;pointer-events:auto;opacity:0;transform:translateY(8px);transition:opacity .2s, transform .2s';
            stack.appendChild(t);
            requestAnimationFrame(function() {
              t.style.opacity = '1';
              t.style.transform = 'translateY(0)';
            });
            setTimeout(function() {
              t.style.opacity = '0';
              t.style.transform = 'translateY(8px)';
              setTimeout(function() { if (t.parentNode) t.parentNode.removeChild(t); }, 220);
            }, 3000);
          };
          if (document.body) run();
          else document.addEventListener('DOMContentLoaded', run);
        })();
        """
        webView.evaluateJavaScript(js, in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("AGD toast JS error: \(error.localizedDescription)")
            }
        }
    }

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

    /// Resolve a navigation that leaked into /__agd/ back onto the SWF's
    /// real directory. Returns nil when the request is a legitimate
    /// runtime asset (player.html itself, ruffle/*, ecard pages — anything
    /// that exists under mirror-runtime/), or when the current page isn't
    /// the inline player, so normal handling proceeds.
    static func reanchorPlayerEscape(url: URL, currentPage: URL?) -> URL? {
        let sub = String(url.path.dropFirst("/__agd/".count))
        guard !sub.isEmpty else { return nil }
        if let res = Bundle.main.resourceURL {
            let runtimeFile = res.appendingPathComponent("mirror-runtime", isDirectory: true)
                .appendingPathComponent(sub)
            if FileManager.default.fileExists(atPath: runtimeFile.path) { return nil }
        }
        guard let current = currentPage,
              current.path.hasPrefix("/__agd/player.html"),
              let comps = URLComponents(url: current, resolvingAgainstBaseURL: false),
              let swfStr = comps.queryItems?.first(where: { $0.name == "swf" })?.value,
              let swfURL = URL(string: swfStr)
        else { return nil }
        var target = swfURL.deletingLastPathComponent()
        for piece in sub.split(separator: "/") {
            target.appendPathComponent(String(piece))
        }
        if var rebuilt = URLComponents(url: target, resolvingAgainstBaseURL: false) {
            rebuilt.query = url.query
            return rebuilt.url
        }
        return target
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // getURL escapes from gallery-launched games. Ruffle resolves a
        // relative getURL NAVIGATION target against the host page's URL
        // (/__agd/player.html), not against the SWF-dir `base` it uses for
        // asset fetches — so Kit's Railway map clicking "cincinnatiut.html"
        // navigates to /__agd/cincinnatiut.html, which can never exist and
        // 404s as "not preserved". Re-anchor: take the leaked leaf path,
        // resolve it against the SWF's directory (carried in the player
        // page's ?swf= query), and navigate there instead. The scheme
        // handler's /sw/-parent fallback covers SWFs whose targets are
        // siblings of their wrapper page rather than of the SWF itself.
        if scheme == "agd", url.path.hasPrefix("/__agd/"),
           let reanchored = Self.reanchorPlayerEscape(url: url, currentPage: webView.url) {
            decisionHandler(.cancel)
            DispatchQueue.main.async {
                webView.load(URLRequest(url: reanchored))
            }
            return
        }

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
            // Known-broken-in-Ruffle SWFs: button event propagation through
            // nested loadMovie'd children is incomplete in Ruffle 0.3-nightly,
            // and these specific games' click handlers never fire on the
            // doll/character picker. The inline player is a dead end for
            // them — Ruffle loads the SWF but clicks silently no-op. Route
            // straight to the bundled Adobe Flash Player projector (64-bit
            // x86_64, verified loads on modern macOS) which handles the
            // game's actual Flash semantics correctly.
            let pathLower = swfURL.path.lowercased()
            // (Empty — paper_dolls.swf was the only blacklist entry and
            // the projector also can't render it. The gallery routes
            // its tile to the Shockwave version instead.)
            let routeStraightToProjector: [String] = []
            if routeStraightToProjector.contains(where: { pathLower.hasSuffix($0) }) {
                GameLauncher.shared.launch(originalURL: swfURL)
                decisionHandler(.cancel)
                return
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

        // External http/https: only allowlisted hosts (Ko-fi) escape into
        // Safari. The 2008 page's hardcoded links to kitkittredge.com,
        // mattel.com careers, etc. get canceled with an in-page toast so
        // the user knows why nothing opened. Script-initiated navigations
        // (trackers, JS redirects, beacons) are always cancelled silently.
        if scheme == "http" || scheme == "https" {
            if navigationAction.navigationType == .linkActivated {
                let host = url.host?.lowercased() ?? ""
                if Self.allowedExternalHosts.contains(host) {
                    NSWorkspace.shared.open(url)
                } else {
                    showExternalToast(in: webView)
                }
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
        let scheme = url.scheme?.lowercased() ?? ""

        // For our own agd:// URLs, ALWAYS allow popups regardless of
        // navigationType. The 2008 footer linked /legal/trademarks.html
        // via window.open() from an onclick handler; WKWebView reports
        // that as .other (script-initiated), and dropping these would
        // eat the trademarks click. agd:// is our internal scheme —
        // never an external ad — so just load it in the current webView.
        if scheme == "agd" {
            webView.load(URLRequest(url: url))
            return nil
        }
        // For http/https popups (script-initiated or otherwise), apply
        // the same allowlist + toast policy as the inline-nav path. The
        // 2008 fun.html footer's "Terms and Conditions" link uses
        // onclick="openTerms()" which calls window.open() — that's
        // script-initiated, so without this it'd be silently eaten.
        // The autopoll that previously made us suppress script popups
        // is disarmed at source by the patcher (pollCanGo=false), so
        // legitimate user-clicked openX() handlers can flow through now.
        if scheme == "http" || scheme == "https" {
            let host = url.host?.lowercased() ?? ""
            if Self.allowedExternalHosts.contains(host) {
                NSWorkspace.shared.open(url)
            } else {
                showExternalToast(in: webView)
            }
            return nil
        }
        // Other schemes: only follow if a real user gesture initiated.
        if navigationAction.navigationType != .linkActivated {
            return nil
        }
        webView.load(URLRequest(url: url))
        return nil
    }

    /// Tear down ProjectorOverlay's shadow-mask windows whenever the
    /// user navigates — masks from a DCR on a previous page would
    /// otherwise persist as ghost frames on whatever page comes next.
    /// Hook multiple events because back-nav cached restores may skip
    /// didCommit entirely, and a single late hook leaves a "white flash"
    /// frame for ~200ms while the new page loads.
    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {
        NotificationCenter.default.post(name: .AGDPageDidNavigate, object: webView)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        NotificationCenter.default.post(name: .AGDPageDidNavigate, object: webView)
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
