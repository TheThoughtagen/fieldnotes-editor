#!/bin/sh
set -eu

# Keep the signed universal Mach-O in Contents/MacOS. This stable Resources
# entry point avoids duplicating executable code while remaining app-relative.
launcher=$0
while test -L "$launcher"; do
  directory=$(CDPATH= cd -- "$(dirname -- "$launcher")" && pwd)
  target=$(readlink "$launcher")
  case "$target" in
    /*) launcher=$target ;;
    *) launcher="$directory/$target" ;;
  esac
done
launcher_directory=$(CDPATH= cd -- "$(dirname -- "$launcher")" && pwd)
exec "$launcher_directory/../../MacOS/fieldnotes" "$@"
