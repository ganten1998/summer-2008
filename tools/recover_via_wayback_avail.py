#!/usr/bin/env python3
"""Recover via Wayback's `availability` API.

Different from recover_via_cc.py and the main downloader:
  - The main downloader picks WHATEVER timestamp came first in our CDX
    extract, which sometimes is a useless 302 redirect (e.g. molly/book.php's
    2007-09 capture is a redirect; the 2008-04 capture is the real content).
  - This script asks Wayback's availability API for the closest *good*
    snapshot to our 2008-07-11 anchor, then fetches that one.

Avoids the rate-limited CDX search API (which times out) and the urllib
redirect bug (we explicitly handle 302s).
"""
from __future__ import annotations
import argparse
import gzip
import json
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
UA = "Summer 2008 Archive recovery +preservation"


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


def best_timestamp(url: str) -> str | None:
    """Ask Wayback's availability API for the best snapshot."""
    api = "https://archive.org/wayback/available?" + urllib.parse.urlencode({
        "url": url,
        "timestamp": ANCHOR,
    })
    req = urllib.request.Request(api, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read())
        snap = data.get("archived_snapshots", {}).get("closest")
        if snap and snap.get("status") == "200":
            return snap.get("timestamp")
        return None
    except Exception as e:  # noqa: BLE001
        print(f"    avail-api failed: {e}", file=sys.stderr)
        return None


def fetch_at(url: str, timestamp: str) -> bytes | None:
    """Fetch via id_ raw replay. Manually inspect Location headers to
    distinguish 'no capture redirect to live' from 'real content'."""
    wb = f"https://web.archive.org/web/{timestamp}id_/{url}"
    req = urllib.request.Request(wb, headers={
        "User-Agent": UA,
        "Accept": "*/*",
        "Accept-Encoding": "gzip",
    })
    # Build an opener with no auto-redirect so we can inspect 302s.
    class NoRedir(urllib.request.HTTPRedirectHandler):
        def http_error_302(self, req, fp, code, msg, headers):
            raise urllib.error.HTTPError(req.full_url, code,
                                         "no-content (redirect to live)",
                                         headers, fp)
        http_error_301 = http_error_303 = http_error_307 = http_error_302
    opener = urllib.request.build_opener(NoRedir())
    try:
        with opener.open(req, timeout=45) as resp:
            data = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                try:
                    data = gzip.decompress(data)
                except OSError:
                    pass
            return data if data else None
    except urllib.error.HTTPError as e:
        # A 302 here means Wayback redirected us out — no usable capture.
        if e.code in (301, 302, 303, 307):
            loc = e.headers.get("Location", "")
            # If the redirect target is ALSO a Wayback URL with a different
            # timestamp, follow it manually (Wayback sometimes redirects
            # between timestamps internally).
            if loc.startswith("https://web.archive.org/") or loc.startswith("http://web.archive.org/"):
                try:
                    req2 = urllib.request.Request(loc, headers={"User-Agent": UA, "Accept-Encoding": "gzip"})
                    with urllib.request.urlopen(req2, timeout=45) as r2:
                        d2 = r2.read()
                        if r2.headers.get("Content-Encoding") == "gzip":
                            try:
                                d2 = gzip.decompress(d2)
                            except OSError:
                                pass
                        return d2 if d2 else None
                except Exception:
                    return None
            return None
        return None
    except Exception:
        return None


def recover_one(url: str, force: bool = False) -> tuple[str, str]:
    dest = safe_local_path(url)
    if dest.exists() and dest.stat().st_size > 0 and not force:
        return ("skip", str(dest))

    ts = best_timestamp(url)
    if not ts:
        return ("no-captures", url)

    data = fetch_at(url, ts)
    if not data or len(data) == 0:
        return ("no-content", f"availability-api said ts={ts}; fetch returned empty")

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    tmp.write_bytes(data)
    tmp.rename(dest)
    return ("ok", f"{ts} ({len(data)}B) -> {dest}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--urls-file", default=None,
                    help="File with one URL per line; default reads stdin")
    ap.add_argument("--force", action="store_true",
                    help="Re-download even if file already exists")
    args = ap.parse_args()

    if args.urls_file:
        urls = [l.strip() for l in Path(args.urls_file).read_text().splitlines()
                if l.strip() and not l.startswith("#")]
    else:
        urls = [l.strip() for l in sys.stdin if l.strip() and not l.startswith("#")]

    print(f"Recovering {len(urls)} URLs via Wayback availability API")
    print(f"Anchor: {ANCHOR}")
    print()

    ok = skipped = no_cap = no_content = 0
    for i, url in enumerate(urls, 1):
        status, detail = recover_one(url, force=args.force)
        marker = {"ok": "✓", "skip": "·", "no-captures": "✗", "no-content": "?"}[status]
        print(f"[{i:>3}/{len(urls)}] {marker} {status:>11}  {url}")
        if status == "ok":
            ok += 1
            print(f"                    {detail}")
        elif status == "skip":
            skipped += 1
        elif status == "no-captures":
            no_cap += 1
        else:
            no_content += 1
            print(f"                    {detail}")
        time.sleep(0.3)

    print()
    print(f"Summary: ok={ok}  skip={skipped}  no-captures={no_cap}  no-content={no_content}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
