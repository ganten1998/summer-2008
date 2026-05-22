using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
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
    private readonly PrefsStore _prefs;

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

    public MirrorHandler(string resourcesDir, PrefsStore prefs)
    {
        _resourcesDir = resourcesDir;
        _mirrorDir    = Path.Combine(resourcesDir, "mirror");
        _dashboardDir = Path.Combine(resourcesDir, "dashboard");
        _runtimeDir   = Path.Combine(resourcesDir, "mirror-runtime");
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
                args.Response = ServeFile(env, hit, uri);
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

            // 8. Not in archive.
            args.Response = StubPages.NotFoundResponse(env, uri);
        }
        catch (Exception ex)
        {
            args.Response = StubPages.ErrorResponse((CoreWebView2)sender!, ex);
        }
    }

    private record FileResolution(string FullPath, bool IsFile);

    private FileResolution? ResolveMirrorPath(string host, string path, string query)
    {
        // Map "/" to "/index.html" — matches Swift behaviour
        if (path.EndsWith("/", StringComparison.Ordinal))
            path += "index.html";

        // mirror/<host>/<path>[__<query>]
        var relativePath = path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        var fullPath = Path.Combine(_mirrorDir, host, relativePath);

        if (!string.IsNullOrEmpty(query))
        {
            // Sanitize query the same way build_url_list.py / download_mirror.py do:
            // keep [A-Za-z0-9._-], replace runs of anything else with a single underscore.
            var safe = Regex.Replace(query, "[^A-Za-z0-9._-]+", "_");
            if (safe.Length > 128) safe = safe[..128];
            fullPath = fullPath + "__" + safe;
        }

        return new FileResolution(fullPath, File.Exists(fullPath));
    }

    private CoreWebView2WebResourceResponse ServeFromDir(
        CoreWebView2 env, string root, string path, Uri uri)
    {
        if (path.EndsWith("/", StringComparison.Ordinal)) path += "index.html";
        var rel = path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        // Strip any query suffix on the leaf for MIME-type purposes.
        var underscored = rel.IndexOf("__", StringComparison.Ordinal);
        var lookup = underscored < 0 ? rel : rel[..underscored];
        var full = Path.Combine(root, lookup);
        if (!File.Exists(full)) return StubPages.NotFoundResponse(env, uri);
        return ServeFile(env, full, uri);
    }

    private CoreWebView2WebResourceResponse ServeFile(CoreWebView2 env, string fullPath, Uri uri)
    {
        var bytes = File.ReadAllBytes(fullPath);
        var stream = new MemoryStream(bytes);
        var mime = MimeFor(fullPath);
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
                    if (v is null) { body = "null"; status = 200; reason = "OK"; }
                    else            { body = v;      status = 200; reason = "OK"; }
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
