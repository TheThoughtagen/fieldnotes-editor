#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$repository_root/build/FIELDNOTES.app"
configuration=${1:-debug}

test -x "$app/Contents/MacOS/FIELDNOTESApp"
test -x "$app/Contents/MacOS/fieldnotes"
test "$(find "$app/Contents/MacOS" -maxdepth 1 -type f | wc -l | tr -d ' ')" = 2
! cmp -s "$app/Contents/MacOS/FIELDNOTESApp" "$app/Contents/MacOS/fieldnotes"
test -f "$app/Contents/Resources/editor-web/index.html"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" | grep -qx 'com.thethoughtagen.fieldnotes'
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" | grep -qx 'FIELDNOTESApp'
if test "$configuration" = release; then
  test "$(xcrun lipo -archs "$app/Contents/MacOS/FIELDNOTESApp")" = "x86_64 arm64" || \
    test "$(xcrun lipo -archs "$app/Contents/MacOS/FIELDNOTESApp")" = "arm64 x86_64"
  test "$(xcrun lipo -archs "$app/Contents/MacOS/fieldnotes")" = "x86_64 arm64" || \
    test "$(xcrun lipo -archs "$app/Contents/MacOS/fieldnotes")" = "arm64 x86_64"
  codesign --verify --strict "$app"
fi
