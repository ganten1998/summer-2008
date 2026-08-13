import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Invisible NSView positioned over the top ~28pt of the window's
/// content area. Its sole job is to make the title-bar region of the
/// window draggable — `mouseDownCanMoveWindow = true` tells AppKit that
/// drag gestures starting here should reposition the window. Ordinary
/// clicks and scrolls pass through to the WebView below, so the AG nav
/// links remain interactive. Transparent so the WebView's AG red
/// navbar continues to show through.
private final class DraggableTitleBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Window-drag message handler. JS posts here on mousedown over any
/// data-agd-drag region (the entire body, in practice) once a small
/// movement threshold has been exceeded. We then call
/// NSWindow.performDrag with the *cached* most-recent leftMouse event
/// — NOT NSApp.currentEvent, which is unreliable across async hops
/// (the WKWebView postMessage round-trip can leave it stale or nil,
/// which is exactly what was causing drag to fire only intermittently).
private final class WindowDragHandler: NSObject, WKScriptMessageHandler {
    weak var window: NSWindow?
    private var lastMouseEvent: NSEvent?
    private var monitor: Any?

    override init() {
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged]
        ) { [weak self] event in
            self?.lastMouseEvent = event
            return event
        }
    }
    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let window = window, let event = lastMouseEvent else { return }
        window.performDrag(with: event)
    }
}

/// Diagnostic: receives the element-info string from every drag-tagged
/// mousedown so we can see exactly what the user is clicking on when
/// something doesn't drag/hover. Writes only when AGD_DEBUG is set — see
/// `agdLog`.
private final class DragDiagHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard agdDebugEnabled else { return }
        guard let info = message.body as? String else { return }
        agdLog("drag-mousedown target=\(info)")
    }
}

/// JS console + JS error capture. Every console.log/warn/error and every
/// uncaught error on every page is piped here via injected JS. Lets us debug
/// stuck SWFs / page errors without requiring the user to open Safari Web
/// Inspector. Both the injection and this handler are gated on AGD_DEBUG, so
/// a shipping build neither injects the hook nor writes anything.
private final class ConsoleBridgeHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard agdDebugEnabled else { return }
        guard let line = message.body as? String else { return }
        agdLog(line)
    }
}

/// Weak wrapper that receives DCR launch requests from flash-bridge.js
/// without going through WKWebView navigation. Avoids polluting the
/// nav-history with cancelled agd-launch:// entries that cost the user
/// extra Back presses.
private final class DCRLaunchHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            GameLauncher.shared.launch(originalURL: url)
        }
    }
}

/// Host bridge for explicit "open this URL in the user's default app"
/// requests from in-page JS (used by the ecard wizard's Send Email
/// buttons to launch mailto/Gmail/Yahoo/Outlook compose). Goes through
/// here rather than `window.location.href` so we bypass
/// NavigationHandler's strict external-link allowlist — those clicks
/// are explicit user actions in OUR UI, not stray 2008 page links the
/// allowlist exists to gate.
private final class OpenExternalHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}

