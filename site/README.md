# tunk.dev — the marketing site

Static HTML and CSS. No framework, no build step, no bundler. Open `index.html`
straight from the filesystem and it renders correctly, including the fonts,
because every asset is local.

One inline `<script>` runs an `IntersectionObserver` for the section entrances.
With JavaScript off, nothing is ever hidden: the CSS only hides `.enter`
elements under `[data-anim="on"]`, and that attribute is set by the script
itself.

## Deploy

Upload the contents of this directory to any static host, root of the domain.

```bash
# Cloudflare Pages
wrangler pages deploy site --project-name tunk

# Netlify
netlify deploy --dir=site --prod

# GitHub Pages, S3, nginx: copy the directory, nothing to configure
```

Then check `https://tunk.dev/og.png`, `/robots.txt`, `/sitemap.xml` and
`/llms.txt` all resolve at the root. The `<head>` references them with absolute
paths, so serving the site from a sub-path needs those five `/`-prefixed
`href`s changed.

### Local preview

```bash
cd site && python3 -m http.server 8931
```

Opening `index.html` by double-clicking also works. The service worker-free,
JSON-LD-only setup has no origin requirements.

## Files

| File | What it is |
|---|---|
| `index.html` | The page. Semantic sections, `SoftwareApplication` and `FAQPage` JSON-LD, full Open Graph and Twitter card metadata. |
| `styles.css` | Every visual rule. Tokens come from `../design/IDENTITY.md`. |
| `llms.txt` | Plain-text summary for language models, per the llmstxt.org convention. Kept in sync with the page by hand. |
| `robots.txt`, `sitemap.xml` | Standard. Both point at `https://tunk.dev/`. |
| `fonts/inter-latin-var.woff2` | Inter variable, latin subset, weights 400–600, 47 KB. Self-hosted so the page has no third-party requests. |
| `vendor/daub.css` | The DAUB component library. See the note below. |
| `tools/` | The scripts that generate every generated asset. Not deployed. |

### `tools/`

| Script | What it does |
|---|---|
| `plot-trace.py` | Reads `data/raw` and writes `img/trace-real.svg`. Pure stdlib. |
| `render-assets.py` | Renders the favicon set from `design/icon.svg` and composes `og.png`, then installs both into `site/`. Needs `playwright` and `magick`. |
| `og-template.html` | The Open Graph layout that `render-assets.py` screenshots. |
| `gen-images.py`, `gen-hero2.py` | The gpt-image-2 calls that produced the photographs, prompts included. Need `OPENAI_API_KEY`. |

```bash
cd site/tools
python3 plot-trace.py       # after new recordings land
python3 render-assets.py    # after design/icon.svg changes
```

Do not deploy `tools/`. It is source, not site.

### Generated assets

| Asset | Size | How it was made |
|---|---|---|
| `og.png` | 1200 × 630 | Composed in Chromium from an HTML template, over `img/hero@2x.jpg` with the app icon and wordmark. |
| `favicon.ico` | 16, 32, 48 | Three sizes packed with ImageMagick, each rendered separately from `design/icon.svg`. |
| `favicon.svg` | vector | Copied from `design/icon.svg`'s flat sibling `design/favicon.svg`. Browsers that support SVG icons take this; the `.ico` is the fallback. |
| `apple-touch-icon.png` | 180 × 180 | Rendered from `design/icon.svg`. |
| `icon-16/32/192/512.png` | as named | Rendered from `design/icon.svg`, each size drawn from the vector rather than downscaled from 1024, so the small ones keep their edges. |
| `site.webmanifest` | — | Hand-written. |
| `img/trace-real.svg` | 1200 × 476 | Generated from the real dataset. See below. |
| `img/hero.jpg`, `hero@2x.jpg` | 720 / 1440 wide | gpt-image-2, then cropped and converted. |
| `img/gesture.jpg`, `gesture@2x.jpg` | 720 / 1440 wide | gpt-image-2. |
| `img/surface.jpg`, `surface@2x.jpg` | 600 / 1200 wide | gpt-image-2. |

The icons are re-cut by rendering `design/icon.svg` in headless Chromium at each
size, then packing the `.ico`. ImageMagick's own SVG renderer flattens the
icon's gradients into mud and must not be used for this.

**If `design/icon.svg` changes, the whole favicon set and `og.png` need
regenerating.** They are snapshots, not references.

## The images, and what produced them

Three photographs were generated with OpenAI **`gpt-image-2`** at `quality: high`,
then cropped and converted to progressive JPEG with ImageMagick. Nothing was
photographed and nothing was licensed from a stock library.

**`img/hero.jpg`** — the hero.

> Photograph, close three-quarter view of an open modern space-grey aluminium
> laptop on a warm oak desk in soft daylight from a window on the left. A
> person's right hand rests to the right of the laptop with index and middle
> fingertips touching the bare machined aluminium of the palm rest, in the empty
> metal area to the RIGHT of the trackpad, well clear of the trackpad and well
> clear of every key. Wide bare metal between the fingertips and the trackpad
> edge. The trackpad is fully visible, empty and untouched. Shallow depth of
> field, fingertips and palm rest sharp, screen dark and off, background falling
> away soft. No logos, no text, no screen content, no graphics, no overlay.
> Editorial product photography, natural light, calm neutral colour.

