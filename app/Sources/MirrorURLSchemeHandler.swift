import Foundation
import WebKit
import UniformTypeIdentifiers

/// Handles `agd://` URL requests by serving content from the on-disk mirror
/// shipped inside the app bundle (or the user's Application Support cache for
/// content backfilled from Wayback on demand).
///
/// URL layout:
///   agd://dashboard/<path>           -> Resources/dashboard/<path>
///   agd://<original-host>/<path>     -> Resources/mirror/<original-host>/<path>
///                                       (falls back to live Wayback fetch)
///
/// Files backfilled at runtime are cached under
/// `~/Library/Application Support/AGD Launcher/cache/<host>/<path>` so that
/// the read-only app bundle isn't mutated.
final class MirrorURLSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Anchor timestamp for any Wayback backfill. Matches the snapshot we're
    /// presenting -- if Wayback doesn't have that URL on this date, the helper
    /// will gracefully widen the window in MirrorBackfiller.
    static let snapshotTimestamp = "20080711092743"

    private let session: URLSession
    private let bundleResources: URL
    private let cacheRoot: URL
    private let queue = DispatchQueue(label: "agd.url-handler", qos: .userInitiated, attributes: .concurrent)
    private var inFlight: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var stoppedKeys = Set<ObjectIdentifier>()   // tasks WKWebView has already cancelled
    private let inFlightLock = NSLock()

    override init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = [
            "User-Agent": "AGD-Launcher/1.0 (offline preservation)",
        ]
        cfg.requestCachePolicy = .useProtocolCachePolicy
        self.session = URLSession(configuration: cfg)

        self.bundleResources = Bundle.main.resourceURL
            ?? URL(fileURLWithPath: ".")

        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let appCache = (support ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("AGD Launcher", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        self.cacheRoot = appCache

        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "agd", code: 400))
            return
        }
        queue.async { [weak self] in
            self?.serve(urlSchemeTask, url: url)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        inFlightLock.lock()
        stoppedKeys.insert(key)
        let task = inFlight.removeValue(forKey: key)
        inFlightLock.unlock()
        task?.cancel()
    }

    // MARK: - Routing

    private func serve(_ task: WKURLSchemeTask, url: URL) {
        let host = (url.host ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path

        if host == "dashboard" {
            serveDashboard(task: task, url: url, path: path)
            return
        }
        if host == "runtime" {
            serveRuntime(task: task, url: url, path: path)
            return
        }
        if host == "games" {
            serveGameAsset(task: task, url: url, path: path)
            return
        }
        // Otherwise it's a mirror URL.
        serveMirror(task: task, url: url, host: host, path: path)
    }

    private func serveRuntime(task: WKURLSchemeTask, url: URL, path: String) {
        // Cross-origin preference store. All pages (dashboard, mirror at any
        // host, runtime player) share one source of truth via this endpoint,
        // so the volume slider — and any future setting — feels seamless
        // across the whole app instead of per-origin localStorage.
        //
        //   GET   agd://runtime/__prefs__/<key>   -> {"value": <stored or null>}
        //   PUT   agd://runtime/__prefs__/<key>   body = raw JSON value, stores
        if path.hasPrefix("/__prefs__/") {
            servePrefs(task: task, url: url, key: String(path.dropFirst("/__prefs__/".count)))
            return
        }
        let resolved = bundleResources
            .appendingPathComponent("mirror-runtime", isDirectory: true)
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        respondWithFile(task: task, url: url, file: resolved)
    }

    // MARK: - Prefs store

    private static let prefsLock = NSLock()
    private static var prefsCache: [String: Any]?

    private func prefsFileURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("Summer 2008", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prefs.json")
    }

    private func loadPrefs() -> [String: Any] {
        Self.prefsLock.lock(); defer { Self.prefsLock.unlock() }
        if let cached = Self.prefsCache { return cached }
        let url = prefsFileURL()
        if let data = try? Data(contentsOf: url),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            Self.prefsCache = dict
            return dict
        }
        Self.prefsCache = [:]
        return [:]
    }

    private func storePref(_ key: String, value: Any?) {
        Self.prefsLock.lock(); defer { Self.prefsLock.unlock() }
        var dict = Self.prefsCache ?? [:]
        if value is NSNull || value == nil {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = value!
        }
        Self.prefsCache = dict
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: prefsFileURL(), options: [.atomic])
        }
    }

    private func servePrefs(task: WKURLSchemeTask, url: URL, key: String) {
        let method = task.request.httpMethod?.uppercased() ?? "GET"
        if key.isEmpty {
            respondJSON(task: task, url: url, status: 400, json: ["error": "missing key"])
            return
        }
        switch method {
        case "GET":
            let value = loadPrefs()[key] ?? NSNull()
            respondJSON(task: task, url: url, status: 200, json: ["value": value])
        case "PUT", "POST":
            // Body is the JSON-encoded value itself (number, string, bool, etc.).
            let body = task.request.httpBody ?? Data()
            let decoded = (try? JSONSerialization.jsonObject(
                with: body, options: [.fragmentsAllowed])) ?? NSNull()
            storePref(key, value: decoded)
            respondJSON(task: task, url: url, status: 200, json: ["ok": true])
        case "DELETE":
            storePref(key, value: nil)
            respondJSON(task: task, url: url, status: 200, json: ["ok": true])
        default:
            respondJSON(task: task, url: url, status: 405, json: ["error": "method"])
        }
    }

    private func respondJSON(task: WKURLSchemeTask, url: URL, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let resp = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "\(body.count)",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, PUT, POST, DELETE",
                "Access-Control-Allow-Headers": "Content-Type",
                "Cache-Control": "no-store",
            ])!
        let key = ObjectIdentifier(task)
        DispatchQueue.main.async { [weak self] in
            self?.inFlightLock.lock()
            let stopped = self?.stoppedKeys.contains(key) ?? true
            self?.stoppedKeys.remove(key)
            self?.inFlightLock.unlock()
            guard !stopped else { return }
            task.didReceive(resp)
            task.didReceive(body)
            task.didFinish()
        }
    }

    private func serveDashboard(task: WKURLSchemeTask, url: URL, path: String) {
        let resolved = bundleResources
            .appendingPathComponent("dashboard", isDirectory: true)
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        respondWithFile(task: task, url: url, file: resolved)
    }

    private func serveGameAsset(task: WKURLSchemeTask, url: URL, path: String) {
        let resolved = bundleResources
            .appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        respondWithFile(task: task, url: url, file: resolved)
    }

    private func serveMirror(task: WKURLSchemeTask, url: URL, host: String, path: String) {
        // 0a) IE-only stylesheet stub. Source HTML often includes
        //     <link rel="stylesheet" href="styles_ie6.css"> unconditionally
        //     (no <!--[if IE]--> wrapper), so WKWebView requests files that
        //     only ever applied to IE6/7. Serve a 0-byte 200 to short-circuit
        //     the mirror lookup → cache → Wayback round trip for ~24 dead refs.
        let leaf = (path as NSString).lastPathComponent.lowercased()
        if leaf.hasSuffix("_ie.css") || leaf.hasSuffix("_ie6.css") || leaf.hasSuffix("_ie7.css") {
            sendEmptyCSS(task: task, url: url)
            return
        }
        // 0b) Directory request without trailing slash. WebKit otherwise
        //     leaves the document URL as agd://host/movie (no slash), so
        //     relative refs like <link href="assets/styles.css"> resolve
        //     against "/movie" (treated as a file) → /assets/styles.css —
        //     wrong path, no CSS or images load. WKURLSchemeTask doesn't
        //     reliably follow 301 redirects, so instead serve the dir's
        //     index.html with an injected <base href="<path>/"> so the
        //     browser uses the right base for relative refs.
        var injectBaseHref: String? = nil
        if !path.hasSuffix("/") {
            // Bypass mirrorFileURL — it auto-appends /index.html to
            // extension-less paths, which would point us at the index file
            // (not the directory) and the isDirectory check would fail.
            // Build the raw on-disk path directly.
            let rawDir = bundleResources
                .appendingPathComponent("mirror", isDirectory: true)
                .appendingPathComponent(host, isDirectory: true)
                .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: rawDir.path, isDirectory: &isDir), isDir.boolValue {
                injectBaseHref = path + "/"
            }
        }
        // 0) Reserved synthetic paths -- served from mirror-runtime/ but using
        //    the mirror's host so the synthetic player page is same-origin
        //    with the SWFs/JS it loads. Without this, Ruffle's fetch sees a
        //    cross-origin SWF and refuses to play it.
        if path.hasPrefix("/__agd/") {
            let sub = String(path.dropFirst("/__agd/".count))
            let resolved = bundleResources
                .appendingPathComponent("mirror-runtime", isDirectory: true)
                .appendingPathComponent(sub)
            if FileManager.default.fileExists(atPath: resolved.path) {
                respondWithFile(task: task, url: url, file: resolved)
                return
            }
            sendNotFound(task: task, url: url)
            return
        }
        // 0a) Store / e-commerce subdomains: the URL filter deliberately
        //     dropped every store.americangirl.com URL because the e-commerce
        //     backend (cart, checkout, account, shop pages) can't function
        //     offline. Serve a styled "not in this archive" stub so clicking
        //     a SHOP link in the nav lands somewhere intentional instead of
        //     a bare 404.
        let storeHosts: Set<String> = [
            "store.americangirl.com",
            "stage.store.americangirl.com",
            "shop.americangirl.com",
            "club.americangirl.com",  // partial coverage only
            "aka.www.americangirl.com",
            "mollysblog.americangirl.com",
            "emailresp.americangirl.com",
            "mresponse.americangirl.com",
        ]
        if storeHosts.contains(host) {
            // Only intercept HTML-shaped requests; let actual static assets
            // (images, css) fall through to normal mirror lookup so club/
            // mollysblog imagery we DID grab still serves.
            let ext = (path as NSString).pathExtension.lowercased()
            let isAsset = ["jpg","jpeg","png","gif","ico","css","js","svg","woff","woff2","ttf"].contains(ext)
            if !isAsset {
                // Fall through to mirror lookup first — if we DO have a
                // capture for this host+path, prefer it.
                let mirrorURL = mirrorFileURL(host: host, path: path, query: url.query)
                if !FileManager.default.fileExists(atPath: mirrorURL.path) {
                    serveStoreStub(task: task, url: url, host: host)
                    return
                }
            }
        }
        // 1) Look in the bundled mirror.
        let mirrorURL = mirrorFileURL(host: host, path: path, query: url.query)
        if FileManager.default.fileExists(atPath: mirrorURL.path) {
            respondWithFile(task: task, url: url, file: mirrorURL, injectBaseHref: injectBaseHref)
            return
        }
        // 1a) Query-tolerant fallback. The mirror patcher rewrites
        //     http://www.americangirl.com inside SWF embed query strings
        //     to agd://www.americangirl.com — which changes the
        //     query-encoded filename so the exact path doesn't match.
        //     For binary assets (SWF/DCR/images/PDFs) the query just
        //     conveys runtime config; the file content is the same. Try
        //     base name (no __<query>) as a second look-up.
        if url.query != nil {
            let baseURL = mirrorFileURL(host: host, path: path, query: nil)
            if FileManager.default.fileExists(atPath: baseURL.path) {
                respondWithFile(task: task, url: url, file: baseURL)
                return
            }
            // Same fallback in the cache.
            let baseCache = cacheFileURL(host: host, path: path, query: nil)
            if FileManager.default.fileExists(atPath: baseCache.path) {
                respondWithFile(task: task, url: url, file: baseCache)
                return
            }
            // Glob fallback — any sibling with the same base name and any
            // __<query> suffix. Useful when the file was crawled with a
            // *different* query string than the one the page now requests.
            let dir = baseURL.deletingLastPathComponent()
            let stem = baseURL.lastPathComponent
            if let listing = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                let matches = listing.filter { $0 == stem || $0.hasPrefix(stem + "__") }
                    .sorted { $0.count < $1.count }  // prefer shortest (closest to base)
                if let pick = matches.first {
                    let alt = dir.appendingPathComponent(pick)
                    respondWithFile(task: task, url: url, file: alt)
                    return
                }
            }
        }
        // 2) Look in the runtime backfill cache.
        let cacheURL = cacheFileURL(host: host, path: path, query: url.query)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            respondWithFile(task: task, url: url, file: cacheURL)
            return
        }
        // 2a) Bare-host alias. Pages occasionally link to
        //     agd://americangirl.com/foo when the captured asset lives at
        //     agd://www.americangirl.com/foo (the redirect that the original
        //     server did before we froze the snapshot). Retry the on-disk
        //     lookups (mirror + query-strip + cache) under the www. variant
        //     before paying the Wayback round trip.
        if host == "americangirl.com" {
            let aliasHost = "www.americangirl.com"
            let aliasMirror = mirrorFileURL(host: aliasHost, path: path, query: url.query)
            if FileManager.default.fileExists(atPath: aliasMirror.path) {
                respondWithFile(task: task, url: url, file: aliasMirror)
                return
            }
            if url.query != nil {
                let aliasBase = mirrorFileURL(host: aliasHost, path: path, query: nil)
                if FileManager.default.fileExists(atPath: aliasBase.path) {
                    respondWithFile(task: task, url: url, file: aliasBase)
                    return
                }
            }
            let aliasCache = cacheFileURL(host: aliasHost, path: path, query: url.query)
            if FileManager.default.fileExists(atPath: aliasCache.path) {
                respondWithFile(task: task, url: url, file: aliasCache)
                return
            }
        }
        // 3) Fall back to live Wayback fetch.
        backfillFromWayback(task: task, url: url, host: host, path: path, cacheURL: cacheURL)
    }

    private static let silentMP3: Data = {
        // Properly-framed 1-second silent MP3 (with ID3v2 header) loaded
        // from app/Resources/mirror-runtime/silent.mp3. Ruffle's audio
        // decoder rejects bare null frames as malformed and never fires
        // Sound.onLoad — only a valid MP3 keeps the SWF's state machine
        // moving past the audio-load callback.
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "silent", withExtension: "mp3",
                                subdirectory: "mirror-runtime"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        // Last-ditch fallback if the resource didn't ship for any reason.
        var bytes: [UInt8] = [0xff, 0xfb, 0x10, 0x64]
        bytes.append(contentsOf: Array(repeating: 0, count: 28))
        return Data(bytes)
    }()

    private func sendSilentAudio(task: WKURLSchemeTask, url: URL) {
        // Properly-framed silent MP3 from disk. Enough for Sound.loadSound()
        // / Sound.onLoad to fire success and let the calling AS2/AS3 state
        // machine proceed; the audio simply plays silence. Saves the
        // day-select / play-callback handlers in games that gate progress
        // on audio readiness (Josefina market, etc.) when the original
        // mp3 wasn't preserved in any archive.
        let body = Self.silentMP3
        let resp = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/mpeg",
                "Content-Length": "\(body.count)",
                "Access-Control-Allow-Origin": "*",
                "X-AGD-Source": "silent-audio-stub",
            ]
        )!
        let key = ObjectIdentifier(task)
        DispatchQueue.main.async { [weak self] in
            self?.inFlightLock.lock()
            let stopped = self?.stoppedKeys.contains(key) ?? true
            self?.stoppedKeys.remove(key)
            self?.inFlightLock.unlock()
            guard !stopped else { return }
            task.didReceive(resp)
            task.didReceive(body)
            task.didFinish()
        }
    }

    private func sendEmptyCSS(task: WKURLSchemeTask, url: URL) {
        let body = Data()
        let resp = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/css; charset=utf-8",
                "Content-Length": "0",
                "Cache-Control": "max-age=31536000",
            ]
        )!
        let key = ObjectIdentifier(task)
        DispatchQueue.main.async { [weak self] in
            self?.inFlightLock.lock()
            let stopped = self?.stoppedKeys.contains(key) ?? true
            self?.stoppedKeys.remove(key)
            self?.inFlightLock.unlock()
            guard !stopped else { return }
            task.didReceive(resp)
            task.didReceive(body)
            task.didFinish()
        }
    }

    // MARK: - File responses

    private func respondWithFile(task: WKURLSchemeTask, url: URL, file: URL, injectBaseHref: String? = nil) {
        var resolved = file
        // If the URL points to a directory, try index.html inside it.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
            resolved = resolved.appendingPathComponent("index.html")
        }
        guard var data = try? Data(contentsOf: resolved) else {
            sendNotFound(task: task, url: url)
            return
        }
        let mime = mimeType(for: resolved)
        // Inject <base href="..."> for the directory-without-trailing-slash
        // case (see serveMirror step 0b). Done at serve time rather than at
        // patch time so it stays correct if the file is moved on disk later.
        if let href = injectBaseHref, mime.hasPrefix("text/html") {
            if let html = String(data: data, encoding: .utf8) {
                let baseTag = "<base href=\"\(href)\">"
                var patched: String
                if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
                    patched = html.replacingCharacters(in: headRange, with: "<head>\(baseTag)")
                } else if let htmlRange = html.range(of: "<html", options: .caseInsensitive) {
                    // No <head> — splice base tag right after <html ...>
                    if let closeBracket = html.range(of: ">", range: htmlRange.lowerBound..<html.endIndex) {
                        patched = html.replacingCharacters(in: closeBracket, with: "><head>\(baseTag)</head>")
                    } else {
                        patched = baseTag + html
                    }
                } else {
                    patched = baseTag + html
                }
                data = patched.data(using: .utf8) ?? data
            }
        }
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "max-age=31536000",
        ]
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        let key = ObjectIdentifier(task)
        DispatchQueue.main.async { [weak self] in
            self?.inFlightLock.lock()
            let stopped = self?.stoppedKeys.contains(key) ?? true
            self?.stoppedKeys.remove(key)
            self?.inFlightLock.unlock()
            guard !stopped else { return }
            task.didReceive(resp)
            task.didReceive(data)
            task.didFinish()
        }
    }

    private func serveStoreStub(task: WKURLSchemeTask, url: URL, host: String) {
        let body = storeStubHTML(host: host, url: url).data(using: .utf8)!
        let resp = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": "\(body.count)",
                "Cache-Control": "no-store",
            ])!
        let key = ObjectIdentifier(task)
        DispatchQueue.main.async { [weak self] in
            self?.inFlightLock.lock()
            let stopped = self?.stoppedKeys.contains(key) ?? true
            self?.stoppedKeys.remove(key)
            self?.inFlightLock.unlock()
            guard !stopped else { return }
            task.didReceive(resp)
            task.didReceive(body)
            task.didFinish()
        }
    }

    private func storeStubHTML(host: String, url: URL) -> String {
        let esc: (String) -> String = { s in
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "'", with: "&#39;")
        }
        let displayURL = "//\(host)\(url.path)"
        // Friendly label for which subdomain the user was trying to reach.
        let subtitle: String
        switch host {
        case "store.americangirl.com", "stage.store.americangirl.com", "shop.americangirl.com":
            subtitle = "The American Girl online shop"
        case "club.americangirl.com":
            subtitle = "The American Girl Club (premium subsite)"
        case "mollysblog.americangirl.com":
            subtitle = "Molly\u{2019}s in-character blog"
        case "aka.www.americangirl.com":
            subtitle = "The Akamai CDN frontend"
        case "emailresp.americangirl.com", "mresponse.americangirl.com":
            subtitle = "AG\u{2019}s email response handler"
        default:
            subtitle = host
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Not in this archive — Summer 2008</title>
        <style>
          :root { color-scheme: light; }
          html, body { margin: 0; padding: 0; min-height: 100vh; background: #FBF6EB;
            font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif;
            color: #4A2C20; }
          .wrap { max-width: 600px; margin: 0 auto; padding: 72px 32px 48px; }
          .stamp { display: inline-block; background: #A6192E; color: #FBF6EB;
            font-size: 10.5px; letter-spacing: .22em; text-transform: uppercase; font-weight: 700;
            padding: 5px 12px; border-radius: 999px; margin-bottom: 16px; }
          h1 { font-family: 'Hoefler Text', Georgia, serif; font-style: italic; font-weight: 400;
            color: #7C0C1F; font-size: 32px; line-height: 1.15; margin: 0 0 8px; }
          .sub { color: #8c6a5c; font-size: 13.5px; margin: 0 0 22px; letter-spacing: .04em; }
          p { font-size: 14.5px; line-height: 1.6; color: #5a3a2e; margin: 0 0 14px; }
          code { background: rgba(166,25,46,0.06); border: 1px solid rgba(166,25,46,0.16);
            border-radius: 4px; padding: 2px 7px; font-family: 'SF Mono', Menlo, monospace;
            font-size: 12px; color: #7C0C1F; overflow-wrap: anywhere; display: inline-block; max-width: 100%; }
          .why { background: rgba(166,25,46,0.05); border-left: 3px solid #A6192E;
            padding: 14px 18px; font-size: 13px; margin: 22px 0; border-radius: 4px;
            color: #6a4d40; line-height: 1.55; }
          .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 24px; }
          .btn { display: inline-block; padding: 10px 22px; border-radius: 999px;
            font-size: 11px; letter-spacing: .2em; text-transform: uppercase; font-weight: 600;
            text-decoration: none; cursor: pointer; border: 1px solid transparent;
            font-family: -apple-system, 'SF Pro Text', sans-serif; }
          .btn.primary { background: #A6192E; color: #FBF6EB; }
          .btn.primary:hover { filter: brightness(1.06); }
          .btn.ghost { background: transparent; color: #A6192E; border-color: #A6192E; }
          .btn.ghost:hover { background: rgba(166,25,46,0.08); }
          .foot { margin-top: 56px; font-size: 11.5px; color: #b08c7c; letter-spacing: .06em; }
        </style>
        </head>
        <body>
          <main class="wrap">
            <span class="stamp">Not in this archive</span>
            <h1>\(esc(subtitle)) wasn\u{2019}t preserved.</h1>
            <p class="sub">You were heading toward <code>\(esc(displayURL))</code></p>
            <p>This subdomain was a live, server-backed system in 2008 — shopping cart, account login, real-time checkout, in-browser product database. None of that can function as a static snapshot, so the URL filter deliberately skipped it during the 2008 crawl.</p>
            <div class="why">
              The Summer 2008 archive focuses on what 2008 American Girl actually <em>was</em> as an experience for kids: the character sites, the magazine activities, the Flash games, the e-cards, the Kit Kittredge movie tie-in. Everything you can <em>do</em> got preserved. The e-commerce surface didn\u{2019}t.
            </div>
            <p>If you remember something specific from this subdomain — a product page screenshot, a saved order confirmation, a banner image, anything — let me know. Cataloging what was lost matters too.</p>
            <div class="actions">
              <a class="btn primary" href="agd://dashboard/index.html">Back to the Dashboard</a>
              <a class="btn ghost" href="agd://www.americangirl.com/">Mirror Homepage</a>
            </div>
            <p class="foot">Summer 2008 \u{B7} An American Girl Archive</p>
          </main>
        </body>
        </html>
        """
    }

    private func sendNotFound(task: WKURLSchemeTask, url: URL) {
        let body = notFoundHTML(for: url).data(using: .utf8)!
        let resp = HTTPURLResponse(
            url: url, statusCode: 404, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": "\(body.count)",
            ])!
        let key = ObjectIdentifier(task)
        DispatchQueue.main.async { [weak self] in
            self?.inFlightLock.lock()
            let stopped = self?.stoppedKeys.contains(key) ?? true
            self?.stoppedKeys.remove(key)
            self?.inFlightLock.unlock()
            guard !stopped else { return }
            task.didReceive(resp)
            task.didReceive(body)
            task.didFinish()
        }
    }

    /// Friendly 404 page. Shown when a request can't be served from the
    /// bundled mirror, the runtime backfill cache, OR a live Wayback fetch.
    /// Offers a "back" affordance and a direct Wayback link the user can
    /// click to confirm whether the asset ever existed.
    private func notFoundHTML(for url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        // Hide our own synthetic hosts from the displayed URL.
        let displayHost = (host == "dashboard" || host == "runtime" || host == "games") ? "" : host
        let displayed = displayHost.isEmpty
            ? url.path
            : "//\(displayHost)\(url.path)"
        let waybackHref: String
        if !displayHost.isEmpty {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "web.archive.org"
            comps.path = "/web/2008*/http://\(host)\(url.path)"
            waybackHref = comps.url?.absoluteString ?? ""
        } else {
            waybackHref = ""
        }
        let esc: (String) -> String = { s in
            s
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        let waybackLink = waybackHref.isEmpty
            ? ""
            : "<a class=\"btn ghost\" href=\"\(esc(waybackHref))\">Search the Wayback Machine</a>"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Not in the archive — American Girl 2008</title>
        <style>
          :root { color-scheme: light; }
          html, body { margin: 0; padding: 0; min-height: 100vh; background: #FBF6EB;
            font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif;
            color: #4A2C20; }
          .wrap { max-width: 560px; margin: 0 auto; padding: 80px 32px 48px; text-align: center; }
          .stamp { display: inline-block; padding: 4px 12px; border: 1px solid #A6192E;
            color: #A6192E; font-size: 10px; letter-spacing: .28em; text-transform: uppercase;
            border-radius: 999px; font-weight: 600; }
          h1 { font-family: 'Hoefler Text', Georgia, serif; font-style: italic; font-weight: 400;
            font-size: 38px; margin: 18px 0 12px; line-height: 1.15; color: #7C0C1F; }
          p.lede { font-size: 15px; line-height: 1.55; margin: 0 0 28px; color: #5a3a2e; }
          code.url { display: inline-block; max-width: 100%; overflow-wrap: anywhere;
            background: rgba(166,25,46,0.06); border: 1px solid rgba(166,25,46,0.18);
            padding: 8px 12px; border-radius: 6px; font-size: 12.5px; color: #7C0C1F;
            font-family: 'SF Mono', Menlo, Consolas, monospace; }
          .actions { margin-top: 32px; display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
          .btn { display: inline-block; padding: 9px 18px; border-radius: 999px;
            font-size: 11px; letter-spacing: .2em; text-transform: uppercase; font-weight: 600;
            text-decoration: none; border: 1px solid transparent; cursor: pointer; }
          .btn.primary { background: #A6192E; color: #FBF6EB; }
          .btn.primary:hover { filter: brightness(1.06); }
          .btn.ghost { background: transparent; color: #A6192E; border-color: #A6192E; }
          .btn.ghost:hover { background: rgba(166,25,46,0.08); }
          .foot { margin-top: 56px; font-size: 11.5px; color: #8c6a5c; letter-spacing: .08em; }
        </style>
        </head>
        <body>
          <main class="wrap">
            <span class="stamp">404 · Not in the archive</span>
            <h1>This page wasn't preserved.</h1>
            <p class="lede">The 2008 snapshot of americangirl.com doesn't include this asset — the original page may have been built dynamically, or the link broke before we crawled it.</p>
            <code class="url">\(esc(displayed))</code>
            <div class="actions">
              <a class="btn primary" href="javascript:history.length>1?history.back():(location.href='agd://dashboard/index.html')">Go back</a>
              \(waybackLink)
            </div>
            <p class="foot">American Girl 2008 · Offline Preservation</p>
          </main>
        </body>
        </html>
        """
    }

    // MARK: - Wayback backfill

    private func backfillFromWayback(task: WKURLSchemeTask, url: URL, host: String, path: String, cacheURL: URL) {
        // Rebuild the original URL.
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.path = path
        comps.query = url.query
        guard let originalURL = comps.url else {
            sendNotFound(task: task, url: url)
            return
        }
        let wbString = "https://web.archive.org/web/\(Self.snapshotTimestamp)id_/\(originalURL.absoluteString)"
        guard let wbURL = URL(string: wbString) else {
            sendNotFound(task: task, url: url)
            return
        }

        var req = URLRequest(url: wbURL, timeoutInterval: 30)
        req.setValue("AGD-Launcher/1.0 (offline preservation)", forHTTPHeaderField: "User-Agent")
        let dataTask = session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            self.inFlightLock.lock()
            self.inFlight.removeValue(forKey: ObjectIdentifier(task))
            self.inFlightLock.unlock()

            if let http = resp as? HTTPURLResponse, http.statusCode == 200, let data {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? data.write(to: cacheURL)
                let mime = self.mimeType(for: cacheURL)
                let headers: [String: String] = [
                    "Content-Type": mime,
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*",
                    "X-AGD-Source": "wayback-backfill",
                ]
                let respOut = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                let key = ObjectIdentifier(task)
                DispatchQueue.main.async { [weak self] in
                    self?.inFlightLock.lock()
                    let stopped = self?.stoppedKeys.contains(key) ?? true
                    self?.stoppedKeys.remove(key)
                    self?.inFlightLock.unlock()
                    guard !stopped else { return }
                    task.didReceive(respOut)
                    task.didReceive(data)
                    task.didFinish()
                }
            } else {
                // For audio assets, serve a minimal silent MP3 instead of
                // the 404 stub. Many 2008 Flash games (Josefina's market
                // day-select, etc.) blocked their state machines on
                // failed audio loads — a real 404 made the day-select
                // button do nothing visible. A silent MP3 lets the SWF's
                // sound callback fire normally and the game proceeds.
                let ext = (path as NSString).pathExtension.lowercased()
                if ext == "mp3" || ext == "wav" {
                    self.sendSilentAudio(task: task, url: url)
                } else {
                    self.sendNotFound(task: task, url: url)
                }
            }
        }

        inFlightLock.lock()
        inFlight[ObjectIdentifier(task)] = dataTask
        inFlightLock.unlock()
        dataTask.resume()
    }

    // MARK: - Path / mime helpers

    private func mirrorFileURL(host: String, path: String, query: String?) -> URL {
        let base = bundleResources
            .appendingPathComponent("mirror", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
        return resolveFilePath(base: base, path: path, query: query)
    }

    private func cacheFileURL(host: String, path: String, query: String?) -> URL {
        let base = cacheRoot.appendingPathComponent(host, isDirectory: true)
        return resolveFilePath(base: base, path: path, query: query)
    }

    private func resolveFilePath(base: URL, path: String, query: String?) -> URL {
        var p = path
        if p.hasSuffix("/") {
            p += "index.html"
        }
        if !p.contains(".") && (query == nil) {
            p += "/index.html"
        }
        // Sanitize each segment using the same rules as the Python downloader.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._@,~+()=#%-")
        let segs = p.split(separator: "/").map { seg -> String in
            String(seg).map { ch -> String in
                let s = String(ch)
                if s.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return s }
                return "_"
            }.joined()
        }
        var resolved = base
        for s in segs { resolved.appendPathComponent(s) }
        if let q = query, !q.isEmpty {
            // Append query suffix like the downloader does. Strip trailing
            // dots/spaces — Win32 API forbids those in filenames, so for the
            // Windows port these had to be renamed on disk. We do the same
            // trim here so the cross-platform mirror file naming agrees.
            var safe = String(q.map { ch -> String in
                let s = String(ch)
                if s.range(of: "[A-Za-z0-9._-]", options: .regularExpression) != nil { return s }
                return "_"
            }.joined().prefix(128))
            while safe.hasSuffix(".") || safe.hasSuffix(" ") { safe.removeLast() }
            let last = resolved.lastPathComponent
            resolved = resolved.deletingLastPathComponent().appendingPathComponent("\(last)__\(safe)")
        }
        return resolved
    }

    private func mimeType(for url: URL) -> String {
        // Query-suffixed mirror files break URL.pathExtension. The downloader
        // saves URLs with query strings as `<basename>__<encoded-query>`, so
        // a file like `agc_molly_star.swf?personalMsg=...here...` lands on
        // disk as `agc_molly_star.swf__personalMsg_Your_..._here...` —
        // pathExtension returns "" (trailing dots) or junk like "swf__foo",
        // either way MIME falls to octet-stream and Ruffle silently rejects
        // the SWF. Strip the __<query> tail before extracting the extension.
        let leaf = url.lastPathComponent
        let logical: String
        if let qSep = leaf.range(of: "__") {
            logical = String(leaf.prefix(upTo: qSep.lowerBound))
        } else {
            logical = leaf
        }
        let ext: String
        if let dot = logical.lastIndex(of: ".") {
            ext = String(logical[logical.index(after: dot)...]).lowercased()
        } else {
            ext = ""
        }
        switch ext {
        case "html", "htm":   return "text/html; charset=utf-8"
        case "php":           return "text/html; charset=utf-8"  // mirror snapshots are pre-rendered HTML saved under the original .php URL
        case "css":           return "text/css; charset=utf-8"
        case "js":            return "application/javascript; charset=utf-8"
        case "json":          return "application/json"
        case "svg":           return "image/svg+xml"
        case "png":           return "image/png"
        case "jpg", "jpeg":   return "image/jpeg"
        case "gif":           return "image/gif"
        case "ico":           return "image/x-icon"
        case "swf":           return "application/x-shockwave-flash"
        case "dcr":           return "application/x-director"
        case "wasm":          return "application/wasm"
        case "map":           return "application/json"
        case "pdf":           return "application/pdf"
        case "mp4":           return "video/mp4"
        case "mov":           return "video/quicktime"
        case "woff":          return "font/woff"
        case "woff2":         return "font/woff2"
        case "ttf":           return "font/ttf"
        case "otf":           return "font/otf"
        case "xml":           return "application/xml"
        case "txt":           return "text/plain; charset=utf-8"
        default:
            if #available(macOS 11.0, *), let type = UTType(filenameExtension: ext)?.preferredMIMEType {
                return type
            }
            return "application/octet-stream"
        }
    }
}
