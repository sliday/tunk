#!/usr/bin/env python3
"""Rasterise the favicon set from design/icon.svg and compose og.png.

Chromium renders the SVG, so the gradients and blurs in the icon survive.
ImageMagick's own SVG renderer flattens them, which is why it is not used here.

Pages are loaded with goto() from real files. set_content() leaves the page on
an about:blank origin, which blocks every file:// sub-resource, so images come
out as broken placeholders.
"""
import os, shutil
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = HERE  # PNGs land here, then install() copies them into place
STAGE = os.path.join(HERE, ".stage")
SITE = os.path.normpath(os.path.join(HERE, ".."))
ICON = os.path.normpath(os.path.join(SITE, "..", "design", "icon.svg"))

ICON_SIZES = [16, 32, 48, 180, 192, 512]


def main():
    os.makedirs(STAGE, exist_ok=True)
    shutil.copy(ICON, os.path.join(STAGE, "icon.svg"))
    shutil.copy(os.path.join(SITE, "img", "hero@2x.jpg"), os.path.join(STAGE, "hero.jpg"))

    og = open(os.path.join(OUT, "og-template.html")).read()
    og = og.replace("IMG_HERO", "hero.jpg").replace("IMG_ICON", "icon.svg")
    open(os.path.join(STAGE, "og.html"), "w").write(og)

    with sync_playwright() as pw:
        b = pw.chromium.launch()

        for s in ICON_SIZES:
            wrap = os.path.join(STAGE, f"icon-{s}.html")
            open(wrap, "w").write(
                f'<!doctype html><meta charset="utf-8">'
                f'<style>html,body{{margin:0;padding:0;background:transparent}}'
                f'img{{display:block;width:{s}px;height:{s}px}}</style>'
                f'<img src="icon.svg">'
            )
            page = b.new_page(viewport={"width": s, "height": s}, device_scale_factor=1)
            page.goto("file://" + wrap)
            page.wait_for_timeout(150)
            page.screenshot(path=f"{OUT}/icon-{s}.png", omit_background=True)
            page.close()
            print(f"icon-{s}.png")

        page = b.new_page(viewport={"width": 1200, "height": 630}, device_scale_factor=1)
        page.goto("file://" + os.path.join(STAGE, "og.html"))
        page.wait_for_timeout(600)
        page.screenshot(path=f"{OUT}/og.png")
        page.close()
        print("og.png")

        b.close()


def install():
    """Put the rendered files where index.html expects them."""
    import shutil
    pairs = [("icon-180.png", "apple-touch-icon.png"),
             ("icon-192.png", "icon-192.png"),
             ("icon-512.png", "icon-512.png"),
             ("icon-16.png", "icon-16.png"),
             ("icon-32.png", "icon-32.png"),
             ("og.png", "og.png")]
    for src, dst in pairs:
        shutil.copy(os.path.join(OUT, src), os.path.join(SITE, dst))
    os.system('magick "%s/icon-16.png" "%s/icon-32.png" "%s/icon-48.png" "%s/favicon.ico"'
              % (OUT, OUT, OUT, SITE))
    shutil.copy(os.path.normpath(os.path.join(SITE, "..", "design", "favicon.svg")),
                os.path.join(SITE, "favicon.svg"))
    print("installed into", SITE)


main()
install()
