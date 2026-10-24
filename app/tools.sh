#!/bin/bash
# Puts the helper programs and the speech model inside the app:
#   app/tools.sh "build/CCI Sermon Cutter.app"
# fills Contents/Helpers (ffmpeg, ffprobe, whisper-cli, deno, yt-dlp) and
# Contents/Resources/models.
#
# Every piece is pinned: downloads by SHA-256, sources by git commit. Each
# helper runs on both Apple silicon and Intel Macs: ffmpeg and whisper.cpp
# are built here from source once for each, then joined into one universal
# program, using only what comes with macOS (VideoToolbox, Metal,
# Accelerate), so the app needs nothing installed on the Mac it runs on,
# Homebrew included. ffmpeg is built without GPL parts (it encodes with
# VideoToolbox), under the LGPL, and without iconv (only for subtitle text,
# which the app never reads).
#
# Everything is kept in a cache outside the repo, so this is slow only the
# first time (building ffmpeg twice takes several minutes) or after a
# version here changes.
set -euo pipefail

APP="${1:?usage: app/tools.sh <path to .app>}"
CACHE="${SERMONCUT_TOOLS_CACHE:-$HOME/Library/Caches/org.ccikw.sermoncutter.build}"
ARCHS=(arm64 x86_64)

FFMPEG_TAG=n8.1.3
FFMPEG_COMMIT=1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7
WHISPER_TAG=v1.9.5
WHISPER_COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
DENO_VERSION=2.9.8
DENO_SHA_arm64=9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e
DENO_SHA_x86_64=4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c
# yt-dlp_macos already holds both kinds of Mac in one program.
YTDLP_VERSION=2026.10.21
YTDLP_SHA=7a6fe71d7d680f1fb0ac18d4949873d77db2859e90017c0f44bd94b23be4ee40
MODEL=ggml-small.en-q8_0.bin
MODEL_SHA=67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
# Only to build whisper.cpp, when this Mac has no cmake of its own.
CMAKE_VERSION=4.4.4
CMAKE_SHA=4b7b73704b1db9b374e5c9ab8e17ac6148b817b6396ee75cd94a852cbac9d305

# Build with macOS's own tools and libraries only: nothing from Homebrew or
# /usr/local may leak in through the environment.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_PATH || true
export MACOSX_DEPLOYMENT_TARGET=14.0
JOBS="$(sysctl -n hw.ncpu)"
HOST="$(uname -m)"
mkdir -p "$CACHE/dl"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# runs ARCH: whether this Mac can run programs built for ARCH (Intel ones
# need Rosetta on Apple silicon).
runs() { [ "$1" = "$HOST" ] || arch "-$1" /usr/bin/true 2>/dev/null; }

# fetch URL FILE SHA256: downloads unless FILE is already there and right.
fetch() {
  local url="$1" out="$2" want="$3"
  if [ -f "$out" ] && [ "$(sha "$out")" = "$want" ]; then return 0; fi
  echo "   downloading $(basename "$out")"
  curl -fsSL --retry 3 -o "$out.part" "$url"
  if [ "$(sha "$out.part")" != "$want" ]; then
    echo "   $(basename "$out") is not the expected file (SHA-256 differs); stopping"
    rm -f "$out.part"
    return 1
  fi
  mv "$out.part" "$out"
}

# source_at TAG COMMIT REPO DIR: a fresh checkout of TAG, which must be COMMIT.
source_at() {
  local tag="$1" commit="$2" repo="$3" dir="$4"
  rm -rf "$dir"
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$tag" "$repo" "$dir"
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
    echo "   $repo $tag is not commit $commit; stopping"
    return 1
  fi
}

# portable BINARY: fails if it needs a library that doesn't come with macOS.
portable() {
  local bad
  bad="$(otool -L "$1" | grep -E '^[[:space:]]+/' | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)' || true)"
  if [ -n "$bad" ]; then
    echo "   $(basename "$1") needs libraries that aren't part of macOS:"
    echo "$bad"
    return 1
  fi
}

# universal OUT IN...: joins one program per kind of Mac into one.
universal() {
  local out="$1"; shift
  lipo -create "$@" -output "$out.new"
  mv "$out.new" "$out"
}

# nasm assembles ffmpeg's hand-tuned Intel code. Only a build tool: when this
# Mac has none, the Intel ffmpeg is built without that code (it then decodes
# slower, but works the same).
nasm_bin() {
  for n in /opt/homebrew/bin/nasm /usr/local/bin/nasm; do
    if [ -x "$n" ]; then echo "$n"; return 0; fi
  done
  return 1
}

