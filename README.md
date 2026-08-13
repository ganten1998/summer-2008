# Summer 2008 — An American Girl Archive

> *You'd dump your Tamagotchi in the bottom of your backpack, walk home from school,
> open the family iMac, and click around americangirl.com until dinner. You played
> Kit's Railway Adventure. You sent your friend an e-card with Coconut on it. You
> filled out the "Real Girl of the Year" form even though you were too old. You knew
> the click sound the Flash navigation made before it loaded.*

This is that website. Frozen.

Summer 2008 is an offline, playable snapshot of **americangirl.com** as it existed
around **11 July 2008**: the Nicki Fleming era, the *Kit Kittredge* movie release,
and the original eight historical characters before any retirements.

The site was redesigned in 2011, and what survived afterward lived only in the
Wayback Machine as a stub with no Flash, dead e-cards and missing games. This
project puts it back together as native apps for macOS and Windows. Anything the
bundle missed is patched in from the Wayback Machine on first view and cached, so
by the second visit it works offline too.

---

## What's inside

**The full mid-2008 site.** Every character hub, with bio, book, friends and world
pages. Every Girl of the Year from Lindsey (2001) through Nicki (2007). The Real
Girl of the Year 2008 contestant pages. The *Kit Kittredge* movie subsite. Magazine
Activities, Coconut & Licorice, Quiz Corner, Travel, Paper Dolls, the Mysteries.

