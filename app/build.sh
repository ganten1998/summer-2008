#!/usr/bin/env bash
# Build a self-contained .app bundle for the "Coconut" archive
# (public name: Summer 2008 — An American Girl Archive).
#
#   ./build.sh                 build into ../build/<APP_NAME>.app
#   ./build.sh --no-mirror     skip copying the (large) mirror/ directory
#                              -- useful while iterating on the Swift code
set -eu
# pipefail is bash >=3.2 -- macOS ships /bin/bash 3.2 which is fine, but only
# if we're truly running bash. Older /bin/sh chokes on it.
if [ -n "${BASH_VERSION:-}" ]; then set -o pipefail; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Public-facing bundle name. Em-dash here was sanity-checked against
# codesign + bash quoting; if it ever breaks distribution, fall back to
# the short label "Summer 2008" and keep the full title only in the
# Info.plist CFBundleDisplayName.
APP_NAME="Summer 2008 — An American Girl Archive"
OUT="$ROOT/build/$APP_NAME.app"

INCLUDE_MIRROR=1
for arg in "$@"; do
  case "$arg" in
    --no-mirror) INCLUDE_MIRROR=0 ;;
  esac
done

echo "==> Cleaning previous build"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "==> Compiling Swift sources"
SRC=("$HERE"/Sources/*.swift)
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
swiftc \
  -O \
  -target arm64-apple-macos11 \
  -sdk "$SDK_PATH" \
  -framework AppKit -framework WebKit -framework Foundation \
  -o "$OUT/Contents/MacOS/AGDLauncher" \
  "${SRC[@]}"

echo "==> Copying Info.plist"
cp "$HERE/Resources/Info.plist" "$OUT/Contents/Info.plist"

echo "==> Copying app icon"
if [[ -f "$HERE/Resources/AppIcon.icns" ]]; then
  cp "$HERE/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi

echo "==> Copying dashboard resources"
cp -R "$HERE/Resources/dashboard" "$OUT/Contents/Resources/dashboard"

echo "==> Copying mirror-runtime (flash-bridge.js etc)"
cp -R "$HERE/Resources/mirror-runtime" "$OUT/Contents/Resources/mirror-runtime"

echo "==> Copying bundled Flash Player projector"
if [[ -d "$ROOT/projector/Flash Player.app" ]]; then
  cp -R "$ROOT/projector/Flash Player.app" "$OUT/Contents/Resources/Flash Player.app"
else
  echo "    !! projector/Flash Player.app missing -- SWF games won't launch"
fi

echo "==> Copying bundled Wine + Director projectors (for .dcr Shockwave games)"
if [[ -d "$ROOT/projector/Wine" ]]; then
  ditto "$ROOT/projector/Wine" "$OUT/Contents/Resources/Wine"
else
  echo "    !! projector/Wine missing -- Shockwave games won't launch"
fi
if [[ -d "$ROOT/projector/Shockwave" ]]; then
  ditto "$ROOT/projector/Shockwave" "$OUT/Contents/Resources/Shockwave"
else
  echo "    !! projector/Shockwave missing -- Shockwave games won't launch"
fi

echo "==> Copying curated games"
if [[ -d "$ROOT/games" ]]; then
  mkdir -p "$OUT/Contents/Resources/games"
  if find "$ROOT/games" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    ditto "$ROOT/games" "$OUT/Contents/Resources/games"
  fi
fi

if [[ "$INCLUDE_MIRROR" -eq 1 ]]; then
  echo "==> Patching mirrored HTML/CSS/JS so it works under the agd:// scheme"
  python3 "$ROOT/tools/patch_mirror_html.py" >/dev/null

  echo "==> Regenerating games gallery from current mirror contents"
  python3 "$ROOT/tools/build_games_gallery.py" >/dev/null
  # The gallery generator writes back into app/Resources/dashboard/, so re-copy
  cp "$ROOT/app/Resources/dashboard/games.html" "$OUT/Contents/Resources/dashboard/games.html"

  echo "==> Copying mirror (~$(du -sh "$ROOT/mirror" 2>/dev/null | awk '{print $1}'))"
  mkdir -p "$OUT/Contents/Resources/mirror"
  if [[ -d "$ROOT/mirror" ]]; then
    ditto "$ROOT/mirror" "$OUT/Contents/Resources/mirror"
  fi
else
  echo "==> Skipping mirror copy (--no-mirror)"
  mkdir -p "$OUT/Contents/Resources/mirror"
fi

echo "==> Codesign"
# Sign with the best available identity, in priority order:
#   1. Developer ID Application — real Apple-issued, public distribution
#   2. "Summer 2008 Dev" — local self-signed (created via
#      tools/setup-codesign-identity.sh). Stable cdhash across rebuilds,
#      so macOS Accessibility grants persist between dev iterations.
#   3. ad-hoc — last resort; cdhash changes every build, so every rebuild
#      revokes Accessibility/TCC permissions.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE 'Developer ID Application: [^"]+' | head -1 || true)"
LOCAL_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"Summer 2008 Dev"' | head -1 | tr -d '"' || true)"

if [[ -n "$DEV_ID" ]]; then
  echo "    Using $DEV_ID"
  codesign --force --deep --options runtime \
           --sign "$DEV_ID" "$OUT" \
    || echo "(codesign warning; app still runnable)"
elif [[ -n "$LOCAL_ID" ]]; then
  echo "    Using local self-signed: $LOCAL_ID"
  echo "    (cdhash stable across rebuilds → Accessibility grant persists)"
  codesign --force --deep --sign "$LOCAL_ID" "$OUT" \
    || echo "(codesign warning; app still runnable)"
else
  echo "    No Developer ID or self-signed cert found — falling back to ad-hoc."
  echo "    For stable codesigning: bash tools/setup-codesign-identity.sh"
  echo "    For distribution: enroll at https://developer.apple.com"
  codesign --force --deep --sign - "$OUT" \
    || echo "(codesign warning; app still runnable)"
fi

echo ""
echo "Built: $OUT"
du -sh "$OUT" 2>/dev/null || true
