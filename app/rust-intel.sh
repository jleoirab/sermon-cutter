#!/bin/bash
# Prints a Rust sysroot that can build the engine for Intel Macs with the
# rustc on this Mac, when that rustc can't on its own (Homebrew's Rust comes
# with the standard library for this kind of Mac only). It downloads Rust's
# standard library for x86_64-apple-darwin at exactly this rustc's version,
# checks it against the SHA-256 the Rust project publishes beside it, and
# keeps it in the build cache. Nothing is installed anywhere else.
set -euo pipefail
CACHE="${SERMONCUT_TOOLS_CACHE:-$HOME/Library/Caches/org.ccikw.sermoncutter.build}"
TARGET=x86_64-apple-darwin
VERSION="$(rustc --version | awk '{print $2}')"
SYSROOT="$CACHE/rust-std-$VERSION-$TARGET"
if [ ! -d "$SYSROOT/lib/rustlib/$TARGET/lib" ]; then
  NAME="rust-std-$VERSION-$TARGET"
  URL="https://static.rust-lang.org/dist/$NAME.tar.xz"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "downloading Rust's standard library $VERSION for Intel Macs" >&2
  curl -fsSL --retry 3 -o "$TMP/$NAME.tar.xz" "$URL"
  WANT="$(curl -fsSL --retry 3 "$URL.sha256" | awk '{print $1}')"
  if [ "$(shasum -a 256 "$TMP/$NAME.tar.xz" | cut -d' ' -f1)" != "$WANT" ]; then
    echo "$NAME.tar.xz doesn't match its published SHA-256; stopping" >&2
    exit 1
  fi
  tar -xJf "$TMP/$NAME.tar.xz" -C "$TMP"
  rm -rf "$SYSROOT.new" && mkdir -p "$SYSROOT.new"
  cp -R "$TMP/$NAME/rust-std-$TARGET/lib" "$SYSROOT.new/"
  rm -rf "$SYSROOT" && mv "$SYSROOT.new" "$SYSROOT"
fi
echo "$SYSROOT"
