import AppKit
import ApplicationServices
import Foundation
import WebKit

// MARK: - Private CGS API for actually disabling other-process window shadow.
//
// macOS's standard NSWindow API only lets you set `hasShadow` on YOUR
// own windows. To kill the drop shadow on Wine's projector — which is
// owned by a different process — we go through the SkyLight (formerly
// CoreGraphics services) private interface. Stable since 10.0; same
// approach used by Magnet, Rectangle, BetterTouchTool, Stage Manager,
// and dozens of public window managers. Risk is low.

private typealias CGSConnectionID = Int32
private typealias CGSWindowID     = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetWindowShadowAndRimParameters")
private func CGSSetWindowShadowAndRimParameters(
    _ cid: CGSConnectionID, _ wid: CGSWindowID,
    _ stdDev: Float, _ density: Float,
    _ offsetX: Int32, _ offsetY: Int32,
    _ flags: UInt32, _ rgba: UnsafePointer<Float>?) -> Int32

/// Iterate every on-screen Wine projector window and force its
/// shadow density to 0. Idempotent + cheap; called from the ticker
/// after we find the right window so repeated calls don't pile up.
fileprivate func disableShadow(forCGSWindowID wid: CGSWindowID) {
    let cid = CGSMainConnectionID()
    var rgba: [Float] = [0, 0, 0, 0]
    _ = rgba.withUnsafeBufferPointer { ptr in
        CGSSetWindowShadowAndRimParameters(
            cid, wid,
            /* stdDev   */ 0,
            /* density  */ 0,
            /* offsetX  */ 0,
            /* offsetY  */ 0,
            /* flags    */ 0,
            ptr.baseAddress)
    }
}

/// NSView that paints opaque white EVERYWHERE except inside a rounded
/// rectangle — used as the content view of a NSWindow that frames the
/// bundled Wine projector, masking its drop shadow + rounded chrome
/// corners. The cutout follows the Wine window's curve exactly so we
/// don't get the right-angle artifact at the corners that simple
/// straight-edge strips produced.
final class ShadowMaskView: NSView {
    var innerRect:    NSRect  = .zero
    var cornerRadius: CGFloat = 10
    var maxOpacity:   CGFloat = 1.0   // 1.0 = fully opaque against Wine edge
    var falloff:      CGFloat = 1.0   // gradient extent (0..1 of frame thickness)

    override var wantsDefaultClipping: Bool { false }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Frame thickness — how far the mask area extends outside the
        // wine window rect on each side. We assume equal padding so
        // we can compute from the X distance.
        let pad = max(innerRect.origin.x, 1)

        // Draw a series of inset rounded-rectangle strokes from the
        // wine edge outward. Each stroke is more transparent than the
        // last — a per-pixel gradient cancelling the shadow, which is
        // darkest adjacent to the window and fades with distance.
        let steps = Int(pad)
        for i in 0..<steps {
            let inset = -CGFloat(i)   // negative = expand outward
            let expanded = innerRect.insetBy(dx: inset, dy: inset)
            // Opacity ramps from maxOpacity at the wine edge (i=0) down
            // to 0 at the outermost ring. Square the ramp so the alpha
            // curve matches the shadow's exponential falloff more closely.
            let t = 1.0 - CGFloat(i) / CGFloat(steps - 1)
            let alpha = maxOpacity * t * t
            // Stroke a 1pt rounded-rect ring at this distance.
            let path = NSBezierPath(roundedRect: expanded,
                                    xRadius: cornerRadius + CGFloat(i),
                                    yRadius: cornerRadius + CGFloat(i))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(1.0)
            path.stroke()
        }
    }
}

extension Notification.Name {
    /// Posted by NavigationHandler when the WebView commits a new page,
    /// so ProjectorOverlay can clear stale shadow-mask overlays.
    static let AGDPageDidNavigate = Notification.Name("AGDPageDidNavigate")
}

/// Diagnostics are opt-in via the `AGD_DEBUG` environment variable.
///
/// These log files used to be written unconditionally in shipping builds, to a
/// fixed path in world-writable /tmp, and with no rotation — every console
/// message from every page in every frame, appended synchronously on the main
/// thread. That is a privacy leak (page contents land in a predictable file any
/// local process can read, and another user can pre-create/symlink the path),
/// an unbounded disk consumer, and main-thread I/O on a hot path.
///
/// Turn them on when debugging:
///     AGD_DEBUG=1 "/Applications/Summer 2008 — An American Girl Archive.app/Contents/MacOS/AGDLauncher"
///     tail -f "$TMPDIR/agd-debug.log"
let agdDebugEnabled: Bool = ProcessInfo.processInfo.environment["AGD_DEBUG"] != nil