/// E-card send: receives the recorded card video (or PNG fallback) from
/// the wizard, converts video to a NON-LOOPING animated GIF, and opens a
/// Mail compose window with recipient, subject, body, and the card
/// inlined — which mailto:/webmail compose URLs cannot do.
///
/// Why GIF and not the video itself: no mail client autoplays video
/// attachments (Gmail can't even preview WebKit's MediaRecorder MP4s),
/// but inline animated GIFs play automatically everywhere. Play-once is
/// deliberate: these cards reveal the personal message on their FINAL
/// frames, so a non-looping GIF performs once and then rests permanently
/// on the message — the 2008 finale becomes the email's standing image.
private final class EcardComposeHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let to = dict["to"] as? String,
              let subject = dict["subject"] as? String,
              let body = dict["body"] as? String,
              let fileName = dict["fileName"] as? String,
              let b64 = dict["dataBase64"] as? String,
              let data = Data(base64Encoded: b64) else {
            NSLog("AGD ecardCompose: malformed payload")
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Summer 2008 E-Cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sanitize: the name reaches Mail as the attachment filename.
        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileURL = dir.appendingPathComponent(safeName)
        do { try data.write(to: fileURL) } catch {
            NSLog("AGD ecardCompose: temp write failed: \(error)")
            return
        }
        // Transcode off the main thread — frame extraction over a long
        // card takes a few seconds — then compose on main.
        DispatchQueue.global(qos: .userInitiated).async {
            var attachURL = fileURL
            let ext = fileURL.pathExtension.lowercased()
            if ext == "mp4" || ext == "webm" || ext == "mov" {
                let gifURL = fileURL.deletingPathExtension().appendingPathExtension("gif")
                if Self.gifFromVideo(src: fileURL, dst: gifURL) {
                    attachURL = gifURL
                } else {
                    NSLog("AGD ecardCompose: GIF transcode failed — attaching video as-is")
                }
            }
            DispatchQueue.main.async {
                guard let svc = NSSharingService(named: .composeEmail) else {
                    // No mail client configured — at least reveal the file
                    // so the user can attach it wherever they compose.
                    NSWorkspace.shared.activateFileViewerSelecting([attachURL])
                    return
                }
                svc.recipients = [to]
                svc.subject = subject
                // Card FIRST, then the footer a few lines below — the
                // text is the e-card email's footer, not its opening.
                svc.perform(withItems: [attachURL, "\n\n" + body])
            }
        }
    }

    /// Video → play-once animated GIF via AVAssetImageGenerator + ImageIO.
    /// fps and scale adapt to duration so even the 70-second doodle cards
    /// stay inside mail-attachment territory. The Netscape loop extension
    /// is set to loop count 1: animate through, then freeze on the final
    /// frame (the message).
    private static func gifFromVideo(src: URL, dst: URL) -> Bool {
        let asset = AVAsset(url: src)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0.2 else { return false }

        // Frame budget: ~12fps for short cards, sliding down to 6fps for
        // epics; cap total frames so the encoder and the recipient's mail
        // client both stay happy.
        let fps: Double = duration <= 20 ? 12 : (duration <= 40 ? 9 : 6)
        let frameCount = min(Int(duration * fps), 480)
        guard frameCount > 1 else { return false }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
        // Long cards render at reduced width to hold the byte budget;
        // short ones keep the full 600px.
        gen.maximumSize = duration > 40
            ? CGSize(width: 480, height: 0)
            : CGSize(width: 600, height: 0)

        guard let dest = CGImageDestinationCreateWithURL(
            dst as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { return false }
        // No Netscape loop extension at all = play exactly once, then
        // freeze on the final frame (loop-count 1 makes some viewers play
        // twice; omission is the universal "once").
        let frameProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1.0 / fps,
        ]] as CFDictionary

        var added = 0
        for i in 0..<frameCount {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let img = try? gen.copyCGImage(at: t, actualTime: nil) {
                CGImageDestinationAddImage(dest, img, frameProps)
                added += 1
            }
        }
        guard added > 1, CGImageDestinationFinalize(dest) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dst.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        NSLog("AGD ecardCompose: GIF \(added) frames @\(fps)fps, \(bytes) bytes")
        return true
    }
}

/// Weak wrapper so WKUserContentController doesn't retain AppDelegate.
private final class NavMessageHandler: NSObject, WKScriptMessageHandler {
    weak var appDelegate: AppDelegate?
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let action = message.body as? String else { return }
        DispatchQueue.main.async { [weak self] in
            switch action {
            case "back", "forward":
                // Tear masks down IMMEDIATELY on user click. Don't wait
                // for the WKWebView nav-delegate hooks to fire — back/
                // forward to a cached page can skip didCommit entirely
                // and leave the cover NSWindow visible on top of the
                // new page for hundreds of ms.
                NotificationCenter.default.post(
                    name: .AGDPageDidNavigate,
                    object: self?.appDelegate?.webView)
                if action == "back" {
                    self?.appDelegate?.webView.goBack()
                } else {
                    self?.appDelegate?.webView.goForward()
                }
            default: break
            }
        }
    }
}

