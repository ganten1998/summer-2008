# Summer 2008 — An American Girl Archive

> *You'd dump your Tamagotchi in the bottom of your backpack, walk home from school,
> open the family iMac, and click around americangirl.com until dinner. You played
> Kit's Railway Adventure. You sent your friend an e-card with Coconut on it. You
> filled out the "Real Girl of the Year" form even though you were too old. You knew
> the click sound the Flash navigation made before it loaded.*

This is that website. Frozen.

Summer 2008 is an offline, playable snapshot of **americangirl.com** as it existed
around **11 July 2008** — the Nicki Fleming era, the *Kit Kittredge* movie release,
the original eight historical characters before any retirements (Felicity, Addy,
Kit, Molly, Samantha, Kaya, Josefina, Kirsten).

The website went through a major redesign in 2011 and the original lived only in
the Wayback Machine afterward — a stub of itself, no Flash, dead e-cards, missing
games. This project pulls it back together: every page that was navigable, every
Flash game, every Shockwave puzzle, every e-card you remember. All running locally
on your Mac with no internet required after install.

---

## What's inside

**The full mid-2008 site.** Every character hub — bio pages, book pages, friends
pages, world maps, wallpaper galleries. Every Girl of the Year from Lindsey (2001)
through Nicki (2007). The Real Girl of the Year 2008 contestant pages — Brooke,
Ali, Anna, Clare, Dakota, Emily, Fiona, Georgia, Hannah, Kasey, Kelly, Kelsie,
Madison, Megan, Aisling, Angelina. The *Kit Kittredge* movie subsite. Magazine
Activities. Coconut & Licorice. Quiz Corner. Travel. Paper Dolls. Snack Time. The
Mysteries. Freewheel.

**116 Flash games, playable inline.** Felicity's Colonial Adventure, Kit's Railway
Adventure (Cincinnati Union Terminal, Empire Builder, Glacier Park, World's Fair,
Fancy Free, Hangman, Tangram, Jigsaw, Concentration), Kaya's Catch of the Day,
Kaya's Mountain Escape, Kirsten's Raccoon Caper, Molly's Pedal Power, Molly's
Route 66, Samantha's Scavenger Hunt, Josefina's Santa Fe Market, Addy's *A Life
in Freedom*, Paper Dolls — and every Magazine Activity, every Coconut & Pets game,
every Quiz Corner personality quiz.

**20 Shockwave Director games.** Addy's Mancala, Josefina's Piano, Molly's Pedal
Power, Kirsten's Raccoon Caper and Quilt, Kit's egg hunt, peg solitaire, jigsaw,
Samantha's Sketchbook, the full set of Magazine puzzle pages. These need a real
Director runtime; the app bundles one (Adobe Shockwave projector via Wine).
Click a game's page and the projector spawns directly over the embed area, sized
to the game's native canvas. Drag it anywhere, close it from its window, relaunch
from the same pill — same gesture as the inline Flash pill.

