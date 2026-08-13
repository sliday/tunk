#!/usr/bin/env python3
"""Rasterise the icon set and compose og.png, then install both into site/.

Three sources, and using the wrong one is the mistake this script exists to
prevent. Per IDENTITY.md section 8 and the icon designer's source table:

  favicon.svg        flat mark, owns everything under 32 px. The full mark's
                     bloom and shock ring turn to haze at tab size.
  icon.svg           full mark with its squircle, rim and cast shadow. Owns the
                     browser PNGs declared `purpose: any`, and the OG card.
  icon-fullbleed.svg same artwork with the squircle, the transparent gutter, the
                     rim and the cast shadow removed. Owns apple-touch-icon and
                     any maskable manifest icon, because iOS and Android apply
                     their own corner mask. Feed those icon.svg and you get a
                     rounded tile floating inside another rounded tile with a
                     transparent gutter and a shadow smeared along one edge.

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
FLAT = os.path.join(DESIGN, "favicon.svg")          # under 32 px
FULL = os.path.join(DESIGN, "icon.svg")             # squircle, corners wanted
BLEED = os.path.join(DESIGN, "icon-fullbleed.svg")  # platform applies the mask
STAGE = os.path.join(HERE, ".stage")

# (output name, size, source)
RENDERS = [
    ("icon-16.png", 16, FLAT),
    ("icon-32.png", 32, FLAT),
    ("icon-48.png", 48, FLAT),
    ("icon-192.png", 192, FULL),
    ("icon-512.png", 512, FULL),
    ("apple-touch-icon.png", 180, BLEED),
    ("icon-maskable-512.png", 512, BLEED),
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
    for src in (FLAT, FULL, BLEED):
        shutil.copy(src, os.path.join(STAGE, os.path.basename(src)))

    for out, size, src in RENDERS:
        name = os.path.basename(src)
        wrap = os.path.join(STAGE, f"r-{out}.html")
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
        page.screenshot(path=os.path.join(HERE, out), omit_background=True)
        page.close()
        print(f"  {out:24s} {size:>4} px  from {name}")


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
    for name in ("apple-touch-icon.png", "icon-192.png", "icon-512.png",
                 "icon-maskable-512.png", "og.png"):
        shutil.copy(os.path.join(HERE, name), os.path.join(SITE, name))

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
