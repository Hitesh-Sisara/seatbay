#!/bin/bash
# Builds Seatbay.app into ./build.
#
#   scripts/build.sh               build for this Mac
#   scripts/build.sh --universal   one app for Apple silicon and Intel (what releases use)
#   scripts/build.sh --zip         also write build/Seatbay.zip and build/Seatbay.zip.sha256
#   scripts/build.sh --install     also copy the app to ~/Applications
#
# The version comes from ./VERSION (or $SEATBAY_VERSION); the build number from the git history.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=0; ZIP=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --zip) ZIP=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="${SEATBAY_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${SEATBAY_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCH=()
[[ $UNIVERSAL == 1 ]] && ARCH=(--arch arm64 --arch x86_64)

swift build -c release ${ARCH[@]+"${ARCH[@]}"} --product seatbay-launcher
swift build -c release ${ARCH[@]+"${ARCH[@]}"} --product Seatbay
BIN="$(swift build -c release ${ARCH[@]+"${ARCH[@]}"} --show-bin-path)"

APP="build/Seatbay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Seatbay" "$APP/Contents/MacOS/Seatbay"
cp "$BIN/seatbay-launcher" "$APP/Contents/Resources/seatbay-launcher"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Seatbay</string>
  <key>CFBundleIdentifier</key><string>in.sisara.seatbay</string>
  <key>CFBundleName</key><string>Seatbay</string>
  <key>CFBundleDisplayName</key><string>Seatbay</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License. Not affiliated with Anthropic.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Seatbay passes a sign-in link to the Claude instance you are signing in to.</string>
  <!-- Only used while a sign-in relay is active; claude:// is handed back to Claude afterwards. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Claude sign-in relay</string>
      <key>CFBundleURLSchemes</key><array><string>claude</string></array>
      <key>LSHandlerRank</key><string>None</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

"$APP/Contents/MacOS/Seatbay" --render-app-icon "$APP/Contents/Resources/AppIcon.icns" assets/seatbay-icon.svg
# Ad-hoc signatures: the app isn't notarized (see README, "First open").
codesign --force --sign - "$APP/Contents/Resources/seatbay-launcher"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP $VERSION ($BUILD_NUMBER)$([[ $UNIVERSAL == 1 ]] && echo ', universal')"

if [[ $ZIP == 1 ]]; then
  rm -f build/Seatbay.zip build/Seatbay.zip.sha256
  ditto -c -k --sequesterRsrc --keepParent "$APP" build/Seatbay.zip
  (cd build && shasum -a 256 Seatbay.zip > Seatbay.zip.sha256)
  echo "Wrote build/Seatbay.zip ($(du -h build/Seatbay.zip | cut -f1)) and its SHA-256"
fi

if [[ $INSTALL == 1 ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Seatbay.app"
  cp -R "$APP" "$HOME/Applications/Seatbay.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Seatbay.app" || true
  echo "Installed to ~/Applications/Seatbay.app"
fi
