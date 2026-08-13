# Summer 2008 — Windows port

A native Windows build of the archive, mirroring the macOS .app as
closely as possible:

| Concept            | macOS                          | Windows                                  |
|---|---|---|
| Shell              | Swift + AppKit                 | C# + WPF (.NET 8)                        |
| Web engine         | WKWebView                      | WebView2 (Edge Chromium)                 |
| URL scheme         | `WKURLSchemeHandler` for `agd://` | `WebResourceRequested` filter for `agd://*` |
| Flash playback     | bundled Adobe Flash Player.app | bundled `flashplayer_32_sa.exe`          |
| Shockwave playback | bundled Wine + Director projector | bundled native Director projector (no Wine) |
| Volume persistence | `~/Library/Application Support/Summer 2008/prefs.json` | `%LOCALAPPDATA%\Summer 2008\prefs.json`   |
| Settings storage   | WKWebView default              | WebView2 user-data folder at `%LOCALAPPDATA%\Summer 2008` |
| Distribution       | `.dmg` (Developer ID + notarized)| Inno Setup `.exe` installer              |

The HTML/CSS/JS — dashboard, mirror-runtime (Ruffle, flash-bridge,
volume-control), the ecard wizard, welcome modal, stub pages, and the
mirror itself — is **shared verbatim** with the macOS build. No
duplication.

---

## Install (end user)

Download `Summer-2008-Setup-v1.0.0.exe` from
[Releases](https://github.com/ganten1998/summer-2008/releases), double-click,
follow the installer. Defaults install to `C:\Program Files\Summer 2008\`
and create Start Menu + (optional) Desktop shortcuts.

The first launch may prompt Windows SmartScreen because the installer
isn't yet signed with a Microsoft-trusted EV certificate. Click
**More info → Run anyway**.

**System requirements:** Windows 10 1809 (build 17763) or newer,
x64. The installer auto-installs the Edge WebView2 runtime if it isn't
already present (it ships with every Win10/11 since mid-2021).

---

## Build from source

### One-time prerequisites

1. **.NET 8 SDK** — https://dotnet.microsoft.com/download/dotnet/8.0
2. **Inno Setup 6** — https://jrsoftware.org/isdl.php
   (or `winget install JRSoftware.InnoSetup`)

That's it. No Flashpoint install required — the projector binaries are
downloaded automatically from this repo's `build-deps-v1` release.

### Steps

```powershell
# 1. Clone and enter
git clone https://github.com/ganten1998/summer-2008.git C:\Projects\summer-2008
cd C:\Projects\summer-2008

# 2. Hydrate the projector binaries (downloads ~80 MB from this repo's
#    build-deps-v1 release, or reuses a local Flashpoint if you have one)
.\tools\fetch-projector-windows.ps1

# 3. Build the EXE + Inno Setup installer
cd app-windows
.\build.ps1
```

Output lands at `app-windows\build\Summer-2008-Setup-v1.0.0.exe`
(~400 MB compressed; opens to ~800 MB installed). The plain unpacked
EXE alone is at `app-windows\build\publish\Summer2008.exe` if you want
to run without installing.

### Building from macOS / Linux

Use the GitHub Actions workflow in `.github/workflows/windows-build.yml`.
Push to a branch — CI builds the installer on a Windows runner and
uploads it as a workflow artifact. Tag pushes (`v1.0.0`, `v1.1.0`,
etc.) automatically attach the installer to the matching release.

---

## How the URL handler works

WebView2 lets you intercept any URL scheme via
`CoreWebView2.AddWebResourceRequestedFilter`. We register a filter for
`agd://*` and respond synthetically in `MirrorHandler.cs`:

```
agd://dashboard/index.html
  → reads Resources\dashboard\index.html

agd://www.americangirl.com/agcn/kit/index.html
  → reads Resources\mirror\www.americangirl.com\agcn\kit\index.html

agd://www.americangirl.com/ecards/sw/agc_molly_star.swf?personalMsg=Hi
  → tries exact, then base name, then glob match (query stripped)

agd://store.americangirl.com/anything
  → synthesised "shop wasn't preserved" stub

agd://runtime/__prefs__/volume   (GET / PUT)
  → JSON file at %LOCALAPPDATA%\Summer 2008\prefs.json
```

Navigation interception in `NavHandler.cs` routes `agd-launch://` URLs
(flash-bridge.js's "Open in Flash Projector" pill) into `GameLauncher.cs`,
which spawns the bundled standalone projector via `Process.Start()`.
`mailto:` / `tel:` / `sms:` URLs hand off to the OS via
`ShellExecute = true`.