ffmpeg_arch() {
  local arch="$1"
  local dir="$CACHE/ffmpeg-$FFMPEG_TAG/$arch"
  if [ -x "$dir/ffmpeg" ] && [ -x "$dir/ffprobe" ]; then return 0; fi
  echo "   building ffmpeg $FFMPEG_TAG for $arch (a few minutes, once)"
  local src="$CACHE/src-ffmpeg-$arch" log="$CACHE/ffmpeg-$arch.log" extra=() nasm
  source_at "$FFMPEG_TAG" "$FFMPEG_COMMIT" https://github.com/FFmpeg/FFmpeg "$src"
  if [ "$arch" != "$HOST" ]; then extra+=(--enable-cross-compile --target-os=darwin); fi
  if [ "$arch" = x86_64 ]; then
    if nasm="$(nasm_bin)"; then
      extra+=(--x86asmexe="$nasm")
    else
      extra+=(--disable-x86asm)
      echo "   (no nasm on this Mac: the Intel ffmpeg goes without its hand-tuned code)"
    fi
  fi
  if ! (cd "$src" &&
    ./configure --arch="$arch" ${extra[@]+"${extra[@]}"} --disable-autodetect \
      --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
      --enable-zlib --enable-bzlib \
      --disable-doc --disable-ffplay --disable-debug \
      --extra-cflags="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
      --extra-ldflags="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" &&
    make -j"$JOBS" ffmpeg ffprobe) > "$log" 2>&1; then
    echo "   ffmpeg didn't build for $arch; the end of $log:"
    tail -25 "$log"
    return 1
  fi
  mkdir -p "$dir.new"
  cp "$src/ffmpeg" "$src/ffprobe" "$dir.new/"
  if runs "$arch"; then
    local encoders
    encoders="$(arch "-$arch" "$dir.new/ffmpeg" -hide_banner -encoders 2>/dev/null)"
    case "$encoders" in
      *h264_videotoolbox*) ;;
      *) echo "   this ffmpeg ($arch) can't encode with VideoToolbox"; return 1 ;;
    esac
  fi
  portable "$dir.new/ffmpeg" || return 1
  portable "$dir.new/ffprobe" || return 1
  rm -rf "$dir" && mv "$dir.new" "$dir"
  rm -rf "$src"
}

ffmpeg_tools() {
  local top="$CACHE/ffmpeg-$FFMPEG_TAG"
  # Builds from before Intel was added sit in the top folder: they're the arm64 ones.
  if [ -x "$top/ffmpeg" ] && [ ! -d "$top/arm64" ]; then
    mkdir -p "$top/arm64" && mv "$top/ffmpeg" "$top/ffprobe" "$top/arm64/"
  fi
  for a in "${ARCHS[@]}"; do ffmpeg_arch "$a"; done
  for p in ffmpeg ffprobe; do
    universal "$top/$p" "$top/arm64/$p" "$top/x86_64/$p"
  done
}

cmake_bin() {
  if command -v cmake >/dev/null 2>&1; then command -v cmake; return; fi
  for c in /opt/homebrew/bin/cmake /usr/local/bin/cmake /Applications/CMake.app/Contents/bin/cmake; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  local d="$CACHE/cmake-$CMAKE_VERSION"
  if [ ! -x "$d/CMake.app/Contents/bin/cmake" ]; then
    fetch "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz" \
      "$CACHE/dl/cmake-$CMAKE_VERSION.tar.gz" "$CMAKE_SHA" >&2
    rm -rf "$d" && mkdir -p "$d"
    tar -xzf "$CACHE/dl/cmake-$CMAKE_VERSION.tar.gz" -C "$d" --strip-components 1
  fi
  echo "$d/CMake.app/Contents/bin/cmake"
}

whisper_arch() {
  local arch="$1"
  local dir="$CACHE/whisper-$WHISPER_TAG/$arch"
  if [ -x "$dir/whisper-cli" ]; then return 0; fi
  echo "   building whisper.cpp $WHISPER_TAG for $arch"
  local src="$CACHE/src-whisper-$arch" log="$CACHE/whisper-$arch.log" cm cpu=()
  cm="$(cmake_bin)"
  source_at "$WHISPER_TAG" "$WHISPER_COMMIT" https://github.com/ggml-org/whisper.cpp "$src"
  # Tuned for every Mac of that kind, not just this one: Apple silicon from
  # M1; Intel Macs that run macOS 14 all have AVX2.
  if [ "$arch" = arm64 ]; then
    cpu=(-DGGML_CPU_ARM_ARCH=armv8.4-a)
  else
    cpu=(-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX512=OFF)
  fi
  # Static, with the Metal shaders inside it, and without OpenMP (not part of macOS).
  if ! ("$cm" -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
      -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
      -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF "${cpu[@]}" \
      -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF \
      -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF &&
    "$cm" --build "$src/build" --config Release --target whisper-cli -j "$JOBS") > "$log" 2>&1; then
    echo "   whisper.cpp didn't build for $arch; the end of $log:"
    tail -25 "$log"
    return 1
  fi
  mkdir -p "$dir.new"
  cp "$src/build/bin/whisper-cli" "$dir.new/"
  if runs "$arch"; then
    arch "-$arch" "$dir.new/whisper-cli" --help >/dev/null 2>&1 || { echo "   whisper-cli ($arch) doesn't run"; return 1; }
  fi
  portable "$dir.new/whisper-cli" || return 1
  rm -rf "$dir" && mv "$dir.new" "$dir"
  rm -rf "$src"
}

