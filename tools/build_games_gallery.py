#!/usr/bin/env python3
"""Scan the local mirror, group game SWFs by their HTML wrapper page, and emit
a static games.html that the dashboard links to ("Game Gallery" card).

Why "by wrapper" instead of "by SWF":
   The 2008 AG site shipped each game as one or more SWFs embedded in an HTML
   wrapper that supplies surrounding chrome (menus, navigation, end screens,
   mailto/share links). Listing bare SWFs produces three pathologies:

     1. Duplicate tiles — the same SWF is mirrored at multiple URLs
        (e.g. felicity/sw/pcride.swf == felicity/ride/sw/pcride.swf).
     2. Fragment tiles — `_end`, `_intro`, `_map`, `_mailto` SWFs show up
        as if they were standalone games.
     3. Lost titles — `humanize("cincinnatiut.swf")` becomes "Cincinnatiut"
        instead of the real "Kit's Railway Adventure".

   Grouping by (host, character_dir, wrapper_<title>) collapses each
   multi-SWF "experience" into one tile, uses the curator-written <title>,
   and launches the wrapper HTML (which Ruffle then plays inside the
   WebView with full surrounding chrome).

Categorization uses URL path prefix (Meet the Characters, GOTY, etc.).
"""

from __future__ import annotations
import hashlib
import html
import re
from collections import defaultdict
from pathlib import Path
from urllib.parse import quote, urljoin

ROOT = Path(__file__).resolve().parent.parent
MIRROR = ROOT / "mirror"
OUT = ROOT / "app" / "Resources" / "dashboard" / "games.html"

# Categorization. Each tuple: (display label, blurb, path-matches-regex)
SECTIONS: list[tuple[str, str, re.Pattern[str]]] = [
    ("Meet the Characters",
     "Step into the worlds of the historical American Girls and their friends.",
     re.compile(r"^/agcn/(?P<key>[^/]+)/")),
    ("Girl of the Year",
     "The contemporary girls of each year — Lindsey, Kailey, Marisol, Jess, Nicki.",
     re.compile(r"^/goty/(?P<key>[^/]+)/")),
    ("Magazine Activities",
     "Crafts, games, and quizzes pulled from American Girl Magazine.",
     re.compile(r"^/agmg/(?P<key>[^/]+)?/?")),
    ("Coconut & Pets",
     "Stories and games with Coconut, Licorice, and the rest of the AG pets.",
     re.compile(r"^/coconut/(?P<key>[^/]+)?/?")),
    ("Movies & Video",
     "Trailers, behind-the-scenes, and games from the Kit Kittredge film.",
     re.compile(r"^/movie/(?P<key>[^/]+)?/?")),
    ("Quiz Corner",
     "Personality quizzes from the AG style universe.",
     re.compile(r"^/quiz_corner/(?P<key>[^/]+)?/?")),
    ("Books & Activities",
     "Companion Flash activities from American Girl books.",
     re.compile(r"^/books?/(?P<key>[^/]+)?/?")),
    ("Other Games",
     "Standalone games and curiosities from across the site.",
     re.compile(r"")),
]

PRETTY_NAMES: dict[str, str] = {
    "addy": "Addy Walker",
    "felicity": "Felicity Merriman",
    "josefina": "Josefina Montoya",
    "julie": "Julie Albright",
    "kaya": "Kaya",
    "kirsten": "Kirsten Larson",
    "kit": "Kit Kittredge",
    "molly": "Molly McIntire",
    "samantha": "Samantha Parkington",
    "elizabeth": "Elizabeth Cole",
    "mystery": "American Girl Mysteries",
    "paperdoll": "Paper Dolls",
    "snacktime": "Snack Time",
    "SnackTime": "Snack Time",
    "freewheel": "Freewheel",
    "2001Lindsey": "Lindsey Bergman (2001)",
    "2004Kailey": "Kailey Hopkins (2004)",
    "2005Marisol": "Marisol Luna (2005)",
    "2006Jess": "Jess McConnell (2006)",
    "2007Nicki": "Nicki Fleming (2007)",
    # Magazine / quiz / non-character group keys (appear as <h3> sub-headers
    # under Magazine Activities, Quiz Corner, etc.)
    "feature":    "Magazine Features",
    "minigames":  "Mini Games",
    "todotoday":  "To-Do Today",
    "wrap":       "It's a Wrap",
    "pets":       "Pet Quizzes",
    "quizzes":    "Personality Quizzes",
    "sggmoney":   "A Smart Girl's Guide to Money",
    "licorice":   "Licorice the Cat",
    "assets":     "Trailers & Promos",
}

