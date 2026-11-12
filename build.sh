#!/bin/sh
# Builds "Keyboard Writer.app" into build/ and, outside CI, copies it to
# /Applications when the copy there is missing or differs. Needs Xcode or
# its command line tools (xcode-select --install). VERSION sets the app's
# version; a release build gets it from the App workflow.
set -eu
cd "$(dirname "$0")"
version="${VERSION:-0.0}"

swift build -c release
app="build/Keyboard Writer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/KeyboardWriter" "$app/Contents/MacOS/KeyboardWriter"
cp targets.json "$app/Contents/Resources/targets.json"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Keyboard Writer</string>
    <key>CFBundleDisplayName</key><string>Keyboard Writer</string>
    <key>CFBundleIdentifier</key><string>com.github.russwinch.keyboard-writer</string>
    <key>CFBundleExecutable</key><string>KeyboardWriter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDownloadsFolderUsageDescription</key><string>To find the firmware .zip you downloaded.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>To copy firmware onto the keyboard's bootloader drive.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $PWD/$app ($version)"

installed="/Applications/Keyboard Writer.app"
if [ -n "${CI:-}" ]; then
    exit 0
fi
if diff -rq "$app" "$installed" >/dev/null 2>&1; then
    echo "$installed is already this build"
else
    rm -rf "$installed"
    cp -R "$app" "$installed"
    echo "Installed $installed"
fi
