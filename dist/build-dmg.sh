#!/bin/bash
# Package dist/Tunk.app as dist/Tunk-<version>.dmg: the app, an Applications
# symlink, a background that shows the drag, and Finder window geometry so it
# opens the way a non-technical person expects. hdiutil only; no create-dmg.
#
# Steps, each of which leaves something you can inspect:
#   1. build-app.sh                         (skip with NO_BUILD=1)
#   2. dist/dmg-staging/                    the folder that becomes the volume
#   3. dist/Tunk-<version>-rw.dmg           writable image, mounted for step 4
#   4. .DS_Store on the mounted image       window size, icon size, icon
#                                           positions, background picture
#   5. hdiutil convert -format UDZO         the compressed, read-only artefact
#   6. hdiutil verify
#
# Step 4 never depends on Finder. No unattended session (SSH, CI, an agent)
# can answer the Automation prompt Finder scripting needs, so the layout is
# tried in this order and the first one that works wins:
#   a. dist/dmg-assets/DS_Store   a committed .DS_Store from an earlier run.
#                                 Copied in as-is. The layout keys off the item
#                                 names (Tunk.app, Applications) and the volume
#                                 name, and Finder resolves the background
#                                 alias by path when file ids differ, so it
#                                 keeps working across rebuilt images.
#   b. dist/dmg-layout.py         writes the .DS_Store directly. Needs the
#                                 optional dev modules ds_store and mac_alias
#                                 (pip3 install --user ds_store mac_alias; add
#                                 --break-system-packages if pip refuses on a
#                                 Homebrew Python). Saves the result to (a) so
#                                 it gets committed.
#   c. Finder via osascript       10 s timeout. Needs a logged-in session that
#                                 has allowed this terminal to control Finder.
#                                 Also saves to (a).
#   d. none                       the image still builds and verifies; Finder
#                                 shows default positions and no background.
#                                 The script exits 0 and prints the fix.
# REFRESH_LAYOUT=1 skips (a) and rewrites it from (b) or (c).
# NO_FINDER=1 skips (c).
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
# SetFile ships in Xcode and in the CLT but neither puts it on PATH, so take it
# from the toolchain; failing that, write the Finder flag (0x0400 at bytes
# 8-9 of FinderInfo) with xattr.
if [ -x "$DEVELOPER_DIR/usr/bin/SetFile" ]; then
    "$DEVELOPER_DIR/usr/bin/SetFile" -a C "$MOUNT" || true
elif command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT" || true
else
    xattr -wx com.apple.FinderInfo \
        "0000000000000000 0400 0000000000000000000000000000000000000000 0000" "$MOUNT" 2>/dev/null || true
fi

save_layout() {
    if [ ! -f "$LAYOUT_CACHE" ] || [ "${REFRESH_LAYOUT:-0}" = 1 ]; then
        mkdir -p "$(dirname "$LAYOUT_CACHE")"
        cp "$MOUNT/.DS_Store" "$LAYOUT_CACHE"
        echo "  cached the layout at $LAYOUT_CACHE (commit it so every clone ships it)"
    fi
}

layout_from_cache() {
    [ "${REFRESH_LAYOUT:-0}" = 1 ] && return 1
    [ -f "$LAYOUT_CACHE" ] || return 1
    cp "$LAYOUT_CACHE" "$MOUNT/.DS_Store"
    echo "  layout: copied $LAYOUT_CACHE"
}

layout_from_python() {
    python3 -c 'import ds_store, mac_alias' 2>/dev/null || return 1
    python3 "$DIST/dmg-layout.py" "$MOUNT" "$WIN_W" "$WIN_H" "$ICON_SIZE" \
        "$APP_X" "$ICON_Y" "$APPS_X" || return 1
    save_layout
}

layout_from_finder() {
    [ "${NO_FINDER:-0}" = 1 ] && return 1
    osascript - "$MOUNT" "$WIN_W" "$WIN_H" "$ICON_SIZE" "$APP_X" "$ICON_Y" "$APPS_X" <<'EOF' || return 1
on run argv
    set mountPath to item 1 of argv
    set winW to (item 2 of argv) as integer
    set winH to (item 3 of argv) as integer
    set iconSize to (item 4 of argv) as integer
    set appX to (item 5 of argv) as integer
    set iconY to (item 6 of argv) as integer
    set appsX to (item 7 of argv) as integer
    -- Without a timeout an unanswered Automation prompt holds the build for
    -- 60 s per event. 10 s is enough for a human who is there to click Allow.
    with timeout of 10 seconds
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
            end tell
            set opts to icon view options of theWindow
            -- Some Finder builds refuse this one (-10006) while accepting the
            -- rest; the positions below still land, so do not let it abort.
            try
                set arrangement of opts to not arranged
            end try
            set icon size of opts to iconSize
            set text size of opts to 13
            set label position of opts to bottom
            set shows item info of opts to false
            set shows icon preview of opts to true
            set background picture of opts to file ".background:background.tiff" of theDisk
            set position of item "Tunk.app" of theDisk to {appX, iconY}
            set position of item "Applications" of theDisk to {appsX, iconY}
            update theDisk without registering applications
            delay 1
            close theWindow
        end tell
    end timeout
end run
EOF
    sleep 2   # let Finder flush .DS_Store
    [ -f "$MOUNT/.DS_Store" ] || return 1
    save_layout
}

layout=none
if layout_from_cache; then
    layout=cache
elif layout_from_python; then
    layout=python
elif layout_from_finder; then
    layout=finder
    echo "  layout: Finder wrote it"
else
    echo "  layout: NONE. The image still builds, but Finder will show default icon" >&2
    echo "          positions and no background." >&2
    echo "  FIX:    pip3 install --user ds_store mac_alias && make -C dist dmg   (then commit dist/dmg-assets/DS_Store)" >&2
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

# Mount the finished image read-only and prove the three things B2 asks for,
# plus that the .DS_Store carries the two keys Finder needs (bwsp for the
# window, icvp for icon size and background).
CHECK="$(hdiutil attach -readonly -noverify -noautoopen "$DMG" \
         | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
fail=0
[ -d "$CHECK/Tunk.app" ]                        || { echo "  MISSING Tunk.app" >&2; fail=1; }
[ -L "$CHECK/Applications" ]                    || { echo "  MISSING Applications link" >&2; fail=1; }
[ -f "$CHECK/.background/background.tiff" ]     || { echo "  MISSING background" >&2; fail=1; }
if [ -f "$CHECK/.DS_Store" ]; then
    if grep -q bwsp "$CHECK/.DS_Store" && grep -q icvp "$CHECK/.DS_Store"; then
        echo "  layout: .DS_Store has window bounds and icon view settings"
    else
        echo "  layout: .DS_Store present but incomplete (bwsp/icvp missing); Finder will not show the background" >&2
    fi
else
    echo "  layout: default (no .DS_Store)"
fi
hdiutil detach "$CHECK" -quiet || true
[ "$fail" -eq 0 ] || exit 1

rm -rf "$STAGING"
echo
echo "built: $DMG ($(du -h "$DMG" | cut -f1))   layout: $layout"
echo "try:   open $DMG"
