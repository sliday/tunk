#!/usr/bin/env python3
"""Write the Finder window layout of a mounted DMG as a .DS_Store, no Finder.

Run by build-dmg.sh as

    dmg-layout.py <mount> <winW> <winH> <iconSize> <appX> <iconY> <appsX> [<copy-to>]

It needs the ds_store and mac_alias modules (pip3 install --user ds_store
mac_alias). They are an optional build-time tool: the app never sees them, and
build-dmg.sh falls back to a cached .DS_Store or to Finder when the import
fails. The keys written are the ones Finder itself writes for an icon-view
window with a background picture:

    .            vSrn  1
    .            bwsp  window bounds, no toolbar / sidebar / status bar
    .            icvp  icon view: size, text size, grid, background alias
    .            icvl  view style "icnv" (icon view)
    Tunk.app     Iloc  icon centre, window coordinates
    Applications Iloc  icon centre, window coordinates

The background is referenced as a mac alias to <mount>/.background/
background.tiff, built against the mounted volume so it carries the volume
name and the path. Finder resolves it by path when the file ids of a later
image differ, which is why the file can be cached and reused across builds.
"""
import os
import sys


def main(argv):
    if len(argv) not in (8, 9):
        sys.stderr.write(__doc__)
        return 2
    try:
        from ds_store import DSStore
        from mac_alias import Alias
    except ImportError as e:
        sys.stderr.write(f"dmg-layout.py: {e} (pip3 install --user ds_store mac_alias)\n")
        return 3

    mount = argv[1]
    win_w, win_h, icon_size, app_x, icon_y, apps_x = (int(v) for v in argv[2:8])
    copy_to = argv[8] if len(argv) == 9 else None
    background = os.path.join(mount, ".background", "background.tiff")
    if not os.path.isfile(background):
        sys.stderr.write(f"dmg-layout.py: no background at {background}\n")
        return 1

    # Screen position of the window; the content area is win_w x win_h.
    left, top = 200, 120
    bwsp = {
        "WindowBounds": f"{{{{{left}, {top}}}, {{{win_w}, {win_h}}}}}",
        "ShowStatusBar": False,
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
    }
    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,  # 0 default, 1 colour, 2 picture
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "backgroundImageAlias": Alias.for_file(background).to_bytes(),
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 13.0,
        "iconSize": float(icon_size),
        "arrangeBy": "none",
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }

    path = os.path.join(mount, ".DS_Store")
    if os.path.exists(path):
        os.remove(path)
    with DSStore.open(path, "w+") as d:
        d["."]["vSrn"] = ("long", 1)
        d["."]["bwsp"] = bwsp
        d["."]["icvp"] = icvp
        d["."]["icvl"] = ("type", b"icnv")
        d["Tunk.app"]["Iloc"] = (app_x, icon_y)
        d["Applications"]["Iloc"] = (apps_x, icon_y)

    if copy_to:
        os.makedirs(os.path.dirname(copy_to), exist_ok=True)
        with open(path, "rb") as src, open(copy_to, "wb") as dst:
            dst.write(src.read())
    print(f"  layout: wrote {path} ({os.path.getsize(path)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
