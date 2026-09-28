#!/bin/bash
# Builds a firmware release.
#
#   tools/release.sh 3.0.0
#
# Checks that PROJECT_VER in CMakeLists.txt is the version given, builds, and writes to dist/:
#   espdeck-firmware-VERSION.bin          the OTA app image (what ESPDeck Bridge sends)
#   espdeck-firmware-VERSION-merged.bin   bootloader + partition table + otadata + app, for
#                                         flashing at 0x0 over USB (the web installer uses it)
#   *.sha256                              "<hash>  <file>", as shasum writes them
# It then copies the merged image into ../web/firmware/ and points ../web/manifest.json at it.
# It doesn't sign them: tools/sign_release.sh does, with the key in FIRMWARE_SIGNING_KEY
# (the release workflow runs it next). ESPDeck Bridge won't install an unsigned release.
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: tools/release.sh X.Y.Z" >&2
	exit 1
fi

DEVICE="$( cd "$( dirname "$0" )/.." && pwd )"
ROOT="$( cd "$DEVICE/.." && pwd )"
WEB="$ROOT/web"
DIST="$DEVICE/dist"
CORE_DIR="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
PIO="$( command -v pio || echo "$CORE_DIR/penv/bin/pio" )"
ENVIRONMENT="espdeck"
CHIP="esp32s3"

cd "$DEVICE"

# MARK: Version

PROJECT_VER="$( sed -n 's/^set(PROJECT_VER "\(.*\)")$/\1/p' CMakeLists.txt )"
if [ "$PROJECT_VER" != "$VERSION" ]; then
	echo "PROJECT_VER in CMakeLists.txt is \"$PROJECT_VER\", not \"$VERSION\"." >&2
	exit 1
fi

# MARK: Build

export SSL_CERT_FILE="${SSL_CERT_FILE:-$( "$CORE_DIR/penv/bin/python" -c 'import certifi; print(certifi.where())' 2>/dev/null || true )}"
[ -n "$SSL_CERT_FILE" ] || unset SSL_CERT_FILE
"$PIO" run -e "$ENVIRONMENT"

# The Python that PlatformIO set up, which has esptool's dependencies.
PYTHON="$CORE_DIR/penv/bin/python"
[ -x "$PYTHON" ] || PYTHON="python3"
ESPTOOL_PACKAGE="$CORE_DIR/packages/tool-esptoolpy"

# Flash layout straight from the build: the extra images (bootloader, partition table,
# otadata) with their offsets, and the app's offset.
METADATA="$( mktemp )"
trap 'rm -f "$METADATA"' EXIT
"$PIO" project metadata -e "$ENVIRONMENT" --json-output > "$METADATA"
read -r APP_OFFSET BUILD_DIR IMAGES < <( "$PYTHON" - "$METADATA" "$ENVIRONMENT" <<'EOF'
import json, os, sys
data  = json.load( open( sys.argv[1] ) )[sys.argv[2]]
extra = data["extra"]
parts = " ".join( f"{image['offset']} {image['path']}" for image in extra["flash_images"] )
print( extra["application_offset"], os.path.dirname( data["prog_path"] ), parts )
EOF
)
APP="$BUILD_DIR/firmware.bin"

# The app description in the image must carry the same version.
"$PYTHON" - "$APP" "$VERSION" <<'EOF'
import struct, sys
data = open( sys.argv[1], "rb" ).read()
# 24-byte image header, 8-byte segment header, then esp_app_desc_t: magic, secure version,
# two reserved words, version[32].
magic, = struct.unpack_from( "<I", data, 32 )
version = data[48:80].split( b"\0" )[0].decode()
if magic != 0xABCD5432 or version != sys.argv[2]:
	sys.exit( f"firmware.bin reports version {version!r} (magic {magic:#x}), expected {sys.argv[2]}" )
EOF

# MARK: Images

mkdir -p "$DIST"
OTA_NAME="espdeck-firmware-$VERSION.bin"
MERGED_NAME="espdeck-firmware-$VERSION-merged.bin"
cp "$APP" "$DIST/$OTA_NAME"
# shellcheck disable=SC2086  # IMAGES is "offset path" pairs; build paths have no spaces
PYTHONPATH="$ESPTOOL_PACKAGE" "$PYTHON" -m esptool --chip "$CHIP" merge-bin -o "$DIST/$MERGED_NAME" \
	--flash-mode keep --flash-freq keep --flash-size keep \
	$IMAGES "$APP_OFFSET" "$APP"

sha256() {
	if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}
( cd "$DIST" && sha256 "$OTA_NAME" > "$OTA_NAME.sha256" && sha256 "$MERGED_NAME" > "$MERGED_NAME.sha256" )

# MARK: Web installer

mkdir -p "$WEB/firmware"
find "$WEB/firmware" -name 'espdeck-firmware-*-merged.bin' ! -name "$MERGED_NAME" -delete
cp "$DIST/$MERGED_NAME" "$WEB/firmware/$MERGED_NAME"
cat > "$WEB/manifest.json" <<EOF
{
  "name": "ESPDeck",
  "version": "$VERSION",
  "new_install_prompt_erase": true,
  "new_install_improv_wait_time": 15,
  "builds": [
    {
      "chipFamily": "ESP32-S3",
      "parts": [
        { "path": "firmware/$MERGED_NAME", "offset": 0 }
      ]
    }
  ]
}
EOF

echo
echo "Release $VERSION:"
( cd "$DIST" && cat "$OTA_NAME.sha256" "$MERGED_NAME.sha256" )
echo "Web installer now points at web/firmware/$MERGED_NAME."

echo
echo "To publish, push the tag firmware-v$VERSION: the release workflow builds, signs and uploads."

