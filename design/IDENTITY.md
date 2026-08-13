# Tunk — visual identity

Everything the marketing site at **tunk.dev** needs. This file stands alone: you should
never have to ask the designer a question to build from it.

It does not contradict `UI_STANDARD.md`, which governs the SwiftUI panel and the
engineering progress page. Where both speak, this file repeats the rule so you do not have
to hold two documents open. `UI_STANDARD.md` wins on the app; this file wins on the site.

---

## 1. What you are selling

You double-tap the body of your MacBook — palm rest, deck, bottom case — and it fires a
keyboard shortcut or runs a macOS Shortcut. Tunk reads the built-in accelerometer at
796 Hz and picks the deliberate double-tap out of everything else the laptop feels:
typing, trackpad clicks, a mug set down, footfall, bass through the desk.

The reference is **iPhone Back Tap**. Say that early on the page. It does the entire job of
explaining the product, and it borrows Apple's credibility for a gesture people already
trust.

**Tone.** Precise, physical, unhurried. Tunk is a measuring instrument that happens to be
convenient. Numbers are the persuasion: 796 Hz, 220 ms, p95 under 250 ms, zero false
triggers while typing. Lead with them. Do not write "magic", "effortless", "just tap".

**The one thing the design must never say:** finger, hand, cursor, or accessibility icon.
Those all read as something else. The identity is built from the physics instead — a
transient, a surface, a shock, two beats.

---

## 2. Palette

Three families. Graphite is the room, aluminium is the object, amber is the event.

### Graphite — the ground

| Token | Hex | Used for |
|---|---|---|
| `--ink-000` | `#0B0D10` | Dark page background |
| `--ink-100` | `#101216` | Dark section background, alternating band |
| `--ink-200` | `#16191E` | Dark card surface; light-mode primary text |
| `--ink-300` | `#20242B` | Dark card surface, raised |
| `--ink-400` | `#2C313A` | Dark hairlines, dark input fill |
| `--ink-500` | `#3D434D` | Dark disabled fill |
| `--ink-600` | `#5A616B` | Light-mode secondary text |
| `--ink-700` | `#868D96` | Light-mode tertiary text |
| `--ink-800` | `#9BA2AB` | Dark-mode secondary text |
| `--ink-900` | `#E8EAED` | Dark-mode primary text |
| `--ink-950` | `#F4F6F8` | Light page background |

### Aluminium — the machine

| Token | Hex | Used for |
|---|---|---|
| `--alu-100` | `#F2F5F8` | A lit metal edge. The brightest thing on a dark page after amber |
| `--alu-300` | `#B4BBC3` | Edge falloff |
| `--alu-500` | `#79808A` | Deck body |
| `--alu-700` | `#333941` | Deck body, in shadow |

Aluminium is the app icon's ground: the icon is a space-grey deck seen from above, with two
amber strikes on it. That is a deliberate value inversion away from the graphite mood —
the first icon was graphite on graphite and measured 37/255 mean luminance, which is a
blank tile at 16 px. The shipped mark measures 106 and holds that flat from 16 to 256. Use
aluminium anywhere you are depicting the machine or a surface being struck. Do not use it
for ordinary dividers; see the shadow rule below, ordinary dividers should not exist.

### Amber — the tap

| Token | Hex | Used for |
|---|---|---|
| `--amber-300` | `#FFD98A` | Bloom, the hot centre of a fresh strike |
| `--amber-400` | `#FFC24D` | Icon core highlight, hover state of a primary button |
| `--amber-500` | `#FFB020` | **Primary.** CTA fill, the live indicator, links on dark |
| `--amber-600` | `#FF8A12` | Gradient partner for 500, glow colour |
| `--amber-700` | `#F0700A` | Pressed state, links on light (500 fails contrast on white) |

**The restraint rule: one amber element per viewport.** Amber is an event, and an event
that happens six times at once is a background. If a section has an amber CTA, its
diagram is aluminium and graphite only. This single rule does more for the page than any
other line in this file.

### Semantic

| Token | Light | Dark | Used for |
|---|---|---|---|
| `--ok` | `#248A3D` | `#30D158` | A metric that passed |
| `--bad` | `#D70015` | `#FF453A` | A metric that failed, a blocked permission |

**There is deliberately no warning colour.** Any amber warning would collide with the
brand and make the CTA look like an error. Anything that would have been a warning uses
`--bad` at low emphasis, or plain `--ink` text with an icon.

