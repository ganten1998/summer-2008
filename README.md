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
Flash game, every Shockwave puzzle, every e-card you remember. Native apps for
**macOS and Windows** — same content, same Ruffle inline play, same handoff to
the real Adobe projector when Ruffle stumbles. The bundle covers the common
path; anything we missed is patched in from the Wayback Machine on first view
and cached, so by the second visit it's offline too.

---

## What's inside

**The full mid-2008 site.** Every character hub — bio pages, book pages, friends
pages, world maps, wallpaper galleries. Every Girl of the Year from Lindsey (2001)
through Nicki (2007). The Real Girl of the Year 2008 contestant pages — Brooke,
Ali, Anna, Clare, Dakota, Emily, Fiona, Georgia, Hannah, Kasey, Kelly, Kelsie,
Madison, Megan, Aisling, Angelina. The *Kit Kittredge* movie subsite. Magazine
Activities. Coconut & Licorice. Quiz Corner. Travel. Paper Dolls. Snack Time. The
Mysteries. Freewheel.

**112 Flash games and animations, playable inline.** Felicity's Colonial Adventure, Kit's Railway
Adventure (Cincinnati Union Terminal, Empire Builder, Glacier Park, World's Fair,
Fancy Free, Hangman, Tangram, Jigsaw, Concentration), Kaya's Catch of the Day,
Kaya's Mountain Escape, Kirsten's Raccoon Caper, Molly's Pedal Power, Molly's
Route 66, Samantha's Scavenger Hunt, Josefina's Santa Fe Market, Addy's *A Life
in Freedom*, Paper Dolls — and every Magazine Activity, every Coconut & Pets game,
every Quiz Corner personality quiz.

**30 Shockwave Director games and activities.** Addy's Mancala, Josefina's Piano,
Molly's Pedal Power, Kirsten's Raccoon Caper and Quilt, Kit's egg hunt, peg
solitaire, jigsaw, Samantha's Sketchbook, Sea Horse Round Up, Mahjong Mania,
An American Girl in Paris, the full set of Magazine puzzle pages. These need a real
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
server-rendered from a database, and the chooser URL was never reached by a
single web crawler in 2007 or 2008. Wayback's full CDX, every Common Crawl
index from 2008 through 2015, archive.today, the Memento aggregator, every
search engine, and the Flashpoint Archive database have all been checked,
twice, years apart. The page exists nowhere on the public internet. Selecting that dropdown
option lands on a styled note explaining what happened, with a request: if you
ever saved one of these to a school computer, or remember the names of specific
cards, please tell me.

**Nine e-card animations.** Of the 95 cards E-Card Central offers, 86 now have
their animation. The remaining nine (a few character birthdays, some holiday
cards) were either never captured, or survive only as empty redirect records.
Their entries still appear in the chooser, because a card you can't open is at
least a record that it existed.

**Eight magazine feature games** from the 2008 issues (Animal Cupcakes, Island
Party, Puppy Video, Shades, Smiling Pets, Stunt Girl, You Pick It, Plus or
Minus). Flashpoint Archive, which does curate other games from the same
directories, was confirmed not to hold these either.

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

Downloads are at [Releases](https://github.com/ganten1998/summer-2008/releases).
Both bundle the entire mirror, every Flash + Shockwave projector, and the
runtime — fully self-contained, no companion apps required.

### macOS

Download `Summer 2008 v1.0.dmg` (949 MB installed).
Requires macOS 11 or newer. Universal binary, native on both Apple
Silicon and Intel.

Open the DMG, drag the app to Applications, launch it. That's the whole
install: the app is signed with an Apple Developer ID and notarized by
Apple, so there's no security warning and nothing to click around.

**One caveat on Apple Silicon.** The Flash and Shockwave projectors are
the original Adobe runtimes, Intel software from the 2000s, so they
need Rosetta. Everything else in the archive, including all the inline
Ruffle games, works without it. If you click a projector game and don't
have Rosetta, the app tells you and hands you the one-line command:

```bash
softwareupdate --install-rosetta --agree-to-license
```

### Windows

Download `Summer-2008-Setup-v1.0.0.exe` (315 MB). Requires Windows 10
1809 (build 17763) or newer, x64. Double-click to run the installer —
follow the standard next-next-finish flow. The installer creates Start
Menu + (optional) Desktop shortcuts and auto-installs the Edge WebView2
runtime if it isn't already present.

**First launch** — Windows SmartScreen may say "Windows protected your
PC" because the installer isn't signed with an EV certificate yet.
Click **More info → Run anyway**. You only do it once; future launches
are normal.

---

## Build from source

The canonical source repository is on
**[Codeberg](https://codeberg.org/ganten1998/summer-2008)**; the GitHub
repo is a mirror that additionally carries the release binaries and the
Windows CI. Either will build.

### macOS (.app and .dmg)

```bash
# 1. Clone
git clone https://codeberg.org/ganten1998/summer-2008.git ~/Projects/summer-2008
cd ~/Projects/summer-2008

# 2. Hydrate the projector binaries (Wine + Director from your local
#    Flashpoint install)
./tools/fetch-projector.sh

# 3. Build the .app (universal, signed with whatever identity you have)
./app/build.sh

# 4. (Optional) Notarize. Needs a Developer ID cert and stored
#    notarytool credentials; see the header of the script
./app/notarize.sh

# 5. (Optional) Wrap into a distributable DMG
./app/make-dmg.sh --release
```

The .app lands at `build/Summer 2008 — An American Girl Archive.app`.

### Windows (.exe installer)

Requires .NET 8 SDK + Inno Setup 6. **No Flashpoint install required** —
projector binaries auto-download from this repo's `build-deps-v1` release.

```powershell
# From a Windows machine (or via the windows-build.yml GitHub Actions
# workflow on push)
git clone https://github.com/ganten1998/summer-2008.git C:\Projects\summer-2008
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

Two native shells around the same content. The macOS app is WebKit
(`WKWebView` + `MirrorURLSchemeHandler.swift`); the Windows app is WPF +
WebView2 (`MainWindow.xaml.cs` + `MirrorHandler.cs`). Both register the
same custom URL scheme (`agd://`) and route every request through the
same pipeline:

- Serves files out of a bundled mirror tree (~111 MB of preserved HTML / CSS
  / JS / SWF / DCR / images).
- Falls through to a runtime backfill cache if the user hits a URL we don't
  have, then to a live Wayback fetch as a last resort — both platforms pin
  to the same `20080711092743` snapshot timestamp, so the heal-on-first-view
  behavior is identical.
- Routes `.swf` clicks into an inline [Ruffle](https://ruffle.rs) player.
- Routes `.dcr` clicks to a bundled Adobe Director projector. macOS uses
  Wine to run the Windows projector; Windows runs it natively.
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

On macOS the window itself is fully draggable from any non-interactive
surface — the red AG navigation bar, the dashboard's solid-color header,
the empty page background — using a threshold-based mousedown handler
that distinguishes a deliberate drag from a single click (links and
tile-card clicks pass through intact). The Director projector windows
are positioned, focused, and torn down via macOS Accessibility APIs; on
quit, every spawned projector is SIGKILLed before the host exits so
nothing leaks across launches.

On Windows the bottom-right "Open in Flash Projector" pill spawns the
bundled `flashplayer_32_sa.exe` (or `Projector.exe` for `.dcr`) as a
separate top-level window — no AX driving, no overlay positioning. Same
end result: real Adobe runtime, no Ruffle limits, one click away
whenever you need it.

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
