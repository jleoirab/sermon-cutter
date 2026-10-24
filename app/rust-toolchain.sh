#!/bin/bash
# Prints the bin folder of a Rust toolchain that builds the engine for both
# Apple silicon and Intel Macs. Homebrew's Rust can only build for the Mac
# it's on, and rustup isn't needed: this downloads the official Rust
# components (rustc, cargo, and the standard library for each kind of Mac)
# at a pinned version, checks each against the SHA-256 the Rust project
# publishes beside it, and installs them into the build cache. Nothing is
# installed anywhere else, and the Rust you use in Terminal stays as it is.
set -euo pipefail
CACHE="${SERMONCUT_TOOLS_CACHE:-$HOME/Library/Caches/org.ccikw.sermoncutter.build}"
VERSION=1.99.1
HOST="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin"
DIR="$CACHE/rust-$VERSION"
if [ ! -x "$DIR/bin/cargo" ] || [ ! -d "$DIR/lib/rustlib/x86_64-apple-darwin" ] || [ ! -d "$DIR/lib/rustlib/aarch64-apple-darwin" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "   getting Rust $VERSION for building for both kinds of Mac (once)" >&2
  rm -rf "$DIR.new"
  for c in "rustc-$VERSION-$HOST" "cargo-$VERSION-$HOST" \
           "rust-std-$VERSION-aarch64-apple-darwin" "rust-std-$VERSION-x86_64-apple-darwin"; do
    URL="https://static.rust-lang.org/dist/$c.tar.xz"
    curl -fsSL --retry 3 -o "$TMP/$c.tar.xz" "$URL"
    WANT="$(curl -fsSL --retry 3 "$URL.sha256" | awk '{print $1}')"
    if [ "$(shasum -a 256 "$TMP/$c.tar.xz" | cut -d' ' -f1)" != "$WANT" ]; then
      echo "$c.tar.xz doesn't match its published SHA-256; stopping" >&2
      exit 1
    fi
    tar -xJf "$TMP/$c.tar.xz" -C "$TMP"
    "$TMP/$c/install.sh" --prefix="$DIR.new" --disable-ldconfig --without=rust-docs >/dev/null
  done
  rm -rf "$DIR" && mv "$DIR.new" "$DIR"
fi
echo "$DIR/bin"
