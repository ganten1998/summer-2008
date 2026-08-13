#!/usr/bin/env python3
"""Verify every binary asset in the mirror is actually what its extension says.

Earlier recovery passes fetched from Wayback without checking magic bytes.
Wayback answers a miss with a styled HTML "not archived" page and HTTP 200,
so a failed recovery lands on disk as a .swf/.gif/.jpg of the right name and
the wrong content. The app then fails at runtime — a blank Ruffle canvas or a
broken image — with nothing in the build output to suggest anything is wrong.

This walks the mirror and reports any file whose leading bytes contradict its
extension, plus zero-byte files and HTML error pages masquerading as assets.

    python3 tools/verify_mirror_integrity.py [--mirror DIR] [--delete-corrupt]

Exit status is 1 if anything corrupt was found, so it can gate a release.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MAGIC = {
    ".swf": [b"FWS", b"CWS", b"ZWS"],
    ".dcr": [b"RIFX", b"XFIR", b"RIFF"],
    ".dir": [b"RIFX", b"XFIR"],
    ".dxr": [b"RIFX", b"XFIR"],
    ".gif": [b"GIF87a", b"GIF89a"],
    ".jpg": [b"\xff\xd8\xff"],
    ".jpeg": [b"\xff\xd8\xff"],
    ".png": [b"\x89PNG\r\n\x1a\n"],
    ".pdf": [b"%PDF"],
    ".mp3": [b"ID3", b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"],
    ".ico": [b"\x00\x00\x01\x00", b"\x00\x00\x02\x00"],
    ".zip": [b"PK\x03\x04"],
}

# Wayback / server error pages that got saved with an asset extension.
ERROR_SMELL = re.compile(
    rb"wayback machine has not archived|got an HTTP \d+ response|"
    rb"<title>\s*Internet Archive|Page cannot be found|"
    rb"<!DOCTYPE html|<html",
    re.IGNORECASE)


def check(path: str) -> tuple[str, str] | None:
    """Return (kind, detail) if the file is bad, else None."""
    ext = os.path.splitext(path)[1].lower()
    try:
        size = os.path.getsize(path)
    except OSError as e:
        return ("unreadable", repr(e))

    if size == 0:
        return ("empty", "0 bytes")

    magic = MAGIC.get(ext)
    if not magic:
        return None

    try:
        with open(path, "rb") as fh:
            head = fh.read(4096)
    except OSError as e:
        return ("unreadable", repr(e))

    if any(head.startswith(m) for m in magic):
        return None

    # Gzipped-but-valid is acceptable; the runtime decompresses.
    if head.startswith(b"\x1f\x8b"):
        return None

    if ERROR_SMELL.search(head[:2048]):
        return ("html-error-page", f"{size}B, starts {head[:24]!r}")

    # A file whose bytes are a *different but valid* image format is not
    # damage — the 2008 servers really did hand out JPEGs named .gif, and
    # every browser (including WKWebView and WebView2) sniffs image content
    # rather than trusting the extension. Flag it separately so it does not
    # fail a release gate.
    for other_ext, other_magic in MAGIC.items():
        if other_ext == ext:
            continue
        if any(head.startswith(m) for m in other_magic):
            return ("mislabeled", f"{size}B, is actually {other_ext} "
                                  f"(authentic 2008 server behaviour, renders fine)")

    return ("bad-magic", f"{size}B, starts {head[:24]!r}")


# Win32 forbids these in filenames. A mirror file that violates them makes
# `git checkout` fail outright on Windows — which takes down the Windows CI
# build at step one, before anything is compiled. This has regressed once
# already (35 files fixed in da17646, 9 reintroduced in 457035a), so it is
# checked on every run rather than trusted.
WIN_RESERVED_CHARS = set('<>:"|?*')
WIN_RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}


def windows_unsafe(name: str) -> str | None:
    if name != name.rstrip(". "):
        return "ends with a dot or space"
    if WIN_RESERVED_CHARS & set(name):
        bad = "".join(sorted(WIN_RESERVED_CHARS & set(name)))
        return f"contains reserved character(s) {bad}"
    if name.split(".")[0].upper() in WIN_RESERVED_NAMES:
        return f"uses the reserved device name {name.split('.')[0]}"
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mirror", default=os.path.join(ROOT, "mirror"))
    ap.add_argument("--delete-corrupt", action="store_true",
                    help="remove files that are HTML error pages or empty "
                         "(so a recovery pass can re-fetch them)")
    args = ap.parse_args()

    bad: dict[str, list[tuple[str, str]]] = defaultdict(list)
    total = 0
    for dirpath, _dirnames, filenames in os.walk(args.mirror):
        for name in filenames:
            path = os.path.join(dirpath, name)
            total += 1

            unsafe = windows_unsafe(name)
            if unsafe:
                bad["windows-illegal-name"].append(
                    (os.path.relpath(path, args.mirror), unsafe))

            verdict = check(path)
            if verdict:
                kind, detail = verdict
                bad[kind].append((os.path.relpath(path, args.mirror), detail))

    print(f"scanned {total} files under {args.mirror}")
    if not bad:
        print("✓ every asset's content matches its extension")
        return 0

    removed = 0
    for kind in sorted(bad):
        entries = bad[kind]
        print(f"\n== {kind} ({len(entries)}) ==")
        for rel, detail in sorted(entries)[:40]:
            print(f"  {rel}\n      {detail}")
        if len(entries) > 40:
            print(f"  … and {len(entries) - 40} more")

        if args.delete_corrupt and kind in ("html-error-page", "empty"):
            for rel, _ in entries:
                try:
                    os.remove(os.path.join(args.mirror, rel))
                    removed += 1
                except OSError:
                    pass

    if removed:
        print(f"\nremoved {removed} corrupt files — re-run deep_recover.py "
              f"to try to refill them")

    # Only genuine damage fails the gate. "mislabeled" is faithful to the
    # original site and "empty" is usually a real zero-byte file (robots.txt).
    fatal = sum(len(v) for k, v in bad.items()
                if k in ("html-error-page", "bad-magic", "unreadable",
                         "windows-illegal-name"))
    informational = sum(len(v) for k, v in bad.items()
                        if k in ("mislabeled", "empty"))
    print(f"\n{fatal} genuinely corrupt, {informational} informational")
    if fatal == 0:
        print("✓ no corrupt assets — safe to ship")
    return 1 if fatal else 0


if __name__ == "__main__":
    sys.exit(main())