/// AppDelegate sets up the menu bar, builds the main window, and configures a
/// WKWebView that loads the dashboard via the custom `agd://` scheme.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var navHandler: NavigationHandler!
    var schemeHandler: MirrorURLSchemeHandler!
    private var msgHandler: NavMessageHandler!
    private var dcrLaunchHandler: DCRLaunchHandler!
    private var openExternalHandler: OpenExternalHandler!
    private var ecardComposeHandler: EcardComposeHandler!
    private var dragHandler: WindowDragHandler!
    private var dragDiagHandler: DragDiagHandler!
    private var consoleBridge: ConsoleBridgeHandler!
    var overlay: ProjectorOverlay!

    /// An agd:// URL handed to us by Launch Services before the webview
    /// existed (cold launch via an e-card pickup link in an email).
    /// Stashed here and loaded once applicationDidFinishLaunching has
    /// built the webview.
    private var pendingOpenURL: URL?

    /// Launch Services hands us agd:// URLs here — both on cold launch
    /// (before applicationDidFinishLaunching) and while running. This is
    /// what makes an e-card pickup link in a recipient's email open the
    /// app directly on their animated card, like the 2008 email link did.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme?.lowercased() == "agd" }) else { return }
        if let webView = webView {
            DispatchQueue.main.async {
                webView.load(URLRequest(url: url))
                self.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            pendingOpenURL = url
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBar()

        // Belt-and-suspenders cleanup of any orphan Wine/Director
        // projectors from a previous run that didn't go through our
        // applicationWillTerminate path (force-quit, crash, kill -9).
        // Without this they accumulate and float on screen with title
        // bars showing — the "centered window with label" the user
        // reported.
        //
        // Scoped to processes spawned from our own bundle: matching on
        // bare "wine-preloader" would also kill CrossOver/Whisky/any other
        // Wine app the user happens to be running. See sweepOrphanProjectors.
        GameLauncher.shared.sweepOrphanProjectors()

        // Startup AX trust probe — log on launch so we can see if the
        // PERSISTENT grant works (we'd see trusted=true from the moment
        // the app starts) vs an in-session-only grant (trusted flips
        // false→true mid-run, can be cached weirdly). Also dumps the
        // bundle ID + binary path so any TCC entry-collision is visible.
        do {
            let trusted = AXIsProcessTrusted()
            let bundleID = Bundle.main.bundleIdentifier ?? "(no bundle id)"
            let exePath  = Bundle.main.executableURL?.path ?? "(no exe path)"
            NSLog("AGD: startup AXIsProcessTrusted=\(trusted) bundleID=\(bundleID) exe=\(exePath)")
            agdLog("startup AXIsProcessTrusted=\(trusted) bundleID=\(bundleID) exe=\(exePath)")
        }

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // 2008 QuickTime <embed autoplay=true> fired immediately on page
        // load with sound — no user gesture needed. WKWebView's default
        // requires a user interaction before audible media plays; clearing
        // the requirement restores the period-faithful behavior.
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        schemeHandler = MirrorURLSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "agd")

        // Swift-side handler for back/forward messages from the injected nav bar.
        msgHandler = NavMessageHandler()
        msgHandler.appDelegate = self
        config.userContentController.add(msgHandler, name: "agdNav")

        // DCR launch handler: flash-bridge.js posts the .dcr URL here
        // when the user clicks the projector pill. Going through a
        // script message handler (rather than window.location.href to
        // an agd-launch:// URL) avoids history-pollution that costs the
        // user an extra Back press to escape the game page.
        dcrLaunchHandler = DCRLaunchHandler()
        config.userContentController.add(dcrLaunchHandler, name: "launchDCR")

        // External-URL bridge for the ecard wizard's Send Email chooser.
        // Wizard JS posts mailto:/https://gmail.com/... here; we shell
        // out via NSWorkspace. Bypasses NavigationHandler's allowlist
        // (which would otherwise toast-block the webmail compose URLs).
        openExternalHandler = OpenExternalHandler()
        config.userContentController.add(openExternalHandler, name: "openExternal")
        ecardComposeHandler = EcardComposeHandler()
        config.userContentController.add(ecardComposeHandler, name: "ecardCompose")

        // Window-drag handler: JS calls into here on mousedown over any
        // data-agd-drag region (nav bars). We invoke NSWindow.performDrag
        // so the user can grab the visible red AG nav or our injected
        // dashboard bar to move the window — same gesture as dragging
        // a native title bar.
        dragHandler = WindowDragHandler()
        config.userContentController.add(dragHandler, name: "agdDrag")
        dragDiagHandler = DragDiagHandler()
        config.userContentController.add(dragDiagHandler, name: "agdDragDiag")

        // Console bridge: pipes every console.log/warn/error and every
        // uncaught error to the diagnostic log. Lets us debug stuck SWFs and
        // page errors without needing Safari Web Inspector.
        //
        // Gated on AGD_DEBUG: in a shipping build we skip both the message
        // handler and the user script entirely, so no hook is installed into
        // every frame of every page and nothing is written to disk.
        if agdDebugEnabled {
        consoleBridge = ConsoleBridgeHandler()
        config.userContentController.add(consoleBridge, name: "agdConsole")
        let consoleJS = """
        (function () {
          if (window.__agd_console_bridged) return;
          window.__agd_console_bridged = true;
          function send(level, args) {
            try {
              var parts = [];
              for (var i = 0; i < args.length; i++) {
                var a = args[i];
                if (a == null) { parts.push(String(a)); continue; }
                if (typeof a === 'string') { parts.push(a); continue; }
                try { parts.push(JSON.stringify(a)); }
                catch (e) { parts.push(String(a)); }
              }
              window.webkit.messageHandlers.agdConsole.postMessage(
                '[' + level + '] ' + parts.join(' '));
            } catch (e) {}
          }
          ['log', 'warn', 'error', 'info', 'debug'].forEach(function (lvl) {
            var orig = console[lvl];
            console[lvl] = function () {
              send(lvl, arguments);
              if (orig) orig.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (e) {
            send('uncaught', [e.message, '@', (e.filename || '?') + ':' + (e.lineno || 0)]);
          });
          window.addEventListener('unhandledrejection', function (e) {
            send('rejection', [String(e.reason)]);
          });
        })();
        """
        config.userContentController.addUserScript(WKUserScript(
            source: consoleJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page))
        }   // if agdDebugEnabled

        // Bridge that places the bundled Wine/Director projector window
        // over the .dcr embed area on game pages. Receives the embed's
        // bounding rect from flash-bridge.js via the `dcrRect` handler.
        overlay = ProjectorOverlay()
        config.userContentController.add(overlay, name: "dcrRect")
        GameLauncher.shared.overlay = overlay

        // In-page toast helper. NavigationHandler calls window.__agd_showToast
        // via evaluateJavaScript when the user clicks a non-allowlisted
        // external link, so the cancel isn't silent. Ported from the
        // Windows MainWindow.xaml.cs ToastJs constant. Registered atDocStart
        // so it's available before any user interaction can fire.
        let toastJS = """
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
                "font:13.5px/1.4 -apple-system,sans-serif",
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
                }, 220);
              }, 3000);
            };
            if (document.body) run();
            else document.addEventListener('DOMContentLoaded', run);
          };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(
            source: toastJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page))

        // Hide 2008 popup pages' "Close Window" button. Privacy /
        // termsConditions / similar popups have a <div class="closeWindow">
        // wrapping a window.close() link — meaningful when those pages
        // opened as separate browser windows in 2008, but redundant in
        // our archive because the popups load inline in the same
        // WebView and the injected back-arrow navbar already covers it.
        // (And window.close() on a self-opened window is a no-op in
        // WKWebView anyway, so leaving the button visible would just
        // be a dead affordance.)
        let hidePopupCloseJS = """
        (function() {
          var s = document.createElement('style');
          s.setAttribute('data-agd-runtime', 'hide-popup-close');
          s.textContent = '.closeWindow{display:none!important;}';
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        config.userContentController.addUserScript(WKUserScript(
            source: hidePopupCloseJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page))

        // Inject the drag setup on EVERY page (including dashboard /
        // runtime / games — the previous early-return skipped these and
        // that's why the dashboard wasn't draggable). The back/forward
        // bar is still only injected on mirrored AG pages.
        let navBarJS = """
        (function() {
          var h = location.hostname;
          // Skip iframes — the ecard wizard hosts the Ruffle preview in a
          // same-origin <iframe src=__agd/ecard-frame.html>, which would
          // otherwise inherit the navbar + Ko-fi pill and end up with
          // TWO pills on screen (one in the parent wizard, one inside
          // the tiny 600×350 preview iframe). Navbar is useless in any
          // iframe context anyway.
          if (window !== window.top) return;
          var isInternal = (h === 'dashboard' || h === 'runtime' || h === 'games');

          // -------- Back/forward/Dashboard bar (mirrored AG pages only) --------
          if (!isInternal) {
            var bar = document.createElement('div');
            bar.style.cssText = [
              'position:fixed','top:0','left:0','right:0','height:40px',
              'background:#A6192E','z-index:2147483647',
              'display:flex','align-items:center','justify-content:flex-end',
              'padding:0 14px','gap:4px',
              'box-shadow:0 2px 8px rgba(0,0,0,.25)'
            ].join(';');
            bar.setAttribute('data-agd-drag', 'true');

            var btnStyle = [
              'color:#FBF6EB','background:rgba(255,246,235,0.15)',
              'border:none','border-radius:6px',
              'font:600 15px/1 -apple-system,sans-serif',
              'padding:5px 10px','cursor:pointer',
              'opacity:.85','transition:opacity .15s',
              'text-decoration:none','display:inline-flex','align-items:center'
            ].join(';');

            // Back button
            var backBtn = document.createElement('button');
            backBtn.textContent = '\\u2190';
            backBtn.title = 'Back';
            backBtn.style.cssText = btnStyle;
            backBtn.onmouseenter = function(){ backBtn.style.opacity='1'; };
            backBtn.onmouseleave = function(){ backBtn.style.opacity='0.85'; };
            backBtn.onclick = function(){ webkit.messageHandlers.agdNav.postMessage('back'); };

            // Forward button
            var fwdBtn = document.createElement('button');
            fwdBtn.textContent = '\\u2192';
            fwdBtn.title = 'Forward';
            fwdBtn.style.cssText = btnStyle;
            fwdBtn.style.marginLeft = '4px';
            fwdBtn.onmouseenter = function(){ fwdBtn.style.opacity='1'; };
            fwdBtn.onmouseleave = function(){ fwdBtn.style.opacity='0.85'; };
            fwdBtn.onclick = function(){ webkit.messageHandlers.agdNav.postMessage('forward'); };

            // Dashboard link
            var dashLink = document.createElement('a');
            dashLink.href = 'agd://dashboard/index.html';
            dashLink.textContent = '\\u2302  Dashboard';
            dashLink.style.cssText = [
              'color:#FBF6EB','text-decoration:none',
              'font:600 11px/1 -apple-system,sans-serif',
              'letter-spacing:.18em','text-transform:uppercase',
              'opacity:.9','transition:opacity .15s',
              'margin-left:6px'
            ].join(';');
            dashLink.onmouseenter = function(){ dashLink.style.opacity='1'; };
            dashLink.onmouseleave = function(){ dashLink.style.opacity='0.9'; };

            bar.appendChild(backBtn);
            bar.appendChild(fwdBtn);
            bar.appendChild(dashLink);
            document.body.insertBefore(bar, document.body.firstChild);

            // Push body content below the bar.
            var current = parseInt(getComputedStyle(document.body).paddingTop) || 0;
            document.body.style.paddingTop = (current + 40) + 'px';

            // Bottom-left Ko-fi tip pill — same look + position as the one
            // on the dashboard, inlined so we don't need the dashboard
            // stylesheet on mirror pages. Ko-fi is the only allowlisted
            // external host in NavigationHandler, so target='_blank'
            // escapes to the user's default browser.
            var kofiPill = document.createElement('a');
            kofiPill.href = 'https://ko-fi.com/B0B7EF4TJ';
            kofiPill.target = '_blank';
            kofiPill.rel = 'noopener';
            kofiPill.title = 'Keep this archive online \\u2014 tip the archivist on Ko-fi';
            kofiPill.style.cssText = [
              'position:fixed','left:22px','bottom:22px',
              'z-index:2147483647',
              'display:inline-flex','align-items:center','gap:7px',
              'padding:8px 14px 8px 12px',
              'border-radius:999px',
              'background:rgba(255,252,244,0.92)',
              'border:1px solid rgba(124,12,31,0.20)',
              'box-shadow:0 4px 12px rgba(124,12,31,0.10)',
              'color:#7C0C1F','text-decoration:none',
              'font:600 11px/1 -apple-system,sans-serif',
              'letter-spacing:.14em','text-transform:uppercase',
              'opacity:.82',
              'transition:opacity .18s ease, transform .18s ease, box-shadow .18s ease'
            ].join(';');
            kofiPill.innerHTML = '<span aria-hidden=\"true\" style=\"font-size:13px;line-height:1\">\\u2615</span><span>Tip</span>';
            kofiPill.onmouseenter = function(){
              kofiPill.style.opacity = '1';
              kofiPill.style.transform = 'translateY(-1px)';
              kofiPill.style.boxShadow = '0 8px 22px rgba(124,12,31,0.18)';
            };
            kofiPill.onmouseleave = function(){
              kofiPill.style.opacity = '.82';
              kofiPill.style.transform = 'translateY(0)';
              kofiPill.style.boxShadow = '0 4px 12px rgba(124,12,31,0.10)';
            };
            document.body.appendChild(kofiPill);
          }

          // -------- Window-drag setup (nav bar / header only) --------
          // For mirrored AG pages, the red bar created above already
          // has data-agd-drag and is position:fixed top:0 — drag works
          // anywhere along the top strip.
          //
          // For internal pages (dashboard / runtime / games), tagging
          // the existing header.brand element gave only a needle-in-
          // haystack drag area because the visible "top strip" is
          // mostly margin/whitespace AROUND the header content. Inject
          // an invisible fixed-position drag strip across the top of
          // the window — same shape as the mirror nav bar, but with
          // no visual chrome and no buttons. pointer-events: auto so
          // the mousedown lands here; content below the 36px strip
          // (cards, links, gallery tiles) is unaffected.
          if (isInternal) {
            var dragStrip = document.createElement('div');
            dragStrip.setAttribute('data-agd-drag', 'true');
            dragStrip.style.cssText = [
              'position:fixed','top:0','left:0','right:0','height:36px',
              'z-index:2147483646',
              'background:transparent','pointer-events:auto'
            ].join(';');
            document.body.appendChild(dragStrip);
          }

          // Threshold-based drag: a mousedown over a tagged region starts
          // a drag candidate. Single click without movement → element's
          // own handler fires (link nav, button click). Mousedown + move
          // past 4px → window drag; the click event is naturally suppressed
          // by WebKit since the pointer left the element. Only true text-
          // selection contexts (input/textarea/select) are skipped, since
          // their click-drag is meant to select characters not move windows.
          var dragStart = null;
          document.addEventListener('mousedown', function (e) {
            var t = e.target;
            if (t.closest('input, select, textarea')) return;
            if (!t.closest('[data-agd-drag]')) return;
            dragStart = { x: e.clientX, y: e.clientY };
          }, true);
          document.addEventListener('mousemove', function (e) {
            if (!dragStart) return;
            var dx = e.clientX - dragStart.x;
            var dy = e.clientY - dragStart.y;
            if (dx * dx + dy * dy > 16) {
              dragStart = null;
              try { window.webkit.messageHandlers.agdDrag.postMessage(null); } catch (_) {}
            }
          }, true);
          document.addEventListener('mouseup', function () { dragStart = null; }, true);
        })();
        """
        let script = WKUserScript(source: navBarJS,
                                  injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        webView = WKWebView(frame: frame, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        navHandler = NavigationHandler()
        webView.navigationDelegate = navHandler
        webView.uiDelegate = navHandler

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Summer 2008"
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.98, green: 0.95, blue: 0.91, alpha: 1.0)

        // WebView is the content view directly. Window-drag is handled
        // by injected JS that calls into the agdDrag message handler on
        // mousedown over any [data-agd-drag] region (nav bars).
        window.contentView = webView

        window.makeKeyAndOrderFront(nil)
        dragHandler.window = window

        // When the main window closes, force-terminate the app explicitly.
        // applicationShouldTerminateAfterLastWindowClosed checks every
        // window owned by the app — including our cover + shadow-mask
        // NSWindows from ProjectorOverlay — so when the user clicks the
        // red close button, the cover/mask windows are still "open" and
        // the app would stay alive zombie-style with the white border
        // still painted on screen. Forcing terminate here guarantees the
        // app exits cleanly, our overlays go with it, and the synchronous
        // wine-kill in applicationWillTerminate also fires.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NSApp.terminate(nil)
        }

        // Now that window + webview exist, let the overlay subscribe to
        // window move/resize so the projector follows the host frame.
        overlay.attachToMainWindow(window, webView: webView)

        // A pickup link handed over by Launch Services during cold launch
        // (e-card "view your greeting" link in an email) outranks the
        // dashboard as the start page.
        let startString = pendingOpenURL?.absoluteString
            ?? ProcessInfo.processInfo.environment["AGD_START_URL"]
            ?? "agd://dashboard/index.html"
        pendingOpenURL = nil
        let start = URL(string: startString) ?? URL(string: "agd://dashboard/index.html")!
        webView.load(URLRequest(url: start))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Kill any running Wine/Director projector children before our
    /// process exits — otherwise they stay on screen as orphan windows
    /// the user can't easily close.
    func applicationWillTerminate(_ notification: Notification) {
        GameLauncher.shared.terminateAllProjectors()
    }

    private func installMenuBar() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        // Short label per project naming spec — used for "About …", "Hide …",
        // and "Quit …" menu items where the full title would overflow.
        let appName = "Summer 2008"
        appMenu.addItem(NSMenuItem(title: "About \(appName)",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(appName)",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // Edit menu — without this, the standard Cmd+X / Cmd+C / Cmd+V /
        // Cmd+A keystrokes never reach the focused WKWebView text field,
        // and right-click context menus don't have Cut/Copy/Paste either.
        // The selectors are NSText/NSResponder defaults; target=nil sends
        // them up the responder chain so they land on whatever's focused.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo",
                                    action: Selector(("undo:")),
                                    keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo",
                                  action: Selector(("redo:")),
                                  keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",
                                    action: #selector(NSText.cut(_:)),
                                    keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",
                                    action: #selector(NSText.copy(_:)),
                                    keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",
                                    action: #selector(NSText.paste(_:)),
                                    keyEquivalent: "v"))
        let pastePlain = NSMenuItem(title: "Paste and Match Style",
                                    action: Selector(("pasteAsPlainText:")),
                                    keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .shift, .option]
        editMenu.addItem(pastePlain)
        editMenu.addItem(NSMenuItem(title: "Delete",
                                    action: #selector(NSText.delete(_:)),
                                    keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Select All",
                                    action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let home = NSMenuItem(title: "Dashboard", action: #selector(goHome), keyEquivalent: "0")
        home.target = self
        viewMenu.addItem(home)
        let reload = NSMenuItem(title: "Reload",
                                action: #selector(WKWebView.reload(_:)),
                                keyEquivalent: "r")
        viewMenu.addItem(reload)
        let back = NSMenuItem(title: "Back",
                              action: #selector(WKWebView.goBack(_:)),
                              keyEquivalent: "[")
        viewMenu.addItem(back)
        let forward = NSMenuItem(title: "Forward",
                                 action: #selector(WKWebView.goForward(_:)),
                                 keyEquivalent: "]")
        viewMenu.addItem(forward)
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func goHome() {
        let start = URL(string: "agd://dashboard/index.html")!
        webView.load(URLRequest(url: start))
    }
}
