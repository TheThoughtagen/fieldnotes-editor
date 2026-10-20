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
for key in DEVELOPER_ID APPLE_TEAM_ID SIGNING_KEYCHAIN NOTARY_KEY NOTARY_KEY_ID APP_VERSION; do
  test -n "${!key:-}" || { echo "Required release credential/value missing: $key" >&2; exit 1; }
done
[[ "$APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Invalid APP_VERSION' >&2; exit 1; }
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid APPLE_TEAM_ID' >&2; exit 1; }
# Never mutate version metadata after the build or accept an ad-hoc identity.
for key in CFBundleShortVersionString CFBundleVersion; do
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")
  test "$actual" = "$APP_VERSION" || {
    echo "Bundle $key is $actual; rebuild with APP_VERSION=$APP_VERSION before packaging" >&2; exit 1
  }
done
[[ "$DEVELOPER_ID" == "Developer ID Application: "*" ($APPLE_TEAM_ID)" ]] || {
  echo 'Expected Developer ID Application identity for APPLE_TEAM_ID' >&2; exit 1
}
test -f "$SIGNING_KEYCHAIN"
test -s "$NOTARY_KEY"
# Resolve only valid identities in the dedicated keychain, then sign by fingerprint.
identity=$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | DEVELOPER_ID="$DEVELOPER_ID" node -e '
let data=""; process.stdin.on("data", c => data+=c); process.stdin.on("end", () => {
  const matches = [...data.matchAll(/\b([A-Fa-f0-9]{40}) "([^"\n]+)"/g)].filter(m => m[2] === process.env.DEVELOPER_ID);
  if (matches.length !== 1) process.exit(1); console.log(matches[0][1]);
});') || { echo 'Expected exactly one valid Developer ID identity in signing keychain' >&2; exit 1; }
verify_bundle
stage=$(mktemp -d "$PWD/build/.signed.XXXXXX")
trap 'rm -rf "$stage"' EXIT
reports="$PWD/build/notary-reports"
mkdir -p "$reports"
notary_auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
if test -n "${NOTARY_ISSUER:-}"; then notary_auth+=(--issuer "$NOTARY_ISSUER"); fi
json_field() {
  node -e 'const fs=require("fs"); const v=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))[process.argv[2]]; if(typeof v!=="string" || !v) process.exit(1); console.log(v)' "$1" "$2"
}
notarize() {
  local target="$1" label="$2" submission status wait_result=0
  # Submit separately so the submission ID survives rejection and wait timeouts.
  xcrun notarytool submit "$target" "${notary_auth[@]}" --no-wait --output-format json > "$reports/$label-submit.json" 2> "$reports/$label-submit.stderr"
  submission=$(json_field "$reports/$label-submit.json" id)
  [[ "$submission" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || { echo 'Invalid notary submission ID' >&2; return 1; }
  xcrun notarytool wait "$submission" "${notary_auth[@]}" --timeout 15m --output-format json > "$reports/$label-wait.json" 2> "$reports/$label-wait.stderr" || wait_result=$?
  xcrun notarytool log "$submission" "${notary_auth[@]}" "$reports/$label-log.json" > "$reports/$label-log.stdout" 2> "$reports/$label-log.stderr" || true
  status=$(json_field "$reports/$label-wait.json" status) || status=Unknown
  if test "$wait_result" != 0 || test "$status" != Accepted; then
    echo "Notarization $label did not succeed ($status, exit $wait_result); see $reports" >&2
    return 1
  fi
}
verify_signature() {
  local target="$1" runtime="${2:-}" details
  codesign --verify --strict --verbose=2 "$target"
  details=$(codesign -d --verbose=4 "$target" 2>&1)
  printf '%s\n' "$details" | grep -Fx "Authority=$DEVELOPER_ID" >/dev/null
  printf '%s\n' "$details" | grep -Fx "TeamIdentifier=$APPLE_TEAM_ID" >/dev/null
  printf '%s\n' "$details" | grep -E '^Timestamp=.+$' >/dev/null
  if test "$runtime" = runtime; then
    printf '%s\n' "$details" | grep -E '^CodeDirectory .*flags=.*\(.*runtime.*\)' >/dev/null
  fi
}
codesign --force --options runtime --timestamp --keychain "$SIGNING_KEYCHAIN" --sign "$identity" "$app/Contents/MacOS/fieldnotes"
codesign --force --options runtime --timestamp --keychain "$SIGNING_KEYCHAIN" --entitlements packaging/Fieldnotes.entitlements --sign "$identity" "$app"
verify_signature "$app/Contents/MacOS/fieldnotes" runtime
verify_signature "$app/Contents/MacOS/FIELDNOTESApp" runtime
verify_signature "$app" runtime
ditto -c -k --keepParent "$app" "$stage/FIELDNOTES.zip"
notarize "$stage/FIELDNOTES.zip" app
xcrun stapler staple "$app"
xcrun stapler validate "$app"
verify_signature "$app" runtime
spctl --assess --type execute -v "$app"
mkdir "$stage/contents"
ditto "$app" "$stage/contents/FIELDNOTES.app"
ln -s /Applications "$stage/contents/Applications"
dmg="$stage/FIELDNOTES-$APP_VERSION.dmg"
hdiutil create -volname FIELDNOTES -srcfolder "$stage/contents" -format UDZO "$dmg"
codesign --force --timestamp --keychain "$SIGNING_KEYCHAIN" --sign "$identity" "$dmg"
verify_signature "$dmg"
notarize "$dmg" dmg
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
verify_signature "$dmg"
hdiutil verify "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
# Only successful final stapled bytes receive the published digest and output paths.
(cd "$stage" && shasum -a 256 "$(basename "$dmg")" > "FIELDNOTES-$APP_VERSION.sha256")
mv "$dmg" "$PWD/build/FIELDNOTES-$APP_VERSION.dmg"
mv "$stage/FIELDNOTES-$APP_VERSION.sha256" "$PWD/build/FIELDNOTES-$APP_VERSION.sha256"
