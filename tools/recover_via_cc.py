#!/usr/bin/env python3
"""Recover URLs that Wayback didn't have by pulling them from Common Crawl.

For each input URL:
  1. Query Common Crawl's CC-MAIN-2008-2009 index for matching records.
  2. For each record, byte-range fetch the WARC entry from S3.
  3. Decompress the WARC record, parse out the HTTP response body, save.

The CC index entry gives us: filename, offset, length. We do a single
`Range: bytes=offset-(offset+length-1)` HTTP GET on
`https://data.commoncrawl.org/<filename>`, decompress the gzipped record
inline, and split off the HTTP response body. Way faster than Wayback's
rate-limited per-URL fetch.
"""

from __future__ import annotations
import argparse
import gzip
import io
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
CC_INDEX_API = "https://index.commoncrawl.org"
CC_DATA = "https://data.commoncrawl.org"
UA = "Summer 2008 Archive recovery (preservation) +noindex"

# Try each index in order; stop at the first hit. The 2008-2009 index is
# the temporal sweet spot for AG's mid-2008 era, but the site stayed up
# largely unchanged for years afterwards so the later annual crawls also
# often have copies. We stop at 2015 because by then AG had migrated to
# new templates and the URL shapes had drifted.
CC_INDEXES = [
    "CC-MAIN-2008-2009",
    "CC-MAIN-2009-2010",
    "CC-MAIN-2012",
    "CC-MAIN-2013-20",
    "CC-MAIN-2013-48",
    "CC-MAIN-2014-10",
    "CC-MAIN-2014-23",
    "CC-MAIN-2014-35",
    "CC-MAIN-2014-49",
    "CC-MAIN-2015-06",
    "CC-MAIN-2015-22",
    "CC-MAIN-2015-40",
]


def safe_local_path(url: str) -> Path:
    """Mirror the downloader's path convention so files land where the app
    looks for them."""
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


def _normalize_url_for_cc(url: str) -> str:
    """CC's index strips default ports — `http://host:80/path` is keyed as
    `http://host/path`. Strip the default-port suffix so our lookups match."""
    p = urllib.parse.urlsplit(url)
    host = p.hostname or ""
    if (p.scheme == "http" and p.port == 80) or (p.scheme == "https" and p.port == 443):
        netloc = host
    elif p.port:
        netloc = f"{host}:{p.port}"
    else:
        netloc = host
    return urllib.parse.urlunsplit((p.scheme, netloc, p.path, p.query, p.fragment))


def _cc_lookup_one_index(index: str, url: str) -> list[dict]:
    api = f"{CC_INDEX_API}/{index}-index?" + urllib.parse.urlencode({
        "url": _normalize_url_for_cc(url),
        "output": "json",
        "limit": 20,
    })
    req = urllib.request.Request(api, headers={"User-Agent": UA})
    out = []
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            for line in r:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
    except Exception:
        return []
    return out


def cc_lookup(url: str) -> tuple[str | None, list[dict]]:
    """Search across CC indexes; return (winning_index, hits) for the
    first index that has at least one capture."""
    for idx in CC_INDEXES:
        hits = _cc_lookup_one_index(idx, url)
        if hits:
            return (idx, hits)
        time.sleep(0.15)  # be gentle on the index API
    return (None, [])


def fetch_warc_record(filename: str, offset: int, length: int) -> bytes | None:
    """Byte-range fetch one record from a CC WARC on S3."""
    url = f"{CC_DATA}/{filename}"
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Range": f"bytes={offset}-{offset + length - 1}",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except Exception as e:  # noqa: BLE001
        print(f"    warc-fetch failed: {e}", file=sys.stderr)
        return None


def _strip_http_response(rest: bytes) -> bytes | None:
    """Given bytes starting with `HTTP/x.x <code> ...\\r\\n<headers>\\r\\n\\r\\n<body>`,
    return the body if it's a 2xx; None otherwise."""
    sep = rest.find(b"\r\n\r\n")
    if sep < 0:
        # Some ancient records use bare \n separators.
        sep = rest.find(b"\n\n")
        if sep < 0:
            return None
        http_headers = rest[:sep]
        body = rest[sep + 2:]
    else:
        http_headers = rest[:sep]
        body = rest[sep + 4:]

    first_line = http_headers.split(b"\n", 1)[0].decode("latin-1", errors="ignore").strip()
    m = re.match(r"HTTP/\d\.\d\s+(\d{3})", first_line)
    if not m:
        return None
    code = int(m.group(1))
    if not (200 <= code < 300):
        return None

    if re.search(rb"^Content-Encoding:\s*gzip", http_headers,
                 re.MULTILINE | re.IGNORECASE):
        try:
            body = gzip.decompress(body)
        except OSError:
            pass

    return body


