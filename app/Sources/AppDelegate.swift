import AppKit
import WebKit

/// Weak wrapper so WKUserContentController doesn't retain AppDelegate.
private final class NavMessageHandler: NSObject, WKScriptMessageHandler {
    weak var appDelegate: AppDelegate?
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let action = message.body as? String else { return }
        DispatchQueue.main.async { [weak self] in
            switch action {
            case "back":    self?.appDelegate?.webView.goBack()
            case "forward": self?.appDelegate?.webView.goForward()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBar()

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        schemeHandler = MirrorURLSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "agd")

        // Swift-side handler for back/forward messages from the injected nav bar.
        msgHandler = NavMessageHandler()
        msgHandler.appDelegate = self
        config.userContentController.add(msgHandler, name: "agdNav")

        // Inject a nav bar into every mirrored site page (not dashboard/runtime/games).
        // Back/forward fire webView.goBack()/goForward() via the agdNav message handler.
        let navBarJS = """
        (function() {
          var h = location.hostname;
          if (h === 'dashboard' || h === 'runtime' || h === 'games') return;

          var bar = document.createElement('div');
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
        window.contentView = webView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.98, green: 0.95, blue: 0.91, alpha: 1.0)
        window.makeKeyAndOrderFront(nil)

        let startString = ProcessInfo.processInfo.environment["AGD_START_URL"]
            ?? "agd://dashboard/index.html"
        let start = URL(string: startString) ?? URL(string: "agd://dashboard/index.html")!
        webView.load(URLRequest(url: start))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