### Ready to paste

```css
:root {
  color-scheme: light dark;

  --ink-000:#0B0D10; --ink-100:#101216; --ink-200:#16191E; --ink-300:#20242B;
  --ink-400:#2C313A; --ink-500:#3D434D; --ink-600:#5A616B; --ink-700:#868D96;
  --ink-800:#9BA2AB; --ink-900:#E8EAED; --ink-950:#F4F6F8;

  --alu-100:#F2F5F8; --alu-300:#B4BBC3; --alu-500:#79808A; --alu-700:#333941;

  --amber-300:#FFD98A; --amber-400:#FFC24D; --amber-500:#FFB020;
  --amber-600:#FF8A12; --amber-700:#F0700A;

  /* light mode assignments */
  --bg:var(--ink-950); --surface:#FFFFFF; --surface-2:#FFFFFF;
  --text:var(--ink-200); --text-2:var(--ink-600); --text-3:var(--ink-700);
  --accent:var(--amber-500); --accent-text:var(--amber-700);
  --on-accent:#1A1206;
  --hair:rgba(0,0,0,0.10);
  --ok:#248A3D; --bad:#D70015;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg:var(--ink-000); --surface:var(--ink-200); --surface-2:var(--ink-300);
    --text:var(--ink-900); --text-2:var(--ink-800); --text-3:var(--ink-600);
    --accent:var(--amber-500); --accent-text:var(--amber-400);
    --on-accent:#1A1206;
    --hair:rgba(255,255,255,0.10);
    --ok:#30D158; --bad:#FF453A;
  }
}
```

**Text on amber is `--on-accent` `#1A1206`, never white.** White on `#FFB020` is about
1.9:1 and fails everything. Near-black on amber is about 11:1.

**Amber as a link colour on a light background must be `--amber-700` `#F0700A`**, which is
about 3.4:1 on `#F4F6F8` — enough for large text and UI, not enough for body copy. For
body-copy links on light, use `--text` with an underline and let hover bring the amber.

**Image outlines**, per `UI_STANDARD.md`: `outline: 1px solid rgba(0,0,0,0.1)` on light,
`rgba(255,255,255,0.1)` on dark. Pure black and pure white, never a tinted neutral. Do not
apply this to `icon.svg` renders — the icon carries its own rim and cast shadow, and a
second outline reads as a mistake.

---

## 3. Type

Two families. No third.

```css
--font-sans: "Inter", -apple-system, BlinkMacSystemFont, "SF Pro Text",
             "Segoe UI", system-ui, sans-serif;
--font-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo,
             "DejaVu Sans Mono", Consolas, monospace;
```

Self-host **Inter** as a variable `woff2`, subset to latin, `font-display: swap`, weights
400–600 only. The fallback stack is real: on a Mac before the font loads, and on a Mac with
the request blocked, `-apple-system` gives SF Pro, which is close enough in metrics that
the swap does not reflow badly.

Never load a 700. Inter 700 sits heavy next to SF and the page starts shouting. Headings
are 600.

`--font-mono` is not webfont-loaded. It carries key names (`⌃⌥⌘V`), file paths, and metric
values, all of which look correct in the platform mono and cost nothing.

### Scale

Mobile first. Desktop values in parentheses apply at `min-width: 768px`.

| Role | Size / line | Weight | Tracking |
|---|---|---|---|
| Display | 40 / 44 (72 / 76) | 600 | `-0.03em` |
| H1 | 32 / 38 (48 / 54) | 600 | `-0.025em` |
| H2 | 24 / 30 (32 / 38) | 600 | `-0.02em` |
| H3 | 20 / 28 (24 / 32) | 600 | `-0.015em` |
| Body large | 18 / 28 | 400 | `0` |
| Body | 16 / 26 | 400 | `0` |
| Small | 14 / 22 | 400 | `0` |
| Tiny | 12 / 18 | 400 | `0.005em` |
| Eyebrow | 12 / 16 | 600 | `0.08em`, uppercase |
| Metric | 32 / 36 (44 / 48) | 600 | `-0.02em`, `--font-mono` |

**Every number that could change gets `font-variant-numeric: tabular-nums`.** Metric
tables, the latency figure, the sample rate, anything counting. This is in
`UI_STANDARD.md` for the app and it applies just as hard on the site.

`text-wrap: balance` on every heading. `text-wrap: pretty` on every paragraph.
`-webkit-font-smoothing: antialiased` on `:root`.

