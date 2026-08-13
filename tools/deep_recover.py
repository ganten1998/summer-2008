#!/usr/bin/env python3
"""Deep multi-strategy recovery for assets the earlier passes could not find.

Why this exists
---------------
`recover_via_wayback_avail.py` and `exhaustive_recovery.py` both ask Wayback
for a *specific* URL. That silently misses a whole class of captures: the
2008 site served many assets with a query string baked into the request
(`ecards/sw/agc_bday_addy.swf?personalMsg=Your+personal+message+goes+here...`).
Wayback keys captures by the *full* URL including query, so an exact-URL CDX
query for `.../agc_bday_addy.swf` returns **zero rows** even though the file
is archived and downloadable. That one blind spot accounts for most of the
"unrecoverable" e-card SWFs.

Strategies, in order (first verified hit wins):

  1. exact       — CDX for the precise URL.
  2. qvariant    — CDX prefix on the *file*, catching `file.swf?...` captures.
  3. hostswap    — repeat 1+2 across every known host alias, with/without :80.
  4. dirsweep    — CDX prefix on the containing *directory*, then match the
                   basename case-insensitively. Recovers files whose captured
                   path differs in case or has extra query cruft.
  5. cdx_any     — CDX with matchType=domain filtered to the basename, for
                   assets that moved between directories.

Every candidate is downloaded through the `id_` raw modifier (no Wayback
toolbar injection) and then **content-verified** by magic bytes for its
extension, so we never write a soft-404 HTML page over a real asset. Among
verified candidates we prefer HTTP 200, then the largest payload, then the
capture closest to the archive's target date (2008-07-11).

Usage:
    python3 tools/deep_recover.py --targets FILE [--out DIR] [--jobs N]
                                  [--report FILE] [--dry-run]

`--out` defaults to the repo's mirror/, writing each asset to
mirror/<host>/<path> exactly where the runtime expects it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIRROR = os.path.join(ROOT, "mirror")

# The snapshot the whole archive is pinned to. Ties break toward this date.
TARGET_TS = "20080711092743"

CDX = "http://web.archive.org/cdx/search/cdx"
WB = "https://web.archive.org/web"

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

# Host aliases the 2008 site answered on. A file missing under one host is
# very often present under another.
HOST_ALIASES = [
    "www.americangirl.com",
    "americangirl.com",
    "club.americangirl.com",
    "store.americangirl.com",
    "mollysblog.americangirl.com",
]

# ── content verification ───────────────────────────────────────────────────
# Wayback happily returns a styled "not archived" HTML page with HTTP 200.
# Without magic-byte checks those land on disk as corrupt .swf/.gif files
# that fail silently inside the app.

MAGIC = {
    ".swf": [b"FWS", b"CWS", b"ZWS"],
    ".dcr": [b"RIFX", b"XFIR", b"RIFF"],
    ".dir": [b"RIFX", b"XFIR"],
    ".gif": [b"GIF87a", b"GIF89a"],
    ".jpg": [b"\xff\xd8\xff"],
    ".jpeg": [b"\xff\xd8\xff"],
    ".png": [b"\x89PNG\r\n\x1a\n"],
    ".pdf": [b"%PDF"],
    ".ico": [b"\x00\x00\x01\x00", b"\x00\x00\x02\x00"],
    ".mov": None,   # checked structurally below
    ".mp3": None,
    ".css": None,   # text checks below
    ".js": None,
    ".xml": None,
    ".html": None,
    ".htm": None,
}

HTML_SMELL = re.compile(
    rb"<html|<!doctype|wayback machine|internet archive|"
    rb"page cannot be (found|displayed)|404 not found|"
    rb"got an HTTP \d+ response",
    re.IGNORECASE)

# The unambiguous "this is an archive error, not content" markers. Applied even
# to formats that may legitimately contain markup (e.g. XML).
ARCHIVE_ERROR = re.compile(
    rb"wayback machine has not archived|got an HTTP \d+ response|"
    rb"the wayback machine is an initiative|"
    rb"this content is not available in the wayback machine",
    re.IGNORECASE)


def verify(data: bytes, ext: str) -> tuple[bool, str, bytes]:
    """Return (ok, reason, bytes_to_write).

    The third element matters: when the replay layer hands back a gzip-wrapped
    payload we must write the *decompressed* bytes. Verifying the inner content
    and then storing the still-compressed wrapper would put a gzip stream on
    disk under a .swf name — Ruffle and the Director projector read the file
    directly off disk with no Content-Encoding negotiation, so it would fail to
    load while passing every check.
    """
    if not data:
        return False, "empty", data
    if len(data) < 16:
        return False, f"too small ({len(data)}B)", data

    # Unwrap gzip once, up front, so every check below sees real content.
    if data.startswith(b"\x1f\x8b"):
        try:
            import gzip
            inner = gzip.decompress(data)
            if inner:
                data = inner
        except Exception:
            return False, "corrupt gzip", data

    magic = MAGIC.get(ext, "unset")

    if isinstance(magic, list):
        if any(data.startswith(m) for m in magic):
            return True, "magic ok", data
        return False, f"bad magic {data[:8]!r}", data

    if ext == ".mov":
        # ISO-BMFF / QuickTime: a top-level atom in the first 12 bytes.
        if any(t in data[:64] for t in (b"ftyp", b"moov", b"mdat", b"wide")):
            return True, "qt atom ok", data
        return False, f"no qt atom {data[:12]!r}", data

    if ext == ".mp3":
        if data.startswith(b"ID3") or data[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
            return True, "mp3 frame ok", data
        return False, "no mp3 frame", data

    if ext in (".css", ".js", ".xml"):
        head = data[:4096]
        # .xml is NOT exempt from the archive-error check. An XML data file is
        # exactly the kind of asset Wayback answers with a soft-404 HTML page,
        # and the games load these directly — a stored error page silently
        # breaks a game rather than failing loudly. Only the generic "<html"
        # smell is relaxed for XML (an XML doc may legitimately embed markup);
        # the unambiguous archive-error strings still reject it.
        if ARCHIVE_ERROR.search(head):
            return False, "archive error page", data
        if ext != ".xml" and HTML_SMELL.search(head):
            return False, "html error page", data
        try:
            head.decode("utf-8")
        except UnicodeDecodeError:
            try:
                head.decode("latin-1")
            except UnicodeDecodeError:
                return False, "not text", data
        return True, "text ok", data

    if ext in (".html", ".htm"):
        if ARCHIVE_ERROR.search(data[:8192]):
            return False, "wayback soft-404", data
        return True, "html ok", data

    # Unknown extension: reject obvious archive error pages, else accept.
    if HTML_SMELL.search(data[:2048]):
        return False, "html error page", data
    return True, "unverified ext, non-trivial", data


# ── HTTP plumbing ──────────────────────────────────────────────────────────

_throttle = threading.Semaphore(8)
_last_call = [0.0]
_lock = threading.Lock()


def http_get(url: str, timeout: int = 60, retries: int = 4) -> bytes | None:
    """GET with polite pacing + exponential backoff on 429/5xx."""
    for attempt in range(retries):
        with _throttle:
            # Global minimum spacing so we stay welcome at archive.org.
            with _lock:
                gap = time.time() - _last_call[0]
                if gap < 0.12:
                    time.sleep(0.12 - gap)
                _last_call[0] = time.time()
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return r.read()
            except urllib.error.HTTPError as e:
                if e.code in (429, 500, 502, 503, 504):
                    time.sleep(min(2 ** attempt * 1.5, 20))
                    continue
                return None
            except Exception:
                time.sleep(min(2 ** attempt, 10))
                continue
    return None


class CDXUnavailable(Exception):
    """The CDX endpoint could not be reached / parsed — distinct from 'no rows'."""


def cdx_query(url_pattern: str, match_type: str | None = None,
              limit: int = 500, filters: list[str] | None = None,
              strict: bool = False) -> list[dict]:
    """Return CDX rows as dicts. Never collapses — we want every capture.

    With strict=True a transport failure raises CDXUnavailable instead of
    returning []. Callers that cache results need that distinction: caching an
    empty list after one network blip permanently marks a directory as having
    no captures for the rest of the run.
    """
    params = {
        "url": url_pattern,
        "output": "json",
        "fl": "original,timestamp,statuscode,length,digest,mimetype",
        "limit": str(limit),
    }
    if match_type:
        params["matchType"] = match_type
    q = CDX + "?" + urllib.parse.urlencode(params)
    for f in (filters or []):
        q += "&filter=" + urllib.parse.quote(f)
    raw = http_get(q, timeout=90)
    if raw is None:
        if strict:
            raise CDXUnavailable(url_pattern)
        return []
    try:
        rows = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        # An empty body is a legitimate "no captures" answer from CDX; a body
        # that exists but will not parse is a transport/format failure.
        if raw.strip():
            if strict:
                raise CDXUnavailable(url_pattern)
        return []
    if not rows or len(rows) < 2:
        return []
    head, body = rows[0], rows[1:]
    return [dict(zip(head, r)) for r in body]


def score(row: dict) -> tuple:
    """Rank candidates: HTTP 200 first, then bigger, then closest to target date."""
    st = str(row.get("statuscode") or "")
    ok200 = 0 if st == "200" else 1
    try:
        length = int(row.get("length") or 0)
    except (TypeError, ValueError):
        length = 0
    ts = str(row.get("timestamp") or "0")
    try:
        distance = abs(int(ts[:8]) - int(TARGET_TS[:8]))
    except ValueError:
        distance = 10 ** 9
    return (ok200, -length, distance)


# Empty-payload SHA1 that Wayback uses for redirect/blank captures.
EMPTY_DIGEST = "3I42H3S6NNFQ2MSVX7XZKYAYSCX5QBYJ"

# Set by --deep. Gates the domain-wide scan (strategy 5), which costs Wayback
# a full-index walk per target and must not run in the first pass.
DEEP = [False]


def usable(row: dict) -> bool:
    if row.get("digest") == EMPTY_DIGEST:
        return False
    st = str(row.get("statuscode") or "")
    # '-' shows up for revisit records, which still replay fine.
    return st in ("200", "-", "")


def download(row: dict) -> bytes | None:
    ts = row.get("timestamp")
    orig = row.get("original")
    if not ts or not orig:
        return None
    return http_get(f"{WB}/{ts}id_/{orig}", timeout=120)


# ── directory sweep cache ──────────────────────────────────────────────────

_dir_cache: dict[str, list[dict]] = {}
_dir_lock = threading.Lock()


def dir_rows(host: str, directory: str) -> list[dict]:
    """CDX prefix enumeration of a directory, cached across targets.

    Only *successful* queries are cached. A transient failure must not be
    memoized as "this directory has no captures" — with dozens of targets
    sharing a directory, one blip would sink all of them for the whole run.
    """
    key = f"{host}{directory}"
    with _dir_lock:
        if key in _dir_cache:
            return _dir_cache[key]
    try:
        rows = cdx_query(f"{host}{directory}*", limit=3000, strict=True)
    except CDXUnavailable:
        return []          # deliberately not cached — retry on the next target
    with _dir_lock:
        _dir_cache[key] = rows
    return rows


def basename_of(original: str) -> str:
    path = urllib.parse.urlsplit(original).path
    return path.rsplit("/", 1)[-1].lower()


# ── the recovery core ──────────────────────────────────────────────────────

def candidates_for(host: str, path: str) -> list[tuple[str, dict]]:
    """Yield (strategy, row) candidates, cheapest strategy first."""
    out: list[tuple[str, dict]] = []
    seen: set[tuple] = set()

    def add(strategy: str, rows: list[dict]):
        for r in rows:
            if not usable(r):
                continue
            k = (r.get("original"), r.get("timestamp"))
            if k in seen:
                continue
            seen.add(k)
            out.append((strategy, r))

    directory, _, fname = path.rpartition("/")
    directory += "/"
    fname_l = fname.lower()

    hosts = [host] + [h for h in HOST_ALIASES if h != host]

    for h in hosts:
        # 1. exact
        add("exact", cdx_query(f"{h}{path}", limit=200))
        # 2. query-variant: prefix on the file itself
        add("qvariant", cdx_query(f"{h}{path}*", limit=200))
        if out:
            break  # cheap strategies hit; don't hammer every alias

    if not out:
        # 4. directory sweep, case-insensitive basename match
        for h in hosts:
            rows = [r for r in dir_rows(h, directory)
                    if basename_of(r.get("original", "")) == fname_l]
            add("dirsweep", rows)
            if out:
                break

    if not out and DEEP[0]:
        # 5. domain-wide search for the basename (asset relocated between
        #    directories). Expensive — Wayback has to scan the whole domain
        #    index — so it is opt-in via --deep and only ever runs against
        #    the residue left by strategies 1-4.
        rows = [r for r in cdx_query("americangirl.com", match_type="domain",
                                     limit=4000,
                                     filters=[f"original:.*{re.escape(fname)}.*"])
                if basename_of(r.get("original", "")) == fname_l]
        add("cdx_any", rows)

    out.sort(key=lambda sr: score(sr[1]))
    return out


def recover_one(target: str, outdir: str, dry_run: bool) -> dict:
    parsed = urllib.parse.urlsplit(
        target if "://" in target else "agd://" + target)
    host = parsed.netloc
    path = parsed.path
    if not path or path.endswith("/"):
        return {"target": target, "status": "skip", "reason": "not a file"}

    ext = os.path.splitext(path)[1].lower()
    dest = os.path.join(outdir, host, path.lstrip("/"))

    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return {"target": target, "status": "already", "dest": dest}

    try:
        cands = candidates_for(host, path)
    except Exception as e:
        return {"target": target, "status": "error", "reason": repr(e)}

    if not cands:
        return {"target": target, "status": "notfound", "tried": "all strategies"}

    attempts = 0
    for strategy, row in cands[:12]:
        attempts += 1
        data = download(row)
        if not data:
            continue
        ok, why, payload = verify(data, ext)
        if not ok:
            continue
        if dry_run:
            return {"target": target, "status": "would-write", "strategy": strategy,
                    "timestamp": row.get("timestamp"), "bytes": len(payload),
                    "via": row.get("original"), "verify": why}
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        # Write to a sibling temp file and rename: os.replace is atomic on the
        # same filesystem, so a killed run can never leave a half-written asset
        # in the mirror. The suffix includes the thread id because several
        # targets can map to the same destination via host aliases.
        tmp = f"{dest}.{threading.get_ident()}.part"
        with open(tmp, "wb") as fh:
            fh.write(payload)
        os.replace(tmp, dest)
        return {"target": target, "status": "recovered", "strategy": strategy,
                "timestamp": row.get("timestamp"), "bytes": len(payload),
                "via": row.get("original"), "dest": dest, "verify": why}

    return {"target": target, "status": "failed-verify",
            "candidates": len(cands), "attempts": attempts}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--targets", required=True,
                    help="file of agd:// or http:// URLs, one per line")
    ap.add_argument("--out", default=MIRROR)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--report", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--deep", action="store_true",
                    help="enable the domain-wide basename scan (slow; use "
                         "only on the residue of a first pass)")
    args = ap.parse_args()
    DEEP[0] = args.deep

    with open(args.targets) as fh:
        targets = [ln.strip() for ln in fh
                   if ln.strip() and not ln.startswith("#")]

    print(f"==> {len(targets)} targets, {args.jobs} workers, out={args.out}")
    results = []
    done = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = {pool.submit(recover_one, t, args.out, args.dry_run): t
                for t in targets}
        for fut in as_completed(futs):
            r = fut.result()
            results.append(r)
            done += 1
            if r["status"] in ("recovered", "would-write"):
                print(f"  [{done}/{len(targets)}] ✓ {r['status']} "
                      f"{r['target']}  ({r.get('strategy')}, "
                      f"{r.get('bytes')}B, {r.get('timestamp')})", flush=True)
            elif done % 25 == 0:
                print(f"  [{done}/{len(targets)}] …", flush=True)

    tally: dict[str, int] = {}
    for r in results:
        tally[r["status"]] = tally.get(r["status"], 0) + 1
    print("\n==> summary")
    for k in sorted(tally, key=lambda k: -tally[k]):
        print(f"    {k:16s} {tally[k]}")

    if args.report:
        with open(args.report, "w") as fh:
            json.dump(results, fh, indent=2)
        print(f"\n    report → {args.report}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
