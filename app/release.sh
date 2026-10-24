#!/bin/bash
# Makes a release: builds the app (as app/build.sh does), then the installer
# and latest.json in build/release, and opens that folder and the Google
# Drive folder side by side. Drag both files into Drive and choose
# "Replace existing file" for each, so the links stay the same.
#
# Before running it: put the new version in app/VERSION (for example 0.8)
# and a line or two on what's new in app/release-notes.txt.
RELEASE=1 exec "$(dirname "$0")/build.sh"
