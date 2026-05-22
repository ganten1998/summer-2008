#!/usr/bin/env python3
"""Rewrite every mirrored HTML/CSS/JS file so that it works inside the WKWebView
when served via the `agd://` scheme.

Transformations:
  * Absolute URLs to americangirl.com hosts -> agd:// + same host
        http://www.americangirl.com/foo       -> agd://www.americangirl.com/foo
        http://www.americangirl.com:80/foo    -> agd://www.americangirl.com/foo
        http://store.americangirl.com/foo     -> agd://store.americangirl.com/foo
        //www.americangirl.com/foo            -> agd://www.americangirl.com/foo
  * SWFObject embeds, <object data="...swf">, <embed src="...swf"> rewritten
    so the user can also right-click "open game" – the Swift navigation
    delegate already routes /.swf/.dcr clicks to the projector.
  * Inert third-party tracking <script src="..."> tags rewritten to /dev/null
    style URLs so the WebView doesn't error out on doubleclick.net,
    webtrendslive.com, cetrk.com, etc.
  * Wipes broken document.write tracking calls.

The script is idempotent (a file that's already patched short-circuits via a
sentinel comment we inject at the top) and writes a single backup copy of the
original mirror as `mirror_unpatched/` the first time it runs.
"""

from __future__ import annotations
import argparse
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIRROR = ROOT / "mirror"
BACKUP = ROOT / "mirror_unpatched"
SENTINEL = "<!-- AGD-PATCHED v5 -->"
# Old sentinel markers we know how to recognize so we can force a re-patch
# when the format changes. When any of these are seen we restore the file
# from BACKUP/ before re-running the patcher.
OLD_SENTINELS = (
    "<!-- AGD-PATCHED v1 -->",
    "<!-- AGD-PATCHED v2 -->",
    "<!-- AGD-PATCHED v3 -->",
    "<!-- AGD-PATCHED v4 -->",
)

# Hosts we re-route to our scheme. Anything else stays untouched so the
# blank-screen failure mode is obvious instead of silently broken.
AGD_HOSTS = (
    "www.americangirl.com",
    "americangirl.com",
    "store.americangirl.com",
    "stage.store.americangirl.com",
    "club.americangirl.com",
    "shop.americangirl.com",
    "aka.www.americangirl.com",
    "mollysblog.americangirl.com",
    "emailresp.americangirl.com",
)

TRACKER_HOSTS = (
    "doubleclick.net",
    "ad.doubleclick.net",
    "webtrendslive.com",
    "statse.webtrendslive.com",
    "cetrk.com",
    "google-analytics.com",
    "googletagmanager.com",
    "googlesyndication.com",
    "scorecardresearch.com",
    "omniture.com",
    "2o7.net",
)

ABS_HOST_RE = re.compile(
    r"\b(https?:)?//"                                       # scheme + //
    r"([A-Za-z0-9.-]+\.americangirl\.com)"                  # host
    r"(?::\d+)?"                                            # optional :80
    r"(?=[/'\"\s>?#])",                                     # boundary
)

DOCWRITE_TRACKING_RE = re.compile(
    r"document\.write\(\s*['\"]<(?:img|script|noscript)[^'\"]*"
    r"(?:doubleclick|webtrendslive|cetrk|omniture|2o7|scorecard|googletag)"
    r"[^'\"]*['\"]\s*[^)]*\)\s*;?",
    re.IGNORECASE,
)


def rewrite_absolute_host(html_text: str) -> str:
    """http(s)://*.americangirl.com[:80]/... -> agd://same-host/..."""
    def repl(m: re.Match[str]) -> str:
        host = m.group(2).lower()
        if host in AGD_HOSTS:
            return f"agd://{host}"
        return m.group(0)  # untouched
    return ABS_HOST_RE.sub(repl, html_text)


def neutralize_trackers(html_text: str) -> str:
    out = html_text
    for host in TRACKER_HOSTS:
        # Replace any reference to a tracker host with a clearly-broken local
        # path so the WebView can fail fast & quiet (404 from our handler).
        out = re.sub(
            r"https?://[A-Za-z0-9.-]*" + re.escape(host) + r"[^\s'\"<>)]*",
            "agd://disabled/" + host.split(".")[0],
            out,
            flags=re.IGNORECASE,
        )
    # Wipe analytics document.write() calls that would otherwise leave broken
    # <img>/<script> tags in the DOM at parse time.
    out = DOCWRITE_TRACKING_RE.sub("/* AGD: tracker stripped */", out)
    return out


