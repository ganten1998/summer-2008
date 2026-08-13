#!/usr/bin/env bash
# Build a distributable .dmg of Summer 2008 — An American Girl Archive.
#
#   ./make-dmg.sh                 builds the .app first if missing, then DMGs it
#   ./make-dmg.sh --skip-build    use the existing .app in build/ as-is
#   ./make-dmg.sh --release       name it "Summer 2008 v<VERSION>.dmg" for
#                                 publication instead of "Pre-Release N"
#
# Default output is build/Summer 2008 — Pre-Release N.dmg, auto-incrementing N.
# With --release it is build/Summer 2008 v<VERSION>.dmg — the exact filename
# the README tells people to download, so the two cannot drift apart.
set -eu
if [ -n "${BASH_VERSION:-}" ]; then set -o pipefail; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="Summer 2008 — An American Girl Archive"
APP_PATH="$ROOT/build/$APP_NAME.app"
VOL_NAME="Summer 2008 — An American Girl Archive"

SKIP_BUILD=0
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --release)    RELEASE=1 ;;
  esac
done

# Single source of truth for the version: read it back out of the Info.plist
# that actually ships, so the DMG name can never disagree with the bundle.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$HERE/Resources/Info.plist" 2>/dev/null || echo "1.0")"

# If the bundle already carries a stapled notarization ticket, rebuilding it
# would silently throw that away: build.sh starts with `rm -rf "$OUT"` and
# re-signs from scratch, and a fresh signature has no ticket. The documented
# release order is build → notarize (staples the .app) → make-dmg, so the
# default rebuild would undo step 4 every time. Detect it and keep the ticket.
STAPLED=0
if [ -d "$APP_PATH" ] && xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
  STAPLED=1
fi

if [ "$STAPLED" -eq 1 ] && [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> Existing .app is notarized and stapled — NOT rebuilding"
  echo "    (a rebuild would discard the ticket; pass --skip-build to silence)"
elif [ "$SKIP_BUILD" -eq 0 ] || [ ! -d "$APP_PATH" ]; then
  echo "==> Building the .app first"
  bash "$HERE/build.sh"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "!! .app missing at $APP_PATH after build" >&2
  exit 1
fi

if [ "$RELEASE" -eq 1 ]; then
  DMG_PATH="$ROOT/build/Summer 2008 v$VERSION.dmg"
  rm -f "$DMG_PATH"
else
  # Auto-increment pre-release number based on existing artifacts.
  N=1
  while [ -e "$ROOT/build/Summer 2008 — Pre-Release $N.dmg" ]; do
    N=$((N + 1))
  done
  DMG_PATH="$ROOT/build/Summer 2008 — Pre-Release $N.dmg"
fi

echo "==> Staging DMG contents"
STAGE="$(mktemp -d -t agd-dmg)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/.bg"

# Copy the .app into the stage.
ditto "$APP_PATH" "$STAGE/$APP_NAME.app"

# Drop in an Applications symlink so users can drag-to-install.
ln -s /Applications "$STAGE/Applications"

# README-y note inside the DMG.
cat > "$STAGE/About this archive.txt" <<EOF
Summer 2008 — An American Girl Archive
=======================================

Drag the .app to your /Applications folder, then launch it.

What this is:
  An offline snapshot of americangirl.com captured around July 2008
  — the era of Nicki Fleming as Girl of the Year, the Kit Kittredge
  movie release, and the historical character lineup of Felicity,
  Addy, Kit, Molly, Samantha, Kaya, Josefina, Kirsten.

What plays:
  • 116 Flash games (via Ruffle + bundled Adobe Flash Player projector)
  • 20 Shockwave Director games (via bundled Wine + Director projector)
  • Every preserved e-card with personalize + Mail.app handoff

Known gaps:
  • American Girl Magazine e-cards (category=agm) — never crawled
  • store.americangirl.com — e-commerce, can't function offline
  • A handful of mid-game Ruffle errors on specific titles

Codename: Coconut
EOF

echo "==> Creating DMG → $DMG_PATH"
hdiutil create -volname "$VOL_NAME" \
               -srcfolder "$STAGE" \
               -ov -format UDZO \
               -fs HFS+ \
               -imagekey zlib-level=9 \
               "$DMG_PATH"

# Sign the disk image itself. Gatekeeper evaluates the DMG on download, so an
# unsigned DMG wrapping a notarized app still trips a warning before the user
# has opened anything.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE 'Developer ID Application: [^"]+' | head -1 || true)"
if [ -n "$DEV_ID" ]; then
  echo "==> Signing the DMG with $DEV_ID"
  codesign --force --timestamp --sign "$DEV_ID" "$DMG_PATH" \
    || echo "    (DMG signing failed; the app inside is still signed)"
fi

du -sh "$DMG_PATH" 2>/dev/null || true
echo ""
echo "Built: $DMG_PATH"
if [ "$RELEASE" -eq 1 ] && [ -n "$DEV_ID" ]; then
  echo ""
  echo "Next: bash app/notarize.sh --dmg \"$DMG_PATH\""
fi
