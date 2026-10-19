#!/usr/bin/env bash
# Tests, builds a universal Hop.app, signs it and packages build/Hop-<version>.dmg.
#
#   ./build.sh                                  ad-hoc signed (personal use)
#   SIGN_ID="Developer ID Application: …" ./build.sh
#   SIGN_ID=… NOTARY_PROFILE=hop ./build.sh     also notarize + staple the DMG
#   VERSION=1.1.0 ./build.sh
set -euo pipefail

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/Hop.app"
DMG="$OUT/Hop-$VERSION.dmg"
STAGE="$OUT/dmg-stage"
ARCHS=(--arch arm64 --arch x86_64)

cd "$ROOT"
mkdir -p "$OUT"

echo "==> Running tests"
swift test

echo "==> Building universal release binary"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Hop"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "==> Rendering app icon"
  rm -rf "$OUT/AppIcon.iconset"
  swift scripts/make-icon.swift "$OUT/AppIcon.iconset"
  iconutil -c icns "$OUT/AppIcon.iconset" -o Resources/AppIcon.icns
fi

echo "==> Assembling Hop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hop"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
if [[ -n "${SIGN_ID:-}" ]]; then
  TIMESTAMP=()
  [[ -n "${NOTARY_PROFILE:-}" ]] && TIMESTAMP=(--timestamp)
  codesign --force --options runtime "${TIMESTAMP[@]+"${TIMESTAMP[@]}"}" --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Creating DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Hop" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --sign "$SIGN_ID" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

hdiutil verify "$DMG" >/dev/null
echo
echo "Built $(lipo -archs "$APP/Contents/MacOS/Hop") Hop $VERSION ($BUILD_NUMBER)"
echo "DMG: $DMG"
