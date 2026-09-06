#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${APP_OUTPUT:-MAC Switch.app}"
read -r -a TARGET_ARCHS <<< "${ARCHS:-$(uname -m)}"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
for arch in "${TARGET_ARCHS[@]}"; do
    case "$arch" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 1 ;; esac
done
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macswitch-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx$MIN_OS" \
    Sources/NetworkCore.swift Sources/AddressLibrary.swift Tests/CoreTests.swift Tests/LibraryTests.swift -o "$BUILD_DIR/CoreTests"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx$MIN_OS" \
    Sources/NetworkCore.swift Sources/PrivilegedHelper.swift -o "$BUILD_DIR/TestHelper"
"$BUILD_DIR/CoreTests" "$BUILD_DIR/TestHelper"

HELPERS=()
EXECUTABLES=()
for arch in "${TARGET_ARCHS[@]}"; do
    printf 'Building %s (macOS %s+)\n' "$arch" "$MIN_OS"
    xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx$MIN_OS" \
        Sources/NetworkCore.swift Sources/PrivilegedHelper.swift -o "$BUILD_DIR/Helper-$arch"
    xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx$MIN_OS" \
        Sources/NetworkCore.swift Sources/AddressLibrary.swift Sources/AddressListView.swift Sources/MACSwitchApp.swift -o "$BUILD_DIR/App-$arch"
    HELPERS+=("$BUILD_DIR/Helper-$arch")
    EXECUTABLES+=("$BUILD_DIR/App-$arch")
done
if [[ ${#TARGET_ARCHS[@]} -eq 1 ]]; then
    cp "${HELPERS[0]}" "$APP/Contents/Helpers/MACSwitchHelper"
    cp "${EXECUTABLES[0]}" "$APP/Contents/MacOS/MACSwitch"
else
    xcrun lipo -create "${HELPERS[@]}" -output "$APP/Contents/Helpers/MACSwitchHelper"
    xcrun lipo -create "${EXECUTABLES[@]}" -output "$APP/Contents/MacOS/MACSwitch"
fi
cp Info.plist "$APP/Contents/Info.plist"
if [[ -f AppIcon.icns ]]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP/Contents/Helpers/MACSwitchHelper"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
xcrun lipo "$APP/Contents/MacOS/MACSwitch" -verify_arch "${TARGET_ARCHS[@]}"
xcrun lipo "$APP/Contents/Helpers/MACSwitchHelper" -verify_arch "${TARGET_ARCHS[@]}"
printf 'Built: %s\n' "$APP"
