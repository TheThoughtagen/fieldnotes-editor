#!/bin/sh
set -eu

configuration=${1:-debug}
case "$configuration" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_version=${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repository_root/Sources/FieldnotesApp/Info.plist")}
case "$app_version" in
  *[!0-9.]*|'') echo 'Invalid APP_VERSION (expected X.Y.Z)' >&2; exit 1 ;;
esac
printf '%s\n' "$app_version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
  echo 'Invalid APP_VERSION (expected X.Y.Z)' >&2; exit 1
}
build_root="$repository_root/build"
app_bundle="$build_root/FIELDNOTES.app"
mkdir -p "$build_root"
stage=$(mktemp -d "$build_root/.FIELDNOTES.app.XXXXXX")
backup="$build_root/.FIELDNOTES.app.previous"

cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources/bin" "$stage/Contents/Resources/editor-web"

cd "$repository_root"
npm run build --workspace @cruciblesoftware/fieldnotes-renderer
npm run build --workspace @thethoughtagen/fieldnotes-editor-web

build_thin() {
  architecture=$1
  scratch="$repository_root/.build/release-$architecture"
  MACOSX_DEPLOYMENT_TARGET=14.0 swift build \
    --configuration release \
    --arch "$architecture" \
    --scratch-path "$scratch"
  MACOSX_DEPLOYMENT_TARGET=14.0 swift build \
    --configuration release \
    --arch "$architecture" \
    --scratch-path "$scratch" \
    --show-bin-path
}

assert_minos() {
  binary=$1
  minimum=$(xcrun vtool -show-build "$binary" | awk '$1 == "minos" { print $2; exit }')
  test "$minimum" = "14.0" || {
    echo "$binary has deployment target ${minimum:-unknown}, expected 14.0" >&2
    exit 1
  }
}

if test "$configuration" = release; then
  arm_bin=$(build_thin arm64 | tail -n 1)
  intel_bin=$(build_thin x86_64 | tail -n 1)
  assert_minos "$arm_bin/FieldnotesApp"
  assert_minos "$arm_bin/fieldnotes"
  assert_minos "$intel_bin/FieldnotesApp"
  assert_minos "$intel_bin/fieldnotes"
  xcrun lipo -create "$arm_bin/FieldnotesApp" "$intel_bin/FieldnotesApp" -output "$stage/Contents/MacOS/FIELDNOTESApp"
  xcrun lipo -create "$arm_bin/fieldnotes" "$intel_bin/fieldnotes" -output "$stage/Contents/MacOS/fieldnotes"
  for executable in FIELDNOTESApp fieldnotes; do
    arches=$(xcrun lipo -archs "$stage/Contents/MacOS/$executable")
    normalized_arches=$(printf '%s\n' $arches | sort | tr '\n' ' ' | sed 's/ $//')
    test "$normalized_arches" = "arm64 x86_64" || {
      echo "$executable has unexpected architectures: $arches" >&2
      exit 1
    }
  done
else
  MACOSX_DEPLOYMENT_TARGET=14.0 swift build --configuration debug
  bin_path=$(MACOSX_DEPLOYMENT_TARGET=14.0 swift build --configuration debug --show-bin-path)
  cp "$bin_path/FieldnotesApp" "$stage/Contents/MacOS/FIELDNOTESApp"
  cp "$bin_path/fieldnotes" "$stage/Contents/MacOS/fieldnotes"
fi

cp "$repository_root/Sources/FieldnotesApp/Info.plist" "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_version" "$stage/Contents/Info.plist"
cp "$repository_root/packaging/AppIcon.icns" "$stage/Contents/Resources/AppIcon.icns"
cp -R "$repository_root/build/editor-web/." "$stage/Contents/Resources/editor-web/"
cp "$repository_root/scripts/fieldnotes-launcher.sh" "$stage/Contents/Resources/bin/fieldnotes"
chmod 755 \
  "$stage/Contents/MacOS/FIELDNOTESApp" \
  "$stage/Contents/MacOS/fieldnotes" \
  "$stage/Contents/Resources/bin/fieldnotes"

plutil -lint "$stage/Contents/Info.plist" >/dev/null
test -x "$stage/Contents/MacOS/FIELDNOTESApp"
test -x "$stage/Contents/MacOS/fieldnotes"
test -x "$stage/Contents/Resources/bin/fieldnotes"
test -f "$stage/Contents/Resources/editor-web/index.html"
test -s "$stage/Contents/Resources/AppIcon.icns"

if test "$configuration" = release; then
  codesign --force --sign - "$stage/Contents/MacOS/fieldnotes"
  codesign --force --sign - "$stage/Contents/MacOS/FIELDNOTESApp"
  codesign --force --sign - "$stage"
  codesign --verify --strict "$stage"
fi

rm -rf "$backup"
if test -e "$app_bundle"; then
  mv "$app_bundle" "$backup"
fi
if mv "$stage" "$app_bundle"; then
  rm -rf "$backup"
else
  test ! -e "$backup" || mv "$backup" "$app_bundle"
  exit 1
fi
trap - EXIT HUP INT TERM

echo "$app_bundle"
