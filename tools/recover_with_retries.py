#!/usr/bin/env python3
"""Multi-pass wrapper around recover_via_wayback_avail.py.

Usage:
  python tools/recover_with_retries.py <urls-file> [max_passes] [--label NAME]

Each pass invokes the underlying recovery tool and parses its per-URL output.
URLs that returned "no-content" (availability API said a snapshot exists,
fetch returned empty) or "no-captures" (avail API itself errored — could be
real, could be transient) roll into the next pass. Pass output streams live
so it's tail-friendly.
"""
from __future__ import annotations
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "recover_via_wayback_avail.py"

# Per-URL status line emitted by the underlying tool:
#   [  1/697] ✓          ok  http://www.americangirl.com/...
# (status field is right-padded width 11.) Unicode markers vary by status.
LINE_RE = re.compile(r"^\[\s*\d+/\s*\d+\]\s+\S+\s+(\S+)\s+(http\S+)\s*$")


def run_pass(urls_file: Path, pass_n: int, label: str) -> tuple[list[str], list[str], int]:
    n_urls = sum(1 for line in urls_file.read_text().splitlines() if line.strip())
    bar = "=" * 70
    print(f"\n{bar}\n=== {label} PASS {pass_n}  ({n_urls} URLs)  started {time.strftime('%H:%M:%S')}\n{bar}", flush=True)

    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"

    proc = subprocess.Popen(
        [sys.executable, "-u", str(TOOL), "--urls-file", str(urls_file)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        env=env,
    )

    transient: list[str] = []
    no_caps: list[str] = []
    ok = 0
    skipped = 0

    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        m = LINE_RE.match(line.rstrip())
        if not m:
            continue
        status, url = m.group(1), m.group(2)
        if status == "ok":
            ok += 1
        elif status == "skip":
            skipped += 1
        elif status == "no-content":
            transient.append(url)
        elif status == "no-captures":
            no_caps.append(url)

    proc.wait()
    print(
        f"\n--- {label} pass {pass_n} done: ok={ok}  skip={skipped}  "
        f"transient={len(transient)}  no-captures={len(no_caps)} ---",
        flush=True,
    )
    return transient, no_caps, ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("urls_file")
    ap.add_argument("max_passes", nargs="?", type=int, default=3)
    ap.add_argument("--label", default="MAIN")
    args = ap.parse_args()

    current = Path(args.urls_file).resolve()
    total_ok = 0
    final_unrecovered: list[str] = []
    last_pass = 0

    for pass_n in range(1, args.max_passes + 1):
        last_pass = pass_n
        transient, no_caps, ok = run_pass(current, pass_n, args.label)
        total_ok += ok
        remaining = transient + no_caps
        if not remaining:
            print(f"✓ {args.label}: nothing left to retry after pass {pass_n}.", flush=True)
            break
        if pass_n == args.max_passes:
            final_unrecovered = remaining
            break
        retry_file = current.parent / f"recovery_pass{pass_n + 1}_{args.label.lower()}.txt"
        retry_file.write_text("\n".join(remaining) + "\n")
        print(f"→ Pass {pass_n + 1}: retrying {len(remaining)} URLs (transient + no-captures)", flush=True)
        current = retry_file
        time.sleep(5)

    bar = "=" * 70
    print(f"\n{bar}\n=== {args.label} DONE: {total_ok} files recovered across {last_pass} passes ===", flush=True)
    if final_unrecovered:
        fail_file = Path(args.urls_file).resolve().parent / f"recovery_unrecovered_{args.label.lower()}.txt"
        fail_file.write_text("\n".join(final_unrecovered) + "\n")
        print(f"=== {len(final_unrecovered)} URLs unrecoverable. Listed at: {fail_file} ===", flush=True)
    print(bar, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
