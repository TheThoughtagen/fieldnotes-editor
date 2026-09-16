#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/FIELDNOTES.app"
verify_bundle() {
  plutil -lint "$app/Contents/Info.plist"
  for name in FIELDNOTESApp fieldnotes; do
    binary="$app/Contents/MacOS/$name"
    arches=$(lipo -archs "$binary" | tr ' ' '\n' | sort | tr '\n' ' ')
    test "$arches" = 'arm64 x86_64 ' || { echo "Not universal: $binary ($arches)" >&2; exit 1; }
    echo "$name: $arches"
    if nm "$binary" 2>/dev/null | grep IntegrationControl >/dev/null; then
      echo 'Refusing automation-enabled app' >&2; exit 1
    fi
    if strings "$binary" | grep FIELDNOTES_INTEGRATION_CONTROL_V1 >/dev/null; then
      echo 'Refusing automation-enabled app marker' >&2; exit 1
    fi
  done
  test -f "$app/Contents/Resources/editor-web/index.html"
  test -s "$app/Contents/Resources/AppIcon.icns"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" = AppIcon
  test "$(head -c 4 "$app/Contents/Resources/AppIcon.icns")" = icns
  test ! -e "$app/Contents/Resources/integration"
  "$app/Contents/Resources/bin/fieldnotes" --help
  codesign --verify --strict --verbose=2 "$app"
}
case "${1:-}" in
  --verify-unsigned) verify_bundle; exit 0 ;;
  '') ;;
  *) echo "usage: $0 [--verify-unsigned]" >&2; exit 64 ;;
esac
for key in DEVELOPER_ID NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER APP_VERSION; do
  test -n "${!key:-}" || { echo "Required release credential/value missing: $key" >&2; exit 1; }
done
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid APP_VERSION' >&2; exit 1; }
verify_bundle
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$app/Contents/Info.plist"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$app/Contents/MacOS/fieldnotes"
codesign --force --options runtime --timestamp --entitlements packaging/Fieldnotes.entitlements --sign "$DEVELOPER_ID" "$app"
codesign --verify --strict --verbose=2 "$app"
stage=$(mktemp -d "$PWD/build/.dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/FIELDNOTES.app"
ln -s /Applications "$stage/Applications"
dmg="$PWD/build/FIELDNOTES-$APP_VERSION.dmg"
hdiutil create -volname FIELDNOTES -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg"
xcrun notarytool submit "$dmg" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
# Only the final stapled bytes receive the published digest.
(cd build && shasum -a 256 "$(basename "$dmg")" > "FIELDNOTES-$APP_VERSION.sha256")
