import AppKit
import Foundation

/// Resolves an `agd://` or `agd-launch://` URL to a real on-disk file and
/// opens it with the right external player:
///   * `.swf` → bundled Wine + Flash 32 standalone projector (Windows EXE)
///   * `.dcr` → bundled Wine + Director projector (Director 12 by default)
///
/// Both projector chains are Wine-driven and live under `Contents/Resources/`
/// so the .app is fully self-contained; nothing outside the bundle is
/// required at runtime.
final class GameLauncher {
    static let shared = GameLauncher()

    private let bundleResources: URL

    /// Per-DCR running projector tracking. Each click on the Director stub
    /// would otherwise spawn a fresh Wine/projector process; if one is
    /// already running for the same .dcr, we bring its window to front
    /// instead of doubling up.
    private var runningDCRProcesses: [String: Process] = [:]
    private let dcrLock = NSLock()

    /// Singleton overlay manager that positions the projector window over
    /// the embed area in the WebView. Set by AppDelegate after the window
    /// + webview are constructed.
    var overlay: ProjectorOverlay?

    /// Look up the PID of a running projector by its DCR URL/path. Used
    /// by ProjectorOverlay to re-target the right window when the user
    /// moves/resizes the host window or scrolls the page.
    func runningPID(forDCR url: String) -> Int32 {
        dcrLock.lock(); defer { dcrLock.unlock() }
        for (key, proc) in runningDCRProcesses where proc.isRunning {
            // Match either the resolved-file path or just the leaf name,
            // since flash-bridge.js reports the agd:// URL.
            if key == url || url.hasSuffix(((key as NSString).lastPathComponent)) {
                return proc.processIdentifier
            }
        }
        return 0
    }

    /// Director projector executable to use for .dcr files. PJ12 (Director
    /// 12) is the newest version Flashpoint ships and plays the broadest
    /// range of 2005–2008-era AG content. We can add per-game overrides
    /// later if a specific game needs an older runtime.
    private let directorProjectorRelPath = "Shockwave/PJ12/SPR.exe"

    /// Flash 32 standalone projector executable. Windows EXE driven by the
    /// same bundled Wine that runs the Shockwave projector — keeps the
    /// .app fully self-contained and avoids needing a macOS-native
    /// Flash Player.app (Adobe stopped shipping those long before 2008's
    /// content needed preserving anyway).
    private let flashProjectorRelPath = "Flash/flashplayer_32_sa.exe"

    init() {
        let res = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        self.bundleResources = res
    }

    func launch(originalURL: URL) {
        guard let assetPath = resolve(url: originalURL) else {
            presentMissing(url: originalURL)
            return
        }

        let ext = assetPath.pathExtension.lowercased()
        switch ext {
        case "swf":
            launchSWF(at: assetPath)
        case "dcr":
            // Pass the original agd:// URL through to launchDCR so the
            // overlay-track key matches what flash-bridge.js posts via
            // the dcrRect message handler. Without this they're tracked
            // under different keys (local file path vs agd:// URL) and
            // ProjectorOverlay.apply silently returns when it can't find
            // the matching layout.
            launchDCR(at: assetPath, originalURL: originalURL)
        default:
            // Unknown extension — try the Flash projector and hope for the best.
            launchSWF(at: assetPath)
        }
    }

    // MARK: - SWF (Wine + Flash 32 standalone projector)

    private func launchSWF(at swfPath: URL) {
        let wineDir = bundleResources.appendingPathComponent("Wine", isDirectory: true)
        let wineload = wineDir
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("wineload")
        let projector = bundleResources
            .appendingPathComponent(flashProjectorRelPath)

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: wineload.path) else {
            presentNoWine(dcrPath: swfPath, wineload: wineload)
            return
        }
        guard fm.fileExists(atPath: projector.path) else {
            presentNoFlashProjector(swfPath: swfPath, projector: projector)
            return
        }