# Some wrapper <title>s are useless boilerplate that 2008-era CMS pages
# share across hundreds of activities. When we encounter one, fall back to
# the humanized directory name (which is usually the slug like "barnBuddies"
# or "coverPoll").
GENERIC_TITLE_PATTERNS = (
    re.compile(r"^american\s+girl\s+magazine\s+activit", re.IGNORECASE),
    re.compile(r"^american\s+girl(\s+|$)", re.IGNORECASE),
    re.compile(r"^mini\s+games?$", re.IGNORECASE),
    re.compile(r"^untitled", re.IGNORECASE),
)

# Explicit title overrides keyed by canonical (host, path). Use sparingly —
# the source HTML is canonical, but a handful of pages have wrong titles
# (e.g. Nicki's wrapper says "2005" instead of "2007") that we patch here.
TITLE_OVERRIDES: dict[tuple[str, str], str] = {
    ("www.americangirl.com", "/goty/2007Nicki/index.html"):
        "Nicki Fleming — Girl of the Year 2007",
    ("www.americangirl.com", "/agcn/julie/swf/Julie_bball.swf"):
        "Julie's Basketball",
    ("www.americangirl.com", "/agcn/mystery/mystery_home.swf"):
        "American Girl Mysteries",
    # /agcn/felicity/ride/index.html's <title> tag says "Colonial
    # Adventure" but the wrapper actually launches pcride.swf, a
    # distinct game about riding Penny (Felicity's horse). Without
    # this override it collides with the real /felicity/colonial.php
    # tile and shows two Colonial Adventure entries.
    ("www.americangirl.com", "/agcn/felicity/ride/index.html"):
        "Felicity's Pony Ride",
}

# Path prefixes whose SWFs are site chrome (banners, ads, video assets),
# not games. Suppress these from the gallery entirely.
SUPPRESS_PATH_PREFIXES = (
    "/site/",          # site-wide chrome / homepage Flash banners
    "/hp_ads/",        # homepage ad slots
    "/static/",        # store.americangirl.com static assets
    "/images/",        # decorative
    "/agmg/todotoday/sw/",  # daily mini-game fragments loaded by parent SWF
    "/movie/assets/",       # movie player chrome
    "/movie/molly/assets/", # ditto, scoped
    # BTS (Behind the Scenes Sept/Oct) sub-activities — Cookie Break,
    # CheerMaker, Cover Poll. The main /agmg/bts/index.html SWF
    # internally navigates to all three via getURL on its three buttons,
    # so listing them as separate gallery tiles would be duplicates.
    "/agmg/bts/cheer_so/",
    "/agmg/bts/cookie_so/",
    "/agmg/bts/cover_so/",
    # /agcn/felicity/adventure/index.html is a 1-SWF launcher that's a
    # smaller variant of the canonical /agcn/felicity/colonial.php
    # wrapper (41 SWFs · 2934 KB) and shares its title. Hiding it
    # leaves the full colonial.php tile as the single Colonial
    # Adventure entry.
    "/agcn/felicity/adventure/",
)

# Wrapper filenames that are internal segments of a larger experience and
# should never be the entry-point tile.
FRAGMENT_SUFFIXES = ("_end", "_mailto", "_share", "_credits")

# Wrappers that ARE entry points (preferred over plain wrappers).
ENTRY_HINTS = ("index", "menu", "main", "intro", "start", "home")

