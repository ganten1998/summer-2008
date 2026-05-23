#!/usr/bin/env bash
# Create a self-signed "Summer 2008 Dev" code-signing certificate in the
# user's login keychain. Build.sh detects it automatically and signs the
# .app with it instead of ad-hoc.
#
# Why we need this:
#   ad-hoc signed apps get a new cdhash on every rebuild. macOS Accessibility
#   trust is keyed by cdhash, so every rebuild silently revokes whatever
#   permission you've granted. Self-signed apps keep a stable identity
#   across rebuilds → AX trust persists → projector positioning works
#   without re-granting permission every dev cycle.
#
# Run once:
#     ./tools/setup-codesign-identity.sh
#
# Then any subsequent `bash app/build.sh` picks it up automatically.
# Look for "Using Developer ID Application: …" or "Using …Summer 2008 Dev…"
# in the build output.

set -eu
if [ -n "${BASH_VERSION:-}" ]; then set -o pipefail; fi

CERT_NAME="Summer 2008 Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✓ $CERT_NAME already exists in keychain"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "==> Generating self-signed code-signing certificate '$CERT_NAME'"
TMP="$(mktemp -d -t agd-cs)"
trap 'rm -rf "$TMP"' EXIT

# Private key.
openssl genrsa -out "$TMP/key.pem" 2048

# CSR + self-signed cert with codeSigning extended key usage. Valid 100yr.
openssl req -new -x509 -key "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 36500 \
    -subj "/CN=$CERT_NAME" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature"

# Pack into PKCS12 with the cert + private key. Use the LEGACY ciphers
# (-legacy) because the modern PBE algorithms macOS `security import`
# can't decrypt — verified via "MAC verification failed" errors.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/bundle.p12" \
    -name "$CERT_NAME" \
    -passout "pass:agd-codesign-temp" \
    -legacy

echo "==> Importing into login keychain"
security import "$TMP/bundle.p12" \
    -k "$KEYCHAIN" \
    -P "agd-codesign-temp" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productsign

# Trust the cert for code signing. This is the bit that needs sudo.
echo "==> Marking the cert as trusted for code signing"
echo "    (this needs sudo for /System trust adjustments)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$TMP/cert.pem" 2>/dev/null || \
    security add-trusted-cert -r trustRoot -p codeSign \
        -k "$KEYCHAIN" "$TMP/cert.pem"

# Authorize codesign to use the private key without prompting on each build.
SHA=$(openssl x509 -in "$TMP/cert.pem" -fingerprint -sha1 -noout | \
      sed -E 's/.*=//; s/://g')

# Allow codesign tool to access the private key non-interactively.
echo "==> Configuring keychain partition list for non-interactive use"
echo "    (you'll be prompted for your login password)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$(security default-keychain | xargs -I {} basename {} .keychain-db)" \
    "$KEYCHAIN" 2>/dev/null || \
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    "$KEYCHAIN"

echo ""
echo "Done. Verify:"
echo ""
security find-identity -v -p codesigning | grep -E "$CERT_NAME|Developer ID" || true
echo ""
echo "Now rebuild: bash app/build.sh"
echo "Then go to System Settings → Privacy & Security → Accessibility,"
echo "remove all old 'Summer 2008' entries, run the app, grant AX once."
echo "The cdhash will now be stable across rebuilds so AX trust persists."