/// Per-user temp dir, not /tmp — NSTemporaryDirectory() is inside the user's
/// own container, so the log is not world-readable and cannot be pre-empted by
/// another user planting a symlink at a guessable path.
let agdLogPath: String =
    (NSTemporaryDirectory() as NSString).appendingPathComponent("agd-debug.log")

/// Append a line to the diagnostic log. No-op unless AGD_DEBUG is set.
///
/// macOS Sequoia+ redacts NSLog interpolations as `<private>` in the unified
/// log, which is why this writes to a file at all.
func agdLog(_ msg: String) {
    guard agdDebugEnabled else { return }
    let line = "\(Date()) \(msg)\n"
    NSLog("AGD: %@", msg)  // keep NSLog for whoever has it filtered in already
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: agdLogPath) {
        if let fh = FileHandle(forWritingAtPath: agdLogPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        }
    } else {
        try? data.write(to: URL(fileURLWithPath: agdLogPath))
    }
}

/// Makes the bundled Wine + Director projector window LOOK embedded in
/// the main app's WebView. There's no in-browser Director runtime
/// (Ruffle is Flash-only), so the actual game runs in a separate native
/// window owned by Wine. This class positions that window directly over
/// the `.dcr <embed>` area, and re-positions it continuously so it
/// follows the host frame through:
///   • normal user window moves / resizes
///   • AeroSpace and other tiling WM-driven moves (which don't always
///     fire NSWindow notifications)
///   • multi-monitor setups (window may sit on any screen)
///   • page scrolling
///   • DPI / scale changes
///
/// Pipeline:
///   1. flash-bridge.js measures the .agd-dcr stub's bounding rect and
///      posts it to the `dcrRect` script message handler, plus
///      re-emits on scroll/resize.
///   2. GameLauncher calls `track(dcrURL:pid:)` after Process.run().
///   3. We poll the AX API for a Wine window with the right pid and
///      apply position + size. Continues at ~30 FPS until the projector
///      exits.
///
/// AX (Accessibility) API is used directly instead of shelling to
/// `osascript`. AppleScript is ~50–100ms per call; AX is ~1–5ms — which
/// makes continuous 30 FPS repositioning feasible without burning CPU.
final class ProjectorOverlay: NSObject, WKScriptMessageHandler {
    /// The most recent layout the JS reported (viewport-relative pixels).
    private struct DesiredLayout {
        let dcrURL:  String
        let frame:   CGRect           // viewport-relative
        let dpr:     CGFloat
        let viewportSize: CGSize
    }

    /// One per actively-tracked DCR.
    private final class Track {
        let dcrURL: String
        let pid:    pid_t
        var lastApplied: CGRect = .zero
        var consecutiveNotFound = 0
        var firstPlacementDone = false
        /// Ticks elapsed while still hunting for the projector window. Used to
        /// run the window scan at a fraction of the tick rate before first
        /// placement — see `apply`.
        var searchTicks = 0
        /// When we started hunting, so the search can be given up on rather
        /// than run forever if the projector never opens a window.
        let searchStarted = Date()
        var gaveUpLogged = false
        init(dcrURL: String, pid: pid_t) {
            self.dcrURL = dcrURL
            self.pid = pid
        }
    }

    /// Scan for the projector window every Nth tick before first placement.
    /// The 60 Hz rate exists to out-race Director's own startup centering,
    /// which only matters once the window *exists*; until then a ~10 Hz hunt
    /// is plenty and costs a sixth as much.
    private static let searchTickDivisor = 6

    /// Stop hunting after this long. Wine bootstrapping a fresh WINEPREFIX can
    /// legitimately take tens of seconds, so this is generous — it exists only
    /// to stop an unbounded scan when the projector dies without a window.
    private static let searchDeadline: TimeInterval = 180

    weak var webView: NSView?
    weak var window:  NSWindow?

    private var layouts:  [String: DesiredLayout] = [:]
    private var tracks:   [String: Track] = [:]
    private var observers: [NSObjectProtocol] = []
    private var tickTimer: Timer?

    /// Was the offset for a macOS title bar in the version where Wine
    /// drew its native chrome. With "Decorated"="N" in user.reg the
    /// Wine window is borderless — no offset, no cover NSWindow needed.
    private static let titleBarHeight: CGFloat = 0

    /// Per-DCR cover NSWindow that hides the Wine window's title bar.
    /// We own these so we can set styleMask = .borderless freely.
    private var coverWindows: [String: NSWindow] = [:]