# Orphan-SWF stems that are almost certainly internal fragments of a larger
# experience (loaders, splash screens, transition art) and not playable on
# their own. Used to suppress junk tiles when no wrapper claims the SWF.
ORPHAN_FRAGMENT_STEMS = re.compile(
    r"""(?ix) ^(
        \d+                       # pure-numeric filenames (asset libraries)
      | main | menu | shell       # generic launcher names — meaningless without their wrapper
      | .* (loading|splash|preloader|intro|credits|howto|how_to|end)
    )$"""
)

# Regex matching SWF references inside <param value=...>, <embed src=...>,
# <object data=...>, and bare swfobject embedSWF("...") calls.
SWF_REF_RE = re.compile(
    r'''(?ix)
    (?:                                 # any of:
      <param\b[^>]*\bvalue\s*=\s*       # <param value="...">
    | <embed\b[^>]*\bsrc\s*=\s*         # <embed src="...">
    | <object\b[^>]*\bdata\s*=\s*       # <object data="...">
    | swfobject\.embedSWF\s*\(\s*       # swfobject.embedSWF("...
    | embedSWF\s*\(\s*                  # AC_FL_RunContent first arg
    )
    ["']                                # opening quote
    ([^"']+?\.swf)                      # the SWF URL
    ["']                                # closing quote
    '''
)

TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)


# Tokens we expand when humanizing 2008-era filename slugs. These are the
# abbreviations the AG site used internally; the player only sees them via
# our derived tile titles, so expanding them removes the worst "Bball" /
# "Vid" / "Wpaper" embarrassments.
HUMANIZE_EXPANSIONS = {
    "bball": "basketball",
    "vid":   "video",
    "wpaper": "wallpaper",
    "pic":   "picture",
    "pics":  "pictures",
    "lbry":  "library",
    "ecard": "e-card",
    "ecards": "e-cards",
    "intro": "intro",
    "mgr":   "manager",
    # Concatenated lowercase slugs the camelCase splitter can't handle.
    "coverpoll":    "cover poll",
    "winningwords": "winning words",
    "minigames":    "mini games",
    "scvhunt":      "scavenger hunt",
    "railadvn":     "railway adventure",
}


# Words that stay lowercase in title-case (except at start/end).
TITLE_SMALL = {"a", "an", "and", "as", "at", "but", "by", "for", "in",
               "of", "on", "or", "the", "to", "vs", "via"}


def smart_title(s: str) -> str:
    """Title-case a phrase respecting small connector words and not
    destroying ALL-CAPS / mixed-case tokens that are already capitalized."""
    words = s.split(" ")
    out: list[str] = []
    for i, w in enumerate(words):
        if not w:
            continue
        lw = w.lower()
        is_first_or_last = (i == 0 or i == len(words) - 1)
        if not is_first_or_last and lw in TITLE_SMALL:
            out.append(lw)
        elif w.isupper() and len(w) <= 4:
            out.append(w)                          # leave likely-acronyms alone
        else:
            out.append(lw[:1].upper() + lw[1:])    # canonical capitalization
    return " ".join(out)


def humanize(name: str) -> str:
    base = name.rsplit(".", 1)[0]
    base = base.replace("_", " ").replace("-", " ")
    # Insert space before camelCase humps (barnBuddies -> barn Buddies)
    base = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", base)
    base = re.sub(r"\s+", " ", base).strip()
    parts = [HUMANIZE_EXPANSIONS.get(p.lower(), p) for p in base.split(" ")]
    return smart_title(" ".join(parts))


def is_generic_title(title: str) -> bool:
    return any(p.match(title) for p in GENERIC_TITLE_PATTERNS)


def normalize_wrapper_title(title: str) -> str:
    """Light cleanup for titles pulled from wrapper <title> tags. Source
    pages from 2008 sometimes write them all-lowercase or all-caps; for
    those (and only those) we apply title-case. Mixed-case titles like
    "Kit's Railway Adventure" are kept verbatim."""
    if not title:
        return title
    stripped = re.sub(r"[\W_]+", "", title)
    if stripped and (stripped.islower() or stripped.isupper()):
        return smart_title(title.lower())
    return title


