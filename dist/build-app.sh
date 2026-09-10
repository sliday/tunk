#!/bin/bash
# Assemble Tunk.app from the SwiftPM binary.
#
# The operator gets something to double-click. Everything here is deliberate:
#   - LSUIElement in Info.plist is what removes the dock icon
#   - the bundle id is dev.tunk.Tunk, which is also the UserDefaults suite the
#     app stores settings in, so the bundle and the bare binary share settings
#   - ad-hoc codesign, because Accessibility and Input Monitoring are granted to
#     a signature; an unsigned bundle gets re-prompted on every rebuild
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
CONFIG="${CONFIG:-release}"
SCRATCH="${SCRATCH:-$ROOT/.build-app}"
APP="$DIST/Tunk.app"

echo "==> building tunk ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --scratch-path "$SCRATCH" --product tunk

BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --scratch-path "$SCRATCH" \
        --product tunk --show-bin-path)/tunk"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIST/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BIN" "$APP/Contents/MacOS/Tunk"

# Ad-hoc signature. TCC keys its grants off this, and it changes on every
# rebuild, so expect to re-approve Accessibility and Input Monitoring after a
# rebuild. That is macOS, not Tunk.
echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo
# The same assertion bin/refresh.sh makes about the CLI binaries. A stale
# bundle is worse than a stale CLI: --acceptance is the PRD's live driving
# test, and running fifty prompted taps against yesterday's detector measures
# yesterday's detector while looking exactly like a fresh result. This bundle
# was found four hours behind its sources, missing a calibration measure and
# two fixes to the acceptance test itself.
NEWEST=$(find "$ROOT/Sources" -name '*.swift' -newer "$APP/Contents/MacOS/Tunk" 2>/dev/null | head -1)
if [ -n "$NEWEST" ]; then
    echo "ERROR: $APP is older than $NEWEST after building it." >&2
    echo "       The build did not take. Do not trust anything measured with it." >&2
    exit 1
fi
echo "  bundle is newer than every source file"

echo "built: $APP"
echo "run:   open $APP        (or: $APP/Contents/MacOS/Tunk)"
echo "quit:  the menubar item, or pkill -f Tunk.app"
