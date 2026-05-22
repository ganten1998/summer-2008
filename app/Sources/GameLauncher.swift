import AppKit
import Foundation

/// Resolves an `agd://` or `agd-launch://` URL to a real on-disk file and
/// opens it with the right external player:
///   * `.swf` → bundled Flash Player.app (Adobe standalone projector)
///   * `.dcr` → bundled Wine + Director projector (Director 12 by default)
///
/// Both projector chains live under `Contents/Resources/` so the .app is
/// fully self-contained; nothing outside the bundle is required at runtime.
final class GameLauncher {
    static let shared = GameLauncher()

    private let bundleResources: URL
    private let flashProjectorURL: URL?

    /// Director projector executable to use for .dcr files. PJ12 (Director
    /// 12) is the newest version Flashpoint ships and plays the broadest
    /// range of 2005–2008-era AG content. We can add per-game overrides
    /// later if a specific game needs an older runtime.
    private let directorProjectorRelPath = "Shockwave/PJ12/SPR.exe"

    init() {
        let res = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        self.bundleResources = res
        let flash = res.appendingPathComponent("Flash Player.app")
        self.flashProjectorURL = FileManager.default.fileExists(atPath: flash.path) ? flash : nil
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
            launchDCR(at: assetPath)
        default:
            // Unknown extension — try the Flash projector and hope for the best.
            launchSWF(at: assetPath)
        }
    }

    // MARK: - SWF (Adobe Flash standalone projector)

    private func launchSWF(at swfPath: URL) {
        guard let projector = flashProjectorURL else {
            presentNoFlashProjector(swfPath: swfPath)
            return
        }

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        // Don't also set cfg.arguments to the SWF path — NSWorkspace.open()
        // already passes [swfPath] to the projector. Setting both makes
        // Flash Player open the same file twice and pop two windows.
        NSWorkspace.shared.open([swfPath], withApplicationAt: projector, configuration: cfg) { _, err in
            if let err = err {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't launch the Flash projector"
                    alert.informativeText = err.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - DCR (Adobe Shockwave Director, via Wine)

    private func launchDCR(at dcrPath: URL) {
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
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't launch the Shockwave projector"
                alert.informativeText = "Wine failed to start:\n\(error.localizedDescription)\n\nGame: \(dcrPath.lastPathComponent)"
                alert.runModal()
            }
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

    private func presentNoFlashProjector(swfPath: URL) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Missing Flash Projector"
            alert.informativeText = "Couldn't find the bundled Flash Player.app at:\n\(self.bundleResources.appendingPathComponent("Flash Player.app").path)\n\nThe game is at: \(swfPath.path)"
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
