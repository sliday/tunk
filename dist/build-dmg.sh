#!/bin/bash
# Package dist/Tunk.app as dist/Tunk-<version>.dmg: the app, an Applications
# symlink, a background that shows the drag, and Finder window geometry so it
# opens the way a non-technical person expects. hdiutil only; no create-dmg.
#
# Steps, each of which leaves something you can inspect:
#   1. build-app.sh                         (skip with NO_BUILD=1)
#   2. dist/dmg-staging/                    the folder that becomes the volume
#   3. dist/Tunk-<version>-rw.dmg           writable image, mounted for step 4
#   4. Finder via osascript                 writes .DS_Store: window size, icon
#                                           size, icon positions, background
#   5. hdiutil convert -format UDZO         the compressed, read-only artefact
#   6. hdiutil verify
#
# Step 4 needs a logged-in Finder and Automation permission for the terminal
# running this. When that is missing (an SSH session, a CI box, an agent
# session whose permission prompt nobody answers) the AppleEvent times out.
# Fallback, in order:
#   a. dist/dmg-assets/DS_Store, a .DS_Store that Finder wrote on an earlier
#      run in a GUI session. It is copied into the image as-is. The layout
#      keys off the item names (Tunk.app, Applications) and the volume name,
#      and Finder resolves the background alias by path when the file ids do
#      not match, so a cached one keeps working across rebuilt images. The
#      first successful Finder run writes it; commit it.
#   b. no layout at all: the image still mounts with the app, the alias and
#      the background file, but Finder shows default positions and no
#      background until someone runs this once from Terminal.
# Set NO_FINDER=1 to skip the Finder pass on purpose (uses the cache if it
# exists), REFRESH_LAYOUT=1 to overwrite the cache from a fresh Finder run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST="$ROOT/dist"
APP="$DIST/Tunk.app"
STAGING="$DIST/dmg-staging"
LAYOUT_CACHE="$DIST/dmg-assets/DS_Store"
VOLNAME="Tunk"

# Window geometry, in points, origin top-left of the Finder window content.
WIN_W=660; WIN_H=400
ICON_Y=190; APP_X=165; APPS_X=495; ICON_SIZE=128

# shellcheck source=dist/toolchain.sh
. "$DIST/toolchain.sh"
tunk_pick_toolchain

if [ "${NO_BUILD:-0}" != 1 ]; then
    "$DIST/build-app.sh"
