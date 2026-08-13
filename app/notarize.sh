#!/usr/bin/env bash
# Notarize and staple Summer 2008 — An American Girl Archive.
#
#   ./notarize.sh              notarize + staple build/<APP_NAME>.app
#   ./notarize.sh --dmg PATH   notarize + staple a .dmg instead
#
# Prerequisite (one time):
#
#   xcrun notarytool store-credentials "AGD_NOTARY" \
#       --apple-id <your-apple-id> --team-id 6GFLLR9599 \
#       --password <app-specific-password>
#
# Create the app-specific password at appleid.apple.com → Sign-In and
# Security → App-Specific Passwords. Your regular Apple ID password will
# NOT work.
#
# Why both the .app and the .dmg get notarized: stapling the .app makes the
# installed copy pass Gatekeeper offline; stapling the .dmg makes the
# *download itself* pass before the user has even opened it. Skipping the
# second one is the usual reason a notarized app still shows a warning.
set -eu
if [ -n "${BASH_VERSION:-}" ]; then set -o pipefail; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="Summer 2008 — An American Girl Archive"
PROFILE="${NOTARY_PROFILE:-AGD_NOTARY}"

TARGET="$ROOT/build/$APP_NAME.app"
IS_DMG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dmg) IS_DMG=1; TARGET="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -e "$TARGET" ]; then
  echo "!! Nothing to notarize at: $TARGET" >&2
  echo "   Build it first:  bash app/build.sh" >&2
  exit 1
fi

# Fail early and legibly if credentials were never stored, rather than
# after a multi-minute upload.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
!! No notarytool credentials found for profile "$PROFILE".

   Store them once with:

     xcrun notarytool store-credentials "$PROFILE" \\
         --apple-id <your-apple-id-email> \\
         --team-id 6GFLLR9599 \\
         --password <app-specific-password>

   (app-specific password from appleid.apple.com → Sign-In and Security)
EOF
  exit 1
fi

echo "==> Preflight: signature must be Developer ID + hardened runtime"
if ! codesign -dv --verbose=4 "$TARGET" 2>&1 | grep -q 'Developer ID Application'; then
  echo "!! $TARGET is not signed with a Developer ID identity." >&2
  echo "   Apple will reject it. Rebuild with the cert in your keychain." >&2
  exit 1
fi
if [ "$IS_DMG" -eq 0 ]; then
  if ! codesign -dv --verbose=4 "$TARGET" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "!! Hardened runtime flag missing — Apple requires it." >&2
    exit 1
  fi
fi

if [ "$IS_DMG" -eq 1 ]; then
  UPLOAD="$TARGET"
  CLEANUP=""
else
  # notarytool takes .zip/.dmg/.pkg — never a bare .app. ditto preserves the
  # bundle's symlinks and extended attributes; `zip` would corrupt them.
  UPLOAD="$ROOT/build/notarize-upload.zip"
  rm -f "$UPLOAD"
  echo "==> Zipping bundle for upload (this is ~400 MB compressed)"
  ditto -c -k --keepParent "$TARGET" "$UPLOAD"
  CLEANUP="$UPLOAD"
fi

echo "==> Submitting to Apple (this usually takes 2–15 minutes)"
set +e
SUBMIT_OUT="$(xcrun notarytool submit "$UPLOAD" \
    --keychain-profile "$PROFILE" --wait --timeout 45m 2>&1)"
SUBMIT_RC=$?
set -e
echo "$SUBMIT_OUT"

SUBMISSION_ID="$(printf '%s\n' "$SUBMIT_OUT" \
  | grep -oE '\bid: [0-9a-f-]{36}' | head -1 | awk '{print $2}')"

if [ $SUBMIT_RC -ne 0 ] || ! printf '%s\n' "$SUBMIT_OUT" | grep -q 'status: Accepted'; then
  echo ""
  echo "!! Notarization did not succeed." >&2
  if [ -n "$SUBMISSION_ID" ]; then
    echo "==> Fetching the rejection log:" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2 || true
  fi
  [ -n "$CLEANUP" ] && rm -f "$CLEANUP"
  exit 1
fi

[ -n "$CLEANUP" ] && rm -f "$CLEANUP"

echo "==> Stapling the ticket"
xcrun stapler staple "$TARGET"

echo "==> Verifying"
xcrun stapler validate "$TARGET"
spctl -a -t "$([ "$IS_DMG" -eq 1 ] && echo open --context context:primary-signature || echo exec)" \
      -vv "$TARGET" 2>&1 | tail -3 || true

echo ""
echo "✓ Notarized and stapled: $TARGET"
