#!/bin/sh
set -eu

# Keep the signed universal Mach-O in Contents/MacOS. This stable Resources
# entry point avoids duplicating executable code while remaining app-relative.
launcher_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$launcher_directory/../../MacOS/fieldnotes" "$@"
