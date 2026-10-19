#!/usr/bin/env bash
# Tests, builds a universal Hop.app, signs it and packages build/Hop-<version>.dmg
# (manual installs) and build/Hop-<version>.zip (in-app updates).
#
#   ./build.sh                                  signs with the identity scripts/signing-identity.sh
#                                               picks (Apple Development preferred), else ad-hoc
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
ZIP="$OUT/Hop-$VERSION.zip"
STAGE="$OUT/dmg-stage"
ARCHS=(--arch arm64 --arch x86_64)

cd "$ROOT"
mkdir -p "$OUT"

SIGN_ID="$(scripts/signing-identity.sh)"
SIGN_NAME="ad-hoc"
if [[ -n "$SIGN_ID" ]]; then
  SIGN_NAME="$(security find-identity -v -p codesigning | grep -F "$SIGN_ID" | sed -E 's/.*"(.*)".*/\1/' | head -1)"
  SIGN_NAME="${SIGN_NAME:-$SIGN_ID}"
fi

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

echo "==> Signing ($SIGN_NAME)"
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

echo "==> Creating update archive"
# In-app updates download this zip; the DMG is for manual installs.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/Hop")"

# Keep only the DMG so Spotlight and Launch Services don't offer a second copy of Hop.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"

echo
echo "Built $ARCHS_BUILT Hop $VERSION ($BUILD_NUMBER), signed $SIGN_NAME"
echo "DMG: $DMG"
echo "ZIP: $ZIP"