def parse_warc_response(blob: bytes) -> bytes | None:
    """Decompress a single Common Crawl record and return the HTTP response body.

    CC index entries may point at either WARC (CC-MAIN-2014+ and modern
    crawls) or ARC (CC-MAIN-2008-2009, the legacy IA format). The two
    have different framing around the HTTP response:

      WARC layout (after gunzip):
          WARC/1.0\\r\\n
          WARC-Type: response\\r\\n  ...headers...\\r\\n
          \\r\\n
          HTTP/1.1 200 OK\\r\\n  ...headers...\\r\\n\\r\\n
          <body>

      ARC layout (after gunzip):
          <url> <ip> <date> <mime> <length>\\n           ← single-line metadata
          HTTP/1.1 200 OK\\r\\n  ...headers...\\r\\n\\r\\n
          <body>
    """
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(blob)) as g:
            raw = g.read()
    except OSError:
        raw = blob

    if raw.startswith(b"WARC/"):
        # WARC: skip the WARC header block (terminated by blank line),
        # then parse the inner HTTP response.
        sep = raw.find(b"\r\n\r\n")
        if sep < 0:
            return None
        warc_headers = raw[:sep]
        if b"WARC-Type: response" not in warc_headers:
            return None
        return _strip_http_response(raw[sep + 4:])

    # ARC: first line is metadata, then HTTP response. The metadata is
    # space-separated: <url> <ip> <date> <mime-type> <length>.
    nl = raw.find(b"\n")
    if nl < 0:
        return None
    first_line = raw[:nl].decode("latin-1", errors="ignore")
    if " " not in first_line:
        return None
    # Sanity-check: the first token should look URL-ish.
    if not first_line.startswith(("http://", "https://")):
        return None
    return _strip_http_response(raw[nl + 1:])


def recover_one(url: str, force: bool = False) -> tuple[str, str]:
    dest = safe_local_path(url)
    if dest.exists() and dest.stat().st_size > 0 and not force:
        return ("skip", str(dest))

    idx, hits = cc_lookup(url)
    if not hits:
        return ("no-captures", url)

    hits_200 = [h for h in hits if h.get("status") == "200"] or hits
    hits_200.sort(key=lambda h: h.get("timestamp", ""), reverse=True)

    for h in hits_200[:5]:
        filename = h.get("filename")
        offset = int(h.get("offset", 0))
        length = int(h.get("length", 0))
        if not filename or length <= 0:
            continue
        blob = fetch_warc_record(filename, offset, length)
        if blob is None:
            continue
        body = parse_warc_response(blob)
        if body is None or len(body) == 0:
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".tmp")
        tmp.write_bytes(body)
        tmp.rename(dest)
        return ("ok", f"{idx} {h.get('timestamp', '?')} ({len(body)}B) -> {dest}")
    return ("no-content", f"{idx}: tried {min(5, len(hits_200))} captures, none yielded usable content")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--urls-file", default=None,
                    help="File with one URL per line; default reads stdin")
    ap.add_argument("--force", action="store_true",
                    help="Re-download even if file already exists on disk")
    args = ap.parse_args()

    if args.urls_file:
        urls = [l.strip() for l in Path(args.urls_file).read_text().splitlines()
                if l.strip() and not l.startswith("#")]
    else:
        urls = [l.strip() for l in sys.stdin if l.strip() and not l.startswith("#")]

    print(f"Recovering {len(urls)} URLs from {len(CC_INDEXES)} CC indexes "
          f"({CC_INDEXES[0]} … {CC_INDEXES[-1]})")
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
        time.sleep(0.25)

    print()
    print(f"Summary: ok={ok}  skip={skipped}  no-captures={no_cap}  no-content={no_content}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