# ---------- mirror indexing ----------------------------------------------

def iter_files(suffixes: tuple[str, ...]) -> list[Path]:
    out: list[Path] = []
    if not MIRROR.exists():
        return out
    for p in MIRROR.rglob("*"):
        if p.is_file() and p.suffix.lower() in suffixes:
            out.append(p)
    return out


def mirror_url_for(p: Path) -> tuple[str, str]:
    """Return (host, path) for a file inside mirror/."""
    rel = p.relative_to(MIRROR)
    parts = rel.parts
    host = parts[0]
    path = "/" + "/".join(parts[1:])
    return host, path


def extract_swf_refs(html_path: Path) -> list[str]:
    """Return absolute mirror paths of SWFs referenced by an HTML wrapper.

    Resolves relative paths against the wrapper's own URL. Strips query
    strings. Skips refs we can't resolve (off-host, absolute http, etc.)."""
    try:
        text = html_path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return []
    refs = SWF_REF_RE.findall(text)
    if not refs:
        return []
    host, wrapper_path = mirror_url_for(html_path)
    # urljoin treats unknown schemes (agd://) as opaque, so resolve under
    # http:// and translate back.
    base = f"http://{host}{wrapper_path}"
    out: list[str] = []
    seen: set[str] = set()
    for ref in refs:
        ref = ref.split("?", 1)[0].split("#", 1)[0].strip()
        if not ref:
            continue
        resolved = urljoin(base, ref)
        prefix = f"http://{host}/"
        if not resolved.startswith(prefix):
            continue
        rel = "/" + resolved[len(prefix):]
        if rel in seen:
            continue
        seen.add(rel)
        out.append(rel)
    return out


def extract_title(html_path: Path) -> str | None:
    try:
        text = html_path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return None
    m = TITLE_RE.search(text)
    if not m:
        return None
    title = re.sub(r"\s+", " ", m.group(1)).strip()
    # Trim AG-site boilerplate suffix like " | American Girl"
    title = re.sub(r"\s*[|—-]\s*American Girl.*$", "", title, flags=re.IGNORECASE)
    return title or None


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------- experience grouping ------------------------------------------

def experience_key(host: str, wrapper_path: str) -> tuple[str, str]:
    """Stable key that puts all wrappers for one 'game experience' together.

    Heuristic: an experience lives in a leaf directory under a character/
    section root (e.g. /agcn/kit/railadvn, /agcn/felicity/ride). We use
    (host, parent-dir-of-wrapper) as the key — that collapses every wrapper
    in railadvn/ into one experience while keeping ride/ and adventure/
    separate even though they share a <title>."""
    parent = wrapper_path.rsplit("/", 1)[0]
    if not parent:
        parent = "/"
    return (host, parent)


def is_fragment(wrapper_name: str) -> bool:
    stem = wrapper_name.rsplit(".", 1)[0].lower()
    return any(stem.endswith(suf) for suf in FRAGMENT_SUFFIXES)


def entry_score(wrapper_name: str) -> int:
    """Lower = more likely to be the entry-point wrapper for an experience."""
    stem = wrapper_name.rsplit(".", 1)[0].lower()
    if is_fragment(stem):
        return 1000
    for i, hint in enumerate(ENTRY_HINTS):
        if stem == hint:
            return i  # exact match wins
    for i, hint in enumerate(ENTRY_HINTS):
        if hint in stem:
            return 10 + i
    return 100  # plain wrapper


# ---------- main ---------------------------------------------------------

