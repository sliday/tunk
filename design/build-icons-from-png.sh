#!/usr/bin/env bash
# Build AppIcon.icns from a transparent 1024 px PNG instead of the SVG.
#
# The GPT image 2.5 drafts in design/mockups/ come back with a faint
# semi-transparent halo around the object. This strips it (alpha under 128 goes
# to 0), crops to the object, scales it to the 824 px body that icon.svg uses
# inside its 1024 canvas, centres it, and then cuts the iconset with sips.
#
#   ./design/build-icons-from-png.sh design/mockups/gpt-icon-v2.png
#
# Writes design/icon-1024.png (the cleaned source, tracked), design/png/icon-*.png,
# design/AppIcon.iconset/ and design/AppIcon.icns. Needs python3 with Pillow
# (pip3 install pillow) plus sips and iconutil, which ship with macOS.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?usage: build-icons-from-png.sh <transparent-1024.png>}"
CLEAN="$DIR/icon-1024.png"
OUT="$DIR/png"
ICONSET="$DIR/AppIcon.iconset"
BODY=824
CANVAS=1024

python3 - "$SRC" "$CLEAN" "$BODY" "$CANVAS" <<'PY'
import sys
from PIL import Image

src, dst, body, canvas = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
im = Image.open(src).convert("RGBA")
alpha = im.getchannel("A").point(lambda a: 0 if a < 128 else (255 if a >= 240 else a))
im.putalpha(alpha)
bbox = alpha.point(lambda a: 255 if a else 0).getbbox()
if not bbox:
    sys.exit("no opaque pixels in " + src)
obj = im.crop(bbox)
w, h = obj.size
scale = body / max(w, h)
obj = obj.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
out.paste(obj, ((canvas - obj.width) // 2, (canvas - obj.height) // 2), obj)
out.save(dst)
px = out.load()
corners = [px[0, 0][3], px[canvas - 1, 0][3], px[0, canvas - 1][3], px[canvas - 1, canvas - 1][3]]
print(f"cleaned {src} -> {dst}: object {obj.width}x{obj.height} of {canvas}, corners alpha {corners}")
PY

rm -rf "$OUT" "$ICONSET"
mkdir -p "$OUT" "$ICONSET"
for s in 16 32 64 128 256 512 1024; do
  sips -s format png -z "$s" "$s" "$CLEAN" --out "$OUT/icon-${s}.png" >/dev/null
  echo "  png/icon-${s}.png"
done

cp "$OUT/icon-16.png"   "$ICONSET/icon_16x16.png"
cp "$OUT/icon-32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$OUT/icon-32.png"   "$ICONSET/icon_32x32.png"
cp "$OUT/icon-64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$OUT/icon-128.png"  "$ICONSET/icon_128x128.png"
cp "$OUT/icon-256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$OUT/icon-256.png"  "$ICONSET/icon_256x256.png"
cp "$OUT/icon-512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$OUT/icon-512.png"  "$ICONSET/icon_512x512.png"
cp "$OUT/icon-1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"
echo "  AppIcon.icns"
echo
echo "open $DIR/contact-sheet.html to review the small sizes"
