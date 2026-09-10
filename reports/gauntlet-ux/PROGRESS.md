# Gauntlet: UI, setup ease, installer, icon — live progress

Started 2026-09-11 00:20. Bar: `BAR.md` in this folder. Branch: `worktree-qa-finalize-ux`.

## Baseline (before any round)

| Check | Result |
|---|---|
| Tests | 387 executed, 0 failures (Xcode toolchain) |
| Held-out harness | desk 20/20, soft 20/20, lap 16/20, 0 FP, p95 208.9 ms, VERDICT FAIL — matches RESUME |
| Build with Command Line Tools only | **fails**: `plugin for module 'SwiftUIMacros' not found` on every `@State` |
| Build with Xcode toolchain | passes |
| `dist/build-app.sh` in a fresh clone | **absent**: `dist/` is gitignored, only the local checkout has it |
| First-run onboarding | none; a permission card appears inside Settings when a grant is missing |
| Settings | one column, seven cards, ~4100 px tall at 2x; experiments visible on the first screen |
| Icon | vector squircle, two amber discs, opaque tile |

## Pieces and rounds

| Piece | Round | Critic verdict | Biggest gap named |
|---|---|---|---|
| onboarding + menu | — | not started | — |
| settings IA | — | not started | — |
| installer + docs | — | not started | — |
| icon | 1 | bar wins: I1 pass, I2 marginal, I3 pass | centre emboss ring reads as a nose at 128 px and below |
| icon | 2 | bar wins: I1 FAIL (icns still the ring draft: my build was cut short by a `\| head` pipe), I2 marginal, I3 pass | icns not rebuilt from the ring-free source |
| icon | 3 | icns rebuilt from `gpt-icon-v4-noring.png`, 1024 member pixel-identical to `design/icon-1024.png`; I2 stays marginal by design (two lit dots read as eyes next to object icons; the identity accepts that) | — |

Rounds append below as they land.