**The full e-card system.** Choose a card, type a personalized message, preview
it with your message embedded, send it to a friend by handoff to your Mac's Mail
app (the original "send" backend died with the 2008 servers, so the message
goes out from your own account — feels right, doesn't pretend).

---

## What's missing

I tried. Some things didn't survive:

**American Girl Magazine e-cards** (the "agm" dropdown in E-Card Central) were
server-rendered from a database, and the URL was never reached by a single web
crawler in 2007–2008 — I checked Wayback's full CDX, every Common Crawl index
from 2008 through 2015, archive.today, Memento aggregator, every search engine.
The page exists nowhere on the public internet. Selecting that dropdown option
lands on a styled note explaining what happened, with a request: if you ever
saved one of these to a school computer, or remember the names of specific
cards, please tell me.

**store.americangirl.com** was 58,000+ URLs of e-commerce — cart, checkout,
account, product database. None of that can be a static snapshot. Clicking a
SHOP link lands on a polite "the catalogue lives in a different kind of archive"
explainer.

**The "send for real" backend.** Replaced with macOS Mail handoff. Your message
plus a deep-link to the animated card goes out from your own email — same
gesture, different plumbing.

**A handful of mid-game Ruffle hiccups.** Ruffle's ActionScript support is
99% there; some clicks inside Kit's Railway Adventure throw mid-play error
codes. The bottom-right of every game page carries a paired control stack — a
volume pill and an "Open in Flash Projector" pill above it, both sharing the
same shape, gradient, hover-to-expand behavior. The Flash pill hands off to
the real Adobe Flash Player (bundled in the .app); the volume pill applies a
single setting across every inline Ruffle player and persists it between
sessions. That projector pill is the canonical playback path whenever Ruffle
stumbles.

---

## Install

Downloads are at [Releases](https://github.com/ganten7/summer-2008/releases).
Both bundle the entire mirror, every Flash + Shockwave projector, and the
runtime — fully self-contained, no companion apps required.

### macOS

Download `Summer 2008 v1.0.dmg` (~390 MB compressed, 800 MB installed).
Requires macOS 11 or newer. Apple Silicon native; Intel works under
Rosetta.

**First launch** — the app isn't signed with an Apple Developer ID yet,
so macOS will block it. The unlock takes about 20 seconds:

*On macOS 15 (Sequoia), macOS 26 (Tahoe), or newer:*
1. Double-click the .app. You'll see a dialog: *"Apple could not verify
   '… An American Girl Archive' is free of malware"*. Click **Done**.
2. Open **System Settings → Privacy & Security**. Scroll to the
   "Security" section near the bottom. You'll see *"Summer 2008 — An
   American Girl Archive was blocked to protect your Mac."* with an
   **Open Anyway** button next to it.
3. Click **Open Anyway**, enter your Mac password to confirm. The app
   launches.

*On macOS 11–14 (Big Sur through Sonoma):*
1. Right-click the .app → **Open** → click **Open** in the warning dialog.

### Windows

Download `Summer-2008-Setup-v1.0.0.exe` (~400 MB). Requires Windows 10
1809 (build 17763) or newer, x64. Double-click to run the installer —
follow the standard next-next-finish flow. The installer creates Start
Menu + (optional) Desktop shortcuts and auto-installs the Edge WebView2
runtime if it isn't already present.

**First launch** — Windows SmartScreen may say "Windows protected your
PC" because the installer isn't signed with an EV certificate yet.
Click **More info → Run anyway**.

Either way, you only do it once — future launches are normal.

---

## Build from source

### macOS (.app and .dmg)

```bash
# 1. Clone
git clone https://github.com/ganten7/summer-2008.git ~/Projects/summer-2008
cd ~/Projects/summer-2008

# 2. Hydrate the projector binaries (Wine + Director from your local
#    Flashpoint install)
./tools/fetch-projector.sh

# 3. Build the .app
./app/build.sh

# 4. (Optional) Wrap into a distributable DMG
./app/make-dmg.sh
```

The .app lands at `build/Summer 2008 — An American Girl Archive.app`.

### Windows (.exe installer)

Requires .NET 8 SDK + Inno Setup 6. **No Flashpoint install required** —
projector binaries auto-download from this repo's `build-deps-v1` release.

```powershell
# From a Windows machine (or via the windows-build.yml GitHub Actions
# workflow on push)
git clone https://github.com/ganten7/summer-2008.git C:\Projects\summer-2008
cd C:\Projects\summer-2008

# Pulls ~80 MB of native Director + Flash projectors from the build-deps release
.\tools\fetch-projector-windows.ps1

cd app-windows
.\build.ps1
```

The installer lands at `app-windows\build\Summer-2008-Setup-v1.0.0.exe`.

### Cross-platform

The CI workflow at `.github/workflows/windows-build.yml` runs on every
push and produces the Windows installer as a workflow artifact (or
attaches it to the matching release on `v*` tag pushes). So Mac
developers can produce Windows installers without ever booting Windows.

---

## How it works (for the curious)

The app is a native macOS WebKit shell with a custom URL scheme (`agd://`).
Every request goes through `MirrorURLSchemeHandler.swift`, which:

- Serves files out of a bundled mirror tree (~111 MB of preserved HTML / CSS
  / JS / SWF / DCR / images).
- Falls through to a runtime backfill cache if the user hits a URL we don't
  have, then to a live Wayback fetch as a last resort.
- Routes `.swf` clicks into an inline [Ruffle](https://ruffle.rs) player.
- Routes `.dcr` clicks to a bundled Wine + Adobe Director projector
  (Flashpoint Archive's distribution).
- Serves styled stub pages for known-dead surfaces (`store.*`, magazine
  ecards, search forms, login flows) so dead-ends feel intentional instead
  of broken.

`tools/build_url_list.py` filtered Wayback's CDX dump down to a list of URLs
worth crawling. `tools/download_mirror.py` is a multi-shard, source-IP-pluggable
Wayback downloader with adaptive backoff. `tools/recover_via_cc.py` and
`tools/recover_via_wayback_avail.py` are recovery passes for URLs the primary
crawler missed — they hit Common Crawl's S3 WARC index and Wayback's
availability API respectively. About 4% of the URL list needed recovery; most
of that was character `.php` wrapper pages.

The patcher (`tools/patch_mirror_html.py`) injects Ruffle / volume-control
scripts at the top of every HTML file in the mirror, rewrites cross-domain
URLs to the `agd://` scheme, neutralizes 2008-era tracking pixels, and
intercepts dead form `<form action="…cgi">` patterns so submits land on a
styled "the live 2008 server is gone" page instead of vanishing into 404.

The window itself is fully draggable from any non-interactive surface — the
red AG navigation bar, the dashboard's solid-color header, the empty page
background — using a threshold-based mousedown handler that distinguishes a
deliberate drag from a single click (links and tile-card clicks pass through
intact). The Director projector windows are positioned, focused, and torn
down via macOS Accessibility APIs; on quit, every spawned projector is
SIGKILLed before the host exits so nothing leaks across launches.

The gallery is regenerated on every build by `tools/build_games_gallery.py` —
it walks the mirror, groups SWFs by their HTML wrapper, dedupes by SHA-256,
sorts into sections, and emits the dashboard's `games.html`.

---

## Contribute — the one real ask

If you ever encounter content from the 2008-era American Girl site that
isn't in this archive — especially the American Girl Magazine e-cards
that disappeared — **please open an issue or get in touch**.

Old saved HTML pages from school computers. Browser cache exports.
Screenshots. SWF files with `agm_` in the filename. Even just remembered
card titles. Cataloging what was lost matters too.

---

## Posture

This is a tip-only preservation project — not commercial. American Girl is
Mattel's trademark; nothing here re-hosts current AG content or competes
with anything in market. The goal is exactly one thing: keep a working
copy of the mid-2008 site reachable, the way kids actually used it, before
it slips further out of memory.

If this matters to you, you can [tip the archivist a coffee on Ko-fi](https://ko-fi.com/B0B7EF4TJ) — it
covers the small hosting and distribution costs.

---

## Credits

- The 2008 American Girl team and Mattel — original content.
- The [Internet Archive Wayback Machine](https://web.archive.org/)
  — source of ~95% of the mirror.
- [Common Crawl](https://commoncrawl.org/) — recovery source for what
  Wayback missed.
- [Ruffle](https://ruffle.rs/) — Flash emulator that makes the inline
  playback possible.
- [Flashpoint Archive](https://flashpointarchive.org/) — Wine + Director
  projector distribution.
- Adobe — Flash Player and Director, both retired and now necessary
  archaeology.

Built for everyone who remembers.

---

*Codename: Coconut.*
