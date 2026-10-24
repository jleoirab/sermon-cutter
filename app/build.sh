#!/bin/bash
# Builds the engine and the Mac app, for Apple silicon and Intel Macs, and
# installs "CCI Sermon Cutter.app" in ~/Applications. Run from anywhere:
#   app/build.sh
# A release (app/release.sh, or a file named .release in the repo) also makes
# the installer and latest.json, ready to put on Google Drive.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="${RELEASE:-0}"
if [ -e "$ROOT/.release" ]; then rm -f "$ROOT/.release"; RELEASE=1; fi
source "$ROOT/app/release.conf"
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
# rustup's toolchain when there is one: it can also build for Intel Macs.
if [ -x "$HOME/.cargo/bin/rustup" ]; then export PATH="$HOME/.cargo/bin:$PATH"; fi
(cd "$ROOT" && cargo build --release >> "$FULL" 2>&1) || { echo "engine build failed:"; grep -E "^error" -A6 "$FULL" | head -60; exit 1; }
# And for Intel Macs: with rustup, its standard library for Intel; with
# Homebrew's Rust, the same one kept in the build cache (app/rust-intel.sh).
INTEL_FLAGS=""
if command -v rustup >/dev/null 2>&1; then
  rustup target list --installed | grep -qx x86_64-apple-darwin || rustup target add x86_64-apple-darwin >> "$FULL" 2>&1
else
  SYSROOT="$(bash "$ROOT/app/rust-intel.sh")" || { echo "couldn't get Rust's standard library for Intel Macs"; exit 1; }
  INTEL_FLAGS="--sysroot=$SYSROOT"
fi
(cd "$ROOT" && RUSTFLAGS="$INTEL_FLAGS" cargo build --release --target x86_64-apple-darwin >> "$FULL" 2>&1) ||
  { echo "the engine didn't build for Intel Macs:"; grep -E "^error" -A6 "$FULL" | head -30; exit 1; }
echo "ok"

# A timing request: time the export's ffmpeg command instead of building the app.
if [ -e "$ROOT/.bench" ]; then
  rm -f "$ROOT/.bench"
  bash "$ROOT/app/bench.sh"
  exit $?
fi

echo "== app"
X86="x86_64-apple-macosx14.0"
if ! (cd "$ROOT/app" && swift build -c release >> "$FULL" 2>&1 &&
      swift build -c release --triple "$X86" --product SermonCutter >> "$FULL" 2>&1); then
  echo "app build failed:"
  grep -E "error:" -A3 "$FULL" | grep -v "xcrun: error: unable to lookup item" | head -150
  exit 1
fi
grep -E "warning:" "$FULL" | grep -v "^ld: warning" | sort -u | head -40
echo "ok"

echo "== bundle"
BINS="$(cd "$ROOT/app" && swift build -c release --show-bin-path)"
BIN_X86="$(cd "$ROOT/app" && swift build -c release --triple "$X86" --show-bin-path)/SermonCutter"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Helpers" "$OUT/Contents/Resources/Fonts"
lipo -create "$BINS/SermonCutter" "$BIN_X86" -output "$OUT/Contents/MacOS/$APP_NAME"
# The engine sits with the helpers it runs.
lipo -create "$ROOT/target/release/sermoncut" "$ROOT/target/x86_64-apple-darwin/release/sermoncut" \
  -output "$OUT/Contents/Helpers/sermoncut"
cp "$ROOT/app/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
cp "$ROOT"/app/Resources/Fonts/* "$OUT/Contents/Resources/Fonts/"
# 0.7 as people see it; the build number counts commits, so it only goes up.
SHORT_VERSION="$(tr -d ' \n' < "$ROOT/app/VERSION")"
BUILD_NUMBER="$(cd "$ROOT" && git rev-list --count HEAD)"
# The release key signs each installer; the app checks updates with its
# public half. The private half stays in this Mac's keychain.
REL="$BINS/SermonRelease"
KEY_SERVICE="CCI Sermon Cutter release key"
if ! RELEASE_KEY="$(security find-generic-password -a release -s "$KEY_SERVICE" -w 2>/dev/null)"; then
  RELEASE_KEY="$("$REL" new-key)"
  security add-generic-password -a release -s "$KEY_SERVICE" -w "$RELEASE_KEY" -T /usr/bin/security
  echo "made a new release key, kept in this Mac's keychain as \"$KEY_SERVICE\""
fi
PUBLIC_KEY="$(printf %s "$RELEASE_KEY" | "$REL" public-key)"
MANIFEST_URL="https://drive.usercontent.google.com/download?id=$MANIFEST_ID&amp;export=download&amp;confirm=t"
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
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>SCUpdateManifestURL</key><string>$MANIFEST_URL</string>
  <key>SCUpdatePublicKey</key><string>$PUBLIC_KEY</string>
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

# Sign with a stable identity, so macOS remembers the app's permissions
# (Documents folder) from one version to the next. A release makes the free,
# self-made one ("Sermon Cutter Dev") the first time.
if [ "$RELEASE" = "1" ]; then bash "$ROOT/app/signing-identity.sh" || echo "(couldn't make the signing certificate; signing ad hoc)"; fi
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | grep '"Sermon Cutter Dev"' | head -1 | awk '{print $2}')"
codesign --force --deep --sign "${IDENTITY:--}" "$OUT" >> "$FULL" 2>&1 || echo "(signing failed; the app still runs from this Mac)"
echo "signed: ${IDENTITY:+Sermon Cutter Dev}${IDENTITY:-ad hoc}; version $SHORT_VERSION (build $BUILD_NUMBER)"

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
for f in "$OUT/Contents/MacOS/$APP_NAME" "$H"/*; do
  case " $(lipo -archs "$f" 2>/dev/null) " in
    *" arm64 "*" x86_64 "*|*" x86_64 "*" arm64 "*) ;;
    *) echo "$(basename "$f") isn't built for both Apple silicon and Intel ($(lipo -archs "$f" 2>&1))"; exit 1 ;;
  esac
done
echo "every program is built for Apple silicon and Intel"
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

if [ "$RELEASE" = "1" ]; then
  echo "== release"
  bash "$ROOT/app/package.sh" "$OUT" "$REL" || { echo "the release couldn't be packaged"; exit 1; }
fi

if [ "${RUN_TESTS:-0}" = "1" ]; then
  echo "== tests"
  (cd "$ROOT/app" && swift test 2>&1 | tail -25)
fi