def main() -> int:
    if not MIRROR.exists():
        print(f"No {MIRROR}; nothing to do.")
        return 0

    swfs = [p for p in iter_files((".swf",)) if p.is_file()]
    wrappers = [p for p in iter_files((".html", ".htm", ".php")) if p.is_file()]
    print(f"Indexed {len(swfs)} SWFs and {len(wrappers)} HTML/PHP wrappers")

    # swf_relpath_by_host[host] = { "/agcn/.../foo.swf": Path(...) }
    swf_paths: dict[tuple[str, str], Path] = {}
    for s in swfs:
        host, path = mirror_url_for(s)
        swf_paths[(host, path)] = s

    # wrapper_swfs[(host, wrapper_path)] = [swf_path, ...]
    # swf_wrappers[(host, swf_path)] = [wrapper_path, ...]
    wrapper_swfs: dict[tuple[str, str], list[str]] = defaultdict(list)
    swf_wrappers: dict[tuple[str, str], list[str]] = defaultdict(list)

    for w in wrappers:
        whost, wpath = mirror_url_for(w)
        # Skip wrappers in suppressed paths — without this filter, BTS
        # sub-activities (cookie_so/, cheer_so/, cover_so/) and
        # /felicity/adventure/ get their own gallery tiles even though
        # their parent wrapper already absorbs them via SWF refs.
        if any(wpath.startswith(prefix) for prefix in SUPPRESS_PATH_PREFIXES):
            continue
        for ref in extract_swf_refs(w):
            if (whost, ref) in swf_paths:
                wrapper_swfs[(whost, wpath)].append(ref)
                swf_wrappers[(whost, ref)].append(wpath)

    # SHA-dedupe: collapse identical SWFs at different paths.
    # canonical[(host,swf_path)] = (host, canonical_swf_path)
    sha_to_canonical: dict[str, tuple[str, str]] = {}
    canonical: dict[tuple[str, str], tuple[str, str]] = {}
    for (host, path), p in sorted(swf_paths.items(), key=lambda kv: (len(kv[0][1]), kv[0][1])):
        try:
            digest = sha256(p)
        except OSError:
            continue
        if digest in sha_to_canonical:
            canonical[(host, path)] = sha_to_canonical[digest]
        else:
            sha_to_canonical[digest] = (host, path)
            canonical[(host, path)] = (host, path)

    # Build experiences: group wrappers by (host, parent-dir).
    # experience[(host, dir)] = {
    #   "title": "Kit's Railway Adventure",
    #   "wrappers": [wrapper_path, ...],
    #   "entry": wrapper_path,
    #   "swfs": [(host, swf_path), ...],   # canonical SWFs only
    # }
    experiences: dict[tuple[str, str], dict] = {}
    for (host, wpath), refs in wrapper_swfs.items():
        if not refs:
            continue
        key = experience_key(host, wpath)
        exp = experiences.setdefault(key, {
            "wrappers": [],
            "swfs": set(),
            "titles": [],
        })
        exp["wrappers"].append(wpath)
        for r in refs:
            exp["swfs"].add(canonical[(host, r)])
        title = extract_title(MIRROR / host / wpath.lstrip("/"))
        if title:
            exp["titles"].append((wpath, title))

    # Pick entry-point wrapper + title for each experience.
    for key, exp in experiences.items():
        host = key[0]
        wraps = sorted(set(exp["wrappers"]), key=lambda w: (entry_score(w.rsplit("/", 1)[-1]), w))
        entry = wraps[0]
        exp["entry"] = entry
        # Explicit override wins outright (handful of source pages have
        # wrong/misleading <title>s — e.g. Nicki dated 2005 not 2007).
        override = TITLE_OVERRIDES.get((host, entry))
        if override:
            exp["title"] = override
            continue
        # Prefer title from the entry wrapper; fall back to most-common title.
        title_map = dict(exp["titles"])
        title = title_map.get(entry)
        if not title:
            counts: dict[str, int] = defaultdict(int)
            for _, t in exp["titles"]:
                counts[t] += 1
            title = max(counts, key=counts.get) if counts else None
        # If the chosen title is generic CMS boilerplate ("American Girl
        # Magazine Activity"), use the humanized directory slug instead so
        # tiles read "Barn Buddies" / "Cover Maker" not 5x identical text.
        if title and is_generic_title(title):
            slug = key[1].rstrip("/").rsplit("/", 1)[-1]
            humanized = humanize(slug)
            if humanized and not is_generic_title(humanized):
                title = humanized
        if not title:
            title = humanize(entry.rsplit("/", 1)[-1])
        exp["title"] = normalize_wrapper_title(title)

    # Orphan SWFs: ones with no wrapper at all (canonical version not already
    # claimed by some experience). Before they become standalone tiles, try
    # to absorb them into the nearest ancestor-directory experience — this
    # catches SWFs that the main game loads dynamically via ActionScript
    # (e.g. paperdoll's pick_doll.swf / agc_loading.swf, loaded by
    # paper_dolls.swf at runtime).
    claimed_swfs: set[tuple[str, str]] = set()
    for exp in experiences.values():
        for sk in exp["swfs"]:
            claimed_swfs.add(sk)

    def find_ancestor_experience(host: str, swf_path: str) -> tuple[str, str] | None:
        parent = swf_path.rsplit("/", 1)[0]
        while parent:
            if (host, parent) in experiences:
                return (host, parent)
            if "/" not in parent:
                break
            parent = parent.rsplit("/", 1)[0]
        return None

    orphans: list[tuple[str, str, Path]] = []
    absorbed = 0
    seen_canon: set[tuple[str, str]] = set()
    for (host, path), p in swf_paths.items():
        canon = canonical[(host, path)]
        if canon in claimed_swfs:
            continue
        if canon in seen_canon:
            continue
        seen_canon.add(canon)
        chost, cpath = canon
        anc = find_ancestor_experience(chost, cpath)
        if anc is not None:
            experiences[anc]["swfs"].add(canon)
            claimed_swfs.add(canon)
            absorbed += 1
            continue
        # Suppress site chrome, ad slots, video assets, and known dynamic
        # fragments outright — they're not games and clutter "Other Games".
        if any(cpath.startswith(prefix) for prefix in SUPPRESS_PATH_PREFIXES):
            continue
        # Filter obvious internal fragments (loaders, splash, numeric assets)
        stem = Path(cpath).stem
        if ORPHAN_FRAGMENT_STEMS.match(stem):
            continue
        cfile = swf_paths.get(canon, p)
        orphans.append((chost, cpath, cfile))
    if absorbed:
        print(f"Absorbed {absorbed} dynamically-loaded SWFs into ancestor experiences")

    # ---- assemble tiles per (section, group_key) ----
    # tile = ("experience", host, entry_path, title, size_kb, count_swfs)
    #      | ("orphan",     host, swf_path,   title, size_kb, 1)
    Tile = tuple[str, str, str, str, int, int]

    grouped: dict[int, dict[str, list[Tile]]] = defaultdict(lambda: defaultdict(list))

    def categorize(path: str) -> tuple[int, str]:
        for idx, (_, _, pattern) in enumerate(SECTIONS):
            if pattern.pattern == "":
                continue
            m = pattern.search(path)
            if m:
                return (idx, m.groupdict().get("key") or "")
        return (len(SECTIONS) - 1, "")

    for key, exp in experiences.items():
        host, dirpath = key
        idx, gkey = categorize(dirpath + "/")
        entry_path = exp["entry"]
        # size = sum of all canonical SWFs the experience embeds
        size_kb = 0
        for chost, cpath in exp["swfs"]:
            sp = swf_paths.get((chost, cpath))
            if sp:
                try:
                    size_kb += sp.stat().st_size // 1024
                except OSError:
                    pass
        grouped[idx][gkey].append(
            ("experience", host, entry_path, exp["title"], size_kb, len(exp["swfs"]))
        )

    for host, path, p in orphans:
        idx, gkey = categorize(path)
        title = TITLE_OVERRIDES.get((host, path)) or humanize(p.name)
        try:
            size_kb = p.stat().st_size // 1024
        except OSError:
            size_kb = 0
        grouped[idx][gkey].append(
            ("orphan", host, path, title, size_kb, 1)
        )

    total_tiles = sum(len(v) for groups in grouped.values() for v in groups.values())
    print(f"Built {total_tiles} tiles "
          f"({len(experiences)} experiences + {len(orphans)} orphan SWFs)")

    # ---- emit HTML ----
    parts: list[str] = [HEAD, NAV_BACK, GALLERY_HEADER.format(total=total_tiles)]

    for idx, (section_title, blurb, _) in enumerate(SECTIONS):
        group_map = grouped.get(idx)
        if not group_map:
            continue
        parts.append('<section class="game-section">')
        parts.append('  <header class="section-head">')
        parts.append(f'    <h2>{html.escape(section_title)}</h2>')
        parts.append(f'    <p>{html.escape(blurb)}</p>')
        parts.append('  </header>')

        for gkey in sorted(group_map.keys(), key=lambda s: s.lower()):
            display = PRETTY_NAMES.get(gkey, humanize(gkey)) if gkey else "Featured"
            tiles = group_map[gkey]
            parts.append('  <div class="char-group">')
            if gkey:
                parts.append(f'    <h3>{html.escape(display)}</h3>')
            parts.append('    <div class="tiles">')
            for kind, host, path, title, size_kb, count in sorted(
                tiles, key=lambda t: (t[3].lower(), t[2].lower())
            ):
                if kind == "experience":
                    target_url = f"agd://{host}{path}"
                    meta = f"{count} SWF{'s' if count != 1 else ''} · {size_kb} KB"
                    ext_label = "play"
                else:
                    swf_url = f"agd://{host}{path}"
                    # Serve the player under the SWF's own host (via the
                    # scheme handler's /__agd/ synthetic path) so the page
                    # and the SWF share an origin -- otherwise Ruffle's
                    # cross-origin check fails and it renders an orange
                    # error square.
                    target_url = (
                        f"agd://{host}/__agd/player.html"
                        f"?swf={quote(swf_url, safe='')}"
                        f"&title={quote(title, safe='')}"
                    )
                    meta = f"{size_kb} KB"
                    ext_label = "swf"
                parts.append(
                    f'      <a class="tile" href="{html.escape(target_url)}" '
                    f'data-ext="{ext_label}" '
                    f'data-projector="agd-launch://{html.escape(host + path)}">'
                    f'<span class="ext">{ext_label.upper()}</span>'
                    f'<span class="t">{html.escape(title)}</span>'
                    f'<span class="meta">{html.escape(meta)}</span>'
                    f'</a>'
                )
            parts.append('    </div>')
            parts.append('  </div>')
        parts.append('</section>')

    parts.append(FOOTER)
    parts.append(AUTOCLICK_JS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(parts), encoding="utf-8")
    print(f"Wrote {OUT}")
    return 0


