#!/bin/sh
# Installs the latest released Keyboard Writer.app into /Applications,
# without needing to build it. Fetched with curl on purpose: a browser
# download is quarantined, and the app is not notarised.
set -eu
installed="/Applications/Keyboard Writer.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/app.zip" \
    https://github.com/russwinch/keyboard-writer/releases/latest/download/Keyboard-Writer.zip
ditto -x -k "$work/app.zip" "$work"
rm -rf "$installed"
cp -R "$work/Keyboard Writer.app" "$installed"
echo "Installed $installed ($(defaults read "$installed/Contents/Info" CFBundleShortVersionString))"
