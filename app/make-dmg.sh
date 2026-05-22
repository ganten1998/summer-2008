#!/usr/bin/env bash
# Build a distributable .dmg of Summer 2008 — An American Girl Archive.
#
#   ./make-dmg.sh                 builds the .app first if missing, then DMGs it
#   ./make-dmg.sh --skip-build    use the existing .app in build/ as-is
#
# Output lands at build/Summer 2008 — Pre-Release N.dmg, auto-incrementing N.
set -eu
if [ -n "${BASH_VERSION:-}" ]; then set -o pipefail; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="Summer 2008 — An American Girl Archive"
APP_PATH="$ROOT/build/$APP_NAME.app"
VOL_NAME="Summer 2008 — An American Girl Archive"

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
  esac
done

if [ "$SKIP_BUILD" -eq 0 ] || [ ! -d "$APP_PATH" ]; then
  echo "==> Building the .app first"
  bash "$HERE/build.sh"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "!! .app missing at $APP_PATH after build" >&2
  exit 1
fi

# Auto-increment pre-release number based on existing artifacts.
N=1
while [ -e "$ROOT/build/Summer 2008 — Pre-Release $N.dmg" ]; do
  N=$((N + 1))
done
DMG_PATH="$ROOT/build/Summer 2008 — Pre-Release $N.dmg"

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

du -sh "$DMG_PATH" 2>/dev/null || true
echo ""
echo "Built: $DMG_PATH"
