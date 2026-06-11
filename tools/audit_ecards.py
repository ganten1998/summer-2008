#!/usr/bin/env python3
"""Audit the e-card chain: theme/index pages → choose.php pages → SWFs.

For every e-card key the chooser pages reference, verify:
  1. a choose.php__ecard_<key>* page exists in the mirror
  2. that page's embedded SWF resolves to a file on disk
     (exact, or a __personalMsg query-variant capture)
  3. the thumbnail image the chooser shows for that key exists
  4. name-affinity heuristic between key and SWF stem, to flag
     pairings that smell wrong (thumbnail-vs-content mismatches)

Run from anywhere; paths are derived from this file's location.
"""
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ECARDS = os.path.join(ROOT, "mirror", "www.americangirl.com", "ecards")
SW = os.path.join(ECARDS, "sw")
IMAGES = os.path.join(ECARDS, "images")

# --- collect chooser listings: key -> (thumb, source page) -------------
# Anchor pattern in index/theme pages:
#   <a href="choose.php?ecard=KEY&action=choose...."> ... <img src="images/THUMB">
LINK_RE = re.compile(
    r"""choose\.php\?ecard=([a-zA-Z0-9_]+)[^>]*>(.*?)</a>""",
    re.IGNORECASE | re.DOTALL)
IMG_RE = re.compile(r"""<img[^>]+src=["']?([^"'\s>]+)""", re.IGNORECASE)
SWF_RE = re.compile(r"""([a-zA-Z0-9_/.-]+\.swf)(\?[^"'\s>]*)?""")

listings = defaultdict(list)   # key -> [(thumb, page)]
for fname in sorted(os.listdir(ECARDS)):
    fpath = os.path.join(ECARDS, fname)
    if not os.path.isfile(fpath):
        continue
    if not (fname.startswith("index.") or fname.startswith("theme")):
        continue
    try:
        html = open(fpath, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for m in LINK_RE.finditer(html):
        key, inner = m.group(1), m.group(2)
        im = IMG_RE.search(inner)
        thumb = im.group(1) if im else None
        listings[key].append((thumb, fname))

# --- collect choose pages: key -> embedded swf -------------------------
choose_pages = defaultdict(list)   # key -> [filename]
for fname in sorted(os.listdir(ECARDS)):
    m = re.match(r"choose\.php__ecard_([a-zA-Z0-9_]+?)_action_choose", fname)
    if m:
        choose_pages[m.group(1)].append(fname)

def embedded_swf(fname):
    html = open(os.path.join(ECARDS, fname), encoding="utf-8",
                errors="replace").read()
    # Only look at object/embed area, skip runtime injections
    hits = [h[0] for h in SWF_RE.findall(html)
            if "runtime" not in h[0] and "ruffle" not in h[0]]
    return sorted(set(hits))

def swf_on_disk(swf_path):
    """Resolve like the scheme handler would: exact name, then any
    __<query> variant capture of the same stem."""
    leaf = swf_path.rsplit("/", 1)[-1]
    if os.path.exists(os.path.join(SW, leaf)):
        return leaf
    for f in os.listdir(SW):
        if f == leaf or f.startswith(leaf + "__"):
            return f
    return None

def tokens(s):
    s = s.lower()
    s = re.sub(r"\.(swf|gif|jpe?g)$", "", s)
    parts = re.split(r"[_\W]+", s)
    out = set()
    for p in parts:
        if len(p) >= 3 and p not in {"ecard", "thumb", "the", "and", "card",
                                      "agc", "agm", "btn", "ecc"}:
            out.add(p)
    return out

ALIAS = {  # known abbreviation families so affinity check isn't naive
    "coconut": "coco", "birthday": "bday", "valentine": "vday",
    "christmas": "xmas", "felicity": "fcty", "kirsten": "krstn",
    "josefina": "jos", "samantha": "sam", "friendship": "friend",
}
def affine(a, b):
    ta, tb = tokens(a), tokens(b)
    for t in list(ta):
        if t in ALIAS:
            ta.add(ALIAS[t])
    for t in list(tb):
        if t in ALIAS:
            tb.add(ALIAS[t])
    # substring containment counts (coconutbirthday vs coco/bday)
    joined_a, joined_b = "".join(sorted(ta)), "".join(sorted(tb))
    for t in tb:
        if t in joined_a or any(t in x or x in t for x in ta):
            return True
    for t in ta:
        if t in joined_b:
            return True
    return False

# --- report -------------------------------------------------------------
problems = []
ok = 0
all_keys = sorted(set(listings) | set(choose_pages))
for key in all_keys:
    listed = listings.get(key, [])
    pages = choose_pages.get(key, [])
    if listed and not pages:
        problems.append(("NO-CHOOSE-PAGE", key,
                         f"linked from {listed[0][1]} (thumb {listed[0][0]}) "
                         f"but no choose.php capture"))
        continue
    if not pages:
        continue
    swfs = embedded_swf(pages[0])
    if not swfs:
        problems.append(("NO-SWF-REF", key, f"{pages[0]} embeds no swf"))
        continue
    for swf in swfs:
        disk = swf_on_disk(swf)
        if not disk:
            problems.append(("SWF-MISSING", key,
                             f"{pages[0]} embeds {swf} — not on disk"))
        elif not affine(key, swf.rsplit('/', 1)[-1]):
            problems.append(("NAME-MISMATCH?", key,
                             f"key '{key}' embeds '{swf}' (on disk: {disk})"))
        else:
            ok += 1
    # thumbnail existence
    for thumb, page in listed:
        if thumb:
            leaf = thumb.rsplit("/", 1)[-1]
            if not os.path.exists(os.path.join(IMAGES, leaf)):
                problems.append(("THUMB-MISSING", key,
                                 f"{page} shows {thumb} — not on disk"))

print(f"e-card keys seen: {len(all_keys)}   chains OK: {ok}   "
      f"problems: {len(problems)}\n")
by_type = defaultdict(list)
for typ, key, detail in problems:
    by_type[typ].append((key, detail))
for typ in sorted(by_type):
    print(f"== {typ} ({len(by_type[typ])}) ==")
    for key, detail in by_type[typ]:
        print(f"  {key:32s} {detail}")
    print()
