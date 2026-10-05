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

# Verzió: a legutóbbi vX.Y.Z git-címke; build-szám: a commitok száma (két kiadás között is egyedi).
VERSION=$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)
VERSION=${VERSION:-0.0.0}
BUILD=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" \
    "$APP/Contents/Info.plist"
cp Support/Readability.js Support/Readability-LICENSE.md Support/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Kész: $APP ($VERSION, build $BUILD)"
