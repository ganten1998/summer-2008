#!/usr/bin/env python3
"""Last-ditch asset recovery — tries every web archive we know about.

For each URL, we attempt sources in order, stopping at first non-empty:

  1. Wayback CDX exhaustive. recover_via_wayback_avail.py only tries the
     single closest snapshot returned by the availability API. CDX lists
     EVERY capture; we walk all captures with statuscode 200, oldest first
     (older captures are more likely to have the original asset before
     site cleanups). Often finds bytes the availability-API call missed.

  2. Wayback host-swap. Same exhaustive CDX walk but against the alternate
     host (americangirl.com ↔ www.americangirl.com). Crawlers sometimes
     only indexed one form.

  3. Memento Time Travel aggregator. timetravel.mementoweb.org federates
     archive.today, UK Web Archive, LoC Web Archive, Library and Archives
     Canada, etc. Returns memento URIs from non-Wayback archives that we
     wouldn't otherwise find.

  4. archive.today direct. archive.ph isn't fully indexed by Memento; try
     it directly.

  5. Live current americangirl.com. Desperate last try — sometimes a 2008
     asset is still on the production CDN years later.

Output: bytes written to mirror/<host>/<sanitized-path>. Per-URL log line
indicates which source won (or 'EXHAUSTED' if all failed).

Usage:
  python tools/exhaustive_recovery.py <urls-file> [--label NAME]
"""
from __future__ import annotations
import argparse
import gzip
import io
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
UA = "Summer 2008 archive recovery (preservation) +noreply@example.com"
TIMEOUT = 30


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


def http_get(url: str, allow_redirects: bool = True, timeout: int = TIMEOUT) -> tuple[int, bytes, dict] | None:
    """GET a URL; return (status, body, headers) or None on failure.

    Body is gzip-decoded if appropriate. allow_redirects=False uses a
    no-redirect opener so we can inspect 302s (useful for Wayback's
    'no capture available' redirects)."""
    req = urllib.request.Request(url, headers={
        "User-Agent": UA, "Accept": "*/*", "Accept-Encoding": "gzip",
    })
    if allow_redirects:
        opener = urllib.request.build_opener()
    else:
        class NoRedir(urllib.request.HTTPRedirectHandler):
            def http_error_302(self, req, fp, code, msg, headers):
                raise urllib.error.HTTPError(req.full_url, code, "redirect", headers, fp)
            http_error_301 = http_error_303 = http_error_307 = http_error_302
        opener = urllib.request.build_opener(NoRedir())
    try:
        with opener.open(req, timeout=timeout) as resp:
            data = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                try:
                    data = gzip.decompress(data)
                except OSError:
                    pass
            return resp.status, data, dict(resp.headers)
    except urllib.error.HTTPError as e:
        try:
            data = e.read()
        except Exception:
            data = b""
        return e.code, data, dict(e.headers)
    except Exception:
        return None


# ───── source 1+2: Wayback CDX exhaustive ──────────────────────────────────

def wayback_cdx_captures(url: str, limit: int = 25) -> list[str]:
    """List timestamps for every 200-status capture of <url>, oldest first.

    The 'limit' is per-query, and we ask Wayback for the oldest ones (most
    likely to predate site changes that broke the asset)."""
    api = ("http://web.archive.org/cdx/search/cdx?" + urllib.parse.urlencode({
        "url": url,
        "output": "json",
        "filter": "statuscode:200",
        "limit": limit,
        # Drop the most-frequent-timestamp duplicates; we just need distinct ones.
        "collapse": "timestamp:8",
    }))
    r = http_get(api, timeout=20)
    if not r or r[0] != 200 or not r[1]:
        return []
    try:
        rows = json.loads(r[1])
    except Exception:
        return []
    # First row is header: ["urlkey","timestamp","original","mimetype","statuscode","digest","length"]
    if not rows or len(rows) < 2:
        return []
    return [row[1] for row in rows[1:] if len(row) > 1]


def fetch_wayback_at(timestamp: str, original_url: str) -> bytes | None:
    """Raw replay via id_ flag; verify it isn't an empty 'no-capture' redirect."""
    wb = f"https://web.archive.org/web/{timestamp}id_/{original_url}"
    r = http_get(wb, allow_redirects=False, timeout=45)
    if not r:
        return None
    status, body, headers = r
    if status in (301, 302, 303, 307):
        loc = headers.get("Location") or headers.get("location") or ""
        if loc.startswith("https://web.archive.org/") or loc.startswith("http://web.archive.org/"):
            r2 = http_get(loc, timeout=45)
            return r2[1] if r2 and r2[1] else None
        return None
    if status != 200 or not body:
        return None
    return body


def try_wayback_cdx(url: str) -> bytes | None:
    """Walk every capture for <url>, oldest first; first non-empty wins."""
    timestamps = wayback_cdx_captures(url)
    for ts in timestamps:
        b = fetch_wayback_at(ts, url)
        if b:
            return b
        time.sleep(0.25)
    return None


def try_wayback_host_swap(url: str) -> bytes | None:
    """Try the same exhaustive CDX walk against the bare/www host swap."""
    p = urllib.parse.urlsplit(url)
    if p.hostname == "americangirl.com":
        alt = url.replace("//americangirl.com", "//www.americangirl.com", 1)
    elif p.hostname == "www.americangirl.com":
        alt = url.replace("//www.americangirl.com", "//americangirl.com", 1)
    else:
        return None
    return try_wayback_cdx(alt)


# ───── source 3: Memento Time Travel aggregator ────────────────────────────

