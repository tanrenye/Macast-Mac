#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c release "$@"
binary="$(swift build -c release --show-bin-path "$@")/MyCast"
app="$root/dist/MyCast.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$binary" "$app/Contents/MacOS/MyCast"
install -m 644 scripts/Info.plist "$app/Contents/Info.plist"
install -m 644 Assets/MyCast.icns "$app/Contents/Resources/MyCast.icns"
# Finder may tag an existing bundle after it is opened.
xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
codesign --force --sign - "$app"
printf '%s\n' "$app"
