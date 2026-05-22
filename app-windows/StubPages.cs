using System;
using System.IO;
using System.Text;
using Microsoft.Web.WebView2.Core;

namespace Summer2008;

/// <summary>
/// HTML for synthesized landing pages we serve when a request can't be
/// satisfied from the bundled mirror. Mirrors the macOS shell's
/// storeStubHTML / notFoundHTML / serveStoreStub helpers.
/// </summary>
internal static class StubPages
{
    public static CoreWebView2WebResourceResponse NotFoundResponse(
        CoreWebView2 env, Uri uri)
    {
        var html = NotFoundHtml(uri);
        return Make(env, html, 404, "Not Found");
    }

    public static CoreWebView2WebResourceResponse StoreStubResponse(
        CoreWebView2 env, string host, Uri uri)
    {
        var html = StoreStubHtml(host, uri);
        return Make(env, html, 200, "OK");
    }

    public static CoreWebView2WebResourceResponse ErrorResponse(
        CoreWebView2 env, Exception ex)
    {
        var body = $"<!DOCTYPE html><html><body style='font-family:-apple-system,sans-serif;background:#FBF6EB;color:#7C0C1F;padding:32px'>" +
                   $"<h2>Internal error</h2><pre style='white-space:pre-wrap'>{System.Net.WebUtility.HtmlEncode(ex.Message)}\n\n{System.Net.WebUtility.HtmlEncode(ex.StackTrace ?? "")}</pre></body></html>";
        return Make(env, body, 500, "Internal Server Error");
    }

    private static CoreWebView2WebResourceResponse Make(
        CoreWebView2 env, string html, int status, string reason)
    {
        var bytes = Encoding.UTF8.GetBytes(html);
        var headers = string.Join("\r\n",
            "Content-Type: text/html; charset=utf-8",
            $"Content-Length: {bytes.Length}",
            "Cache-Control: no-store");
        return env.Environment.CreateWebResourceResponse(
            new MemoryStream(bytes), status, reason, headers);
    }

    private static string StoreStubHtml(string host, Uri uri)
    {
        string subtitle = host.ToLowerInvariant() switch
        {
            "store.americangirl.com"
            or "stage.store.americangirl.com"
            or "shop.americangirl.com"           => "The American Girl online shop",
            "club.americangirl.com"              => "The American Girl Club (premium subsite)",
            "mollysblog.americangirl.com"        => "Molly’s in-character blog",
            "aka.www.americangirl.com"           => "The Akamai CDN frontend",
            "emailresp.americangirl.com"
            or "mresponse.americangirl.com"      => "AG’s email response handler",
            _                                    => host,
        };

        var displayURL = $"//{host}{uri.AbsolutePath}";
        var sb = new StringBuilder(8192);
        sb.Append("""
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Not in this archive — Summer 2008</title>
        <style>
          :root { color-scheme: light; }
          html, body { margin:0; padding:0; min-height:100vh; background:#FBF6EB;
            font-family:-apple-system,'Segoe UI','SF Pro Text','Helvetica Neue',Arial,sans-serif; color:#4A2C20; }
          .wrap { max-width:600px; margin:0 auto; padding:72px 32px 48px; }
          .stamp { display:inline-block; background:#A6192E; color:#FBF6EB;
            font-size:10.5px; letter-spacing:.22em; text-transform:uppercase; font-weight:700;
            padding:5px 12px; border-radius:999px; margin-bottom:16px; }
          h1 { font-family:'Hoefler Text',Georgia,serif; font-style:italic; font-weight:400;
            color:#7C0C1F; font-size:32px; line-height:1.15; margin:0 0 8px; }
          .sub { color:#8c6a5c; font-size:13.5px; margin:0 0 22px; letter-spacing:.04em; }
          p { font-size:14.5px; line-height:1.6; color:#5a3a2e; margin:0 0 14px; }
          code { background:rgba(166,25,46,0.06); border:1px solid rgba(166,25,46,0.16);
            border-radius:4px; padding:2px 7px; font-family:'Segoe UI Mono','SF Mono',Menlo,monospace;
            font-size:12px; color:#7C0C1F; overflow-wrap:anywhere; display:inline-block; max-width:100%; }
          .why { background:rgba(166,25,46,0.05); border-left:3px solid #A6192E;
            padding:14px 18px; font-size:13px; margin:22px 0; border-radius:4px;
            color:#6a4d40; line-height:1.55; }
          .actions { display:flex; gap:10px; flex-wrap:wrap; margin-top:24px; }
          .btn { display:inline-block; padding:10px 22px; border-radius:999px;
            font-size:11px; letter-spacing:.2em; text-transform:uppercase; font-weight:600;
            text-decoration:none; cursor:pointer; border:1px solid transparent;
            font-family:-apple-system,'Segoe UI',sans-serif; }
          .btn.primary { background:#A6192E; color:#FBF6EB; }
          .btn.primary:hover { filter:brightness(1.06); }
          .btn.ghost { background:transparent; color:#A6192E; border-color:#A6192E; }
          .btn.ghost:hover { background:rgba(166,25,46,0.08); }
          .foot { margin-top:56px; font-size:11.5px; color:#b08c7c; letter-spacing:.06em; }
        </style></head><body>
          <main class="wrap">
            <span class="stamp">Not in this archive</span>
            <h1>
        """);
        sb.Append(System.Net.WebUtility.HtmlEncode(subtitle));
        sb.Append(" wasn’t preserved.</h1><p class=\"sub\">You were heading toward <code>");
        sb.Append(System.Net.WebUtility.HtmlEncode(displayURL));
        sb.Append("""
        </code></p>
            <p>This subdomain was a live, server-backed system in 2008 — shopping cart, account login, real-time checkout, in-browser product database. None of that can function as a static snapshot, so the URL filter deliberately skipped it during the 2008 crawl.</p>
            <div class="why">The Summer 2008 archive focuses on what 2008 American Girl actually <em>was</em> as an experience for kids: the character sites, the magazine activities, the Flash games, the e-cards, the Kit Kittredge movie tie-in. Everything you can <em>do</em> got preserved. The e-commerce surface didn’t.</div>
            <p>If you remember something specific from this subdomain — a product page screenshot, a saved order confirmation, a banner image, anything — let me know. Cataloging what was lost matters too.</p>
            <div class="actions">
              <a class="btn primary" href="agd://dashboard/index.html">Back to the Dashboard</a>
              <a class="btn ghost" href="agd://www.americangirl.com/">Mirror Homepage</a>
            </div>
            <p class="foot">Summer 2008 · An American Girl Archive</p>
          </main></body></html>
        """);
        return sb.ToString();
    }

