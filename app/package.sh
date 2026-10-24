#!/bin/bash
# Packages a release that app/build.sh just built (it runs this for
# app/release.sh):
#   app/package.sh "build/CCI Sermon Cutter.app" <path to SermonRelease>
# Writes build/release/CCI Sermon Cutter.dmg (open it, drag the app into
# Applications) and build/release/latest.json (the version, the macOS it
# needs, and the installer's SHA-256 signed with the release key), then opens
# that folder and the Google Drive folder to drag them across.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: app/package.sh <.app> <SermonRelease>}"
REL="${2:?usage: app/package.sh <.app> <SermonRelease>}"
source "$ROOT/app/release.conf"
NAME="CCI Sermon Cutter"
DEST="$ROOT/build/release"
STAGE="$ROOT/build/dmg"

rm -rf "$DEST" "$STAGE"
mkdir -p "$DEST" "$STAGE"
# What the disk image shows: the app, and Applications to drag it onto.
cp -cR "$APP" "$STAGE/" 2>/dev/null || cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
echo "   making the installer"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DEST/$NAME.dmg" >/dev/null
rm -rf "$STAGE"

DOWNLOAD="https://drive.usercontent.google.com/download?id=$INSTALLER_ID&export=download&confirm=t"
security find-generic-password -a release -s "CCI Sermon Cutter release key" -w |
  "$REL" manifest "$DEST/$NAME.dmg" "$APP" "$DOWNLOAD" "$ROOT/app/release-notes.txt" "$DEST/latest.json" |
  sed 's/^/   /'
echo "   $DEST"
echo "   Drag both files into $DRIVE_FOLDER and choose \"Replace existing file\" for each."
open "$DEST"
open "$DRIVE_FOLDER"
