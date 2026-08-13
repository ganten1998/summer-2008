using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using Microsoft.Web.WebView2.Core;

namespace Summer2008;

/// <summary>
/// Serves agd:// URL requests from the bundled local resources.
///
/// This is the Windows analogue of the macOS MirrorURLSchemeHandler.swift.
/// Routing rules, in order:
///
///   • agd://runtime/__prefs__/&lt;key&gt;        — prefs file IO (GET/PUT/DELETE)
///   • agd://dashboard/...                  — dashboard HTML
///   • agd://runtime/...                    — mirror-runtime JS / Ruffle WASM
///   • agd://www.americangirl.com/__agd/... — synthetic pages (ecard wizard,
///                                            dead-form stub, etc.)
///   • agd://store.americangirl.com/...     — synthetic "shop closed" stub
///     and other known-dead subdomains
///   • agd://&lt;host&gt;/&lt;path&gt;                — mirror file lookup with
///                                            query-tolerant fallbacks
///   • anything else                        — styled 404
/// </summary>
public sealed class MirrorHandler
{
    private readonly string _resourcesDir;
    private readonly string _mirrorDir;
    private readonly string _dashboardDir;
    private readonly string _runtimeDir;
    private readonly string _cacheDir;
    private readonly PrefsStore _prefs;

    // Single static HttpClient — socket exhaustion if we new one per request.
    private static readonly HttpClient _http = CreateHttpClient();

