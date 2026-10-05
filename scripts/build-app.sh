#!/bin/zsh
# Release build, majd .app csomag készítése a build/ mappába.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Paperboy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Paperboy" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/"
cp Support/Readability.js Support/Readability-LICENSE.md "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Kész: $APP"
