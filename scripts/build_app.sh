#!/bin/sh
# Builds dist/Chipless Reader.app and dist/Chipless-Reader.dmg from the sources.
# Needs Xcode or the Xcode Command Line Tools. Run it again after changing the app or the firmware core.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Chipless Reader.app"
PKG="$ROOT/sdk/AltraReaderKit"

echo "== Building the app"
if ! swift build --package-path "$PKG" -c release --product ChiplessReaderApp --arch arm64 --arch x86_64; then
    echo "Universal build not available here, building for this Mac only"
    swift build --package-path "$PKG" -c release --product ChiplessReaderApp
fi
BIN="$(swift build --package-path "$PKG" -c release --product ChiplessReaderApp --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null || true)"
[ -x "$BIN/ChiplessReaderApp" ] || BIN="$(swift build --package-path "$PKG" -c release --product ChiplessReaderApp --show-bin-path)"

echo "== Building the demo reader (the firmware core compiled for the Mac)"
HELPER_DIR="$ROOT/firmware/host/build"
mkdir -p "$HELPER_DIR"
cc -O2 -std=c11 -Wall -DRF_BACKEND_SIM -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -I"$ROOT/firmware/core" \
    -o "$HELPER_DIR/chipless-vreader-universal" "$ROOT/firmware/host/main_host.c" "$ROOT"/firmware/core/*.c -lm

echo "== Assembling the app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ChiplessReaderApp" "$APP/Contents/MacOS/ChiplessReaderApp"
cp "$HELPER_DIR/chipless-vreader-universal" "$APP/Contents/MacOS/chipless-vreader"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP/Contents/MacOS/chipless-vreader"
codesign --force --sign - "$APP"

echo "== Making the disk image"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$ROOT/dist/Chipless-Reader.dmg"
hdiutil create -quiet -volname "Chipless Reader" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/Chipless-Reader.dmg"
rm -rf "$STAGE"

echo "Done: $APP"
echo "      $ROOT/dist/Chipless-Reader.dmg"