whisper_tool() {
  local top="$CACHE/whisper-$WHISPER_TAG"
  if [ -x "$top/whisper-cli" ] && [ ! -d "$top/arm64" ]; then
    mkdir -p "$top/arm64" && mv "$top/whisper-cli" "$top/arm64/"
  fi
  for a in "${ARCHS[@]}"; do whisper_arch "$a"; done
  universal "$top/whisper-cli" "$top/arm64/whisper-cli" "$top/x86_64/whisper-cli"
}

deno_tool() {
  local top="$CACHE/deno-$DENO_VERSION" a name want
  if [ -x "$top/deno" ] && [ ! -d "$top/arm64" ]; then
    mkdir -p "$top/arm64" && mv "$top/deno" "$top/arm64/"
  fi
  for a in "${ARCHS[@]}"; do
    [ -x "$top/$a/deno" ] && continue
    if [ "$a" = arm64 ]; then name=aarch64; else name=x86_64; fi
    want="DENO_SHA_$a"
    fetch "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-$name-apple-darwin.zip" \
      "$CACHE/dl/deno-$DENO_VERSION-$a.zip" "${!want}"
    rm -rf "$top/$a.new" && mkdir -p "$top/$a.new"
    unzip -q "$CACHE/dl/deno-$DENO_VERSION-$a.zip" -d "$top/$a.new"
    if runs "$a"; then
      arch "-$a" "$top/$a.new/deno" --version >/dev/null || { echo "   deno ($a) doesn't run"; return 1; }
    fi
    portable "$top/$a.new/deno" || return 1
    rm -rf "$top/$a" && mv "$top/$a.new" "$top/$a"
  done
  universal "$top/deno" "$top/arm64/deno" "$top/x86_64/deno"
}

ytdlp_tool() {
  local dir="$CACHE/yt-dlp-$YTDLP_VERSION"
  if [ -x "$dir/yt-dlp" ]; then return 0; fi
  fetch "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos" \
    "$CACHE/dl/yt-dlp_macos-$YTDLP_VERSION" "$YTDLP_SHA"
  rm -rf "$dir.new" && mkdir -p "$dir.new"
  cp "$CACHE/dl/yt-dlp_macos-$YTDLP_VERSION" "$dir.new/yt-dlp"
  chmod 755 "$dir.new/yt-dlp"
  [ "$("$dir.new/yt-dlp" --version)" = "$YTDLP_VERSION" ] || { echo "   yt-dlp doesn't run"; return 1; }
  rm -rf "$dir" && mv "$dir.new" "$dir"
}

speech_model() {
  local f="$CACHE/models/$MODEL"
  if [ -f "$f" ] && [ "$(sha "$f")" = "$MODEL_SHA" ]; then return 0; fi
  mkdir -p "$CACHE/models"
  # The copy set up by hand before the app carried one saves a download.
  local old="$HOME/Movies/SermonCutter/models/$MODEL"
  if [ -f "$old" ] && [ "$(sha "$old")" = "$MODEL_SHA" ]; then
    cp "$old" "$f"
    return 0
  fi
  fetch "$MODEL_URL" "$f" "$MODEL_SHA"
}

echo "   ffmpeg $FFMPEG_TAG, whisper.cpp $WHISPER_TAG, deno $DENO_VERSION, yt-dlp $YTDLP_VERSION, $MODEL; for ${ARCHS[*]}"
ffmpeg_tools
whisper_tool
deno_tool
ytdlp_tool
speech_model

# Into the app. On APFS, cp -c makes clones: no time, no extra disk.
copy() { cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"; }
HELPERS="$APP/Contents/Helpers"
MODELS="$APP/Contents/Resources/models"
mkdir -p "$HELPERS" "$MODELS"
copy "$CACHE/ffmpeg-$FFMPEG_TAG/ffmpeg" "$HELPERS/ffmpeg"
copy "$CACHE/ffmpeg-$FFMPEG_TAG/ffprobe" "$HELPERS/ffprobe"
copy "$CACHE/whisper-$WHISPER_TAG/whisper-cli" "$HELPERS/whisper-cli"
copy "$CACHE/deno-$DENO_VERSION/deno" "$HELPERS/deno"
copy "$CACHE/yt-dlp-$YTDLP_VERSION/yt-dlp" "$HELPERS/yt-dlp"
copy "$CACHE/models/$MODEL" "$MODELS/$MODEL"
chmod 755 "$HELPERS"/*
echo "   $(du -sh "$HELPERS" | cut -f1) of helpers, $(du -sh "$MODELS" | cut -f1) speech model"
