#!/bin/bash
# Builds the engine and the Mac app, and installs "CCI Sermon Cutter.app" in
# ~/Applications. Run from anywhere: app/build.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CCI Sermon Cutter"
# What the app was called before; an old copy is quit and moved to the Trash.
OLD_NAME="Sermon Cutter"
OUT="$ROOT/build/$APP_NAME.app"
FULL="$ROOT/.build-full.txt"
: > "$FULL"

# A diagnostic request: sample the running app instead of building.
if [ -e "$ROOT/.build-diagnose" ]; then
  rm -f "$ROOT/.build-diagnose"
  # Match on the path: macOS keeps only 16 characters of a process name.
  PID="$(pgrep -f "$APP_NAME.app/Contents/MacOS/" | head -1)"
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
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Helpers" "$OUT/Contents/Resources/Fonts"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
# The engine sits with the helpers it runs.
cp "$ROOT/target/release/sermoncut" "$OUT/Contents/Helpers/sermoncut"
cp "$ROOT/app/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
cp "$ROOT"/app/Resources/Fonts/* "$OUT/Contents/Resources/Fonts/"
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
  <key>CFBundleShortVersionString</key><string>0.6</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSDocumentsFolderUsageDescription</key><string>CCI Sermon Cutter saves each sermon in your Service folder and reads banners from it.</string>
</dict>
</plist>
PLIST
echo "== helpers"
# ffmpeg, ffprobe, whisper-cli, deno, yt-dlp and the speech model, inside the app.
bash "$ROOT/app/tools.sh" "$OUT" || { echo "the helpers couldn't be put in the app"; exit 1; }

# Sign with a stable identity when there is one, so macOS remembers the
# app's permissions (Documents folder) from one build to the next.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Sermon Cutter Dev"' | head -1 | tr -d '"')"
codesign --force --deep --sign "${IDENTITY:--}" "$OUT" >> "$FULL" 2>&1 || echo "(signing failed; the app still runs from this Mac)"
echo "signed: ${IDENTITY:-ad hoc}"

# Each helper still runs once signed, and the engine finds every one of them
# inside the app with nothing else on the PATH (no Homebrew).
echo "== check"
H="$OUT/Contents/Helpers"
"$H/ffmpeg" -hide_banner -version | head -1
echo "yt-dlp $("$H/yt-dlp" --version)"
"$H/deno" --version | head -1
# whisper-cli loads the speech model and listens to two seconds of silence.
SILENCE="$ROOT/build/silence.wav"
"$H/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 2 -c:a pcm_s16le "$SILENCE"
if "$H/whisper-cli" -m "$OUT/Contents/Resources/models/ggml-small.en-q8_0.bin" -f "$SILENCE" -np -nt >/dev/null 2>"$ROOT/build/whisper-check.log"; then
  echo "whisper-cli runs with the speech model"
else
  echo "whisper-cli can't use the speech model:"; tail -5 "$ROOT/build/whisper-check.log"; exit 1
fi
FOUND="$(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$H/sermoncut" tools --tools-dir "$ROOT/build/no-tools")"
if echo "$FOUND" | grep -q null; then echo "the engine can't find every helper: $FOUND"; exit 1; fi
echo "the engine finds every helper inside the app"
echo "app size: $(du -sh "$OUT" | cut -f1)"

# Quit the running copy (under either name) so the new one opens next.
for NAME in "$APP_NAME" "$OLD_NAME"; do
  if pgrep -f "$NAME.app/Contents/MacOS/" >/dev/null; then
    osascript -e "quit app \"$NAME\"" >/dev/null 2>&1
    sleep 2
    pkill -f "$NAME.app/Contents/MacOS/" 2>/dev/null
  fi
done
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP_NAME.app"
cp -cR "$OUT" "$HOME/Applications/" 2>/dev/null || cp -R "$OUT" "$HOME/Applications/"
echo "installed: ~/Applications/$APP_NAME.app"
# The copy built under the old name goes to the Trash, so there's one app.
if [ -d "$HOME/Applications/$OLD_NAME.app" ]; then
  mv "$HOME/Applications/$OLD_NAME.app" "$HOME/.Trash/$OLD_NAME $(date +%H%M%S).app" && echo "moved the old $OLD_NAME.app to the Trash"
fi

if [ "${RUN_TESTS:-0}" = "1" ]; then
  echo "== tests"
  (cd "$ROOT/app" && swift test 2>&1 | tail -25)
fi
