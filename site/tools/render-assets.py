#!/usr/bin/env python3
"""Rasterise the icon set and compose og.png, then install both into site/.

Two sources, and using the wrong one is the mistake this script exists to
prevent. IDENTITY.md section 8: `favicon.svg` is the flat mark and owns
everything under 32 px; `icon.svg` is the full mark and owns 32 px and up. The
full mark's bloom and shock ring turn to haze when shrunk to a browser tab, and
a favicon cut from it reads as a smudge.

Chromium does the rendering, so the icon's gradients survive. ImageMagick's own
SVG renderer flattens them into mud and must not be used here.

Pages load with goto() from real files. set_content() leaves the page on an
about:blank origin, which blocks every file:// sub-resource and yields broken
image placeholders.

    python3 render-assets.py

Needs: playwright (with chromium installed) and ImageMagick's `magick`.
"""
import os
import shutil
import subprocess

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.normpath(os.path.join(HERE, ".."))
DESIGN = os.path.normpath(os.path.join(SITE, "..", "design"))
FLAT = os.path.join(DESIGN, "favicon.svg")   # under 32 px
FULL = os.path.join(DESIGN, "icon.svg")      # 32 px and up
STAGE = os.path.join(HERE, ".stage")

# size -> which source owns it
RENDERS = [
    (16, FLAT),
    (32, FLAT),
    (48, FLAT),
    (180, FULL),
    (192, FULL),
    (512, FULL),
]

# The gap between the two amber strikes must survive the smallest render, or the
# mark stops saying "double". IDENTITY.md section 8, "the one number to protect".
MIN_GAP_PX = 1.4


def gap_at(size_px):
    """Gap between the two strikes in favicon.svg, in pixels at `size_px`."""
    import re
    svg = open(FLAT).read()
    box = re.search(r'viewBox="0 0 (\d+)', svg)
    units = float(box.group(1))
    circles = [(float(m.group(1)), float(m.group(2)))
               for m in re.finditer(r'<circle cx="([\d.]+)"[^/]*?r="([\d.]+)"[^/]*fill="#FF', svg)]
    if len(circles) != 2:
        return None
    (cx1, r1), (cx2, r2) = sorted(circles)
    return ((cx2 - r2) - (cx1 + r1)) * size_px / units


def render(browser):
    os.makedirs(STAGE, exist_ok=True)
    shutil.copy(FLAT, os.path.join(STAGE, "favicon.svg"))
    shutil.copy(FULL, os.path.join(STAGE, "icon.svg"))

    for size, src in RENDERS:
        name = os.path.basename(src)
        wrap = os.path.join(STAGE, f"r-{size}.html")
        with open(wrap, "w") as f:
            f.write(
                '<!doctype html><meta charset="utf-8">'
                '<style>html,body{margin:0;padding:0;background:transparent}'
                f'img{{display:block;width:{size}px;height:{size}px}}</style>'
                f'<img src="{name}">'
            )
        page = browser.new_page(viewport={"width": size, "height": size},
                                device_scale_factor=1)
        page.goto("file://" + wrap)
        page.wait_for_timeout(150)
        page.screenshot(path=os.path.join(HERE, f"icon-{size}.png"),
                        omit_background=True)
        page.close()
        print(f"  icon-{size}.png  from {name}")


def og(browser):
    shutil.copy(os.path.join(HERE, "og-template.html"),
                os.path.join(STAGE, "og.html"))
    page = browser.new_page(viewport={"width": 1200, "height": 630},
                            device_scale_factor=1)
    page.goto("file://" + os.path.join(STAGE, "og.html"))
    page.wait_for_timeout(600)
    page.screenshot(path=os.path.join(HERE, "og.png"))
    page.close()
    print("  og.png  1200x630")


def install():
    """Put the rendered files where index.html expects them."""
    for src, dst in [("icon-180.png", "apple-touch-icon.png"),
                     ("icon-192.png", "icon-192.png"),
                     ("icon-512.png", "icon-512.png"),
                     ("og.png", "og.png")]:
        shutil.copy(os.path.join(HERE, src), os.path.join(SITE, dst))

    # The .ico is a browser-tab artefact end to end, so all three sizes come
    # from the flat mark rather than mixing sources inside one file.
    subprocess.run(["magick",
                    os.path.join(HERE, "icon-16.png"),
                    os.path.join(HERE, "icon-32.png"),
                    os.path.join(HERE, "icon-48.png"),
                    os.path.join(SITE, "favicon.ico")], check=True)

    shutil.copy(FLAT, os.path.join(SITE, "favicon.svg"))
    print("installed into", SITE)


def main():
    g = gap_at(16)
    if g is None:
        print("WARNING: could not measure the strike gap in favicon.svg")
    elif g < MIN_GAP_PX:
        raise SystemExit(
            f"refusing to build: strike gap is {g:.2f} px at 16 px, below the "
            f"{MIN_GAP_PX} px floor. The two strikes will fuse and the mark "
            f"stops saying 'double'. See IDENTITY.md section 8.")
    else:
        print(f"strike gap at 16 px: {g:.2f} px (floor {MIN_GAP_PX})")

    with sync_playwright() as pw:
        b = pw.chromium.launch()
        render(b)
        og(b)
        b.close()
    install()


main()
