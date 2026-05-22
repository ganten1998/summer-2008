#!/usr/bin/env bash
# Launches a second instance of download_mirror.py bound to the iPhone
# USB-tether interface, so it appears to Wayback as a different IP and
# gets its own rate-limit budget.
#
# Prerequisites:
#   1. iPhone: Settings → Personal Hotspot → "Allow Others to Join" ON
#   2. Plug iPhone into Mac with a USB cable (Lightning / USB-C)
#   3. Wait ~5s for macOS to detect the tether interface
#   4. Run this script
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOG="$ROOT/build/mirror_B.log"
PROG="$ROOT/build/mirror_progress_B.log"

# Find the iPhone interface. macOS names the hardware port "iPhone" or
# "iPhone USB". Map the port → device → IPv4 address.
PORT_LINE="$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Hardware Port:/{p=$0} /Device:/{print p"|"$2}' \
  | grep -iE "iphone" | head -1 || true)"

if [[ -z "$PORT_LINE" ]]; then
  echo "❌ No iPhone interface detected." >&2
  echo "   Check: iPhone plugged in via USB, Personal Hotspot enabled, 'Allow Others to Join' ON." >&2
  echo "   Then re-run: $0" >&2
  exit 1
fi

DEV="$(echo "$PORT_LINE" | awk -F'|' '{print $2}')"
IP="$(ipconfig getifaddr "$DEV" 2>/dev/null || true)"

if [[ -z "$IP" ]]; then
  echo "⚠️  Found iPhone interface ($DEV) but it has no IPv4 yet." >&2
  echo "   Try toggling Personal Hotspot off/on, or unplug+replug the cable." >&2
  exit 1
fi

echo "✅ iPhone tether detected: $DEV  →  source IP $IP"
echo "🚀 Launching downloader B (shard 1/2, bound to $IP)"
echo "   Log: $LOG"
echo ""

cd "$ROOT"
rm -f "$LOG"
nohup python3 tools/download_mirror.py \
  --shard 1/2 \
  --source-ip "$IP" \
  --log "$PROG" \
  > "$LOG" 2>&1 &
PID=$!
echo "Downloader B PID: $PID"
echo "Tail the log with: tail -f \"$LOG\""