The first attempt put the fingertips on the trackpad. That contradicts the
product: Tunk suppresses detection while the trackpad is being touched, so a
photograph of someone tapping the trackpad illustrates the one place the gesture
does not work. The prompt above is the corrected second attempt, and the
insistence on bare metal is the whole point of it.

**`img/gesture.jpg`** — the dictation section.

> Photograph, tight overhead macro of two fingertips resting on the brushed
> aluminium palm rest of a laptop, seen from directly above, the fingers
> entering from the right edge of the frame. Soft north light, fine machining
> grain visible in the metal, subtle warm shadow under the knuckles. Muted
> neutral palette, generous empty metal surface on the left half of the frame.
> No screen, no keyboard keys, no logos, no text, no graphics.

**`img/surface.jpg`** — inside the "not measured yet" panel.

> Photograph, low three-quarter view of a closed space-grey aluminium laptop
> lying on a linen bedspread in soft evening light, seen from just above the
> surface so the folds of fabric run out of focus into the background. Emphasis
> on the machined edge of the lid against the soft textile. Muted neutral
> colour, quiet, editorial. No logos, no text, no graphics, nothing on screen.

It illustrates a claim the site explicitly does not make. Soft surfaces are on
the unmeasured list, and the caption says so.

## `img/trace-real.svg` is real data

The two traces are plotted directly from `data/raw`, by a script that reads the
28-byte `accel.bin` records described in `FORMAT.md`.

- **Upper trace** — 60 s starting at t = 505 s of
  `idle__desk__20260813-213857__75bdf7`, a 25-minute recording of the machine
  running Swift builds on a hard desk. Peak deviation about 74 mg.
- **Lower trace** — the full 90 s of
  `confound_music__desk__20260813-213400__93cb8f`, layered 45, 60 and 80 Hz bass
  through the desk. Peak about 3 mg.

Both rows share one vertical scale, so the comparison between them is honest.
The only reduction is a min and max envelope per pixel column, which preserves
every peak rather than averaging it away. The vertical axis is deviation from
the window's mean magnitude, in milli-g.

**There is no tap in the figure, and none is drawn.** The dataset has no
labelled tap sessions yet, and inventing a plausible-looking transient would be
exactly the thing the rest of this page refuses to do.

To regenerate after new recordings land, re-run the plotting script against the
session paths listed at the top of it. Update the `height` attribute on the
`<img>` in `index.html` if the row count changes.

## About DAUB

The site was started on [DAUB](https://daub.dev), which is vendored at
`vendor/daub.css` and used for the key caps in the "what a tap can fire"
section. Its `--db-*` tokens are remapped in `styles.css`, so it wears Tunk's
graphite and amber rather than its own cream and terracotta.

It is not used more widely, and that is worth explaining rather than leaving as
a silent choice. `design/IDENTITY.md` specifies the visual system at a level
DAUB does not reach: outer radius equals inner radius plus padding on every
nested container, one amber element per viewport, an amber glow on exactly one
control per screen, a 0.96 press scale matching the SwiftUI panel. Applying
those to a DAUB card means overriding its radius, padding, shadow and colour,
at which point nothing of the original rule remains. Rather than ship 152 KB of
stylesheet whose every declaration is overridden, the page implements the
IDENTITY spec directly and takes from DAUB only the component that fits as
shipped.

Ways to change that, if wanted:

- **Use more DAUB.** Its accordion, tabs and toast are all sound. They would
  need the same token remapping, which is already in `styles.css`.
- **Drop it entirely.** Delete `vendor/`, remove one `<link>`, and replace the
  four `.db-kbd` elements with a local class. Saves 152 KB.

## Honesty rules this page follows

The project has a standing rule against stating unverified things as measured,
and the page is built to it.

**Stated, because they were measured on real recordings on one M4 Max MacBook
running macOS 26.5:** 796 Hz sample rate, 0.34 ms p95 sensor-to-callback
latency, 0 false triggers across 28 minutes of recorded desk use, about 2% idle
CPU.

**Deliberately absent, and named as absent in their own panel:** detection rate,
end-to-end latency, typing false-positive rate, behaviour on soft surfaces or on
a lap, behaviour on any other MacBook, battery cost.

There is no download button, because there is nothing to download. The call to
action follows the build on GitHub, and the page says the repository is private.

If you add a number here, add it to `llms.txt` and to the FAQ JSON-LD in the
same commit, or the three will drift apart and an answer engine will quote the
stale one.

## Open decisions for the owner

- **The call to action.** It points at `https://github.com/sliday/tunk`, which is
  private, so a visitor following it today gets a 404. No email address was
  invented for a mailing list. Both the button and the note under it are in the
  hero and repeated in the closing section; a real mailing-list URL can replace
  them in four places.
- **`og:locale` is `en_GB`,** matching the page's spelling.