HEAD = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Game Gallery — American Girl 2008</title>
<link rel="stylesheet" href="styles.css">
<link rel="stylesheet" href="games.css">
<script src="agd://runtime/volume-control.js"></script>
</head>
<body class="games-page">
<main class="stage">
'''

NAV_BACK = '''  <nav class="topnav">
    <a class="back" href="agd://dashboard/index.html">‹ Dashboard</a>
    <span class="crumb"><span class="serif italic">American Girl</span> · Game Gallery</span>
  </nav>
'''

GALLERY_HEADER = '''  <header class="gallery-head">
    <p class="tagline">The Archive</p>
    <h1 class="wordmark"><span class="american">Game</span> <span class="girl">Gallery</span></h1>
    <p class="lede">{total} Flash games and animations recovered from americangirl.com — click any tile to step into the original page, where Ruffle plays the game inline.</p>
  </header>
'''

FOOTER = '''  <footer class="credit">
    <p>Games play inline through <em>Ruffle</em>, an open-source Flash emulator. If a title misbehaves, the inline player offers an "Open in Flash Player" fallback that launches it through the bundled Adobe projector.</p>
    <p class="small">Some games depend on Flash 8+ features that Ruffle is still maturing on; the projector fallback is always one click away.</p>
  </footer>
</main>'''

AUTOCLICK_JS = '''<script>
(function () {
  var p = new URLSearchParams(location.search);
  if (p.get("test") === "launch") {
    setTimeout(function () {
      var first = document.querySelector(".tile");
      if (first) first.click();
    }, 1200);
  }
})();
</script>
</body>
</html>
'''


if __name__ == "__main__":
    raise SystemExit(main())
