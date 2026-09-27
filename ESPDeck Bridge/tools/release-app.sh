#!/bin/zsh
# Builds a notarized, Developer ID–signed ESPDeck Bridge release.
#
#   tools/release-app.sh 1.1.0
#
# One-time setup: store notarization credentials in the keychain under the profile name
# "ESPDeck" (an app-specific password from appleid.apple.com):
#
#   xcrun notarytool store-credentials ESPDeck --apple-id you@example.com --team-id TEAMID
#
# Output in dist/: ESPDeck-Bridge-VERSION.zip and its .sha256. Publish both on a GitHub
# release tagged bridge-vVERSION; the app's update check looks for exactly that.

set -euo pipefail

VERSION=${1:?usage: tools/release-app.sh VERSION}
PROFILE=${NOTARY_PROFILE:-ESPDeck}
ROOT=${0:A:h:h}
cd "$ROOT"

SCHEME="ESPDeck Bridge"
DESTINATION="generic/platform=macOS,variant=Mac Catalyst"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
ARCHIVE="$BUILD/ESPDeck-Bridge.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/ESPDeck Bridge.app"
ZIP="$DIST/ESPDeck-Bridge-$VERSION.zip"

# The version in the project must match the tag.
PROJECT_VERSION=$( xcodebuild -project "ESPDeck Bridge.xcodeproj" -scheme "$SCHEME" -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
	| awk -F' = ' '/^ *MARKETING_VERSION = / { print $2; exit }' )
if [[ "$PROJECT_VERSION" != "$VERSION" ]]; then
	echo "MARKETING_VERSION is $PROJECT_VERSION, not $VERSION. Update it in the project first." >&2
	exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

echo "==> Archiving"
xcodebuild -project "ESPDeck Bridge.xcodeproj" -scheme "$SCHEME" -destination "$DESTINATION" \
	-configuration Release -archivePath "$ARCHIVE" archive -quiet

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
	-exportOptionsPlist tools/ExportOptions.plist -allowProvisioningUpdates -quiet

echo "==> Notarizing"
ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

echo "==> Packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
( cd "$DIST" && shasum -a 256 "${ZIP:t}" | awk '{ print $1 }' > "${ZIP:t}.sha256" )

echo
echo "Built $ZIP"
echo "Publish it with:"
echo "  gh release create bridge-v$VERSION \"$ZIP\" \"$ZIP.sha256\" --title \"ESPDeck Bridge $VERSION\" --notes-file NOTES.md"