fi
[ -d "$APP" ] || { echo "no app at $APP; run dist/build-app.sh" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/Tunk-$VERSION.dmg"
RW="$DIST/Tunk-$VERSION-rw.dmg"

# Refuse to package a bundle older than its sources, for the same reason
# build-app.sh refuses to hand one over.
NEWEST=$(find "$ROOT/Sources" -name '*.swift' -newer "$APP/Contents/MacOS/Tunk" 2>/dev/null | head -1)
if [ -n "$NEWEST" ]; then
    echo "ERROR: $APP is older than $NEWEST. Rebuild before packaging." >&2
    exit 1
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# Anything still mounted from a previous run would collide on the volume name.
for m in /Volumes/"$VOLNAME" /Volumes/"$VOLNAME "*; do
    [ -d "$m" ] && hdiutil detach "$m" -quiet 2>/dev/null || true
done

echo "==> staging $STAGING"
rm -rf "$STAGING" "$RW"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/Tunk.app"
ln -s /Applications "$STAGING/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

echo "==> drawing background"
swift "$DIST/dmg-background.swift" "$STAGING/.background/background.tiff" \
    "$WIN_W" "$WIN_H" "$ICON_Y" "$APP_X" "$APPS_X"

echo "==> creating writable image"
hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -ov "$RW"

echo "==> mounting to lay out the window"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" \
         | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[ -d "$MOUNT" ] || { echo "mount failed" >&2; exit 1; }
echo "  mounted at $MOUNT"

# The custom-icon bit on the volume root makes Finder use .VolumeIcon.icns.
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT" || true
fi

layout_with_finder() {
    osascript - "$MOUNT" "$WIN_W" "$WIN_H" "$ICON_SIZE" "$APP_X" "$ICON_Y" "$APPS_X" <<'EOF'
on run argv
    set mountPath to item 1 of argv
    set winW to (item 2 of argv) as integer
    set winH to (item 3 of argv) as integer
    set iconSize to (item 4 of argv) as integer
    set appX to (item 5 of argv) as integer
    set iconY to (item 6 of argv) as integer
    set appsX to (item 7 of argv) as integer
    -- Without a timeout an unanswered Automation prompt holds the build for
    -- 60 s per event. 30 s is enough for a human to click Allow.
    with timeout of 30 seconds
        tell application "Finder"
            set theDisk to (POSIX file mountPath) as alias
            open theDisk
            set theWindow to container window of theDisk
            tell theWindow
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set sidebar width to 0
                -- {left, top, right, bottom} on screen; the content is winW x winH
                set bounds to {200, 120, 200 + winW, 120 + winH}
                set opts to icon view options
                tell opts
                    set arrangement to not arranged
                    set icon size to iconSize
                    set text size to 13
                    set label position to bottom
                    set shows item info to false
                    set shows icon preview to true
                    set background picture to file ".background:background.tiff" of theDisk
                end tell
                set position of item "Tunk.app" of theDisk to {appX, iconY}
                set position of item "Applications" of theDisk to {appsX, iconY}
            end tell
            update theDisk without registering applications
            delay 1
            close theWindow
        end tell
    end timeout
end run
EOF
}

use_cached_layout() {
    if [ -f "$LAYOUT_CACHE" ]; then
        cp "$LAYOUT_CACHE" "$MOUNT/.DS_Store"
        echo "  layout: copied cached $LAYOUT_CACHE"
        return 0
    fi
    echo "  WARNING: no cached layout at $LAYOUT_CACHE either. The image mounts with the app," >&2
    echo "           the Applications alias and the background file, but Finder will show default" >&2
    echo "           icon positions and no background. Run this once from Terminal in a logged-in" >&2
    echo "           session, allow it to control Finder, and commit dist/dmg-assets/DS_Store." >&2
    return 1
}

layout_done=0
if [ "${NO_FINDER:-0}" = 1 ]; then
    echo "==> NO_FINDER=1: skipping the Finder pass"
    use_cached_layout && layout_done=1 || true
elif layout_with_finder; then
    echo "==> Finder wrote the window layout"
    sleep 2   # let Finder flush .DS_Store
    if [ -f "$MOUNT/.DS_Store" ]; then
        layout_done=1
        if [ ! -f "$LAYOUT_CACHE" ] || [ "${REFRESH_LAYOUT:-0}" = 1 ]; then
            mkdir -p "$(dirname "$LAYOUT_CACHE")"
            cp "$MOUNT/.DS_Store" "$LAYOUT_CACHE"
            echo "  cached the layout at $LAYOUT_CACHE (commit it so headless builds keep it)"
        fi
    else
        echo "  WARNING: Finder reported success but wrote no .DS_Store" >&2
        use_cached_layout && layout_done=1 || true
    fi
else
    echo "  WARNING: Finder scripting failed (no GUI session, or the Automation prompt was not allowed)." >&2
    use_cached_layout && layout_done=1 || true
fi

# Open the window on mount. bless does this without Finder's help.
if command -v bless >/dev/null 2>&1; then
    bless --folder "$MOUNT" --openfolder "$MOUNT" 2>/dev/null || true
fi

# Finder and the FS leave droppings that do not belong in a shipped image.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet || { sleep 2; hdiutil detach "$MOUNT" -force -quiet; }

echo "==> compressing to $DMG"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"
rm -f "$RW"

echo "==> verifying"
hdiutil verify -quiet "$DMG"
echo "  checksum ok"

# Mount the finished image read-only and prove the three things B2 asks for.
CHECK="$(hdiutil attach -readonly -noverify -noautoopen "$DMG" \
         | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
fail=0
[ -d "$CHECK/Tunk.app" ]                        || { echo "  MISSING Tunk.app" >&2; fail=1; }
[ -L "$CHECK/Applications" ]                    || { echo "  MISSING Applications link" >&2; fail=1; }
[ -f "$CHECK/.background/background.tiff" ]     || { echo "  MISSING background" >&2; fail=1; }
[ -f "$CHECK/.DS_Store" ] && echo "  layout: .DS_Store present" || echo "  layout: default (no .DS_Store)"
hdiutil detach "$CHECK" -quiet || true
[ "$fail" -eq 0 ] || exit 1

rm -rf "$STAGING"
echo
echo "built: $DMG ($(du -h "$DMG" | cut -f1))"
[ "$layout_done" -eq 1 ] || echo "       (icon layout: Finder defaults; see the header of this script)"
echo "try:   open $DMG"