def try_memento_aggregator(url: str) -> bytes | None:
    """timetravel.mementoweb.org returns mementos across multiple archives.

    We skip web.archive.org URIs (already tried via CDX) and try anything else."""
    api = f"http://timetravel.mementoweb.org/api/json/20080711000000/{url}"
    r = http_get(api, timeout=20)
    if not r or r[0] != 200 or not r[1]:
        return None
    try:
        data = json.loads(r[1])
    except Exception:
        return None
    mementos = data.get("mementos", {})
    candidate_uris: list[str] = []
    for key in ("closest", "first", "last"):
        m = mementos.get(key)
        if not m:
            continue
        for u in (m.get("uri") or []):
            if "web.archive.org" in u:
                continue
            candidate_uris.append(u)
    # Also pull more if there's a timemap link
    tm = (data.get("timemap_uri") or {}).get("json_format")
    if tm:
        r2 = http_get(tm, timeout=20)
        if r2 and r2[0] == 200 and r2[1]:
            try:
                tmdata = json.loads(r2[1])
                for entry in tmdata.get("mementos", {}).get("list", []) or []:
                    u = entry.get("uri")
                    if u and "web.archive.org" not in u and u not in candidate_uris:
                        candidate_uris.append(u)
            except Exception:
                pass
    for uri in candidate_uris[:8]:  # cap per-URL
        r3 = http_get(uri, timeout=30)
        if r3 and r3[0] == 200 and r3[1] and len(r3[1]) > 32:
            # Heuristic: non-empty body that doesn't look like an archive's
            # "no capture" stub
            return r3[1]
        time.sleep(0.25)
    return None


# ───── source 4: archive.today direct ──────────────────────────────────────

def try_archive_today(url: str) -> bytes | None:
    """archive.ph/newest/<url> redirects to most-recent capture (HTML wrapper)."""
    api = f"https://archive.ph/newest/{url}"
    r = http_get(api, timeout=30)
    if not r or r[0] != 200 or not r[1]:
        return None
    # archive.today serves the asset content directly for image/asset URLs
    # (wrapped in their domain), or returns an HTML page for HTML captures.
    # If body looks like an HTML wrapper page (starts with <!DOCTYPE), bail.
    body = r[1]
    if body[:15].lower().startswith(b"<!doctype html") or body[:6].lower().startswith(b"<html"):
        return None
    if len(body) < 32:
        return None
    return body


# ───── source 5: live americangirl.com ─────────────────────────────────────

def try_live_current(url: str) -> bytes | None:
    """Some 2008-era assets are still hosted on the live AG CDN."""
    # Try original URL, plus https:// upgrade
    candidates = [url]
    if url.startswith("http://"):
        candidates.append("https://" + url[len("http://"):])
    for c in candidates:
        r = http_get(c, timeout=15)
        if r and r[0] == 200 and r[1] and len(r[1]) > 32:
            # Make sure it isn't a generic 404 page that returned 200
            if b"page not found" in r[1][:2048].lower() or b"<title>404" in r[1][:2048].lower():
                continue
            return r[1]
    return None


# ───── orchestrator ────────────────────────────────────────────────────────

SOURCES = [
    ("cdx-exhaustive",     try_wayback_cdx),
    ("cdx-host-swap",      try_wayback_host_swap),
    ("memento-aggregator", try_memento_aggregator),
    ("archive-today",      try_archive_today),
    ("live-ag",            try_live_current),
]


def recover_one(url: str) -> tuple[str, str, int]:
    """Try every source for one URL. Returns (status, detail, bytes-written)."""
    dest = safe_local_path(url)
    if dest.exists() and dest.stat().st_size > 0:
        return ("skip", "already on disk", 0)
    for name, fn in SOURCES:
        try:
            data = fn(url)
        except Exception as e:
            data = None
        if data:
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix(dest.suffix + ".tmp")
            tmp.write_bytes(data)
            tmp.rename(dest)
            return ("ok", f"{name} ({len(data)}B)", len(data))
        time.sleep(0.2)
    return ("EXHAUSTED", "all 5 sources empty", 0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("urls_file")
    ap.add_argument("--label", default="EXH")
    args = ap.parse_args()

    urls = [l.strip() for l in Path(args.urls_file).read_text().splitlines() if l.strip()]
    print(f"=== {args.label} exhaustive recovery: {len(urls)} URLs across {len(SOURCES)} sources ===", flush=True)

    by_source: dict[str, int] = {}
    exhausted: list[str] = []
    ok = skip = 0

    for i, url in enumerate(urls, 1):
        status, detail, _ = recover_one(url)
        marker = {"ok": "✓", "skip": "·", "EXHAUSTED": "✗"}.get(status, "?")
        print(f"[{i:>3}/{len(urls)}] {marker} {status:>10}  {url}", flush=True)
        if status == "ok":
            ok += 1
            src = detail.split()[0]
            by_source[src] = by_source.get(src, 0) + 1
            print(f"                    {detail}", flush=True)
        elif status == "skip":
            skip += 1
        else:
            exhausted.append(url)
        time.sleep(0.3)

    print(f"\n=== {args.label} DONE ===", flush=True)
    print(f"recovered: {ok}   skipped: {skip}   exhausted: {len(exhausted)}", flush=True)
    if by_source:
        print("by source:", flush=True)
        for src, n in sorted(by_source.items(), key=lambda kv: -kv[1]):
            print(f"  {src:>22}: {n}", flush=True)
    if exhausted:
        exh_file = Path(args.urls_file).resolve().parent / f"exhaustive_unrecovered_{args.label.lower()}.txt"
        exh_file.write_text("\n".join(exhausted) + "\n")
        print(f"\nFinal exhausted list: {exh_file}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
