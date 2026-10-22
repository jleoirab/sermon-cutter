#!/bin/bash
# Builds the engine and the Mac app, and installs "Sermon Cutter.app" in
# ~/Applications. Run from anywhere: app/build.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Sermon Cutter"
OUT="$ROOT/build/$APP_NAME.app"
FULL="$ROOT/.build-full.txt"
: > "$FULL"

echo "== toolchain"
sw_vers -productVersion
swift --version 2>&1 | head -1
xcode-select -p 2>&1

echo "== engine"
(cd "$ROOT" && cargo build --release >> "$FULL" 2>&1) || { echo "engine build failed:"; grep -E "^error" -A6 "$FULL" | head -60; exit 1; }
echo "ok"

echo "== app"
if ! (cd "$ROOT/app" && swift build -c release >> "$FULL" 2>&1); then
  echo "app build failed:"
  grep -E "error:" -A3 "$FULL" | head -150
  exit 1
fi
grep -E "warning:" "$FULL" | grep -v "^ld: warning" | sort -u | head -30
echo "ok"

echo "== bundle"
BIN="$(cd "$ROOT/app" && swift build -c release --show-bin-path)/SermonCutter"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
cp "$ROOT/target/release/sermoncut" "$OUT/Contents/Resources/sermoncut"
VERSION="$(cd "$ROOT" && git describe --tags --always 2>/dev/null || echo dev)"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>org.ccikw.sermoncutter</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>Sermon Cutter saves each sermon in your Service folder and reads banners from it.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$OUT" >> "$FULL" 2>&1 || echo "(ad-hoc signing failed; the app still runs from this Mac)"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP_NAME.app"
cp -R "$OUT" "$HOME/Applications/"
echo "installed: ~/Applications/$APP_NAME.app"

if [ "${RUN_TESTS:-0}" = "1" ]; then
  echo "== tests"
  (cd "$ROOT/app" && swift test 2>&1 | tail -25)
fi