Measure: `max-width: 68ch` on prose, `1120px` on the page container.

### The wordmark

**Tunk**, Inter 600, tracking `-0.03em`. Sentence case with a capital T. No custom
lettering, no logotype file — the mark is the icon, the wordmark is just type set well.

Lockup: favicon mark on the left, wordmark on the right, gap equal to 0.5× the mark's
height, and align the **centre line of the two amber strikes** to the wordmark's x-height
centre rather than centring the two boxes. Box-centring puts the wordmark slightly low,
because the mark's strikes sit above its own centre.

Do the arithmetic, then render the candidates at 6× and pick by eye. At the shipped size —
mark 30 px, Inter 600 at 20 px — the arithmetic asks for `-2.24 px` and the answer is
**`-2 px`**: within a quarter pixel of the maths, on a whole pixel, and the one that looks
right. Take the whole pixel when it is that close. Recompute if either size changes.

---

## 4. Spacing

Base unit 4. Use the scale, not arbitrary values.

```
4  8  12  16  24  32  48  64  96  128  160
```

| Situation | Mobile | Desktop |
|---|---|---|
| Between sections | 64 | 128 |
| Section heading to its content | 24 | 32 |
| Card padding | 24 | 32 |
| Between cards in a grid | 16 | 24 |
| Inside a button, vertical / horizontal | 12 / 20 | 12 / 24 |
| Paragraph to paragraph | 16 | 16 |
| Page gutter | 20 | 32 |

**Minimum hit area 40 × 40.** Extend the hit region with padding or a pseudo-element
rather than growing the visible control, and never let two hit areas overlap.

---

## 5. Radius

```
--r-xs: 6px    chips, key caps, inline code
--r-sm: 10px   buttons, inputs, small tiles
--r-md: 14px   inner tiles inside a card
--r-lg: 20px   cards
--r-xl: 28px   panels, media frames, the video well
--r-full: 999px pills, the availability badge
```

**Concentric rule, and it outranks the scale: outer radius = inner radius + padding.**

| Inner | Padding | Outer |
|---|---|---|
| 6 | 8 | 14 |
| 10 | 10 | 20 |
| 10 | 24 | 34 |
| 14 | 14 | 28 |

If the arithmetic gives you 34 and the scale offers 28, take the 34. Mismatched nesting is
the single most common thing that makes a panel look wrong, and nobody has ever noticed a
card being 34 instead of 28.

The app icon's own corner is a **continuous** corner, not a circular one — 824 body in a
1024 canvas, radius 184.32, Apple's squircle beziers. If you render a rounded rectangle
behind or beside the icon at a similar size, match it, or the difference reads as sloppy.

---

## 6. Depth

**Shadows, not borders.** A hard 1 px divider between sections reads as a seam. Layer two
or three low-alpha shadows instead.

```css
--shadow-1: 0 1px 2px rgba(0,0,0,0.06), 0 2px 8px rgba(0,0,0,0.05);
--shadow-2: 0 1px 2px rgba(0,0,0,0.07), 0 8px 24px rgba(0,0,0,0.08);
--shadow-3: 0 2px 4px rgba(0,0,0,0.08), 0 12px 32px rgba(0,0,0,0.10),
            0 32px 64px rgba(0,0,0,0.10);
--glow-amber: 0 0 0 1px rgba(255,176,32,0.35), 0 8px 32px rgba(255,138,18,0.25);
```

On dark backgrounds a black shadow does almost nothing, so a raised surface gets a top
inner hairline as well:

```css
@media (prefers-color-scheme: dark) {
  .card { box-shadow: inset 0 1px 0 rgba(255,255,255,0.06),
                      0 8px 32px rgba(0,0,0,0.45); }
}
```

`--glow-amber` goes on exactly one element per viewport, the same one that gets the amber
fill. It is the site's equivalent of the icon's bloom.

The only legitimate line on the page is a **deck**: a full-bleed `--alu-100` rule, 2–4 px,
representing the surface being struck. Use it once or twice, deliberately, as a section
device. Every other divider is a shadow or nothing.

---

## 7. Motion

Two ideas. Both come out of the product, neither is decoration.

### M1 — The double beat

Every entrance on the page animates in **exactly two chunks, 90 ms apart**. Not three, not
a cascade of eight. The pair is the brand, and once a visitor has scrolled two sections
they feel the rhythm without being told.

