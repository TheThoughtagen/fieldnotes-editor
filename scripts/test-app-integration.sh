#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Separate scratch path prevents an automation build from contaminating release products.
swift build --scratch-path .build/integration -Xswiftc -DFIELDNOTES_INTEGRATION
bin=$(swift build --scratch-path .build/integration --show-bin-path)
app="$PWD/build/Integration/FIELDNOTES.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/FieldnotesApp" "$app/Contents/MacOS/FIELDNOTESApp"
cp "$bin/fieldnotes" "$app/Contents/MacOS/fieldnotes"
cp Sources/FieldnotesApp/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.thethoughtagen.fieldnotes.integration" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 fieldnotes-integration" "$app/Contents/Info.plist"
cp -R build/editor-web "$app/Contents/Resources/"
FIELDNOTES_INTEGRATION_APP="$app" swift test --filter CLIAppIntegrationTests