# Order matters: ruffle-boot configures Ruffle, then ruffle.js auto-polyfills
# every Flash embed on the page with an inline WebAssembly player, then
# flash-bridge hooks Ruffle's error events and provides a projector fallback.
RUNTIME_TAGS = (
    '<script src="agd://runtime/ruffle-boot.js" '
    'data-agd-runtime="ruffle-boot"></script>'
    '<script src="agd://runtime/ruffle/ruffle.js" '
    'data-agd-runtime="ruffle"></script>'
    '<script src="agd://runtime/flash-bridge.js" '
    'data-agd-runtime="flash-bridge"></script>'
    '<script src="agd://runtime/volume-control.js" '
    'data-agd-runtime="volume-control"></script>'
)


def patch_html(text: str) -> tuple[str, bool]:
    """Return (new_text, changed)."""
    if SENTINEL in text:
        return text, False
    original = text
    text = rewrite_absolute_host(text)
    text = neutralize_trackers(text)
    text = neutralize_dead_endpoints(text)
    # Inject our sentinel + runtime scripts into <head> so Ruffle is wired up
    # BEFORE any page-level Flash scripts execute.
    injection = SENTINEL + "\n" + RUNTIME_TAGS
    if "<head>" in text:
        text = text.replace("<head>", "<head>\n" + injection, 1)
    elif text.lstrip().startswith("<!DOCTYPE"):
        text = re.sub(r"(<!DOCTYPE[^>]*>)", r"\1\n" + injection, text, count=1)
    else:
        text = injection + "\n" + text
    return text, text != original


# Patterns that point at server-side handlers the static mirror can't run.
# When the patcher sees a `<form action="...">` matching one of these, it
# rewrites the form so submitting it shows a "this used to be live in 2008"
# notice instead of either 404ing or silently doing nothing.
DEAD_ACTION_RE = re.compile(
    r'''(?ix)
    \b(action|src|href)\s*=\s*
    ["']
    (
        (?:agd|http|https)?:?(?://[^/"']+)?     # optional scheme+host
        /[^"']*?                                # path
        \.(?:cgi|pl|jsp|jsf|asp|aspx)           # server-only extension
        (?:\?[^"']*)?                           # optional query
    )
    ["']
    '''
)

# Specific PHP endpoints we KNOW are dead (no static capture). Customize.php
# is handled by the wizard separately; the rest are search/login/contact.
DEAD_PHP_ENDPOINTS = (
    "/contact.php",
    "/search.php",
    "/login.php",
    "/register.php",
    "/cart.php",
    "/checkout.php",
    "/account.php",
    "/feedback.php",
    "/emailus.php",
    "/preview.php",   # ecard preview — superseded by our wizard
    "/send.php",      # ecard send  — superseded by our wizard
)


def neutralize_dead_endpoints(html_text: str) -> str:
    """Replace `<form action="...cgi/jsp/etc">` and known-dead PHP form
    actions so submitting goes to a styled stub page instead of a 404 or a
    fall-through to the dead live server. The stub URL points at
    `agd://www.americangirl.com/__agd/dead-form.html` which the runtime
    serves from mirror-runtime/.

    We also drop `<form ... method="post">` if its action matched, since
    static archives can't accept POSTs anyway.
    """
    def rewrite_form_tag(match: re.Match[str]) -> str:
        whole = match.group(0)
        # Pull out the action
        m = re.search(r'''action\s*=\s*["']([^"']+)["']''', whole, re.IGNORECASE)
        if not m:
            return whole
        action = m.group(1)
        if not _action_is_dead(action):
            return whole
        # Rewrite action to our stub + drop method (we don't accept POST).
        new = re.sub(
            r'''action\s*=\s*["'][^"']+["']''',
            'action="agd://www.americangirl.com/__agd/dead-form.html"',
            whole, count=1, flags=re.IGNORECASE,
        )
        new = re.sub(r'''\bmethod\s*=\s*["']post["']''', 'method="get"',
                     new, count=1, flags=re.IGNORECASE)
        return new

    # Only touch `<form ...>` opening tags (not </form>).
    html_text = re.sub(
        r'<form\b[^>]*>',
        rewrite_form_tag,
        html_text,
        flags=re.IGNORECASE,
    )
    return html_text


