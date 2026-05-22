#!/usr/bin/env bash
# Hydrate projector/Wine and projector/Shockwave from a local Flashpoint
# install. Run this once after cloning, before app/build.sh.
#
# Why this isn't committed to the repo:
#   • Wine 10.20 + 6 Director projector versions is ~610 MB of binary
#     payload that pushes GitHub's recommended repo size.
#   • The Director projectors are Adobe IP. Flashpoint Project
#     redistributes them under their preservation-fair-use stance; we
#     point users at Flashpoint rather than re-host.
#
# Prerequisites: install Flashpoint Infinity or Flashpoint Ultimate from
#   https://flashpointarchive.org/
# The Mac build is at:
#   https://flashpointarchive.org/downloads
#
# Default search locations: ~/Documents, ~/Applications, /Applications.
# Override with FLASHPOINT_PATH=/path/to/Flashpoint ./tools/fetch-projector.sh

set -eu
if [ -n "${BASH_VERSION:-}" ]; then set -o pipefail; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Discover Flashpoint.
discover_flashpoint() {
  if [ -n "${FLASHPOINT_PATH:-}" ] && [ -d "${FLASHPOINT_PATH}/FPSoftware" ]; then
    echo "$FLASHPOINT_PATH"; return 0
  fi
  for parent in "$HOME/Documents" "$HOME/Applications" "/Applications" "$HOME"; do
    for fp in "$parent"/Flashpoint*; do
      if [ -d "$fp/FPSoftware/Wine" ] && [ -d "$fp/FPSoftware/Shockwave" ]; then
        echo "$fp"; return 0
      fi
    done
  done
  return 1
}

FP="$(discover_flashpoint || true)"

if [ -z "$FP" ]; then
  cat >&2 <<'EOF'
✗ Flashpoint not found.

This project bundles a Wine-driven Shockwave projector for the .dcr games
(Addy's Mancala, Kit's Jigsaw, Molly's Pedal Power, Kirsten's Raccoon
Caper, etc.). The projector EXEs are Adobe IP, so the repo doesn't carry
them — you pull them from a local Flashpoint install instead.

How to fix:
  1. Download Flashpoint Infinity or Ultimate for Mac:
       https://flashpointarchive.org/downloads
  2. Unzip it anywhere under ~/Documents/, ~/Applications/, or /Applications/.
  3. Re-run this script:
       ./tools/fetch-projector.sh

If Flashpoint is installed somewhere unusual, point this script at it:
  FLASHPOINT_PATH=/some/where/Flashpoint ./tools/fetch-projector.sh

EOF
  exit 1
fi

echo "✓ Found Flashpoint at: $FP"
echo ""
echo "==> Hydrating projector/Wine (~440 MB)"
mkdir -p "$ROOT/projector"
ditto "$FP/FPSoftware/Wine" "$ROOT/projector/Wine"
echo "✓ projector/Wine ready"

echo ""
echo "==> Hydrating projector/Shockwave (~170 MB, 6 projector versions)"
ditto "$FP/FPSoftware/Shockwave" "$ROOT/projector/Shockwave"
echo "✓ projector/Shockwave ready"

echo ""
echo "==> Done. Run app/build.sh to build the .app."
du -sh "$ROOT/projector"/* 2>/dev/null | sort -h
