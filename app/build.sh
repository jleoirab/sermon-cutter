#!/bin/bash
# Builds the engine and the Mac app, and installs "Sermon Cutter.app" in
# ~/Applications. Run from anywhere: app/build.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Sermon Cutter"
OUT="$ROOT/build/$APP_NAME.app"
FULL="$ROOT/.build-full.txt"
: > "$FULL"

# A diagnostic request: sample the running app instead of building.
if [ -e "$ROOT/.build-diagnose" ]; then
  rm -f "$ROOT/.build-diagnose"
  PID="$(pgrep -x "$APP_NAME" | head -1)"
  echo "== sampling $APP_NAME (pid ${PID:-none})"
  if [ -n "$PID" ]; then
    sample "$PID" 3 -file "$ROOT/.sample.txt" >/dev/null 2>&1
    ps -o pid,pcpu,rss,etime,stat -p "$PID"
    grep -A60 "Call graph" "$ROOT/.sample.txt" | head -80
  fi
  exit 0
fi

echo "== toolchain"
sw_vers -productVersion
swift --version 2>&1 | head -1
xcode-select -p 2>&1

echo "== engine"
(cd "$ROOT" && cargo build --release >> "$FULL" 2>&1) || { echo "engine build failed:"; grep -E "^error" -A6 "$FULL" | head -60; exit 1; }
echo "ok"

# A timing request: time the export's ffmpeg command instead of building the app.
if [ -e "$ROOT/.bench" ]; then
  rm -f "$ROOT/.bench"
  bash "$ROOT/app/bench.sh"
  exit $?
fi

echo "== app"
if ! (cd "$ROOT/app" && swift build -c release >> "$FULL" 2>&1); then
  echo "app build failed:"
  grep -E "error:" -A3 "$FULL" | grep -v "xcrun: error: unable to lookup item" | head -150
  exit 1
fi
grep -E "warning:" "$FULL" | grep -v "^ld: warning" | sort -u | head -40
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
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>Sermon Cutter saves each sermon in your Service folder and reads banners from it.</string>
</dict>
</plist>
PLIST
# Sign with a stable identity when there is one, so macOS remembers the
# app's permissions (Documents folder) from one build to the next.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Sermon Cutter Dev"' | head -1 | tr -d '"')"
codesign --force --deep --sign "${IDENTITY:--}" "$OUT" >> "$FULL" 2>&1 || echo "(signing failed; the app still runs from this Mac)"
echo "signed: ${IDENTITY:-ad hoc}"

# Quit the running copy so the new one opens next.
if pgrep -x "$APP_NAME" >/dev/null; then
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1
  sleep 2
  pkill -x "$APP_NAME" 2>/dev/null
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP_NAME.app"
cp -R "$OUT" "$HOME/Applications/"
echo "installed: ~/Applications/$APP_NAME.app"

if [ "${RUN_TESTS:-0}" = "1" ]; then
  echo "== tests"
  (cd "$ROOT/app" && swift test 2>&1 | tail -25)
fi
