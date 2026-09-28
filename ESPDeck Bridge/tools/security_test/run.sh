#!/bin/bash
# Tests ESPDeck Bridge's release signature check (Updates/FirmwareSignature.swift) and the
# bridge export file (Security/BridgeTransfer.swift), compiled on their own with
# security_test.swift.
#
# Firmware signatures: signs a test file with a throwaway Ed25519 key, using the release
# workflow's own tools/sign_release.sh (the same openssl invocation), then checks it with the
# app's code; checks that sign_release.sh refuses a key that isn't the release key; and that
# the app's embedded public key is the one in firmware_signing_public_key.pem.
#
# Needs OpenSSL 3 (Homebrew's, or set OPENSSL).
set -euo pipefail
cd "$( dirname "$0" )"
APP="../../ESPDeck Bridge"
DEVICE_TOOLS="../../../ESPDeck Device/tools"
export OPENSSL="${OPENSSL:-$( command -v /opt/homebrew/bin/openssl || command -v openssl )}"
WORK="$( mktemp -d )"
trap 'rm -rf "$WORK"' EXIT

# MARK: Signing with a throwaway key

"$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/throwaway.pem"
"$OPENSSL" pkey -in "$WORK/throwaway.pem" -pubout -out "$WORK/throwaway.pub.pem"
"$OPENSSL" pkey -pubin -in "$WORK/throwaway.pub.pem" -outform DER | tail -c 32 > "$WORK/throwaway.raw"
"$OPENSSL" pkey -pubin -in "$DEVICE_TOOLS/firmware_signing_public_key.pem" -outform DER | tail -c 32 > "$WORK/release.raw"
head -c 1500000 /dev/urandom > "$WORK/espdeck-firmware-9.9.9.bin"

FIRMWARE_SIGNING_KEY="$( cat "$WORK/throwaway.pem" )" FIRMWARE_SIGNING_PUBLIC_KEY="$WORK/throwaway.pub.pem" \
	"$DEVICE_TOOLS/sign_release.sh" "$WORK/espdeck-firmware-9.9.9.bin"

# The workflow checks the secret against the release public key: a throwaway key must fail.
if FIRMWARE_SIGNING_KEY="$( cat "$WORK/throwaway.pem" )" "$DEVICE_TOOLS/sign_release.sh" "$WORK/espdeck-firmware-9.9.9.bin" 2> /dev/null; then
	echo "FAIL: sign_release.sh accepted a key that isn't the release key" >&2
	exit 1
fi
echo "ok sign_release.sh refuses a key that isn't the release key"
if env -u FIRMWARE_SIGNING_KEY "$DEVICE_TOOLS/sign_release.sh" "$WORK/espdeck-firmware-9.9.9.bin" 2> /dev/null; then
	echo "FAIL: sign_release.sh ran without FIRMWARE_SIGNING_KEY" >&2
	exit 1
fi
echo "ok sign_release.sh fails without FIRMWARE_SIGNING_KEY"

# MARK: The app's code

# Top-level code has to be in main.swift when several files are compiled together.
cp security_test.swift "$WORK/main.swift"
swiftc -O -o "$WORK/security_test" "$WORK/main.swift" "$APP/Updates/FirmwareSignature.swift" "$APP/Security/BridgeTransfer.swift"
"$WORK/security_test" "$WORK/espdeck-firmware-9.9.9.bin" "$WORK/espdeck-firmware-9.9.9.bin.sig" "$WORK/throwaway.raw" "$WORK/release.raw"