    /// One NSWindow per DCR that frames the Wine window, masking BOTH
    /// macOS's drop shadow AND the rounded corners of Wine's standard
    /// window chrome. Uses a custom NSView that fills white EVERYWHERE
    /// except a rounded-rect cutout matching Wine's frame — so the
    /// curves are followed, not approximated by right-angled strips.
    private var shadowMaskWindows: [String: NSWindow] = [:]
    private static let shadowMaskPadding: CGFloat   = 14  // tight to embed bounds — keeps mask from overlapping nav/text
    private static let wineCornerRadius: CGFloat    = 10  // approx Cocoa window corner

    // MARK: - Public API

    /// Called from GameLauncher.launchDCR after a successful Process.run().
    /// We start tracking the (dcrURL, pid) pair so the periodic ticker
    /// will pick up its window and place it.
    func track(dcrURL: String, pid: Int32) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            agdLog("track pid=\(pid) url=\(dcrURL) AXIsProcessTrusted=\(AXIsProcessTrusted())")
            self.tracks[dcrURL] = Track(dcrURL: dcrURL, pid: pid_t(pid))
            self.startTickerIfNeeded()
        }
    }

    func refresh(dcrURL: String, pid: Int32) {
        // Same as track — the tick will pick it up.
        track(dcrURL: dcrURL, pid: pid)
    }

    func attachToMainWindow(_ window: NSWindow, webView: NSView) {
        self.window  = window
        self.webView = webView
        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification,
                     NSWindow.didEndLiveResizeNotification] {
            let obs = nc.addObserver(forName: name, object: window,
                                     queue: .main) { [weak self] _ in
                self?.tick()
            }
            observers.append(obs)
        }
        // App-activation: when our app loses focus (user clicks elsewhere),
        // hide the cover + shadow-mask NSWindows so they don't float over
        // whatever else the user's working in. They come back when our
        // app regains focus.
        observers.append(nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.setOverlaysHidden(true)
        })
        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.setOverlaysHidden(false)
        })

        // Listen for "page navigated" broadcasts from NavigationHandler.
        // When the user navigates away from a DCR page, the projector
        // window is still alive but no longer has an embed area to mask
        // against. Tear all masks down; if the new page has its own DCR,
        // JS will post a fresh dcrRect and the masks reappear.
        observers.append(nc.addObserver(
            forName: .AGDPageDidNavigate, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tearDownAllMasks()
        })
    }

    /// Toggle visibility of all overlay NSWindows. Used when app
    /// resigns/becomes active.
    private func setOverlaysHidden(_ hidden: Bool) {
        for (_, w) in coverWindows {
            hidden ? w.orderOut(nil) : w.orderFrontRegardless()
        }
        for (_, w) in shadowMaskWindows {
            hidden ? w.orderOut(nil) : w.orderFrontRegardless()
        }
    }

    /// Called from the AGDPageDidNavigate broadcast (didCommit, back/
    /// forward, didStartProvisionalNavigation). Only effects the full
    /// cleanup when something is ACTIVELY positioned — i.e. there's a
    /// running projector. On initial page load, this is a no-op (no
    /// tracks yet → ticker is also idle, no work to undo), which means
    /// `layouts` from the JS rect post stays valid for when the user
    /// clicks the pill a moment later.
    private func tearDownAllMasks() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (_, w) in self.coverWindows      { w.orderOut(nil) }
            for (_, w) in self.shadowMaskWindows { w.orderOut(nil) }
            self.coverWindows.removeAll()
            self.shadowMaskWindows.removeAll()
            // Only the full kill/clear pass when we have active tracks
            // (= user previously clicked a DCR pill on this session).
            // Initial page loads don't disturb the layouts dict.
            if !self.tracks.isEmpty {
                GameLauncher.shared.terminateAllProjectors()
                self.tracks.removeAll()
                self.layouts.removeAll()
            }
        }
    }

    // MARK: - WKScriptMessageHandler (rect from JS)

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "dcrRect",
              let d = message.body as? [String: Any],
              let url = d["url"] as? String,
              let x   = (d["x"]      as? NSNumber)?.doubleValue,
              let y   = (d["y"]      as? NSNumber)?.doubleValue,
              let w   = (d["width"]  as? NSNumber)?.doubleValue,
              let h   = (d["height"] as? NSNumber)?.doubleValue,
              w > 10, h > 10
        else { return }
        let dpr = (d["dpr"] as? NSNumber)?.doubleValue ?? 1.0
        let vpW = (d["vpW"] as? NSNumber)?.doubleValue ?? 0
        let vpH = (d["vpH"] as? NSNumber)?.doubleValue ?? 0
        layouts[url] = DesiredLayout(
            dcrURL: url,
            frame:  CGRect(x: x, y: y, width: w, height: h),
            dpr:    CGFloat(dpr),
            viewportSize: CGSize(width: vpW, height: vpH))
        if !rectLoggedURLs.contains(url) {
            rectLoggedURLs.insert(url)
            agdLog("dcrRect received url=\(url) viewport-rect=(\(Int(x)),\(Int(y)) \(Int(w))×\(Int(h)))")
        }
        tick()  // immediate reposition with the fresh rect
    }
    private var rectLoggedURLs = Set<String>()

    // MARK: - Ticker

    private func startTickerIfNeeded() {
        guard tickTimer == nil else { return }
        // 60 FPS continuous tracking. AX calls are cheap (~1-5ms);
        // doubled rate is needed because Director's startup centering
        // logic re-positions the window from within Wine's process —
        // we have to overwrite it faster than it can fight back.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTickerIfIdle() {
        if tracks.isEmpty {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        // Prune tracks whose process has exited.
        for (url, t) in tracks {
            if !pidAlive(t.pid) {
                tracks.removeValue(forKey: url)
                tearDownCover(for: url)
            }
        }
        for (url, t) in tracks {
            apply(url: url, track: t)
        }
        stopTickerIfIdle()
    }

    private func pidAlive(_ pid: pid_t) -> Bool {
        // kill(pid, 0) returns 0 if pid exists in the process table.
        return kill(pid, 0) == 0
    }

    // MARK: - Position + size application

    private func apply(url: String, track: Track) {
        // One-shot positioning: once we've placed the projector for this
        // track, leave it alone — the user wanted full drag-anywhere
        // freedom on the projector window, not a locked overlay. Subsequent
        // ticks no-op so the user can drag the projector wherever.
        if track.firstPlacementDone { return }
        guard let layout = layouts[url] else {
            if !loggedMissingLayout.contains(url) {
                loggedMissingLayout.insert(url)
                agdLog("apply BAIL: no layout for url=\(url) — known keys=\(Array(layouts.keys))")
            }
            return
        }
        guard let contentRect = screenRect(for: layout) else {
            if !loggedNoScreenRect {
                loggedNoScreenRect = true
                agdLog("apply BAIL: screenRect returned nil — webView=\(webView != nil) window=\(webView?.window != nil)")
            }
            return
        }

        // Throttle the hunt: run the window scan at ~10 Hz rather than 60 Hz
        // until we have placed the window once, and abandon it after the
        // deadline instead of scanning for the life of the process.
        track.searchTicks += 1
        if Date().timeIntervalSince(track.searchStarted) > Self.searchDeadline {
            if !track.gaveUpLogged {
                track.gaveUpLogged = true
                agdLog("giving up on projector window for \(url) after "
                       + "\(Int(Self.searchDeadline))s — pid \(track.pid) never "
                       + "produced a layer-0 window")
            }
            return
        }
        if track.searchTicks % Self.searchTickDivisor != 0 { return }

        guard let axWindow = findProjectorWindow(pid: track.pid) else {
            track.consecutiveNotFound += 1
            if track.consecutiveNotFound == 20 {
                agdLog("still no projector window after 20 scans (~2s) for \(url)")
            }
            return
        }

        // One-shot spawn at the EMBED AREA'S TOP-LEFT corner, exactly.
        // No centering math — user explicitly wants the projector to
        // appear at the embed's natural location on the page, not
        // visually centered within it. Wine keeps its own clamped size;
        // any size mismatch becomes visible margin on right/bottom but
        // that's the honest "separate window pinned at embed origin"
        // look — not a fake-embed illusion. From there the user drags.
        let wineCurrent = currentWindowFrame(axWindow) ?? CGRect(
            x: 0, y: 0,
            width: contentRect.size.width, height: contentRect.size.height)
        let windowRect = CGRect(
            x: contentRect.origin.x,
            y: contentRect.origin.y,
            width:  wineCurrent.size.width,
            height: wineCurrent.size.height)

        // Write once. Mark done so subsequent ticks no-op — the user
        // wants to drag the projector freely. We're not a constraint.
        setWindowFrame(axWindow, position: windowRect.origin, size: windowRect.size)
        track.firstPlacementDone = true

        // (Removed kAXRaiseAction-per-tick — it made the wine window
        // visibly disappear during host drag because of how WindowServer
        // handles raise events during a live drag. Wine going behind
        // the host during drag IS the documented macOS limitation for
        // cross-process window control without Developer ID / private
        // CGS calls. Acceptable trade for not breaking drag.)

        // No more overlay scaffolding — the projector is now a normal
        // freely-draggable Wine window with native macOS chrome. The
        // cover/shadow-mask code is left in the file but never called
        // in this flow; can be cleaned up in a follow-up commit.

        let firstPlacement = (track.lastApplied == .zero)
        track.lastApplied = windowRect
        track.consecutiveNotFound = 0

        // First-time positioning of this projector — dismiss the
        // loading state in JS so the user sees the projector content.
        if firstPlacement {
            dismissLoading(in: url)
        }
    }

    /// Maintain a borderless cream NSWindow positioned exactly over the
    /// Wine window's title bar. The user sees the game content within
    /// the embed area; the title bar visually disappears under our cover.
    private func syncCoverWindow(for url: String, titleBarRect: CGRect) {
        // titleBarRect is in AX top-origin global coords. Convert to
        // AppKit bottom-origin for NSWindow.setFrame.
        guard let primary = NSScreen.screens.first else { return }
        let bottomY = primary.frame.maxY - titleBarRect.origin.y - titleBarRect.height
        let appKitRect = NSRect(x: titleBarRect.origin.x, y: bottomY,
                                width:  titleBarRect.size.width,
                                height: titleBarRect.size.height)

        if let cover = coverWindows[url] {
            cover.setFrame(appKitRect, display: false)
            // Wine activates itself and raises its window when the user
            // interacts with it. Re-assert our cover above on every tick
            // so the title bar doesn't peek through.
            cover.orderFrontRegardless()
            return
        }
        let cover = NSWindow(
            contentRect: appKitRect,
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false)
        cover.isOpaque             = true
        cover.hasShadow            = false
        // Match the AG page bg (white) so the cover blends invisibly.
        cover.backgroundColor      = .white
        // popUpMenu (101) is above any normal window and even above
        // mainMenu (24). Wine's window stays at .normal even when
        // activated, so this guarantees the cover paints over the
        // title bar without competing for z-order each tick.
        cover.level                = NSWindow.Level.popUpMenu
        cover.collectionBehavior   = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        cover.ignoresMouseEvents   = true       // clicks pass through to embed area
        cover.orderFrontRegardless()
        coverWindows[url] = cover
    }

    private func tearDownCover(for url: String) {
        DispatchQueue.main.async { [weak self] in
            self?.coverWindows[url]?.orderOut(nil)
            self?.coverWindows.removeValue(forKey: url)
            self?.shadowMaskWindows[url]?.orderOut(nil)
            self?.shadowMaskWindows.removeValue(forKey: url)
        }
    }

    /// Sync a single shadow-mask NSWindow per DCR. The window sits at
    /// popUpMenu level over a rectangle slightly LARGER than the Wine
    /// frame; its content view is a ShadowMaskView that paints white
    /// EXCEPT inside a rounded-rect cutout matching Wine's frame, so
    /// the curved corners of Wine's chrome AND its drop shadow are
    /// both covered — the cutout's curves follow Wine's curves exactly.
    private func syncShadowMask(for url: String, wineFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let pad = Self.shadowMaskPadding
        let pY = primary.frame.maxY
        let wineBottomYInAppKit = pY - wineFrame.origin.y - wineFrame.size.height
        let outer = NSRect(
            x: wineFrame.origin.x - pad,
            y: wineBottomYInAppKit - pad,
            width:  wineFrame.size.width  + pad * 2,
            height: wineFrame.size.height + pad * 2)
        let innerInOuter = NSRect(
            x: pad, y: pad,
            width:  wineFrame.size.width,
            height: wineFrame.size.height)
        if let existing = shadowMaskWindows[url],
           let mask = existing.contentView as? ShadowMaskView {
            existing.setFrame(outer, display: false)
            mask.innerRect    = innerInOuter
            mask.cornerRadius = Self.wineCornerRadius
            mask.needsDisplay = true
            existing.orderFrontRegardless()
            return
        }
        let win = NSWindow(
            contentRect: outer,
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque             = false
        win.hasShadow            = false
        win.backgroundColor      = .clear
        win.level                = NSWindow.Level.popUpMenu
        win.collectionBehavior   = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents   = true
        let mask = ShadowMaskView(frame: NSRect(origin: .zero, size: outer.size))
        mask.innerRect    = innerInOuter
        mask.cornerRadius = Self.wineCornerRadius
        win.contentView   = mask
        win.orderFrontRegardless()
        shadowMaskWindows[url] = win
    }

    /// Convert a viewport-relative rect (CSS pixels) to a global screen
    /// rect in AppKit's bottom-origin coordinate space. AX API uses
    /// TOP-origin global coordinates (relative to the primary screen),
    /// so we flip at the end.
    private func screenRect(for layout: DesiredLayout) -> CGRect? {
        guard let wv = webView, let win = wv.window else { return nil }
        let wvBoundsInWindow = wv.convert(wv.bounds, to: nil)
        let pointInWindow = NSPoint(
            x: wvBoundsInWindow.origin.x + CGFloat(layout.frame.origin.x),
            y: wvBoundsInWindow.origin.y + wvBoundsInWindow.height
                - CGFloat(layout.frame.origin.y) - CGFloat(layout.frame.height))
        let rectInWindow = CGRect(origin: pointInWindow, size: layout.frame.size)
        let rectInScreen = win.convertToScreen(rectInWindow)

        // AX position is in top-origin global coords. Use the PRIMARY
        // screen's top-left as the origin — this works correctly even
        // when the window sits on a different screen, because AX
        // top-origin coordinates extend across all screens uniformly.
        guard let primary = NSScreen.screens.first else { return rectInScreen }
        let primaryFrame = primary.frame
        let topY = primaryFrame.maxY - rectInScreen.origin.y - rectInScreen.height
        return CGRect(x: rectInScreen.origin.x,
                      y: topY,
                      width:  rectInScreen.size.width,
                      height: rectInScreen.size.height)
    }

    // MARK: - AX window discovery

    /// Find the Wine-launched projector's on-screen window. Primary
    /// strategy uses CoreGraphics' CGWindowListCopyWindowInfo — a public
    /// API that enumerates ALL on-screen windows from ALL processes
    /// with their owner PID + bounds. Much more reliable than AX-driven
    /// process traversal on modern Wine, which forks/execs through
    /// wineload → wine64-preloader → wine64 and ends up with the
    /// visible-window PID nowhere near our launched pid.
    ///
    /// Returns the *AX* element for the window — needed because position
    /// + size are write operations and only AX exposes those for other
    /// processes.
    private func findProjectorWindow(pid: pid_t) -> AXUIElement? {
        // Build candidate PID set: our launched pid + every descendant.
        var pidCandidates = Set<pid_t>([pid])
        for d in descendantPIDs(of: pid) { pidCandidates.insert(d) }

        // Enumerate windows. Drop .optionOnScreenOnly — Wine sometimes
        // creates windows that aren't immediately classified as on-screen,
        // and we want to catch them as soon as they exist.
        let opts: CGWindowListOption = [.excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []

        var best: (pid: pid_t, width: CGFloat, height: CGFloat, ownerName: String, title: String, wid: CGSWindowID)?
        for win in windows {
            let owner = pid_t((win[kCGWindowOwnerPID as String] as? Int) ?? 0)
            let layer = (win[kCGWindowLayer  as String] as? Int) ?? 0
            // Only "regular" windows (layer 0). Helps skip background
            // panels Wine might create.
            guard layer == 0 else { continue }
            let bounds = win[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let w = bounds["Width"]  ?? 0
            let h = bounds["Height"] ?? 0
            if w < 100 || h < 80 { continue }

            let ownerName = (win[kCGWindowOwnerName as String] as? String) ?? ""
            let title     = (win[kCGWindowName       as String] as? String) ?? ""
            let lowerOwner = ownerName.lowercased()
            let lowerTitle = title.lowercased()

            // Match by either:
            //   • owner pid in our wine descendant tree (reliable)
            //   • process name / window title contains a Wine/Director marker
            //   • title contains "Trampoline" / "Macintosh Projector"
            //     (the actual title we saw on Director-projected games)
            let pidMatch = pidCandidates.contains(owner)
            let nameMatch = lowerOwner.contains("wine")
                || lowerOwner.contains("preloader")
                || lowerOwner.contains("projector")
                || lowerOwner.contains("director")
                || lowerOwner.contains("pj12")
                || lowerOwner.contains("spr")
                || lowerTitle.contains("director")
                || lowerTitle.contains("projector")
                || lowerTitle.contains("trampoline")
                || lowerTitle.contains("macintosh")
                || lowerTitle.contains(".dcr")
            if !pidMatch && !nameMatch { continue }

            // Prefer the largest matching window (Director's main canvas).
            let cgsID = CGSWindowID((win[kCGWindowNumber as String] as? Int) ?? 0)
            if best == nil || w * h > best!.width * best!.height {
                best = (owner, w, h, ownerName, title, cgsID)
            }
        }

        guard let chosen = best else {
            // Dump the full window inventory when the count grows — that's
            // a signal a NEW window just appeared. Keeps the log readable
            // (one dump per inventory change) while still catching Wine's
            // window the moment it shows up in CGWindowList.
            if !loggedNoMatch.contains(windows.count) {
                loggedNoMatch.insert(windows.count)
                var lines: [String] = []
                for win in windows {
                    let owner = (win[kCGWindowOwnerPID  as String] as? Int) ?? 0
                    let name  = (win[kCGWindowOwnerName as String] as? String) ?? "?"
                    let title = (win[kCGWindowName       as String] as? String) ?? ""
                    let bounds = win[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                    let layer = (win[kCGWindowLayer as String] as? Int) ?? 0
                    let onScreen = (win[kCGWindowIsOnscreen as String] as? Bool) ?? false
                    lines.append("  pid=\(owner) name='\(name)' title='\(title)' size=\(Int(bounds["Width"] ?? 0))×\(Int(bounds["Height"] ?? 0)) layer=\(layer) onScreen=\(onScreen)")
                }
                agdLog("windows snapshot at \(windows.count) windows:\n" + lines.joined(separator: "\n"))
            }
            return nil
        }
        if !loggedFoundPIDs.contains(chosen.pid) {
            loggedFoundPIDs.insert(chosen.pid)
            agdLog("projector window found: pid=\(chosen.pid) wid=\(chosen.wid) size=\(Int(chosen.width))×\(Int(chosen.height)) ownerName='\(chosen.ownerName)' title='\(chosen.title)'")
        }
        // Kill the Wine window's native drop shadow via CGS — runs every
        // tick (idempotent + cheap), so even if Wine restores the shadow
        // we squash it again. Without this, the white shadow-mask frame
        // can't fully hide the shadow because it bleeds beyond our pad.
        disableShadow(forCGSWindowID: chosen.wid)
        return firstWindow(forPID: chosen.pid)
    }

    private func firstWindow(forPID pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var raw: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard err == .success, let windows = raw as? [AXUIElement] else { return nil }
        for win in windows {
            if isPlausibleProjectorWindow(win) { return win }
        }
        return windows.first
    }

    private func isPlausibleProjectorWindow(_ win: AXUIElement) -> Bool {
        // Filter out tiny tool windows / wine's hidden splashes by
        // requiring at least 200×150 size. Director projectors are
        // typically 400×300 minimum.
        var sizeRaw: AnyObject?
        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRaw) == .success,
           let axval = sizeRaw, CFGetTypeID(axval) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(axval as! AXValue, .cgSize, &size) {
                return size.width >= 100 && size.height >= 80
            }
        }
        return true
    }

    /// Every pid → ppid pair on the system, from a single `sysctl` call.
    ///
    /// This replaces a recursive `pgrep -P` shell-out. Foundation's
    /// `Process.waitUntilExit()` has a fixed ~67 ms floor per invocation
    /// (it polls the run loop in a private mode), so the old implementation
    /// cost (1 + descendants) × 67 ms — and it ran on the main thread from
    /// `tick()` at 60 Hz for as long as the projector window had not yet
    /// appeared. On a first launch, where Wine bootstraps a fresh WINEPREFIX
    /// before Director ever opens a window, that is tens of seconds of solid
    /// main-thread blocking: the app beachballs on its headline interaction.
    ///
    /// One sysctl costs microseconds and never forks.
    private static func processParentMap() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }

        // Ask for headroom: processes can appear between the sizing call and
        // the fetch, and sysctl fails with ENOMEM rather than truncating.
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = size / stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride
        let ok = procs.withUnsafeMutableBytes { buf -> Bool in
            sysctl(&mib, 4, buf.baseAddress, &size, nil, 0) == 0
        }
        guard ok else { return [:] }

        var map: [pid_t: pid_t] = [:]
        let count = size / stride
        map.reserveCapacity(count)
        for i in 0..<count {
            let pid = procs[i].kp_proc.p_pid
            if pid != 0 { map[pid] = procs[i].kp_eproc.e_ppid }
        }
        return map
    }

    private func descendantPIDs(of parent: pid_t) -> [pid_t] {
        let parentOf = Self.processParentMap()
        guard !parentOf.isEmpty else { return [] }

        var childrenOf: [pid_t: [pid_t]] = [:]
        childrenOf.reserveCapacity(parentOf.count)
        for (pid, ppid) in parentOf { childrenOf[ppid, default: []].append(pid) }

        var out: [pid_t] = []
        var seen: Set<pid_t> = [parent]
        var stack: [pid_t] = [parent]
        while let current = stack.popLast() {
            for child in childrenOf[current] ?? [] where !seen.contains(child) {
                seen.insert(child)
                out.append(child)
                stack.append(child)
            }
        }
        return out
    }

    // MARK: - AX write helpers

    /// Read the window's current position+size via AX so we can detect
    /// when something else (Director's startup centering, a tiling WM,
    /// the user dragging the window manually) has moved it away from
    /// where we put it last.
    private func currentWindowFrame(_ win: AXUIElement) -> CGRect? {
        var posRaw: AnyObject?
        var sizeRaw: AnyObject?
        let pe = AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRaw)
        let se = AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRaw)
        guard pe == .success, se == .success,
              let pAX = posRaw, let sAX = sizeRaw,
              CFGetTypeID(pAX) == AXValueGetTypeID(),
              CFGetTypeID(sAX) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(pAX as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sAX as! AXValue, .cgSize, &sz)
        else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private func setWindowFrame(_ win: AXUIElement, position: CGPoint, size: CGSize) {
        var p = position
        var posErr: AXError = .success
        if let posValue = AXValueCreate(.cgPoint, &p) {
            posErr = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posValue)
        }
        var s = size
        var sizeErr: AXError = .success
        if let sizeValue = AXValueCreate(.cgSize, &s) {
            sizeErr = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeValue)
        }
        if !firstWriteLogged {
            firstWriteLogged = true
            // Read back the ACTUAL frame Wine accepted, so we can see
            // any drift between what we asked for and what landed.
            let actual = currentWindowFrame(win)
            agdLog("AX FIRST setWindowFrame: intended pos=(\(Int(position.x)),\(Int(position.y))) size=(\(Int(size.width))×\(Int(size.height))) -> actual=\(actual.map { "(\(Int($0.origin.x)),\(Int($0.origin.y))) \(Int($0.size.width))×\(Int($0.size.height))" } ?? "nil") posErr=\(posErr.rawValue) sizeErr=\(sizeErr.rawValue) trusted=\(AXIsProcessTrusted())")
        }
        if posErr != .success || sizeErr != .success {
            // Log once per failure mode — repeating every tick would spam.
            if loggedAXErrors.insert("\(posErr.rawValue)/\(sizeErr.rawValue)").inserted {
                agdLog("AX setWindowFrame failed pos=\(posErr.rawValue) size=\(sizeErr.rawValue) — likely Accessibility permission denied. AXIsProcessTrusted=\(AXIsProcessTrusted())")
            }
        }
    }
    private var loggedAXErrors = Set<String>()
    private var loggedNoMatch  = Set<Int>()
    private var loggedFoundPIDs = Set<pid_t>()
    private var firstWriteLogged = false
    private var loggedMissingLayout = Set<String>()
    private var loggedNoScreenRect = false

    // MARK: - Permission prompt

    /// Single source of truth for AX trust + the user-facing path to grant
    /// it. Returns true if trusted now; false otherwise (caller aborts).
    /// ONLY ONE dialog — our custom NSAlert. The system-provided AX prompt
    /// is suppressed (we don't call AXIsProcessTrustedWithOptions(prompt:true))
    /// because it gives the user no useful information beyond "Open Settings"
    /// and shows up as a redundant second window. Our modal has the full
    /// instructions + a one-click "Open Settings + Quit" action.
    static func ensureAXTrust() -> Bool {
        if AXIsProcessTrusted() { return true }
        let alert = NSAlert()
        alert.messageText = "One-time setup needed to embed the Director game"
        alert.informativeText = """
            Summer 2008 needs macOS Accessibility permission to position the bundled Director projector inside the page. Without it the game plays in a loose window.

            What to do (about 15 seconds):
            1. Click "Open Settings + Quit" below — System Settings opens to the right pane and Summer 2008 closes.
            2. Toggle "Summer 2008 — An American Girl Archive" on (you'll be password-prompted).
            3. Reopen Summer 2008. The permission is active from the moment the app starts.

            You only do this once.
            """
        alert.addButton(withTitle: "Open Settings + Quit")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            // Give System Settings a beat to surface before we quit, so
            // the user sees the right pane open as we exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        }
        return false
    }

    // MARK: - JS callback

    private func dismissLoading(in dcrURL: String) {
        // Tell flash-bridge.js to remove the .is-loading state from the
        // stub whose URL matches. We can't call the inner function
        // reference directly, but we can iterate window.__AGD_DCR_STUBS__.
        DispatchQueue.main.async { [weak self] in
            guard let wv = self?.webView as? WKWebView else { return }
            let js = """
            (function () {
              var stubs = window.__AGD_DCR_STUBS__ || [];
              for (var i = 0; i < stubs.length; i++) {
                if (stubs[i].__agdDismissLoading) {
                  stubs[i].__agdDismissLoading();
                }
              }
            })();
            """
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Called from GameLauncher.swift's terminationHandler when the
    /// projector process exits. Tears down our overlay cover + tells
    /// flash-bridge.js to flip the embed-area stub back to its idle
    /// "click to play" appearance.
    func projectorDidExit(dcrURL: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tracks.removeValue(forKey: dcrURL)
            self.tearDownCover(for: dcrURL)
            guard let wv = self.webView as? WKWebView else { return }
            let js = """
            (function () {
              var stubs = window.__AGD_DCR_STUBS__ || [];
              for (var i = 0; i < stubs.length; i++) {
                if (stubs[i].__agdProjectorClosed) {
                  stubs[i].__agdProjectorClosed();
                }
              }
              // Reset the page-scoped autolaunch flag so the next visit
              // (e.g., back-then-forward) auto-launches again.
              window.__AGD_DCR_AUTOLAUNCHED__ = false;
            })();
            """
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        tickTimer?.invalidate()
    }
}
