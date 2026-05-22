#!/usr/bin/env python3
"""Polite, resumable Wayback mirror downloader — optimized variant.

Reads build/cdx/url_list.json and fetches each URL in raw (`id_`) form,
saving under mirror/<host>/<path>. Tuned for highest throughput within
Wayback's per-IP rate limit:

  * Per-worker (NOT global) adaptive backoff. One 429 only pauses the
    offending worker; the others keep fetching. Pause duration starts
    short (15s) and doubles on consecutive 429s, decaying back as
    successful fetches accumulate. Replaces the old "first 429 freezes
    everyone for 60s" behavior — single biggest throughput win.
  * 3 workers (up from 2) + 0.3s baseline per-request spacing.
  * 2 retries per URL (down from 4) — saves ~15s on each genuinely-dead URL.
  * --shard N/M: only process URLs where hash(url) % M == N. Lets you
    run multiple parallel instances on the same queue without races.
  * --source-ip IP: bind outbound HTTPS sockets to a specific local IP,
    so a second instance running over an iPhone USB tether (or any
    secondary interface) appears to Wayback as a different IP and gets
    its own rate-limit budget — effectively doubling throughput.
  * --log <file>: split logs cleanly between parallel runs.
"""

from __future__ import annotations
import argparse
import concurrent.futures as cf
import gzip
import http.client
import json
import os
import random
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
URL_LIST = ROOT / "build" / "cdx" / "url_list.json"
MIRROR = ROOT / "mirror"
DEFAULT_LOG = ROOT / "build" / "mirror_progress.log"

MAX_WORKERS = 3
PER_REQUEST_DELAY = 0.3
TIMEOUT = 45
RETRIES = 2

PRIORITY: dict[str, int] = {
    "swf": 0, "dcr": 0,
    "html": 1, "htm": 1, "":  1, "php": 1, "jsp": 1, "jsf": 1,
    "css": 2, "js": 2, "xml": 2, "txt": 2,
    "gif": 3, "jpg": 3, "jpeg": 3, "png": 3, "ico": 3,
    "pdf": 4,
}

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "AGD-Launcher/1.0 (+research/preservation; offline mirror)"
)

# ────────────────────────────────────────────────── source-IP binding
# When --source-ip is set, urllib opens HTTPS sockets bound to that
# local interface IP, so Wayback sees us as that IP rather than the
# Mac's default route. This is how the iPhone-tether parallel speedup
# works: bind the second downloader to the tethered iPhone's IP.
BIND_IP: str | None = None


def _build_opener_with_bind() -> urllib.request.OpenerDirector:
    class BoundHTTPSConnection(http.client.HTTPSConnection):
        def __init__(self, host, *a, **kw):
            if BIND_IP and "source_address" not in kw:
                kw["source_address"] = (BIND_IP, 0)
            super().__init__(host, *a, **kw)

    class BoundHTTPSHandler(urllib.request.HTTPSHandler):
        def https_open(self, req):
            return self.do_open(BoundHTTPSConnection, req)

    return urllib.request.build_opener(BoundHTTPSHandler())


_opener: urllib.request.OpenerDirector | None = None


def _opener_or_default() -> urllib.request.OpenerDirector:
    global _opener
    if _opener is None:
        _opener = _build_opener_with_bind()
    return _opener


# ────────────────────────────────────────────────── per-worker backoff
# Each worker has its own pause window. A 429/503 hit only freezes the
# offending worker; the other two keep pulling. Adaptive duration
# (15s → 30s → 60s) escalates on consecutive failures and decays on
# successes, so transient blips don't snowball.
_pause_lock = threading.Lock()
_pause_until: dict[int, float] = {}        # worker_id -> wake time
_429_counter_lock = threading.Lock()
_consecutive_429 = 0

stats = {"ok": 0, "skip": 0, "fail": 0, "bytes": 0, "started": time.time()}
_stats_lock = threading.Lock()


def _worker_id() -> int:
    return threading.get_ident()


def per_worker_pause() -> None:
    wid = _worker_id()
    while True:
        with _pause_lock:
            wait = _pause_until.get(wid, 0.0) - time.time()
        if wait <= 0:
            return
        time.sleep(min(wait, 1.0))


def trigger_worker_pause(base_seconds: float = 15.0) -> float:
    global _consecutive_429
    with _429_counter_lock:
        _consecutive_429 = min(_consecutive_429 + 1, 4)
        # 15s → 30s → 60s → 60s on the 4th. Capped so we never
        # wait more than a minute on a single hit.
        duration = min(60.0, base_seconds * (2 ** (min(_consecutive_429, 3) - 1)))
    wid = _worker_id()
    with _pause_lock:
        _pause_until[wid] = max(_pause_until.get(wid, 0.0), time.time() + duration)
    return duration


def report_success() -> None:
    global _consecutive_429
    with _429_counter_lock:
        if _consecutive_429 > 0:
            _consecutive_429 -= 1


# ────────────────────────────────────────────────── fetch
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


