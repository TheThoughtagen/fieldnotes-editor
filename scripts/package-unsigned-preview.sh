#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test "$#" = 0 || { echo "usage: APP_VERSION=X.Y.Z $0" >&2; exit 64; }
# Never infer a public release version or modify an already signed bundle.
[[ "${APP_VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo 'Invalid or missing APP_VERSION (expected X.Y.Z)' >&2; exit 1
}
app="$PWD/build/FIELDNOTES.app"
for key in CFBundleShortVersionString CFBundleVersion; do
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")
  test "$actual" = "$APP_VERSION" || {
    echo "Bundle $key is $actual; rebuild with APP_VERSION=$APP_VERSION before packaging" >&2; exit 1
  }
done
scripts/sign-and-package.sh --verify-unsigned
# The unsigned preview carries only local ad-hoc signatures, never Developer ID.
for target in "$app/Contents/MacOS/fieldnotes" "$app/Contents/MacOS/FIELDNOTESApp" "$app"; do
  signature=$(codesign -d --verbose=4 "$target" 2>&1)
  printf '%s\n' "$signature" | grep -qx 'Signature=adhoc' || {
    echo "Refusing non-ad-hoc preview bundle: $target" >&2; exit 1
  }
done
stage=$(mktemp -d "$PWD/build/.preview.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/contents"
ditto "$app" "$stage/contents/FIELDNOTES.app"
ln -s /Applications "$stage/contents/Applications"
cat > "$stage/contents/INSTALL.txt" <<TEXT
FIELDNOTES $APP_VERSION — unsigned preview

Requires macOS 14 (Sonoma) or newer. Supports Apple Silicon and Intel.
Drag FIELDNOTES.app to Applications, then eject this disk image.

This preview is not Developer ID signed and is not notarized by Apple.
macOS may block opening it. Only if you trust this download, attempt to
open the app, then use System Settings > Privacy & Security > Open Anyway
and follow the confirmation prompts. Do not disable Gatekeeper globally.
Apple instructions: https://support.apple.com/en-us/102445

The bundled command-line launcher is:
/Applications/FIELDNOTES.app/Contents/Resources/bin/fieldnotes
TEXT
name="FIELDNOTES-$APP_VERSION-unsigned-preview-universal"
hdiutil create -volname 'FIELDNOTES Preview' -srcfolder "$stage/contents" -format UDZO "$stage/$name.dmg"
hdiutil verify "$stage/$name.dmg"
(cd "$stage" && shasum -a 256 "$name.dmg" > "$name.sha256")
mv "$stage/$name.dmg" "build/$name.dmg"
mv "$stage/$name.sha256" "build/$name.sha256"
printf '%s\n' "build/$name.dmg" "build/$name.sha256"