**112 Flash games and animations, playable inline** through
[Ruffle](https://ruffle.rs). Felicity's Colonial Adventure, Kit's Railway Adventure,
Kaya's Catch of the Day, Kirsten's Raccoon Caper, Molly's Pedal Power, Samantha's
Scavenger Hunt, Josefina's Santa Fe Market, Addy's *A Life in Freedom*, Paper Dolls,
and every Magazine Activity and Quiz Corner quiz.

**30 Shockwave Director games and activities**, including Addy's Mancala,
Josefina's Piano, Samantha's Sketchbook, Sea Horse Round Up and Mahjong Mania.
These need a real Director runtime, so the app bundles one. The projector spawns
over the embed area at the game's native size; drag it anywhere, close it, relaunch
it from the same pill.

**The full e-card system.** Choose a card, type a message, preview it with your
message embedded, then send it by handoff to your mail app. The original send
backend died with the 2008 servers, so the card goes out from your own account.

Every game page carries a volume pill and an "Open in Flash Projector" pill. The
projector pill hands off to the real bundled Adobe runtime whenever Ruffle stumbles.

---

## What's missing

**American Girl Magazine e-cards** (the "agm" category in E-Card Central) were
rendered from a database, and the chooser URL was never reached by any crawler.
Wayback's full CDX, every Common Crawl index from 2008 to 2015, archive.today, the
Memento aggregator, every search engine and the Flashpoint Archive database have
all been checked, twice, years apart. The page exists nowhere on the public
internet. Selecting that option lands on a note explaining what happened.

**Nine e-card animations.** Of the 95 cards E-Card Central offers, 86 now have
their animation. The other nine were never captured, or survive only as empty
redirect records. Their entries still appear in the chooser, because a card you
can't open is at least a record that it existed.

**Eight magazine feature games** from the 2008 issues: Animal Cupcakes, Island
Party, Puppy Video, Shades, Smiling Pets, Stunt Girl, You Pick It, Plus or Minus.
Flashpoint Archive curates other games from the same directories but not these.

**store.americangirl.com**, which was 58,000+ URLs of live e-commerce and cannot be
a static snapshot. SHOP links land on an explainer.

**Some mid-game Ruffle errors** on specific titles. The projector pill is the
fallback.

---

## Install

Downloads are on the [Releases page](https://github.com/ganten1998/summer-2008/releases).
Both bundles are fully self-contained: the whole mirror, every projector, and the
runtime. No companion apps.

### macOS

`Summer.2008.v1.0.dmg`, 519 MB to download and 949 MB installed. Requires macOS 11
or newer. Universal, so native on both Apple Silicon and Intel.

Open the DMG, drag the app to Applications, launch it. That's the whole install.
The app is signed with an Apple Developer ID and notarized, so there is no security
warning to click through.

**One caveat on Apple Silicon.** The Flash and Shockwave projectors are the
original Adobe runtimes, which are Intel software from the 2000s, so they need
Rosetta. Everything else works without it, including all the inline Ruffle games.
If you click a projector game without Rosetta installed, the app tells you and
gives you the command:

```bash
softwareupdate --install-rosetta --agree-to-license
```

### Windows

`Summer-2008-Setup-v1.0.0.exe`, 315 MB. Requires Windows 10 1809 (build 17763) or
newer, x64. Standard installer flow. It creates Start Menu and optional Desktop
shortcuts, and installs the Edge WebView2 runtime if it isn't already present.

SmartScreen may warn once, because the installer isn't signed with an EV
certificate. Choose **More info → Run anyway**.

---

## Build from source

The canonical repository is on
**[Codeberg](https://codeberg.org/ganten1998/summer-2008)**. The GitHub repo
mirrors it and additionally carries the release binaries and the Windows CI.
Either will build.

### macOS

```bash
git clone https://codeberg.org/ganten1998/summer-2008.git ~/Projects/summer-2008
cd ~/Projects/summer-2008

./tools/fetch-projector.sh   # Wine + Director projectors, from a local Flashpoint
./app/build.sh               # universal .app, signed with whatever identity you have
./app/notarize.sh            # optional: needs a Developer ID + notarytool credentials
./app/make-dmg.sh --release  # optional: distributable DMG
```

The app lands at `build/Summer 2008 — An American Girl Archive.app`.

### Windows

Requires .NET 8 SDK and Inno Setup 6. No Flashpoint install needed, because the
projectors download from this repo's `build-deps-v1` release.

```powershell
.\tools\fetch-projector-windows.ps1
cd app-windows
.\build.ps1
```

The installer lands at `app-windows\build\Summer-2008-Setup-v1.0.0.exe`.

The `windows-build.yml` workflow builds the installer on every push and attaches it
to the matching release on a `v*` tag, so you can produce Windows builds without a
Windows machine.

---

## How it works

Two native shells around the same content. macOS is `WKWebView` plus
`MirrorURLSchemeHandler.swift`; Windows is WPF and WebView2 plus `MirrorHandler.cs`.
Both register an `agd://` scheme and route every request the same way:

1. Serve from the bundled mirror.
2. Fall through to a runtime cache, then to a live Wayback fetch pinned to the
   `20080711092743` snapshot, so both platforms heal identically on first view.
3. Route `.swf` into an inline Ruffle player, and `.dcr` to the bundled Director
   projector. macOS runs the Windows projectors under Wine; Windows runs them
   natively.
4. Serve styled stubs for known-dead surfaces, so dead ends feel intentional rather
   than broken.

`tools/patch_mirror_html.py` injects the Ruffle and volume scripts into every page,
rewrites cross-domain URLs to `agd://`, neutralizes 2008-era tracking pixels, and
intercepts dead form actions. `tools/build_games_gallery.py` regenerates the
dashboard on every build by walking the mirror, grouping SWFs by wrapper and
deduplicating by hash. `tools/deep_recover.py` is the recovery tool, and
`tools/verify_mirror_integrity.py` gates a release by checking that every asset's
bytes match its extension.

---

## Contribute

If you ever encounter 2008-era American Girl content that isn't here, especially
the Magazine e-cards, **please open an issue**. Old saved pages from a school
computer, browser cache exports, screenshots, SWF files with `agm_` in the name,
even just remembered card titles. Cataloging what was lost matters too.

---

## Posture

A non-commercial preservation project, not a product. American Girl is a trademark
of Mattel, Inc. This project is not affiliated with or endorsed by them, and
nothing here re-hosts current AG content. The goal is one thing: keep a working
copy of the mid-2008 site reachable, the way kids actually used it.

See [LICENSE](LICENSE) for how the original code and the archived material are
treated differently.

If it matters to you, you can [tip the archivist on Ko-fi](https://ko-fi.com/B0B7EF4TJ).

---

## Credits

The 2008 American Girl team and Mattel for the original content. The
[Internet Archive](https://web.archive.org/) for roughly 95% of the mirror, and
[Common Crawl](https://commoncrawl.org/) for part of the rest.
[Ruffle](https://ruffle.rs/) for making inline Flash playback possible.
[Flashpoint Archive](https://flashpointarchive.org/) for the Wine and Director
projector distribution. Adobe, for Flash and Director, both retired and now
necessary archaeology.

Built for everyone who remembers.

*Codename: Coconut.*
