#!/bin/bash
# Signs release files with the firmware signing key.
#
#   FIRMWARE_SIGNING_KEY="$( cat key.pem )" tools/sign_release.sh dist/espdeck-firmware-X.Y.Z.bin ...
#
# FIRMWARE_SIGNING_KEY holds the Ed25519 private key as PEM (from `openssl genpkey -algorithm
# ed25519`); on GitHub it's the repository secret of the same name. For each file, writes
# <file>.sig next to it: the raw 64-byte Ed25519 signature over the file's exact bytes, which
# ESPDeck Bridge checks before installing a release. Each signature is checked against
# tools/firmware_signing_public_key.pem (the key the app has) before this succeeds, so a wrong
# or rotated key fails here rather than in the app. Ed25519 signatures are deterministic, so
# signing the same file again gives the same .sig.
#
# Needs OpenSSL 3 (LibreSSL, macOS's /usr/bin/openssl, can't sign raw Ed25519); set OPENSSL
# to use a particular one. FIRMWARE_SIGNING_PUBLIC_KEY names a different public key file
# (for tests).
set -euo pipefail

if [ $# -eq 0 ]; then
	echo "usage: FIRMWARE_SIGNING_KEY=... tools/sign_release.sh FILE..." >&2
	exit 1
fi
if [ -z "${FIRMWARE_SIGNING_KEY:-}" ]; then
	echo "FIRMWARE_SIGNING_KEY isn't set. On GitHub, add the private key (PEM) as the repository secret FIRMWARE_SIGNING_KEY." >&2
	exit 1
fi

TOOLS="$( cd "$( dirname "$0" )" && pwd )"
PUBLIC="${FIRMWARE_SIGNING_PUBLIC_KEY:-$TOOLS/firmware_signing_public_key.pem}"
OPENSSL="${OPENSSL:-openssl}"
SIGNATURE_SIZE=64

if [[ "$( "$OPENSSL" version )" != OpenSSL\ 3* ]]; then
	echo "Signing needs OpenSSL 3; $OPENSSL is $( "$OPENSSL" version ). Set OPENSSL to one (Homebrew's: /opt/homebrew/bin/openssl)." >&2
	exit 1
fi

# The key only ever touches a private temporary folder, removed however this ends.
WORK="$( umask 077 && mktemp -d )"
trap 'rm -rf "$WORK"' EXIT
KEY="$WORK/key.pem"
( umask 077 && printf '%s\n' "$FIRMWARE_SIGNING_KEY" > "$KEY" )

if ! "$OPENSSL" pkey -in "$KEY" -pubout -outform DER -out "$WORK/public.der" 2> /dev/null; then
	echo "FIRMWARE_SIGNING_KEY isn't a private key in PEM format." >&2
	exit 1
fi
"$OPENSSL" pkey -pubin -in "$PUBLIC" -outform DER -out "$WORK/expected.der"
if ! cmp -s "$WORK/public.der" "$WORK/expected.der"; then
	echo "FIRMWARE_SIGNING_KEY doesn't match $( basename "$PUBLIC" ), the public key ESPDeck Bridge checks with." >&2
	exit 1
fi

for FILE in "$@"; do
	"$OPENSSL" pkeyutl -sign -rawin -inkey "$KEY" -in "$FILE" -out "$FILE.sig"
	SIZE="$( wc -c < "$FILE.sig" | tr -d ' ' )"
	if [ "$SIZE" != "$SIGNATURE_SIZE" ]; then
		echo "$FILE.sig has $SIZE bytes, not $SIGNATURE_SIZE: the key isn't an Ed25519 key." >&2
		exit 1
	fi
	"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$PUBLIC" -in "$FILE" -sigfile "$FILE.sig" > /dev/null
	echo "Signed $( basename "$FILE" )"
done
