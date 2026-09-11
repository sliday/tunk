# Brand, captured for design explorations

The `explore-design` skill from danny.md wants a brand captured before any
exploration is drawn. Tunk already has one, written down before this page
existed: `design/IDENTITY.md` governs the site, `UI_STANDARD.md` governs the
app. This file is the short version the explorations wear, quoted from those
two so the three cannot drift.

## Palette

Three families. Graphite is the room, aluminium is the object, amber is the
event.

| Token | Hex | Used for |
|---|---|---|
| `--ink-000` | `#0B0D10` | dark page background |
| `--ink-200` | `#16191E` | dark card surface; light-mode text |
| `--ink-400` | `#2C313A` | dark hairline |
| `--ink-900` | `#E8EAED` | dark-mode primary text |
| `--ink-950` | `#F4F6F8` | light page background |
| `--alu-300` | `#B4BBC3` | lit metal edge falloff |
| `--alu-500` | `#79808A` | deck body |
| `--amber-300` | `#FFD98A` | bloom, the hot centre of a strike |
| `--amber-500` | `#FFB020` | **primary.** CTA fill, the live indicator |
| `--amber-600` | `#FF8A12` | gradient partner, glow colour |

**The restraint rule: one amber element per viewport.** Amber is an event, and
an event that happens six times at once is a background.

## Type

Inter, variable, 400 to 600. `--font-sans` falls back to the system stack.
Tabular figures on anything that counts: `font-variant-numeric: tabular-nums`.

## Form

- Concentric radius: outer radius equals inner radius plus padding.
- Shadows, not borders. Layer two or three at low alpha. A hard 1 px divider
  reads as a seam.
- Motion is interruptible and names its properties. Never `transition: all`.
- Honour `prefers-reduced-motion` by dropping to a cross-fade.

## What the mark must never say

Finger, hand, cursor, or accessibility icon. The identity is built from the
physics instead: a transient, a surface, a shock, two beats.

## Voice

Precise, physical, unhurried. Numbers are the persuasion: 796 Hz, 220 ms, p95
under 250 ms, zero false triggers while typing. Never "magic", "effortless",
or "just tap".
