#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$repository_root/build/FIELDNOTES.app"
configuration=${1:-debug}

test -x "$app/Contents/MacOS/FIELDNOTESApp"
test -x "$app/Contents/MacOS/fieldnotes"
test -x "$app/Contents/Resources/bin/fieldnotes"
test "$(find "$app/Contents/MacOS" -maxdepth 1 -type f | wc -l | tr -d ' ')" = 2
! cmp -s "$app/Contents/MacOS/FIELDNOTESApp" "$app/Contents/MacOS/fieldnotes"
file "$app/Contents/MacOS/fieldnotes" | grep -q 'Mach-O'
file "$app/Contents/Resources/bin/fieldnotes" | grep -q 'shell script'
test -f "$app/Contents/Resources/editor-web/index.html"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" | grep -qx 'com.thethoughtagen.fieldnotes'
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" | grep -qx 'FIELDNOTESApp'
set +e
launcher_output=$("$app/Contents/Resources/bin/fieldnotes" 2>&1)
launcher_status=$?
set -e
test "$launcher_status" = 64
printf '%s\n' "$launcher_output" | grep -q '^usage: fieldnotes .*PATH$'
"$app/Contents/Resources/bin/fieldnotes" --help | grep -q 'focus|source|preview'
probe_path='/tmp/FIELDNOTES launcher [*] $ argument.md'
set +e
canonical_output=$("$app/Contents/MacOS/fieldnotes" "$probe_path" 2>&1)
canonical_status=$?
launcher_output=$("$app/Contents/Resources/bin/fieldnotes" "$probe_path" 2>&1)
launcher_status=$?
set -e
test "$launcher_status" = "$canonical_status"
test "$launcher_output" = "$canonical_output"
if test "$configuration" = release; then
  test "$(xcrun lipo -archs "$app/Contents/MacOS/FIELDNOTESApp")" = "x86_64 arm64" || \
    test "$(xcrun lipo -archs "$app/Contents/MacOS/FIELDNOTESApp")" = "arm64 x86_64"
  test "$(xcrun lipo -archs "$app/Contents/MacOS/fieldnotes")" = "x86_64 arm64" || \
    test "$(xcrun lipo -archs "$app/Contents/MacOS/fieldnotes")" = "arm64 x86_64"
  codesign --verify --strict "$app"
fi
