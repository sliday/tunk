# UI standard for Tunk

Two surfaces: the SwiftUI settings panel and menubar (`Sources/TunkApp/**`), and
the live progress page (`web/**`). Both are held to this. A UI critic checks it
against the built artifact, not against a description.

Tunk is a dense desktop utility, not a touch app. Where a rule offers a touch
number and a desktop number, take the desktop one.

## Both surfaces

**Concentric radius.** Outer radius = inner radius + padding. A 12 pt inner
control inside 8 pt of padding needs a 20 pt outer. Mismatched nesting is the
single most common thing that makes a panel look wrong.

**Optical over geometric alignment.** Centre icons by eye. A play triangle, a
chevron, and the Tunk menubar glyph all need a nudge that geometric centring will
not give you.

**Shadows, not borders.** Layer two or three low-alpha shadows for depth. A hard
1 px divider between sections reads as a seam.

**Interruptible motion.** State changes animate with something that can be
interrupted mid-flight. Reserve one-shot keyframes for sequences that genuinely
run once. A user toggling Tunk on and off quickly must never see a queue of
animations drain.

**Split and stagger enters.** Animate semantic chunks, not one container. ~100 ms
between chunks.

**Subtle exits.** Exit with a small fixed offset, not the full height of the
element. Exits are quieter than enters.

**Tabular numbers everywhere a number changes.** This matters more here than in
most apps: the tap monitor, the live latency readout, the sample-rate display and
the calibration counter all update continuously. Proportional digits make them
jitter.

**No animation on first paint.** Opening the settings panel should show it
settled, not mid-entrance.

**Never animate "all".** Name the properties.

**Minimum hit area 40 × 40 pt.** Extend the hit region rather than growing the
visible control. Hit areas must not overlap.

## SwiftUI panel specifics

| Principle | How it lands in SwiftUI |
|---|---|
| tabular numbers | `.monospacedDigit()` on every live readout |
| scale on press | `.scaleEffect(pressed ? 0.96 : 1)` — `0.96`, never below `0.95` |
| interruptible | `.animation(.snappy, value: state)`, not `withAnimation` keyframes |
| stagger | `.delay(Double(index) * 0.1)` on the chunk's transition |
| shadows | stacked `.shadow(color:radius:y:)`, low alpha |
| concentric | `RoundedRectangle(cornerRadius: inner + padding)` on the container |
| reduced motion | honour `@Environment(\.accessibilityReduceMotion)` and drop to a cross-fade |
| hit area | `.contentShape(Rectangle())` on a frame of at least 40 × 40 |

The tap monitor is the one piece of real-time UI. It shows onsets as they land.
Draw it as a decaying strength trace, not a number that flickers. Cap redraw at
display refresh; do not redraw at 796 Hz.

## Progress page specifics

Plain HTML and CSS, no build step, no framework. It gets opened on a phone
mid-run, so it must be readable at 390 px wide and must not need JavaScript to
show the current numbers.

| Principle | How it lands |
|---|---|
| font smoothing | `-webkit-font-smoothing: antialiased` on the root |
| heading wrap | `text-wrap: balance` |
| body wrap | `text-wrap: pretty` |
| metric tables | `font-variant-numeric: tabular-nums` |
| image outlines | `outline: 1px solid rgba(0,0,0,0.1)` light, `rgba(255,255,255,0.1)` dark — pure black and pure white, never a tinted neutral |
| icon swaps | cross-fade with `cubic-bezier(0.2, 0, 0, 1)`, scale `0.25 → 1`, opacity `0 → 1`, blur `4px → 0` |
| transitions | name the properties; never `transition: all` |
| `will-change` | only `transform`, `opacity`, `filter`, and only if you see stutter |

Dark mode via `prefers-color-scheme`, both modes tested. Metric trends per round
are the point of the page — a pass reads as pass at a glance, a regression is
obvious without reading numbers.

## Review output

Report changes as markdown tables grouped by principle, with **Before** and
**After** columns, citing file and property. Omit a table entirely if that
principle needed no change. Do not list findings as loose prose lines.
