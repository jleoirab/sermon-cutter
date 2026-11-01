#!/bin/bash
# Puts a built CCI Sermon Cutter.app into the main Applications folder (the
# one in Finder's sidebar, where the leads' copies go too), or the home
# folder's own if this account can't write there, and moves copies from
# earlier builds or under the old name to the Trash, so there's one app.
#
#   bash app/install.sh "build/CCI Sermon Cutter.app"
set -euo pipefail
SRC="$1"
APP_NAME="CCI Sermon Cutter"
OLD_NAME="Sermon Cutter"
DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
rm -rf "$DEST_DIR/$APP_NAME.app"
cp -cR "$SRC" "$DEST_DIR/" 2>/dev/null || cp -R "$SRC" "$DEST_DIR/"
echo "installed: $DEST_DIR/$APP_NAME.app"
for OLD in "$HOME/Applications/$APP_NAME.app" "$HOME/Applications/$OLD_NAME.app" "/Applications/$OLD_NAME.app"; do
  if [ -d "$OLD" ] && [ "$OLD" != "$DEST_DIR/$APP_NAME.app" ]; then
    mv "$OLD" "$HOME/.Trash/$(basename "$OLD" .app) $(date +%H%M%S).app" && echo "moved the copy in $(dirname "$OLD") to the Trash"
  fi
done