def fetch_one(timestamp: str, url: str) -> tuple[str, str]:
    dest = safe_local_path(url)
    if dest.exists() and dest.stat().st_size > 0:
        with _stats_lock:
            stats["skip"] += 1
        return ("skip", str(dest))

    per_worker_pause()

    wb = f"https://web.archive.org/web/{timestamp}id_/{url}"
    req = urllib.request.Request(wb, headers={
        "User-Agent": UA,
        "Accept": "*/*",
        "Accept-Encoding": "gzip",
        "Connection": "keep-alive",
    })

    opener = _opener_or_default()
    last_status = "err:unknown"
    for attempt in range(1, RETRIES + 1):
        try:
            with opener.open(req, timeout=TIMEOUT) as resp:
                data = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    try:
                        data = gzip.decompress(data)
                    except OSError:
                        pass
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix(dest.suffix + ".tmp")
            tmp.write_bytes(data)
            tmp.rename(dest)
            with _stats_lock:
                stats["ok"] += 1
                stats["bytes"] += len(data)
            report_success()
            time.sleep(PER_REQUEST_DELAY + random.uniform(0, 0.15))
            return ("ok", str(dest))
        except urllib.error.HTTPError as e:
            if e.code in (404, 403):
                with _stats_lock:
                    stats["fail"] += 1
                return (f"http-{e.code}", url)
            if e.code in (429, 503):
                trigger_worker_pause(15.0)
                last_status = f"http-{e.code}"
            else:
                last_status = f"http-{e.code}"
        except urllib.error.URLError as e:
            msg = str(getattr(e, "reason", e))
            if "Connection refused" in msg or "timed out" in msg.lower():
                trigger_worker_pause(20.0)
            last_status = f"err:{msg}"
        except (socket.timeout, http.client.HTTPException) as e:
            last_status = f"err:{e}"
        except Exception as e:  # noqa: BLE001
            last_status = f"err:{e}"
        # Per-attempt jitter before retry. RETRIES=2 means total ~3s of
        # retry pause per dead URL, vs ~20s before.
        time.sleep(1.5 * attempt + random.uniform(0, 0.5))

    with _stats_lock:
        stats["fail"] += 1
    return (last_status, url)


def url_priority(url: str) -> int:
    parts = urllib.parse.urlsplit(url)
    leaf = parts.path.rsplit("/", 1)[-1]
    ext = leaf.rsplit(".", 1)[-1].lower() if "." in leaf else ""
    return PRIORITY.get(ext, 5)


def shard_key(url: str, shard: int, total: int) -> bool:
    """Stable selection: True if THIS instance should handle URL."""
    if total <= 1:
        return True
    # Cheap, stable, well-distributed hash.
    h = 0
    for ch in url:
        h = (h * 131 + ord(ch)) & 0xFFFFFFFF
    return (h % total) == shard


def main() -> int:
    global BIND_IP
    ap = argparse.ArgumentParser()
    ap.add_argument("--shard", default="0/1",
                    help="N/M — only fetch URLs where hash(url) %% M == N")
    ap.add_argument("--source-ip", default=None,
                    help="Bind outbound sockets to this local IP (for tethered second instance)")
    ap.add_argument("--log", default=str(DEFAULT_LOG),
                    help="Per-URL progress log file (parallel runs should use different paths)")
    args = ap.parse_args()

    try:
        shard_n_str, shard_m_str = args.shard.split("/", 1)
        shard_n, shard_m = int(shard_n_str), int(shard_m_str)
        assert 0 <= shard_n < shard_m, "shard N must be < M"
    except Exception as e:  # noqa: BLE001
        print(f"--shard invalid ({e}); expected N/M like 0/2", file=sys.stderr)
        return 2

    if args.source_ip:
        BIND_IP = args.source_ip
        print(f"Binding outbound sockets to {BIND_IP}")

    if not URL_LIST.exists():
        print(f"Missing {URL_LIST} -- run build_url_list.py first.", file=sys.stderr)
        return 2
    urls = json.loads(URL_LIST.read_text())
    if shard_m > 1:
        urls = [u for u in urls if shard_key(u["url"], shard_n, shard_m)]
        print(f"Shard {shard_n}/{shard_m}: {len(urls)} URLs assigned to this instance")
    urls.sort(key=lambda u: (url_priority(u["url"]), u["url"]))
    tier_counts: dict[int, int] = {}
    for u in urls:
        t = url_priority(u["url"])
        tier_counts[t] = tier_counts.get(t, 0) + 1
    print(f"Mirroring {len(urls)} URLs -> {MIRROR} "
          f"(workers={MAX_WORKERS}, delay={PER_REQUEST_DELAY}s, retries={RETRIES})")
    print(f"Priority tiers: {dict(sorted(tier_counts.items()))}")

    MIRROR.mkdir(parents=True, exist_ok=True)
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logf = log_path.open("a", buffering=1)
    logf.write(f"# === run started {time.strftime('%Y-%m-%d %H:%M:%S')} "
               f"shard={shard_n}/{shard_m} bind={BIND_IP or '-'} ===\n")

    last_print = time.time()
    last_count = 0
    with cf.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = [pool.submit(fetch_one, u["timestamp"], u["url"]) for u in urls]
        for i, f in enumerate(cf.as_completed(futures), 1):
            status, target = f.result()
            logf.write(f"{status}\t{target}\n")
            now = time.time()
            if now - last_print > 5 or i == len(futures):
                elapsed = now - stats["started"]
                rate = (i - last_count) / max(1e-6, now - last_print)
                with _pause_lock:
                    max_pause = max(0.0, max(
                        (t - now for t in _pause_until.values()), default=0.0))
                with _429_counter_lock:
                    c429 = _consecutive_429
                print(
                    f"  {i}/{len(urls)}  ok={stats['ok']} skip={stats['skip']} "
                    f"fail={stats['fail']}  {stats['bytes']/1e6:.1f}MB  "
                    f"{rate:.1f} req/s  elapsed={elapsed:.0f}s  429s={c429}"
                    + (f"  paused {max_pause:.0f}s" if max_pause > 0.5 else ""),
                    flush=True,
                )
                last_print = now
                last_count = i

    logf.close()
    print("\nDone.", stats)
    return 0


if __name__ == "__main__":
    sys.exit(main())
