# Image generation prompts

**None were run.** This session had no image generation tool, and no Bash to reach one.
Every vector in `design/` was authored by hand in SVG. Nothing here was traced from,
guided by, or composited with a generated raster.

The file exists anyway because the brief asked for it, and because the mood exploration
is still worth doing — hand-authored gradients are a guess about how light behaves on
anodised aluminium, and a generated plate would either confirm that guess or correct it.

## If the tool becomes available

These are for **mood and lighting reference only**. Nothing generated ships. The shipped
icon stays vector; a generated raster has soft edges and cannot survive 16 px.

**P1 — the material.** Macro photograph of a space-grey anodised aluminium MacBook palm
rest, lit from directly above by a single soft rectangular source, shallow depth of field,
no reflections of a room, no logo, no keys in frame. Cool grey with a faint blue cast.
Studio product photography, 85mm, f/4.
*Answers: is my `#333944 → #101216` body ramp too blue, and is the top-light radial too wide?*

**P2 — the strike.** A single point of warm amber light blooming out of a brushed metal
surface seen edge on, as if the metal itself were glowing from an impact underneath.
Black background, no lens flare, no sparks, no fire. Long exposure, amber only.
*Answers: how far does the bloom actually spread relative to the hot core, and does the
metal go white at the contact point or stay amber?*

**P3 — the shock.** Cross-section illustration of a compression wave travelling downward
through a solid plate from a point impact on its top face. Scientific diagram aesthetic,
concentric wavefronts, monochrome amber on near-black, no labels, no arrows.
*Answers: do real wavefronts stay circular or flatten, and how fast does amplitude fall
across three rings? My arcs guess at 0.34 / 0.19 / 0.10.*

**P4 — the shelf test.** A row of twelve macOS Dock icons at 128 px, one of them amber on
graphite, the rest typical blue and white utility icons.
*Answers the only question that matters commercially: does amber-on-graphite stand out in
a Dock, or does it disappear the way dark icons usually do?*

## What I would change based on each

P1 and P2 feed the gradient stops in `icon.svg` directly. P3 feeds the arc opacities and
radii. P4 is a go / no-go on the amber accent itself; if Tunk vanishes in a Dock row, the
body ramp lightens rather than the amber getting louder, because a louder amber is the one
change that would break the 16 px render.