def _action_is_dead(action: str) -> bool:
    """True if the form action targets a server-side endpoint the mirror
    can't satisfy. Order matters: we whitelist a few known-good static
    paths first so we don't break working flows."""
    a = action.lower()
    # Known-good static paths (let them through unchanged):
    safe_passes = (
        "/__agd/",       # our synthetic pages
        "agd://runtime", # runtime
        "agd://dashboard",
    )
    if any(s in a for s in safe_passes):
        return False
    # Bare-fragment / javascript: / mailto:  — leave alone, those have their
    # own handling.
    if a.startswith(("#", "javascript:", "mailto:", "tel:")):
        return False
    # Extension-based detection
    if re.search(r"\.(cgi|pl|jsp|jsf|asp|aspx)(\?|$)", a):
        return True
    # Specific PHP endpoints we marked dead
    for ep in DEAD_PHP_ENDPOINTS:
        if ep in a:
            return True
    return False


CSS_JS_MARKER = "/* AGD-PATCHED v1 */"


def patch_css(text: str) -> tuple[str, bool]:
    """CSS files: rewrite absolute url(...) references."""
    if CSS_JS_MARKER in text:
        return text, False
    new = rewrite_absolute_host(text)
    new = neutralize_trackers(new)
    new = CSS_JS_MARKER + "\n" + new
    return new, True


def patch_js(text: str) -> tuple[str, bool]:
    if CSS_JS_MARKER in text:
        return text, False
    new = rewrite_absolute_host(text)
    new = neutralize_trackers(new)
    new = CSS_JS_MARKER + "\n" + new
    return new, True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-backup", action="store_true",
                    help="Skip making a backup copy of mirror/ at mirror_unpatched/")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not MIRROR.exists():
        print(f"No {MIRROR} directory; nothing to patch.", file=sys.stderr)
        return 1

    if not args.no_backup and not BACKUP.exists():
        print(f"Creating one-time backup at {BACKUP}/ ...")
        shutil.copytree(MIRROR, BACKUP)

    handlers = {
        ".html": patch_html,
        ".htm": patch_html,
        # PHP files in the mirror are pre-rendered HTML the crawler saved
        # under the original PHP URL — treat them like HTML so Ruffle gets
        # injected, otherwise pages like agcn/addy/menu.php render bare
        # 2008 HTML with broken Flash embeds.
        ".php": patch_html,
        ".css": patch_css,
        ".js": patch_js,
    }

    def true_suffix(path: Path) -> str:
        """The downloader appends `__<query-string>` to URLs with query
        strings (e.g. `choose.php?ecard=X&theme=Y` is saved as
        `choose.php__ecard_X_theme_Y`). Path.suffix on that returns the
        bogus '.php__ecard_X_theme_Y' instead of '.php', so the handler
        lookup misses it. Strip the query suffix first so query-shaped
        pages still get Ruffle injected. Without this, every ecard
        wrapper, every `ecards/index.php?theme=…`, and every other
        query-parameterized PHP page renders bare HTML with dead Flash
        embeds.
        """
        name = path.name
        if "__" in name:
            name = name.split("__", 1)[0]
        return Path(name).suffix.lower()

    changed = unchanged = errored = restored = 0
    for p in MIRROR.rglob("*"):
        if not p.is_file():
            continue
        h = handlers.get(true_suffix(p))
        if not h:
            continue
        try:
            raw = p.read_bytes()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                text = raw.decode("latin-1")

            # If this file still carries an OLD sentinel, restore the
            # untouched source from BACKUP/ so we can re-patch with the
            # current injection. Without this step, files patched on a
            # previous build would never get the new Ruffle scripts.
            if (BACKUP.exists()
                    and any(s in text for s in OLD_SENTINELS)
                    and SENTINEL not in text):
                rel = p.relative_to(MIRROR)
                src = BACKUP / rel
                if src.exists():
                    if not args.dry_run:
                        shutil.copy2(src, p)
                    raw = p.read_bytes()
                    try:
                        text = raw.decode("utf-8")
                    except UnicodeDecodeError:
                        text = raw.decode("latin-1")
                    restored += 1

            new_text, did_change = h(text)
            if did_change and not args.dry_run:
                p.write_text(new_text, encoding="utf-8")
            if did_change:
                changed += 1
            else:
                unchanged += 1
        except Exception as e:  # noqa: BLE001
            print(f"!! {p}: {e}", file=sys.stderr)
            errored += 1

    if restored:
        print(f"Restored {restored} files from {BACKUP.name}/ before re-patching")

    print(f"\nPatched: {changed} files changed, {unchanged} already-patched/no-op, {errored} errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
