#!/usr/bin/env python3
"""Filter the raw CDX dump into a tight set of URLs to mirror.

Tight scope (fast first pass):
  * EVERY .swf and .dcr on the domain, no matter the host
  * On www.americangirl.com / americangirl.com only: html, htm, css, js, xml,
    pdf, images (jpg/png/gif/ico). These are needed for the site to render.
  * Skip store.americangirl.com entirely -- it's dynamic e-commerce that
    won't function offline.
  * Skip Akamai-obfuscated product pages (.pa5wnl9*) under any host.

Images that AREN'T grabbed here (e.g. on store.* subdomains) are backfilled
on demand by the Swift app's custom URL scheme handler when first requested.
"""

from __future__ import annotations
import json
import sys
import re
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
CDX = ROOT / "build" / "cdx" / "all_2007_2008.json"
OUT = ROOT / "build" / "cdx" / "url_list.json"

PRIMARY_HOSTS = {
    "www.americangirl.com",
    "americangirl.com",
    "mollysblog.americangirl.com",   # added: small archive of in-character posts
    "club.americangirl.com",          # added: AG club subsite
}
KEEP_EXTS_PRIMARY = {
    "html", "htm", "css", "js", "xml", "txt", "pdf",
    "jpg", "jpeg", "png", "gif", "ico",
    "swf", "dcr",
    # added: server-rendered wrappers (Addy uses .php for menu/games/friends;
    # other character pages live on .jsp/.jsf; some .cgi/.pl utilities exist)
    "php", "jsp", "jsf", "cgi", "pl",
    # added: media + fonts so the archive plays / renders fully offline
    "mp3", "mp4", "mov", "wav",
    "woff", "woff2", "ttf",
}
KEEP_EXTS_ANY_HOST = {"swf", "dcr"}
SKIP_EXT_PREFIX = "pa5wnl9"  # Akamai's encoded product page extension

# Path prefixes that are server-side functionality (won't work offline) or
# noise (store landing pages, CGI scripts, login/logout endpoints). We drop
# them even when the extension matches our keep-list.
SKIP_PATH_PREFIXES = (
    "/stores/",       # store popups, packages, seating charts — no backend
    "/cgi-bin/",      # Perl/CGI scripts — execute server-side
    "/cgi/",
    "/flash.cgi",
    "/input_filter.php",
    "/logout.php",
)


def ext_of(url: str) -> str:
    path = urlsplit(url).path
    last = path.rsplit("/", 1)[-1]
    if "." in last:
        return last.rsplit(".", 1)[-1].lower()
    return ""


def keep(url: str) -> bool:
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    path = parts.path or "/"
    e = ext_of(url)
    if e.startswith(SKIP_EXT_PREFIX):
        return False
    # Drop server-side / backend paths even when the extension matches.
    for prefix in SKIP_PATH_PREFIXES:
        if path.startswith(prefix):
            return False
    if e in KEEP_EXTS_ANY_HOST:
        return True
    if host in PRIMARY_HOSTS:
        if e in KEEP_EXTS_PRIMARY:
            return True
        if e == "":
            # Directory-style URL (e.g. /games/farmJumble/). Keep -- these are
            # almost always real navigable pages.
            return True
    return False


def main() -> int:
    data = json.loads(CDX.read_text())
    rows = data[1:]
    keep_rows: list[dict] = []
    seen: set[str] = set()
    for r in rows:
        ts, url = r[1], r[2]
        if url in seen:
            continue
        if not keep(url):
            continue
        seen.add(url)
        keep_rows.append({"timestamp": ts, "url": url})
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(keep_rows, indent=2))
    print(f"Kept {len(keep_rows)} of {len(rows)} URLs -> {OUT}")

    host_count: dict[str, int] = {}
    ext_count: dict[str, int] = {}
    for r in keep_rows:
        h = (urlsplit(r["url"]).hostname or "").lower()
        host_count[h] = host_count.get(h, 0) + 1
        e = ext_of(r["url"]) or "(none)"
        ext_count[e] = ext_count.get(e, 0) + 1
    print("\nHosts:")
    for h, n in sorted(host_count.items(), key=lambda x: -x[1])[:10]:
        print(f"  {n:6d}  {h}")
    print("\nExtensions:")
    for e, n in sorted(ext_count.items(), key=lambda x: -x[1])[:15]:
        print(f"  {n:6d}  .{e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
