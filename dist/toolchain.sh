#!/bin/bash
# Pick a toolchain that can compile the app. Sourced by build-app.sh and
# build-dmg.sh; not meant to be run on its own.
#
# The Command Line Tools ship a Swift compiler but not the SwiftUI macro plugin,
# so `swift build --product tunk` under them dies with "plugin for module
# SwiftUIMacros not found" on the first @State. On this machine xcode-select
# points at the CLT and changing that needs sudo, so instead of asking for
# sudo we look for Xcode.app and point DEVELOPER_DIR at it for this process.
# SwiftPM honours DEVELOPER_DIR through xcrun; nothing on the machine changes.
#
# Sets DEVELOPER_DIR and returns 0, or prints the one-line fix and returns 1.
tunk_pick_toolchain() {
    local plugin="Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
    local selected candidate
    selected="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"

    if [ -n "$selected" ] && [ -f "$selected/$plugin" ]; then
        export DEVELOPER_DIR="$selected"
        return 0
    fi

    for candidate in /Applications/Xcode.app/Contents/Developer \
                     /Applications/Xcode-*.app/Contents/Developer \
                     "$HOME"/Applications/Xcode*.app/Contents/Developer; do
        if [ -f "$candidate/$plugin" ]; then
            echo "==> ${selected:-no selected toolchain} cannot build SwiftUI; using $candidate"
            export DEVELOPER_DIR="$candidate"
            return 0
        fi
    done

    echo "ERROR: no toolchain with the SwiftUI macro plugin (the Command Line Tools do not ship one)." >&2
    echo "FIX:   install Xcode from the App Store and re-run; if it lives elsewhere:" >&2
    echo "       DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer $0" >&2
    return 1
}
