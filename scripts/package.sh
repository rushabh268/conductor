#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 0 ]] || { echo 'Usage: scripts/package.sh' >&2; exit 2; }
"$ROOT/scripts/build.sh"
APP="$ROOT/build/Build/Products/Release/Conductor.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p "$ROOT/dist"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Conductor-$VERSION-macos.zip"
(
    cd "$ROOT/dist"
    shasum -a 256 "Conductor-$VERSION-macos.zip" > "Conductor-$VERSION-macos.zip.sha256"
)