```css
.enter {
  opacity: 0; transform: translateY(8px);
  transition: transform 260ms cubic-bezier(0.2, 0, 0, 1),
              opacity   260ms cubic-bezier(0.2, 0, 0, 1);
}
.enter.in { opacity: 1; transform: none; }
.enter.beat-2 { transition-delay: 90ms; }
```

Split by meaning, not by container: heading is beat one, the supporting text and control
together are beat two. Exits use a small fixed offset (4 px), never the element's height,
and are quieter than enters.

**No animation on first paint.** Above-the-fold content renders settled. Add the `.enter`
class only to sections below the fold, and only from an `IntersectionObserver`.

### M2 — Shock into the surface

Press on any primary control:

```css
.btn { transition: transform 120ms cubic-bezier(0.2, 0, 0, 1),
                   background-color 120ms linear; }
.btn:active { transform: scale(0.96); }
```

`0.96`, never below `0.95` — same number as the app, so the site and the panel feel like
one product.

On release, one amber ring expands from the contact point:

```css
@keyframes shock {
  from { transform: translate(-50%,-50%) scale(0.25); opacity: 0.35; }
  to   { transform: translate(-50%,-50%) scale(1);    opacity: 0;    }
}
.ring { animation: shock 320ms cubic-bezier(0.2, 0, 0, 1) forwards;
        will-change: transform, opacity; }
```

Make the ring an **ellipse, `rx` about 1.6× `ry`**. A circular ripple reads as a signal
going outward through the air, which is the wrong story and is also what every Material
button does. A flattened ring reads as energy going down into a surface.

### M3 — Optional, for the hero only

The two strikes in the hero graphic land in sequence, **220 ms apart**. That is the app's
real join window (`maxInterTapNs`, see `notes/DECISIONS.md` D7), so the page's rhythm is
the product's actual timing rather than a number someone liked. Worth a caption.

### Rules that apply to all of it

- Never `transition: all`. Name the properties, every time.
- `will-change` only on `transform`, `opacity`, `filter`, and only where you have seen
  stutter.
- Interruptible. A visitor scrolling up and down fast must never watch a queue of
  animations drain.
- Icon and state swaps cross-fade with `cubic-bezier(0.2, 0, 0, 1)`, scale `0.25 → 1`,
  opacity `0 → 1`, blur `4px → 0`.

### Reduced motion

```css
@media (prefers-reduced-motion: reduce) {
  .enter { transition: opacity 120ms linear; transform: none; }
  .enter.beat-2 { transition-delay: 0ms; }
  .ring { display: none; }
  .hero-sequence { animation: none; }
}
```

Everything collapses to a 120 ms opacity cross-fade, the ring is suppressed, the hero
sequence shows its final frame.

**The `0.96` press scale stays.** It is a direct response to the visitor's own input, not
ambient movement, and removing it makes buttons feel dead. This is a deliberate reading of
the preference, not an oversight.

---

## 8. Using the icon

**The mark is a space-grey deck seen from above, struck twice.** Two amber impact points
own about two-thirds of the tile's width. There is no horizontal surface line — the tile
itself is the surface, which is what frees the strikes to be that large. The two strikes
have radii 128 and 104, a 1.23 ratio; unequal is load-bearing, because two equal discs at
equal height on a rounded tile read as a face. A single low-contrast embossed ring, centred
between the strikes rather than around either one, is the shock the plate carries; it is
the only element permitted to vanish below 128 px.

### Three sources, three jobs. Picking the wrong one is the usual way this goes wrong.

| Source | Cut these from it | Never |
|---|---|---|
| `favicon.svg` | `favicon.ico` at 16/32/48, the header mark, anything under 32 px | Anything large; it is flat and will look bare |
| `icon.svg` | Dock, Finder, `.icns`, `icon-192`, `icon-512`, the OG mark, anything 32 px and up that keeps its own corners | Home-screen icons, anything under 32 px |
| `icon-fullbleed.svg` | `apple-touch-icon.png`, `icon-maskable-512.png`, any manifest entry marked `"purpose": "maskable"` | The Dock or the `.icns` — it has no corners |

Supporting files: `png/` (built by `build-icons.sh`, every size from every source),
`AppIcon.icns` (the app bundle), `menubar-glyph.svg` (reference only, never a site logo),
`explorations/` (rejected directions including the graphite v1 — do not ship these).

