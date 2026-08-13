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

echo "==> Compiling Swift sources (universal: arm64 + x86_64)"
# The app used to be built arm64-only while the README promised "Intel works
# under Rosetta" — which is backwards: Rosetta translates x86_64 → arm64, so
# an arm64-only binary simply will not launch on an Intel Mac. Build a real
# universal binary instead. (Note the bundled Wine tree is x86_64-only, so on
# Apple Silicon the projectors themselves run under Rosetta — GameLauncher
# preflights for that separately.)
SRC=("$HERE"/Sources/*.swift)
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
STAGE="$(mktemp -d -t agd-build)"
trap 'rm -rf "$STAGE"' EXIT

SLICES=()
for ARCH in arm64 x86_64; do
  echo "    → $ARCH"
  if swiftc \
      -O \
      -target "${ARCH}-apple-macos11" \
      -sdk "$SDK_PATH" \
      -framework AppKit -framework WebKit -framework Foundation \
      -framework AVFoundation -framework ImageIO -framework UniformTypeIdentifiers \
      -o "$STAGE/AGDLauncher-$ARCH" \
      "${SRC[@]}"; then
    SLICES+=("$STAGE/AGDLauncher-$ARCH")
  else
    echo "    !! $ARCH slice failed to compile — continuing without it"
  fi
done

if [[ ${#SLICES[@]} -eq 0 ]]; then
  echo "!! No architecture compiled. Aborting." >&2
  exit 1
fi
lipo -create "${SLICES[@]}" -output "$OUT/Contents/MacOS/AGDLauncher"
echo "    architectures: $(lipo -archs "$OUT/Contents/MacOS/AGDLauncher")"

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

echo "==> Copying bundled Flash standalone projector (Wine-driven)"
if [[ -d "$ROOT/projector/Flash" ]]; then
  ditto "$ROOT/projector/Flash" "$OUT/Contents/Resources/Flash"
else
  echo "    !! projector/Flash missing -- SWF projector fallback unavailable"
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
#
# Signing is done INSIDE-OUT (nested Mach-O first, bundle last) rather than
# with `codesign --deep`. Apple deprecated --deep for exactly this case: it
# applies the *same* entitlements to every nested binary and is documented as
# unsuitable for distribution signing. A --deep-signed bundle can pass local
# verification and still be rejected by the notary service.
ENTITLEMENTS="$HERE/Resources/Summer2008.entitlements"
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE 'Developer ID Application: [^"]+' | head -1 || true)"
LOCAL_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"Summer 2008 Dev"' | head -1 | tr -d '"' || true)"

if [[ -n "$DEV_ID" ]]; then
  SIGN_IDENTITY="$DEV_ID"
  # --timestamp and --options runtime are both mandatory for notarization.
  SIGN_FLAGS=(--force --options runtime --timestamp)
  echo "    Using $DEV_ID (hardened runtime + secure timestamp)"
elif [[ -n "$LOCAL_ID" ]]; then
  SIGN_IDENTITY="$LOCAL_ID"
  SIGN_FLAGS=(--force)
  echo "    Using local self-signed: $LOCAL_ID"
  echo "    (dev only — cannot be notarized)"
else
  SIGN_IDENTITY="-"
  SIGN_FLAGS=(--force)
  echo "    No Developer ID or self-signed cert found — falling back to ad-hoc."
  echo "    For stable dev signing:  bash tools/setup-codesign-identity.sh"
  echo "    For distribution:        enroll at https://developer.apple.com"
fi

# Step 1: every nested Mach-O (Wine's ~130 dylibs + its three binaries).
# The bundled Windows projectors (.exe) are PE files — inert data to macOS,
# and codesign must not touch them. Scope the scan to the projector trees;
# the mirror is ~5,000 files of pure content with nothing executable in it.
echo "    Signing nested Mach-O binaries…"
NESTED_COUNT=0
while IFS= read -r bin; do
  if file -b "$bin" 2>/dev/null | grep -q 'Mach-O'; then
    codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" \
             --sign "$SIGN_IDENTITY" "$bin" >/dev/null 2>&1 \
      && NESTED_COUNT=$((NESTED_COUNT + 1)) \
      || echo "      (warn: could not sign $(basename "$bin"))"
  fi
done < <(find "$OUT/Contents/Resources/Wine" \
              "$OUT/Contents/Resources/Flash" \
              "$OUT/Contents/Resources/Shockwave" \
              -type f 2>/dev/null)
echo "    Signed $NESTED_COUNT nested Mach-O binaries"

# Step 2: the bundle itself, last, so the seal covers the signed nested code.
codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" \
         --sign "$SIGN_IDENTITY" "$OUT" \
  || echo "(codesign warning; app still runnable locally)"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$OUT" 2>&1 | tail -3 || true
if [[ -n "$DEV_ID" ]]; then
  echo "    Gatekeeper assessment (expect 'rejected' until notarized+stapled):"
  spctl -a -t exec -vv "$OUT" 2>&1 | tail -3 || true
fi

echo ""
echo "Built: $OUT"
du -sh "$OUT" 2>/dev/null || true
if [[ -n "$DEV_ID" ]]; then
  echo ""
  echo "Next: bash app/notarize.sh    (submit to Apple, then staple)"
fi
