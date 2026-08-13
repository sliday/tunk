#!/usr/bin/env bash
# Rasterise the Tunk marks: the app icon PNG set, the .iconset and AppIcon.icns, the
# menubar glyph, the favicon, and the full-bleed variant for home-screen icons.
#
# Every size is rendered from the vector rather than downscaled from 1024, so the 16 and
# 32 px versions get real hinting off the gradients instead of a blurred 1024.
# Run from anywhere; paths resolve against this file.
#
#   ./design/build-icons.sh
#
# Needs one SVG rasteriser. In order of preference:
#   brew install librsvg      # rsvg-convert, best gradient fidelity
#   brew install resvg
#   brew install --cask inkscape
#   Google Chrome             # headless fallback, no install needed
# iconutil and sips ship with macOS.
#
# Do NOT substitute ImageMagick's built-in SVG renderer. It flattens the gradients.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/icon.svg"
OUT="$DIR/png"
ICONSET="$DIR/AppIcon.iconset"
SIZES=(16 32 64 128 256 512 1024)

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

RENDERER=""
for candidate in rsvg-convert resvg inkscape; do
  if command -v "$candidate" >/dev/null 2>&1; then RENDERER="$candidate"; break; fi
done
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -z "$RENDERER" ] && [ -x "$CHROME" ]; then RENDERER="chrome"; fi
if [ -z "$RENDERER" ]; then
  echo "no SVG rasteriser found. brew install librsvg" >&2
  exit 1
fi
echo "renderer: $RENDERER"

render() { # render <source.svg> <size> <destination.png>
  local src="$1" size="$2" dest="$3"
  case "$RENDERER" in
    rsvg-convert) rsvg-convert -w "$size" -h "$size" -o "$dest" "$src" ;;
    resvg)        resvg -w "$size" -h "$size" "$src" "$dest" ;;
    inkscape)     inkscape "$src" --export-type=png --export-filename="$dest" \
                    -w "$size" -h "$size" >/dev/null 2>&1 ;;
    chrome)
      local tmp; tmp="$(mktemp -d)"
      cp "$src" "$tmp/art.svg"
      cat > "$tmp/wrap.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;padding:0;background:transparent}
img{display:block;width:${size}px;height:${size}px}</style>
<img src="art.svg">
HTML
      "$CHROME" --headless --disable-gpu --hide-scrollbars \
        --default-background-color=00000000 \
        --force-device-scale-factor=1 \
        --window-size="${size},${size}" \
        --screenshot="$dest" "file://$tmp/wrap.html" >/dev/null 2>&1
      rm -rf "$tmp"
      ;;
  esac
}

rm -rf "$OUT" "$ICONSET"
mkdir -p "$OUT" "$ICONSET"

for s in "${SIZES[@]}"; do
  render "$SRC" "$s" "$OUT/icon-${s}.png"
  echo "  png/icon-${s}.png"
done

# Apple's naming. The @2x files are the next size up, same pixels.
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

# Menubar glyph, at the sizes AppKit asks for.
if [ -f "$DIR/menubar-glyph.svg" ]; then
  for s in 18 36 54; do
    render "$DIR/menubar-glyph.svg" "$s" "$OUT/menubar-${s}.png"
    echo "  png/menubar-${s}.png"
  done
fi

# Favicon. Flat by design. 16 is the size that decides whether it works at all.
if [ -f "$DIR/favicon.svg" ]; then
  for s in 16 32 48 192; do
    render "$DIR/favicon.svg" "$s" "$OUT/favicon-${s}.png"
    echo "  png/favicon-${s}.png"
  done
fi

# Full bleed, for apple-touch-icon and maskable manifest icons only. iOS and Android
# apply their own corner mask; giving them the squircle version nests one rounded tile
# inside another with a transparent gutter.
if [ -f "$DIR/icon-fullbleed.svg" ]; then
  for s in 180 192 512; do
    render "$DIR/icon-fullbleed.svg" "$s" "$OUT/fullbleed-${s}.png"
    echo "  png/fullbleed-${s}.png"
  done
fi

echo
echo "open $DIR/contact-sheet.html to review the small sizes"
