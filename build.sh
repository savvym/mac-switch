#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="MAC Switch.app"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macswitch-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    Sources/NetworkCore.swift Sources/AddressLibrary.swift Tests/CoreTests.swift Tests/LibraryTests.swift -o "$BUILD_DIR/CoreTests"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    Sources/NetworkCore.swift Sources/PrivilegedHelper.swift -o "$APP/Contents/Helpers/MACSwitchHelper"
codesign --force --sign - "$APP/Contents/Helpers/MACSwitchHelper"
"$BUILD_DIR/CoreTests" "$PWD/$APP/Contents/Helpers/MACSwitchHelper"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    Sources/NetworkCore.swift Sources/AddressLibrary.swift Sources/AddressListView.swift Sources/MACSwitchApp.swift -o "$APP/Contents/MacOS/MACSwitch"
cp Info.plist "$APP/Contents/Info.plist"
if [[ -f AppIcon.icns ]]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s/%s\n' "$PWD" "$APP"
