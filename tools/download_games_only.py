#!/usr/bin/env python3
"""Fast/polite download of just the SWF + DCR files (the playable games).

This is a focused first pass: small payload (~170 URLs), big payoff (every
Flash & Shockwave asset). Runs single-threaded with a modest delay to stay
well under Wayback's rate ceiling, and surfaces a tidy summary of what we
got versus what 404'd.

After this runs, build/games_inventory.json lists each game's:
  * original URL on www.americangirl.com
  * local path under mirror/ (if download succeeded)
  * download status ("ok" / "http-404" / "err:...")
This file is consumed downstream by tools/match_flashpoint.py.
"""

from __future__ import annotations
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
URL_LIST = ROOT / "build" / "cdx" / "url_list.json"
MIRROR = ROOT / "mirror"
INVENTORY = ROOT / "build" / "games_inventory.json"
LOG = ROOT / "build" / "mirror_progress.log"

DELAY = 0.6  # seconds between fetches; ~1.5/s sustained
TIMEOUT = 60
RETRIES = 4

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "AGD-Launcher/1.0 (+offline preservation)"
)


def safe_local_path(url: str) -> Path:
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "unknown").lower()
    path = parts.path
    segs = [host] + [s for s in path.split("/") if s]
    segs = [re.sub(r"[^A-Za-z0-9._@,~+()=#%-]+", "_", s) for s in segs]
    return MIRROR.joinpath(*segs)


def fetch(timestamp: str, url: str) -> tuple[str, Path | None]:
    dest = safe_local_path(url)
    if dest.exists() and dest.stat().st_size > 0:
        return ("skip", dest)
    wb = f"https://web.archive.org/web/{timestamp}id_/{url}"
    req = urllib.request.Request(wb, headers={
        "User-Agent": UA,
        "Accept": "*/*",
        "Accept-Encoding": "gzip",
        "Connection": "keep-alive",
    })
    last = "err:unknown"
    for attempt in range(1, RETRIES + 1):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
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
            return ("ok", dest)
        except urllib.error.HTTPError as e:
            if e.code in (404, 403):
                return (f"http-{e.code}", None)
            last = f"http-{e.code}"
            time.sleep(15 * attempt)  # heavy backoff on 5xx
        except urllib.error.URLError as e:
            msg = str(e.reason)
            last = f"err:{msg}"
            # Connection refused / timeout -> Wayback IP throttle; back off hard.
            time.sleep(45 if ("Connection refused" in msg or "timed out" in msg.lower()) else 5 * attempt)
        except Exception as e:  # noqa: BLE001
            last = f"err:{e}"
            time.sleep(5 * attempt)
    return (last, None)


def main() -> int:
    if not URL_LIST.exists():
        print(f"Missing {URL_LIST}; run build_url_list.py first.", file=sys.stderr)
        return 2
    urls = json.loads(URL_LIST.read_text())

    def ext_of(url: str) -> str:
        path = urllib.parse.urlsplit(url).path
        last = path.rsplit("/", 1)[-1]
        return last.rsplit(".", 1)[-1].lower() if "." in last else ""

    games = [u for u in urls if ext_of(u["url"]) in ("swf", "dcr")]
    games.sort(key=lambda u: u["url"])
    print(f"Downloading {len(games)} game assets (SWF + DCR) into {MIRROR}\n")

    MIRROR.mkdir(parents=True, exist_ok=True)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    logf = LOG.open("a", buffering=1)
    logf.write(f"# === games-only run started {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")

    inventory: list[dict] = []
    start = time.time()
    ok = skipped = failed = 0
    bytes_total = 0
    for i, u in enumerate(games, 1):
        status, dest = fetch(u["timestamp"], u["url"])
        entry = {
            "timestamp": u["timestamp"],
            "url": u["url"],
            "status": status,
            "local_path": (str(dest.relative_to(ROOT)) if dest else None),
            "size": (dest.stat().st_size if dest and dest.exists() else 0),
        }
        inventory.append(entry)
        if status == "ok":
            ok += 1
            bytes_total += entry["size"]
        elif status == "skip":
            skipped += 1
            bytes_total += entry["size"]
        else:
            failed += 1
        logf.write(f"{status}\t{u['url']}\n")
        if i % 5 == 0 or i == len(games):
            el = time.time() - start
            rate = i / max(1e-6, el)
            print(f"  {i}/{len(games)}  ok={ok} skip={skipped} fail={failed} "
                  f"{bytes_total/1e6:.1f}MB  {rate:.2f}/s  elapsed={el:.0f}s",
                  flush=True)
        time.sleep(DELAY)

    INVENTORY.parent.mkdir(parents=True, exist_ok=True)
    INVENTORY.write_text(json.dumps(inventory, indent=2))
    logf.close()
    print(f"\nDone. {ok} downloaded, {skipped} skipped, {failed} failed.")
    print(f"Inventory: {INVENTORY}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