    private static string NotFoundHtml(Uri uri)
    {
        var url = uri.ToString();
        var waybackUrl = "https://web.archive.org/web/2008/http://" + uri.Host + uri.AbsolutePath
                       + (string.IsNullOrEmpty(uri.Query) ? "" : uri.Query);
        var encoded = System.Net.WebUtility.HtmlEncode(url);
        var waybackEncoded = System.Net.WebUtility.HtmlEncode(waybackUrl);
        return $"""
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Not in this archive — Summer 2008</title>
        <style>
          :root {{ color-scheme: light; }}
          html, body {{ margin:0; padding:0; min-height:100vh; background:#FBF6EB;
            font-family:-apple-system,'Segoe UI','SF Pro Text',sans-serif; color:#4A2C20; }}
          .wrap {{ max-width:560px; margin:0 auto; padding:88px 32px 48px; }}
          .stamp {{ display:inline-block; background:#A6192E; color:#FBF6EB;
            font-size:10.5px; letter-spacing:.22em; text-transform:uppercase; font-weight:700;
            padding:5px 12px; border-radius:999px; margin-bottom:16px; }}
          h1 {{ font-family:'Hoefler Text',Georgia,serif; font-style:italic; font-weight:400;
            color:#7C0C1F; font-size:28px; line-height:1.18; margin:0 0 12px; }}
          p {{ font-size:14px; line-height:1.6; color:#5a3a2e; margin:0 0 14px; }}
          code {{ background:rgba(166,25,46,0.06); border:1px solid rgba(166,25,46,0.16);
            border-radius:4px; padding:2px 7px; font-family:'Segoe UI Mono','SF Mono',Menlo,monospace;
            font-size:11.5px; color:#7C0C1F; overflow-wrap:anywhere; display:inline-block; max-width:100%; }}
          .actions {{ display:flex; gap:10px; flex-wrap:wrap; margin-top:24px; }}
          .btn {{ display:inline-block; padding:9px 20px; border-radius:999px;
            font-size:10.5px; letter-spacing:.2em; text-transform:uppercase; font-weight:600;
            text-decoration:none; border:1px solid transparent;
            font-family:-apple-system,'Segoe UI',sans-serif; }}
          .btn.primary {{ background:#A6192E; color:#FBF6EB; }}
          .btn.ghost {{ background:transparent; color:#A6192E; border-color:#A6192E; }}
        </style></head><body>
          <main class="wrap">
            <span class="stamp">Not in this archive</span>
            <h1>That page wasn’t crawled.</h1>
            <p>The URL <code>{encoded}</code> isn’t in the bundled 2008 snapshot.</p>
            <p>You might find it on the Wayback Machine’s live capture — closest 2008 mirror is here:</p>
            <div class="actions">
              <a class="btn primary" href="{waybackEncoded}" target="_blank">Try the Wayback Machine</a>
              <a class="btn ghost" href="agd://dashboard/index.html">Back to the Dashboard</a>
            </div>
          </main></body></html>
        """;
    }
}