**Why `icon-fullbleed.svg` exists.** `icon.svg` is an 824 body inside a 1024 canvas: a
squircle with a transparent gutter and a baked cast shadow. iOS and Android apply their
own corner mask to home-screen icons. Give them `icon.svg` and you get a rounded tile
floating inside another rounded tile, with a shadow smeared along one edge. The full-bleed
variant is the identical artwork scaled by `1024/824` about the centre with the squircle,
rim and shadow removed, so the two files share every coordinate and cannot drift.

**The manifest trap, which is separate and easy to miss.** Cutting the right PNGs is only
half of it — a manifest entry that *declares* `"purpose": "maskable"` while pointing at the
squircle PNG fails exactly the same way, and nothing on the page looks wrong until someone
adds the site to a home screen. Ship a distinct `icon-maskable-512.png` from
`icon-fullbleed.svg`, point the maskable entry at that file alone, and mark every other
entry `"purpose": "any"` explicitly.

### Check it mechanically, not by eye

Neither failure above is visible in a browser. Both are one assertion away:

- `apple-touch-icon.png` and `icon-maskable-512.png` must be **fully opaque** — alpha 1 in
  every corner pixel.
- `icon-512.png`, `icon-192.png` and every `.icns` member must have **alpha 0** in the
  corner. That gutter is the squircle and it belongs there.

Wire both into whatever cuts your assets. A rule in this document is a thing someone can
misread; an assertion in the build is not.

### The one number to protect

The two strikes must stay separable at the smallest size anything renders at. Below about
**1.4 px** of gap they fuse into one blob and the mark stops saying "double", which is the
entire product.

Two figures, and they measure different files. Keep them straight:

| File | Gap in its own grid | At 16 px | Role |
|---|---|---|---|
| `favicon.svg` | 7.5 units on 64 | **1.88 px** | **Assert on this one.** It is the file that actually renders below 32 px |
| `icon.svg` | 98 units on 1024 | 1.53 px, hypothetically | A design constraint on the master. `icon.svg` is never rendered at 16 px, so this is not a build check |

A guard that measures `icon.svg` and reports 1.53 is measuring a size that never ships.
Measure `favicon.svg`, and expect 1.88.

### Rasterising

Render every size **from the vector**, never by downscaling the 1024. Not with
ImageMagick's SVG renderer, which flattens the gradients into mud. Headless Chromium or
`rsvg-convert` both do it correctly; `build-icons.sh` will fall back through four options.

### Rules

- Never place `icon.svg` on an amber background. Amber on amber kills the only accent.
- Never add a border or outline to it, and never re-corner it with `border-radius`. It
  ships with its own rim and cast shadow, and at 106/255 mean luminance it holds its own
  edge on light and dark alike.
- Never recolour the ground toward graphite to "match the page". That was v1 and it
  measured 37/255, which is a blank tile at 16 px in a Dock.

### Open Graph

1200 × 630, `--ink-000` ground, mark cut from `icon.svg` at roughly 300 px on the left
third. Wordmark and one sentence on the right in `--ink-900`. Amber appears only on the two
strikes — nowhere else in the image, per the restraint rule. **No photograph behind it**:
it breaks the restraint rule and it roughly quadruples the file, because flat artwork
compresses and a photograph does not.

---

## 9. Page furniture

- **Hero.** Eyebrow ("macOS menubar utility"), display heading, one sentence, one amber
  CTA, one quiet secondary link. The iPhone Back Tap comparison lands in the sentence.
- **The gesture.** The hero graphic is the icon's story at full width: a deck, two strikes,
  the shock the plate carries. Animate per M3.
- **The numbers.** A metric strip in `--font-mono` with `tabular-nums`: 796 Hz, p95 latency,
  false triggers while typing, detection rate. Graphite and aluminium only — no amber here,
  the CTA already spent it.
- **What it can fire.** A hotkey, or any macOS Shortcut. Show key caps as `--r-xs` chips in
  `--font-mono`.
- **What it ignores.** Typing, trackpad, a mug, footfall, bass. This section sells the
  product harder than the feature list does, because everyone's first thought is "it will
  go off by accident".
- **Requirements.** Apple Silicon MacBook, Input Monitoring, Accessibility, no sandbox.
  State this plainly and early enough that nobody downloads and then discovers it.

Dark mode is the default mood of the brand, but build both and test both. `prefers-color-scheme`,
no toggle unless there is time.