        // Same WINEPREFIX as the Director projector. First run bootstraps;
        // subsequent runs (Flash or Director) reuse it.
        let prefix = applicationSupportRoot()
            .appendingPathComponent("wineprefix", isDirectory: true)
        try? fm.createDirectory(at: prefix.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        ensureNativeWineChrome(prefix: prefix)

        let task = Process()
        task.executableURL = wineload
        task.arguments = [projector.path, swfPath.path]

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEARCH"] = "wow64"
        env["DYLD_FALLBACK_LIBRARY_PATH"] =
            wineDir.appendingPathComponent("lib").path
        env["WINEDEBUG"] = "fixme-all,err-all"
        task.environment = env
        task.currentDirectoryURL = wineDir

        do {
            try task.run()
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't launch the Flash projector"
                alert.informativeText = "Wine failed to start:\n\(error.localizedDescription)\n\nGame: \(swfPath.lastPathComponent)"
                alert.runModal()
            }
        }
    }

    // MARK: - DCR (Adobe Shockwave Director, via Wine)

    private func launchDCR(at dcrPath: URL, originalURL: URL? = nil) {
        // Gate the launch behind Accessibility trust. Without AX we can't
        // position the Wine window, so we'd just produce a centered loose
        // window — bad UX, and exactly what's been frustrating to debug.
        // Show ONE modal explaining the fix + quit option, then return.
        if !ProjectorOverlay.ensureAXTrust() {
            return
        }

        // Track + overlay key = the agd:// URL form. JS posts under that
        // exact URL; the agd-launch:// scheme is only used to trigger
        // the NavigationHandler intercept. Normalize so both sides agree.
        let rawKey = originalURL?.absoluteString ?? dcrPath.path
        let key = rawKey.replacingOccurrences(of: "agd-launch://", with: "agd://")

        // Already running for this DCR?  Bring its window to front instead
        // of spawning another instance. Without this, every relaunch-pill
        // click stacks up a new Wine+Director process tree.
        dcrLock.lock()
        if let existing = runningDCRProcesses[key], existing.isRunning {
            let pid = existing.processIdentifier
            dcrLock.unlock()
            activateRunningProjector(pid: pid)
            // Also re-emit positioning since the host window may have moved
            // since the projector last positioned itself.
            overlay?.refresh(dcrURL: key, pid: pid)
            return
        }
        runningDCRProcesses.removeValue(forKey: key)
        dcrLock.unlock()

        let wineDir = bundleResources.appendingPathComponent("Wine", isDirectory: true)
        let wineload = wineDir
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("wineload")
        let projector = bundleResources
            .appendingPathComponent("Shockwave", isDirectory: true)
            .appendingPathComponent(String(directorProjectorRelPath.dropFirst("Shockwave/".count)))

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: wineload.path) else {
            presentNoWine(dcrPath: dcrPath, wineload: wineload)
            return
        }
        guard fm.fileExists(atPath: projector.path) else {
            presentNoDirectorProjector(dcrPath: dcrPath, projector: projector)
            return
        }

        // Wine needs a writable WINEPREFIX. Keep it under Application
        // Support so it persists across runs (first run is slow because
        // Wine bootstraps the prefix; subsequent runs reuse it).
        let prefix = applicationSupportRoot()
            .appendingPathComponent("wineprefix", isDirectory: true)
        try? fm.createDirectory(at: prefix.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        // Restore Wine's native macOS chrome (Decorated=Y) — the user
        // wants the projector to be a fully draggable, freely-resizable
        // standard window with a normal title bar. Reverts the earlier
        // Decorated=N borderless setting.
        ensureNativeWineChrome(prefix: prefix)

        let task = Process()
        task.executableURL = wineload
        task.arguments = [projector.path, dcrPath.path]

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        // WoW64 is the modern macOS-friendly Wine arch (matches Flashpoint's
        // wine script choice on Catalina+).
        env["WINEARCH"] = "wow64"
        env["DYLD_FALLBACK_LIBRARY_PATH"] =
            wineDir.appendingPathComponent("lib").path
        // Quiet Wine's chatty fixme/err logs so the user's Console isn't
        // spammed during gameplay; Director itself prints anything important.
        env["WINEDEBUG"] = "fixme-all,err-all"
        task.environment = env

        // Run from the Wine root so Wine resolves its own relative paths
        // (gnutls config, fontconfig defaults) without surprises.
        task.currentDirectoryURL = wineDir

        do {
            try task.run()
            // Track the running process so subsequent clicks reuse it.
            dcrLock.lock()
            runningDCRProcesses[key] = task
            dcrLock.unlock()
            // Drop the entry when the projector quits, so a fresh launch
            // after closing the window starts a new instance cleanly.
            // Also signal the WebView so the JS stub reverts to its
            // "click to play" appearance from the loading state.
            task.terminationHandler = { [weak self] _ in
                guard let self = self else { return }
                self.dcrLock.lock()
                self.runningDCRProcesses.removeValue(forKey: key)
                self.dcrLock.unlock()
                self.overlay?.projectorDidExit(dcrURL: key)
            }
            // Hand off to the overlay manager: it polls for the new Wine
            // window and positions it directly over the embed area in the
            // WebView, then continues following the host window's frame.
            overlay?.track(dcrURL: key, pid: task.processIdentifier)
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't launch the Shockwave projector"
                alert.informativeText = "Wine failed to start:\n\(error.localizedDescription)\n\nGame: \(dcrPath.lastPathComponent)"
                alert.runModal()
            }
        }
    }

    /// Kill every running Wine/Director projector child. Called from
    /// AppDelegate.applicationWillTerminate so closing the host app
    /// doesn't leave orphan projector windows on screen.
    ///
    /// MUST be synchronous — applicationWillTerminate returns and the
    /// process exits immediately, so async work (e.g. scheduled SIGKILL
    /// after a delay) never runs. We send SIGKILL synchronously to
    /// every tracked process AND every named wine binary on the system.
    func terminateAllProjectors() {
        dcrLock.lock()
        let snapshot = runningDCRProcesses
        dcrLock.unlock()
        for (_, proc) in snapshot {
            let pid = proc.processIdentifier
            // SIGTERM the wineload parent so it can clean up.
            proc.terminate()
            // Then SIGKILL the whole subtree immediately — when our
            // process exits, Wine descendants get reparented to launchd
            // and would otherwise linger as orphan windows on screen.
            killDescendants(of: pid)
            kill(pid, SIGKILL)
        }
        // Blanket sweep: any wine binary on the system. Synchronous so
        // it completes before we exit.
        for name in ["wine-preloader", "Projector.exe", "SPR.exe", "PJ12.exe"] {
            let task = Process()
            task.launchPath = "/usr/bin/pkill"
            task.arguments  = ["-9", "-f", name]
            try? task.run()
            task.waitUntilExit()
        }
    }

    /// Walk + SIGKILL every descendant of the given pid via pgrep -P.
    private func killDescendants(of parent: Int32) {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments  = ["-P", String(parent)]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            if let p = Int32(line.trimmingCharacters(in: .whitespaces)) {
                killDescendants(of: p)
                kill(p, SIGKILL)
            }
        }
    }

    /// Bring a running Wine projector's window to front so the user sees
    /// the existing game window instead of getting a fresh one stacked
    /// behind. We can't manipulate Wine's NSWindow directly (different
    /// process), but `NSRunningApplication.activate` works on any pid we
    /// own (Wine inherits permissions from our process).
    private func activateRunningProjector(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        DispatchQueue.main.async {
            app.activate(options: [.activateAllWindows])
        }
    }

    /// Write the registry entry that tells Wine's Cocoa Mac driver to
    /// NOT wrap its windows in macOS chrome (no title bar, no shadow,
    /// no rounded corners). The correct key per CodeWeavers docs is:
    ///
    ///     HKEY_CURRENT_USER\Software\Wine\Mac Driver
    ///     "Decorated" = "N"
    ///
    /// (Earlier I tried "WindowDecorations" — that's the X11 driver's
    /// equivalent, not Mac driver's, and Wine ignored it. The Mac
    /// driver source uses "Decorated".)
    ///
    /// Wine reads user.reg at process start. Appending our key BEFORE
    /// each launch guarantees the next-spawned projector window comes
    /// up borderless from frame zero.
    /// Make sure user.reg does NOT contain a "Decorated"="N" override.
    /// We want Wine's native macOS title bar so the projector is a
    /// fully draggable standalone window — the QoL trade the user
    /// chose over the fake-embed illusion.
    private func ensureNativeWineChrome(prefix: URL) {
        let userReg = prefix.appendingPathComponent("user.reg")
        let fm = FileManager.default
        guard fm.fileExists(atPath: userReg.path),
              let existing = try? String(contentsOf: userReg, encoding: .utf8)
        else { return }
        var cleaned = existing
        cleaned = cleaned.replacingOccurrences(
            of: "\"Decorated\"=\"N\"\n", with: "")
        cleaned = cleaned.replacingOccurrences(
            of: "\"WindowDecorations\"=\"N\"\n", with: "")
        if cleaned != existing {
            try? cleaned.write(to: userReg, atomically: true, encoding: .utf8)
        }
    }

    private func ensureBorderlessWineConfig(prefix: URL) {
        let userReg = prefix.appendingPathComponent("user.reg")
        let macDriverEntry =
            "\n[Software\\\\Wine\\\\Mac Driver] 1234567890\n" +
            "\"Decorated\"=\"N\"\n"
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: userReg.path) {
                let existing = try String(contentsOf: userReg, encoding: .utf8)
                if existing.contains("\"Decorated\"=\"N\"") { return }
                // Strip any older incorrect key we wrote on previous builds
                // so the section stays clean.
                var cleaned = existing
                cleaned = cleaned.replacingOccurrences(
                    of: "\"WindowDecorations\"=\"N\"\n", with: "")
                let appended = cleaned + macDriverEntry
                try appended.write(to: userReg, atomically: true, encoding: .utf8)
            } else {
                // Prefix not yet bootstrapped — pre-seed user.reg.
                let header = "WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n"
                try (header + macDriverEntry).write(to: userReg, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("AGD: couldn't seed borderless Wine config: \(error)")
        }
    }

    // MARK: - Asset resolution

    /// Look in the curated `games/` directory first (Flashpoint-sourced
    /// repairs), then fall back to the asset as it was originally mirrored.
    private func resolve(url: URL) -> URL? {
        let host = (url.host ?? "").lowercased()
        let path = url.path
        let curated = bundleResources
            .appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        if FileManager.default.fileExists(atPath: curated.path) { return curated }

        let mirrored = bundleResources
            .appendingPathComponent("mirror", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        if FileManager.default.fileExists(atPath: mirrored.path) { return mirrored }

        return nil
    }

    private func applicationSupportRoot() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Summer 2008", isDirectory: true)
    }

    // MARK: - Alerts

    private func presentMissing(url: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Game not available in archive"
            alert.informativeText = "We don't have a working copy of:\n\(url.absoluteString)"
            alert.runModal()
        }
    }

    private func presentNoFlashProjector(swfPath: URL, projector: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Missing Flash Projector"
            alert.informativeText = "Couldn't find the bundled Flash standalone projector at:\n\(projector.path)\n\nThe game is at: \(swfPath.path)"
            alert.runModal()
        }
    }

    private func presentNoWine(dcrPath: URL, wineload: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Shockwave runtime missing"
            alert.informativeText = "Couldn't find the bundled Wine binary at:\n\(wineload.path)\n\nShockwave (.dcr) games need Wine + the Director projector — they ship inside this app's Resources folder. Reinstalling Summer 2008 should restore them.\n\nGame: \(dcrPath.lastPathComponent)"
            alert.runModal()
        }
    }

    private func presentNoDirectorProjector(dcrPath: URL, projector: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Director projector missing"
            alert.informativeText = "Couldn't find the bundled Director projector at:\n\(projector.path)\n\nGame: \(dcrPath.lastPathComponent)"
            alert.runModal()
        }
    }
}
