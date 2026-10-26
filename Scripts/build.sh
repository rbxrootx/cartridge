#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Cartridge.app into ./build.
#   Scripts/build.sh            build
#   Scripts/build.sh install    build and copy to /Applications
#   Scripts/build.sh zip        build and create build/Cartridge.zip for distribution
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product Cartridge $ARCHS
BIN="$(swift build -c release --product Cartridge $ARCHS --show-bin-path)/Cartridge"

APP=build/Cartridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cartridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[[ -n "${VERSION:-}" ]] && plutil -replace CFBundleShortVersionString -string "${VERSION#v}" "$APP/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:--}"
[[ "$IDENTITY" == "-" ]] && TIMESTAMP=--timestamp=none || TIMESTAMP=--timestamp
codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Cartridge"))"

case "${1:-}" in
  install)
    rm -rf /Applications/Cartridge.app && cp -R "$APP" /Applications/Cartridge.app && echo "Installed to /Applications/Cartridge.app" ;;
  zip)
    rm -f build/Cartridge.zip
    ditto -c -k --sequesterRsrc --keepParent "$APP" build/Cartridge.zip && echo "Created build/Cartridge.zip" ;;
esac