    private static HttpClient CreateHttpClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Summer2008-Windows/1.0 (offline preservation)");
        return c;
    }

    // Snapshot the project pins to — same constant as MirrorURLSchemeHandler.swift:21.
    // The `id_` flag on the Wayback URL returns the raw resource without
    // Wayback's wrapper HTML/JS injection.
    private const string SnapshotTimestamp = "20080711092743";

    // Subdomains we deliberately didn't crawl (e-commerce, partial captures,
    // ad/email tracking). Show a styled "wasn't preserved" stub when the
    // user lands here, unless we DO have a real capture on disk.
    private static readonly HashSet<string> StoreHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "store.americangirl.com",
        "stage.store.americangirl.com",
        "shop.americangirl.com",
        "club.americangirl.com",
        "aka.www.americangirl.com",
        "mollysblog.americangirl.com",
        "emailresp.americangirl.com",
        "mresponse.americangirl.com",
    };

    private static readonly HashSet<string> AssetExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".png", ".gif", ".ico", ".css", ".js",
        ".svg", ".woff", ".woff2", ".ttf"
    };

    public MirrorHandler(string resourcesDir, string userDataDir, PrefsStore prefs)
    {
        _resourcesDir = resourcesDir;
        _mirrorDir    = Path.Combine(resourcesDir, "mirror");
        _dashboardDir = Path.Combine(resourcesDir, "dashboard");
        _runtimeDir   = Path.Combine(resourcesDir, "mirror-runtime");
        _cacheDir     = Path.Combine(userDataDir, "cache");
        _prefs        = prefs;
    }

    public void OnWebResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        try
        {
            var env = (CoreWebView2)sender!;
            var uri = new Uri(args.Request.Uri);
            var host = uri.Host;
            var path = uri.AbsolutePath;
            var query = uri.Query.TrimStart('?');
            if (string.IsNullOrEmpty(query)) query = "";

            // 1. Prefs endpoint (volume slider state, etc.)
            if (string.Equals(host, "runtime", StringComparison.OrdinalIgnoreCase)
                && path.StartsWith("/__prefs__/", StringComparison.OrdinalIgnoreCase))
            {
                args.Response = HandlePrefs(env, args.Request, path["/__prefs__/".Length..]);
                return;
            }

            // 2. Dashboard
            if (string.Equals(host, "dashboard", StringComparison.OrdinalIgnoreCase))
            {
                args.Response = ServeFromDir(env, _dashboardDir, path, uri);
                return;
            }

            // 3. Runtime (Ruffle WASM, volume-control.js, flash-bridge.js, etc.)
            if (string.Equals(host, "runtime", StringComparison.OrdinalIgnoreCase))
            {
                args.Response = ServeFromDir(env, _runtimeDir, path, uri);
                return;
            }

            // 3a. IE-only stylesheet stub. Source HTML often includes
            //     <link rel="stylesheet" href="styles_ie6.css"> unconditionally
            //     (no <!--[if IE]--> wrapper), so WebView2 requests files that
            //     only ever applied to IE6/7. Serve 0-byte 200 to short-circuit
            //     the mirror lookup + cache + Wayback round trip on ~24 dead refs.
            var leaf = Path.GetFileName(path).ToLowerInvariant();
            if (leaf.EndsWith("_ie.css") || leaf.EndsWith("_ie6.css") || leaf.EndsWith("_ie7.css"))
            {
                args.Response = EmptyCssResponse(env);
                return;
            }

            // 3b. Directory request without trailing slash. WebView2 otherwise
            //     leaves the document URL as agd://host/movie (no slash), so
            //     relative refs like <link href="assets/styles.css"> resolve
            //     against "/movie" (treated as a file) → /assets/styles.css —
            //     wrong path, no CSS or images load. WKURLSchemeTask/WebView2
            //     don't reliably auto-follow synthetic 301s from custom scheme
            //     handlers, so instead serve the directory's index.html with
            //     an injected <base href="<path>/"> so the browser uses the
            //     right base for relative refs.
            string? injectBaseHref = null;
            if (!path.EndsWith("/", StringComparison.Ordinal))
            {
                var dirCheck = Path.Combine(_mirrorDir, host, path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar));
                if (Directory.Exists(dirCheck))
                {
                    injectBaseHref = path + "/";
                }
            }

            // 4. Reserved synthetic mirror paths (/__agd/*) — served from
            //    mirror-runtime under the mirror's host so Ruffle treats
            //    them as same-origin with mirror SWFs.
            if (path.StartsWith("/__agd/", StringComparison.OrdinalIgnoreCase))
            {
                var sub = path["/__agd/".Length..];
                args.Response = ServeFromDir(env, _runtimeDir, "/" + sub, uri);
                return;
            }

            // 5. Store + other intentionally-missing subdomains.
            if (StoreHosts.Contains(host))
            {
                // If we DID grab a capture, prefer it.
                var trial = ResolveMirrorPath(host, path, query);
                if (trial is { IsFile: true, FullPath: var p } && File.Exists(p))
                {
                    args.Response = ServeFile(env, p, uri);
                    return;
                }
                // Otherwise serve the synthetic stub — but skip for plain
                // assets (img/css/js) so referenced images still load if
                // they're on disk in adjacent subdomain captures.
                var ext = Path.GetExtension(path);
                if (!AssetExtensions.Contains(ext))
                {
                    args.Response = StubPages.StoreStubResponse(env, host, uri);
                    return;
                }
            }

            // 6. Bundled mirror.
            var resolved = ResolveMirrorPath(host, path, query);
            if (resolved is { IsFile: true, FullPath: var hit } && File.Exists(hit))
            {
                args.Response = ServeFile(env, hit, uri, injectBaseHref);
                return;
            }

            // 7. Query-tolerant fallback for binary assets (SWF/DCR/img/PDF).
            //    The patcher rewrites http→agd inside SWF embed query strings,
            //    which changes the encoded filename so the exact path misses.
            //    Try base name (no __<query>) and then a glob match.
            if (!string.IsNullOrEmpty(query))
            {
                var bareBase = ResolveMirrorPath(host, path, "");
                if (bareBase is { FullPath: var bp } && File.Exists(bp))
                {
                    args.Response = ServeFile(env, bp, uri);
                    return;
                }
                // Glob: any file whose stem matches the requested filename.
                if (bareBase is { FullPath: var bp2 })
                {
                    var dir = Path.GetDirectoryName(bp2);
                    var stem = Path.GetFileName(bp2);
                    if (dir is not null && Directory.Exists(dir) && !string.IsNullOrEmpty(stem))
                    {
                        var match = Directory.EnumerateFiles(dir)
                            .Where(f => Path.GetFileName(f) == stem
                                     || Path.GetFileName(f).StartsWith(stem + "__", StringComparison.Ordinal))
                            .OrderBy(f => f.Length)
                            .FirstOrDefault();
                        if (match is not null)
                        {
                            args.Response = ServeFile(env, match, uri);
                            return;
                        }
                    }
                }
            }

            // 8. Runtime cache — anything previously backfilled from Wayback
            //    lives at %LOCALAPPDATA%\Summer 2008\cache\<host>\<path>.
            var cachePath = ResolveCachePath(host, path, query);
            if (cachePath is not null && File.Exists(cachePath))
            {
                args.Response = ServeFile(env, cachePath, uri);
                return;
            }

            // 8a. Bare-host alias. Pages occasionally link to
            //     agd://americangirl.com/foo when the captured asset lives at
            //     agd://www.americangirl.com/foo (a redirect the original server
            //     did before we froze the snapshot). Retry the on-disk lookups
            //     (mirror + query-strip + cache) under the www. variant before
            //     paying the Wayback round trip.
            if (string.Equals(host, "americangirl.com", StringComparison.OrdinalIgnoreCase))
            {
                const string aliasHost = "www.americangirl.com";
                var aliasMirror = ResolveMirrorPath(aliasHost, path, query);
                if (aliasMirror is { FullPath: var ap } && File.Exists(ap))
                {
                    args.Response = ServeFile(env, ap, uri);
                    return;
                }
                if (!string.IsNullOrEmpty(query))
                {
                    var aliasBare = ResolveMirrorPath(aliasHost, path, "");
                    if (aliasBare is { FullPath: var abp } && File.Exists(abp))
                    {
                        args.Response = ServeFile(env, abp, uri);
                        return;
                    }
                }
                var aliasCache = ResolveCachePath(aliasHost, path, query);
                if (aliasCache is not null && File.Exists(aliasCache))
                {
                    args.Response = ServeFile(env, aliasCache, uri);
                    return;
                }
            }

            // 9. Last resort: fetch from web.archive.org with our snapshot
            //    timestamp, cache the result, then serve it. Matches the
            //    macOS shell's backfillFromWayback at MirrorURLSchemeHandler.swift:564
            //    so missing assets (e.g. site/images/imgPlay.gif) heal on first view
            //    instead of showing as broken images. Uses a deferral because the
            //    WebView2 event handler can't await.
            if (cachePath is not null)
            {
                var deferral = args.GetDeferral();
                _ = BackfillFromWaybackAsync(env, args, uri, host, path, query, cachePath, deferral);
                return;
            }

            // 10. Truly unservable (couldn't compute a cache path).
            args.Response = StubPages.NotFoundResponse(env, uri);
        }
        catch (Exception ex)
        {
            args.Response = StubPages.ErrorResponse((CoreWebView2)sender!, ex);
        }
    }

    private string? ResolveCachePath(string host, string path, string query)
    {
        try
        {
            if (path.EndsWith("/", StringComparison.Ordinal)) path += "index.html";
            var rel = path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
            var full = Path.Combine(_cacheDir, host, rel);
            if (!string.IsNullOrEmpty(query))
            {
                var safe = Regex.Replace(query, "[^A-Za-z0-9._-]+", "_");
                safe = safe.TrimEnd('.', ' ');
                if (safe.Length > 128) safe = safe[..128].TrimEnd('.', ' ');
                full = full + "__" + safe;
            }
            return full;
        }
        catch { return null; }
    }

    private async Task BackfillFromWaybackAsync(
        CoreWebView2 env,
        CoreWebView2WebResourceRequestedEventArgs args,
        Uri uri, string host, string path, string query,
        string cachePath,
        CoreWebView2Deferral deferral)
    {
        // Captured on entry, which is the WPF UI thread — WebResourceRequested
        // is raised there. WebView2 is STA COM: Environment.CreateWebResourceResponse,
        // the args.Response setter, and Deferral.Complete all throw
        // RPC_E_WRONG_THREAD (0x8001010E) if touched from a threadpool thread.
        // The ConfigureAwait(false) calls below are deliberate — the network
        // fetch and the cache write should NOT occupy the UI thread — but they
        // mean everything after the first await runs on the pool, so every COM
        // interaction has to be marshalled back explicitly.
        var ui = SynchronizationContext.Current;

        void OnUi(Action action)
        {
            if (ui is null) { action(); return; }
            // Send (not Post) so ordering with deferral.Complete is preserved;
            // DispatcherSynchronizationContext runs it inline when already on
            // the UI thread, so this is safe even if no thread hop occurred.
            ui.Send(_ => action(), null);
        }

        try
        {
            var qPart = string.IsNullOrEmpty(query) ? "" : "?" + query;
            var originalUrl = "http://" + host + path + qPart;
            var wbUrl = $"https://web.archive.org/web/{SnapshotTimestamp}id_/{originalUrl}";

            using var resp = await _http.GetAsync(wbUrl).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                OnUi(() => args.Response = StubPages.NotFoundResponse(env, uri));
                return;
            }

            var bytes = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);

            // Persist to cache so subsequent views serve offline.
            try
            {
                var dir = Path.GetDirectoryName(cachePath);
                if (dir is not null) Directory.CreateDirectory(dir);
                File.WriteAllBytes(cachePath, bytes);
            }
            catch { /* best effort — serve from memory if cache write fails */ }

            var mime = MimeFor(cachePath);
            var headers = string.Join("\r\n",
                $"Content-Type: {mime}",
                $"Content-Length: {bytes.Length}",
                "Cache-Control: no-store",
                "Access-Control-Allow-Origin: *",
                "X-AGD-Source: wayback-backfill");
            OnUi(() =>
            {
                var stream = new MemoryStream(bytes);
                args.Response = env.Environment.CreateWebResourceResponse(
                    stream, 200, "OK", headers);
            });
        }
        catch
        {
            // Network failure, DNS failure, timeout, etc. — serve the 404 stub
            // so the user sees a clean "not in this archive" rather than a
            // browser-default error page.
            try { OnUi(() => args.Response = StubPages.NotFoundResponse(env, uri)); }
            catch { }
        }
        finally
        {
            OnUi(() => deferral.Complete());
        }
    }

    private record FileResolution(string FullPath, bool IsFile);

    private FileResolution? ResolveMirrorPath(string host, string path, string query)
    {
        // Map "/" to "/index.html" — matches Swift behaviour
        if (path.EndsWith("/", StringComparison.Ordinal))
            path += "index.html";
        // Extension-less, query-less path → directory ref like /movie/molly.
        // Auto-append /index.html so the lookup hits mirror/<host>/movie/molly/index.html
        // instead of a nonexistent file at mirror/<host>/movie/molly. Without
        // this, the directory case falls through to Wayback backfill which
        // caches the response with no extension, then serves it as
        // application/octet-stream (raw HTML dump). Mirrors the Swift
        // resolveFilePath logic at MirrorURLSchemeHandler.swift:741.
        else if (!Path.GetFileName(path).Contains('.') && string.IsNullOrEmpty(query))
            path += "/index.html";

        // mirror/<host>/<path>[__<query>]
        var relativePath = path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        var fullPath = Path.Combine(_mirrorDir, host, relativePath);

        if (!string.IsNullOrEmpty(query))
        {
            // Sanitize query the same way build_url_list.py / download_mirror.py do:
            // keep [A-Za-z0-9._-], replace runs of anything else with a single underscore.
            // Then strip trailing dots / spaces — Win32 API forbids those in filenames,
            // so ecard placeholders like "personalMsg_..._goes_here..." had to be
            // renamed on disk and the lookup must match the trimmed form.
            var safe = Regex.Replace(query, "[^A-Za-z0-9._-]+", "_");
            safe = safe.TrimEnd('.', ' ');
            if (safe.Length > 128) safe = safe[..128].TrimEnd('.', ' ');
            fullPath = fullPath + "__" + safe;
        }

        return new FileResolution(fullPath, File.Exists(fullPath));
    }

    private CoreWebView2WebResourceResponse ServeFromDir(
        CoreWebView2 env, string root, string path, Uri uri)
    {
        if (path.EndsWith("/", StringComparison.Ordinal)) path += "index.html";
        var rel = path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);

        // Try the path exactly as requested FIRST.
        //
        // This used to unconditionally truncate at the first "__" found
        // anywhere in the relative path, which breaks every runtime asset that
        // legitimately contains a double underscore in its name — all 74
        // paperdoll piece PNGs are named like "Addy__doll.png", so a request
        // for paperdoll/pieces/Addy__doll.png resolved to "paperdoll/pieces/Addy"
        // and 404'd. The dress-up game rendered an empty canvas on Windows.
        // (The Swift original only strips "__" off the leaf, and only to pick
        // a MIME type — never for the file lookup.)
        var full = Path.Combine(root, rel);
        if (File.Exists(full)) return ServeFile(env, full, uri);

        // Only if that misses, fall back to stripping a "__<query>" suffix from
        // the LEAF segment — the downloader's naming convention for URLs that
        // were captured with a query string.
        var dir = Path.GetDirectoryName(rel) ?? string.Empty;
        var leaf = Path.GetFileName(rel);
        var cut = leaf.IndexOf("__", StringComparison.Ordinal);
        if (cut > 0)
        {
            var trimmed = Path.Combine(root, dir, leaf[..cut]);
            if (File.Exists(trimmed)) return ServeFile(env, trimmed, uri);
        }

        return StubPages.NotFoundResponse(env, uri);
    }

    private CoreWebView2WebResourceResponse EmptyCssResponse(CoreWebView2 env)
    {
        var headers = string.Join("\r\n",
            "Content-Type: text/css; charset=utf-8",
            "Content-Length: 0",
            "Cache-Control: max-age=31536000");
        return env.Environment.CreateWebResourceResponse(
            new MemoryStream(Array.Empty<byte>()), 200, "OK", headers);
    }

    private CoreWebView2WebResourceResponse ServeFile(CoreWebView2 env, string fullPath, Uri uri, string? injectBaseHref = null)
    {
        var bytes = File.ReadAllBytes(fullPath);
        var mime = MimeFor(fullPath);
        // Inject <base href="..."> for the directory-without-trailing-slash
        // case (see step 3b in the routing chain). Done at serve time so it
        // stays correct if the file is moved on disk later.
        if (injectBaseHref is not null && mime.StartsWith("text/html", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                var html = Encoding.UTF8.GetString(bytes);
                var baseTag = $"<base href=\"{injectBaseHref}\">";
                var headIdx = html.IndexOf("<head>", StringComparison.OrdinalIgnoreCase);
                string patched;
                if (headIdx >= 0)
                {
                    patched = html.Insert(headIdx + "<head>".Length, baseTag);
                }
                else
                {
                    var htmlIdx = html.IndexOf("<html", StringComparison.OrdinalIgnoreCase);
                    if (htmlIdx >= 0)
                    {
                        var close = html.IndexOf('>', htmlIdx);
                        if (close >= 0)
                            patched = html.Insert(close + 1, $"<head>{baseTag}</head>");
                        else
                            patched = baseTag + html;
                    }
                    else
                    {
                        patched = baseTag + html;
                    }
                }
                bytes = Encoding.UTF8.GetBytes(patched);
            }
            catch { /* fall through with original bytes if encoding fails */ }
        }
        var stream = new MemoryStream(bytes);
        var headers = string.Join("\r\n",
            $"Content-Type: {mime}",
            $"Content-Length: {bytes.Length}",
            "Cache-Control: no-store",
            "Access-Control-Allow-Origin: *");
        return env.Environment.CreateWebResourceResponse(stream, 200, "OK", headers);
    }

    private CoreWebView2WebResourceResponse HandlePrefs(
        CoreWebView2 env, CoreWebView2WebResourceRequest req, string key)
    {
        // Tail off any query so writes don't trash the key on the way in.
        var clean = key;
        var q = clean.IndexOf('?');
        if (q >= 0) clean = clean[..q];
        clean = HttpUtility.UrlDecode(clean);

        var method = req.Method.ToUpperInvariant();
        try
        {
            string body;
            int status;
            string reason;
            switch (method)
            {
                case "GET":
                    var v = _prefs.Get(clean);
                    // Wrap in the same {"value": …} envelope the macOS handler
                    // uses (MirrorURLSchemeHandler.swift respondJSON ["value":]).
                    // volume-control.js reads `j.value`; returning the bare
                    // stored value made that undefined on Windows, so a saved
                    // volume silently never restored between sessions.
                    // The stored string is already JSON (the client PUTs
                    // JSON.stringify(v)), so it embeds directly.
                    body = "{\"value\":" + (v ?? "null") + "}";
                    status = 200;
                    reason = "OK";
                    break;
                case "PUT":
                case "POST":
                    using (var sr = new StreamReader(req.Content ?? new MemoryStream()))
                        body = sr.ReadToEnd();
                    _prefs.Set(clean, body);
                    status = 204; reason = "No Content"; body = "";
                    break;
                case "DELETE":
                    _prefs.Delete(clean);
                    status = 204; reason = "No Content"; body = "";
                    break;
                default:
                    status = 405; reason = "Method Not Allowed"; body = "";
                    break;
            }
            var bytes = Encoding.UTF8.GetBytes(body);
            var headers = string.Join("\r\n",
                "Content-Type: application/json; charset=utf-8",
                $"Content-Length: {bytes.Length}",
                "Cache-Control: no-store");
            return env.Environment.CreateWebResourceResponse(
                new MemoryStream(bytes), status, reason, headers);
        }
        catch (Exception ex)
        {
            return StubPages.ErrorResponse(env, ex);
        }
    }

    // MIME table mirrors Swift's; identical extension → type mapping.
    private static string MimeFor(string path)
    {
        var leaf = Path.GetFileName(path);
        // Strip any "__<query>" tail before extension lookup so query-suffixed
        // files (e.g. choose.php__ecard_X) get the proper Content-Type.
        var idx = leaf.IndexOf("__", StringComparison.Ordinal);
        if (idx > 0) leaf = leaf[..idx];
        var ext = Path.GetExtension(leaf).TrimStart('.').ToLowerInvariant();
        return ext switch
        {
            "html" or "htm"           => "text/html; charset=utf-8",
            "php" or "jsp" or "jsf"   => "text/html; charset=utf-8",
            "asp" or "aspx" or "cgi"  => "text/html; charset=utf-8",
            "css"                     => "text/css; charset=utf-8",
            "js" or "mjs"             => "application/javascript; charset=utf-8",
            "json"                    => "application/json; charset=utf-8",
            "xml"                     => "application/xml; charset=utf-8",
            "txt" or ""               => "text/plain; charset=utf-8",
            "wasm"                    => "application/wasm",
            "swf"                     => "application/x-shockwave-flash",
            "dcr"                     => "application/x-director",
            "flv"                     => "video/x-flv",
            "mp3"                     => "audio/mpeg",
            "mp4"                     => "video/mp4",
            "mov"                     => "video/quicktime",
            "wav"                     => "audio/wav",
            "ogg"                     => "audio/ogg",
            "jpg" or "jpeg"           => "image/jpeg",
            "png"                     => "image/png",
            "gif"                     => "image/gif",
            "svg"                     => "image/svg+xml",
            "ico"                     => "image/x-icon",
            "webp"                    => "image/webp",
            "pdf"                     => "application/pdf",
            "woff"                    => "font/woff",
            "woff2"                   => "font/woff2",
            "ttf"                     => "font/ttf",
            "otf"                     => "font/otf",
            _                         => "application/octet-stream",
        };
    }
}
