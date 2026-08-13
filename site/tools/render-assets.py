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
import json
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

# Corner-alpha thresholds, IDENTITY.md section 8. A full-bleed render must have
# no transparent gutter for iOS or Android to double-mask; a squircle render must
# keep its own. Measured on the current set: full-bleed 1.000 and 0.996, squircle
# 0.000 to 0.004.
#
# These are thresholds, not equalities, and that matters. A full-bleed render
# antialiases its own corner pixel, so `alpha == 1` FAILS ON A CORRECT FILE, and
# `alpha == 0` fails on a correct 16 px squircle for the same reason. A check
# that cries wolf gets switched off, which is worse than no check.
OPAQUE_MIN = 0.95
TRANSPARENT_MAX = 0.05

# The gap between the two amber strikes must survive the smallest render, or the
# mark stops saying "double". IDENTITY.md section 8, "the one number to protect".
#
# Measured on favicon.svg, deliberately. IDENTITY section 8 gives two gap
# figures and they are not interchangeable:
#
#   favicon.svg   7.5 units on 64    1.88 px at 16 px   <- what ships at 16 px
#   icon.svg      98 units on 1024   1.53 px at 16 px   <- master constraint only
#
# icon.svg is never rendered at 16 px, so a guard reading it would be checking a
# size that never reaches a browser tab. If this ever reports 1.53, someone has
# pointed it at the wrong file.
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
        raise SystemExit(
            f"refusing to build: found {len(circles)} amber strikes in "
            f"{os.path.basename(FLAT)}, expected 2, so the gap cannot be "
            f"measured. If the mark was legitimately redrawn, update this "
            f"parser rather than deleting the check — an unverifiable mark "
            f"must not ship unverified. See IDENTITY.md section 8.")
    (cx1, r1), (cx2, r2) = sorted(circles)
    return ((cx2 - r2) - (cx1 + r1)) * size_px / units


def corner_alpha(path):
    """Alpha of the top-left pixel, 0.0 to 1.0."""
    out = subprocess.run(["magick", path, "-crop", "1x1+0+0", "-format", "%[fx:a]", "info:"],
                         capture_output=True, text=True, check=True)
    return float(out.stdout.strip())


def verify():
    """Assert every render carries the gutter its platform expects.

    Two independent failures share one visual symptom, so fixing either alone
    looks complete while the other still ships:

      wrong source   apple-touch-icon.png cut from icon.svg
      wrong manifest a `purpose: maskable` entry pointed at a squircle PNG

    Both surface only once someone adds the site to a home screen, which is why
    this is a build assertion and not a note in the README.
    """
    problems = []
    for out, size, src in RENDERS:
        a = corner_alpha(os.path.join(HERE, out))
        if src is BLEED:
            ok, want = a > OPAQUE_MIN, f"> {OPAQUE_MIN} (full bleed, platform masks it)"
        else:
            ok, want = a < TRANSPARENT_MAX, f"< {TRANSPARENT_MAX} (keeps its own squircle)"
        print(f"  {out:24s} corner alpha {a:.3f}  {'ok' if ok else 'FAIL'}")
        if not ok:
            problems.append(f"{out}: corner alpha {a:.3f}, expected {want}")

    # The manifest declaration fails identically to a wrong source, so check it too.
    manifest = json.load(open(os.path.join(SITE, "site.webmanifest")))
    bleed_outputs = {out for out, _, src in RENDERS if src is BLEED}
    for entry in manifest.get("icons", []):
        name = entry["src"].lstrip("/")
        if entry.get("purpose") == "maskable" and name not in bleed_outputs:
            problems.append(
                f"site.webmanifest declares {entry['src']} as maskable, but it is "
                f"not cut from icon-fullbleed.svg. Android will double-mask it.")

    if problems:
        raise SystemExit("refusing to install:\n  " + "\n  ".join(problems)
                         + "\nSee IDENTITY.md section 8.")


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
    if g < MIN_GAP_PX:
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
    verify()
    install()


main()
