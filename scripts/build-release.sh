#!/bin/zsh
# Builds a Release version of PluralMac Plus into dist/:
#   dist/PluralMac Plus.app
#   dist/PluralMacPlus-<version>-macOS.zip
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
APP_NAME="PluralMac Plus.app"

# xcode-select may point to the Command Line Tools; xcodebuild needs full Xcode
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcodebuild \
    -project "$ROOT/PluralMac.xcodeproj" \
    -scheme PluralMac \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build

BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist")
ZIP="$DIST/PluralMacPlus-$VERSION-macOS.zip"

rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$BUILT_APP" "$DIST/$APP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$DIST/$APP_NAME" "$ZIP"

echo "App: $DIST/$APP_NAME"
echo "Zip: $ZIP"
