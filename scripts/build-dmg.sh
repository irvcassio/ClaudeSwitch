#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeSwitch"
BUNDLE_ID="${BUNDLE_ID:-com.irvcassio.ClaudeSwitch}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

cd "$(dirname "$0")/.."

BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
ARCHIVE_DIR="${BUILD_DIR}/release"
BINARY_PATH=".build/release/${APP_NAME}"
VERSION="1.0.0"
DMG_PATH="${ARCHIVE_DIR}/${APP_NAME}-${VERSION}-arm64.dmg"

echo "=== Building ${APP_NAME} ${VERSION} ==="

echo "1. Tests..."
swift test 2>&1 | tail -3

echo "2. Release binary..."
swift build -c release --arch arm64
[[ -f "$BINARY_PATH" ]] || { echo "Error: no binary at ${BINARY_PATH}" >&2; exit 1; }

echo "3. App bundle..."
rm -rf "$APP_BUNDLE" "$ARCHIVE_DIR"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources" "$ARCHIVE_DIR"
cp "$BINARY_PATH" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# LSUIElement keeps it out of the Dock and the app switcher — it lives in the menu bar only.
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

if [[ -f "Resources/AppIcon.png" ]]; then
  echo "   Icon..."
  ICON_TMP=$(mktemp -d); ICONSET="${ICON_TMP}/AppIcon.iconset"; mkdir -p "$ICONSET"
  for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
              "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "Resources/AppIcon.png" --out "${ICONSET}/icon_$2.png" > /dev/null
  done
  iconutil -c icns "$ICONSET" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  rm -rf "$ICON_TMP"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "4. Signing with ${SIGN_IDENTITY}..."
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
else
  echo "4. Ad-hoc signing (unsigned build)."
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "5. DMG..."
rm -f "$DMG_PATH"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 --window-size 660 400 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 160 185 \
  --app-drop-link 500 185 \
  --hide-extension "${APP_NAME}.app" \
  --no-internet-enable \
  "$DMG_PATH" "$APP_BUNDLE" >/dev/null

echo ""
echo "=== Done ==="
echo "App: ${APP_BUNDLE}"
echo "DMG: ${DMG_PATH}"
echo "SHA256: $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
