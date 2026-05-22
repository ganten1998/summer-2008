#!/usr/bin/env python3
"""Retry failed URLs by hunting through Wayback's full capture history.

The main downloader uses one timestamp per URL — whatever was in our
2007–2008 CDX. When Wayback doesn't actually have an `id_` capture at
that timestamp, it returns a 302 to the original URL, and the script
mistook that for a "real" failure (the redirect chases the dead live
site, gets "Connection refused").

This recovery pass:
  1. For each failed URL, queries Wayback's CDX API for *all* captures
     (any date, any status code).
  2. Sorts captures by proximity to the 2008-07-11 anchor.
  3. Tries each in turn with redirect-following DISABLED, so we get an
     honest "no archive content" instead of a redirect chase.
  4. First successful fetch wins; saves under the same mirror path as
     the main downloader would.
"""

from __future__ import annotations
import argparse
import gzip
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIRROR = ROOT / "mirror"
ANCHOR = "20080711"
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "AGD-Launcher/1.0 (+research/preservation; recovery)"
)


def safe_local_path(url: str) -> Path:
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "unknown").lower()
    path = parts.path or "/"
    if path.endswith("/"):
        path = path + "index.html"
    leaf = path.rsplit("/", 1)[-1]
    if "." not in leaf and not parts.query:
        path = path + "/index.html"
    if parts.query:
        q = re.sub(r"[^A-Za-z0-9._-]+", "_", parts.query)[:128]
        path = path + "__" + q
        if "." not in leaf:
            path += ".html"
    segs = [host] + [s for s in path.split("/") if s]
    segs = [re.sub(r"[^A-Za-z0-9._@,~+()=#%-]+", "_", s) for s in segs]
    return MIRROR.joinpath(*segs)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Surface Wayback redirects (302s out of `id_` URLs mean 'no capture')
    instead of silently following them to the dead live site."""
    def http_error_302(self, req, fp, code, msg, headers):
        raise urllib.error.HTTPError(req.full_url, code, "redirect (no id_ capture)", headers, fp)
    http_error_301 = http_error_303 = http_error_307 = http_error_302


NO_REDIRECT_OPENER = urllib.request.build_opener(NoRedirectHandler())


def cdx_lookup(url: str) -> list[str]:
    """Return all Wayback timestamps for this URL (any year, any status)."""
    api = ("https://web.archive.org/cdx/search/cdx?"
           "url=" + urllib.parse.quote(url, safe="") +
           "&output=json&fl=timestamp,statuscode&limit=200")
    req = urllib.request.Request(api, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read())
        if not data or len(data) < 2:
            return []
        # data[0] is header row; rest are [timestamp, statuscode]
        # Prefer 200s, then 302s (sometimes 302 captures still have content).
        good = [row[0] for row in data[1:] if row[1] == "200"]
        meh  = [row[0] for row in data[1:] if row[1] != "200"]
        return good + meh
    except Exception as e:  # noqa: BLE001
        print(f"    cdx-lookup failed: {e}", file=sys.stderr)
        return []


def fetch_at(url: str, timestamp: str) -> bytes | None:
    """Try fetching one specific Wayback timestamp for this URL. None on miss."""
    wb = f"https://web.archive.org/web/{timestamp}id_/{url}"
    req = urllib.request.Request(wb, headers={
        "User-Agent": UA,
        "Accept": "*/*",
        "Accept-Encoding": "gzip",
        "Connection": "keep-alive",
    })
    try:
        with NO_REDIRECT_OPENER.open(req, timeout=45) as resp:
            data = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                try:
                    data = gzip.decompress(data)
                except OSError:
                    pass
            return data if data else None
    except urllib.error.HTTPError as e:
        if e.code in (429, 503):
            time.sleep(15)  # quick adaptive backoff
        return None
    except Exception:
        return None


def proximity_sort(timestamps: list[str]) -> list[str]:
    """Sort by absolute distance from the 2008-07-11 anchor (newest first
    within equal distance)."""
    anchor = int(ANCHOR + "000000")
    def key(ts):
        try:
            t = int((ts + "00000000000000")[:14])
        except ValueError:
            return (10**20, 0)
        return (abs(t - anchor), -t)
    return sorted(timestamps, key=key)


def recover_one(url: str) -> tuple[str, str]:
    """Returns (status, detail). status in {ok, no-captures, no-content}."""
    dest = safe_local_path(url)
    if dest.exists() and dest.stat().st_size > 0:
        return ("skip", str(dest))

    captures = cdx_lookup(url)
    if not captures:
        return ("no-captures", url)

    captures = proximity_sort(captures)
    tried = 0
    for ts in captures:
        tried += 1
        if tried > 10:
            break  # give up after the 10 closest captures
        data = fetch_at(url, ts)
        if data and len(data) > 0:
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix(dest.suffix + ".tmp")
            tmp.write_bytes(data)
            tmp.rename(dest)
            return ("ok", f"{ts} ({len(data)}B) -> {dest}")
        time.sleep(0.4)
    return ("no-content", f"tried {tried}/{len(captures)} captures, all empty/redirected")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--urls-file", default=None,
                    help="File with one URL per line; default reads from stdin")
    args = ap.parse_args()

    if args.urls_file:
        urls = [line.strip() for line in Path(args.urls_file).read_text().splitlines() if line.strip()]
    else:
        urls = [line.strip() for line in sys.stdin if line.strip()]

    print(f"Recovering {len(urls)} URLs via Wayback CDX (any capture date)")
    print(f"Anchor: {ANCHOR}, fall-off: try up to 10 nearest captures per URL")
    print()

    ok = no_cap = no_content = skip = 0
    for i, url in enumerate(urls, 1):
        status, detail = recover_one(url)
        marker = {"ok": "✓", "skip": "·", "no-captures": "✗", "no-content": "✗"}[status]
        print(f"[{i:>3}/{len(urls)}] {marker} {status:>11}  {url}")
        if status == "ok":
            ok += 1
            print(f"                    {detail}")
        elif status == "skip":
            skip += 1
        elif status == "no-captures":
            no_cap += 1
        else:
            no_content += 1
            print(f"                    {detail}")
        time.sleep(0.3)

    print()
    print(f"Summary: ok={ok}  skip={skip}  no-captures={no_cap}  no-content={no_content}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
