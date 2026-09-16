#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
master=${1:-packaging/AppIcon.png}
output=packaging/AppIcon.icns
test "$#" -le 1 || { echo "usage: $0 [1024px-master.png]" >&2; exit 64; }
test -f "$master" || { echo "Missing icon master: $master" >&2; exit 1; }
properties=$(sips -g format -g pixelWidth -g pixelHeight "$master")
for expected in 'format: png' 'pixelWidth: 1024' 'pixelHeight: 1024'; do
  printf '%s\n' "$properties" | grep -Eq "^[[:space:]]*$expected$" || {
    echo 'Icon master must be a 1024 x 1024 PNG' >&2; exit 1
  }
done
stage=$(mktemp -d "${TMPDIR:-/tmp}/fieldnotes-icon.XXXXXX")
trap 'rm -rf "$stage"' EXIT
iconset="$stage/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -s format png -z "$retina" "$retina" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$stage/AppIcon.icns"
test "$(head -c 4 "$stage/AppIcon.icns")" = icns
cp "$stage/AppIcon.icns" "$output"
echo "$output"
