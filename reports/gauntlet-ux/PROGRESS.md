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
| onboarding + menu | 1 | first critic: ours 8/8; a second fresh critic on the resumed run found B8 failing | B8: reopening onboarding after completion closed the window on the next run-loop turn |
| onboarding + menu | 2 | **ours wins** 8/8 | — |
| settings IA | 1 | bar wins 5/6 | S2: the settings-migration card put 'Confirm window', 'Gate window' on General |
| settings IA | 2 | **ours wins** 6/6 (migration card under Advanced, plain-words pointer on General) | — |
| installer + docs | 1 | bar wins 2/3 (B1, B9 pass) | B2: DMG from a fresh clone has no Finder window layout; Finder automation needs a GUI grant no agent can give |
| installer + docs | 2 | bar wins 2/3: the Finder AppleScript died on 'set arrangement' (-10006), a script error rather than a permission one | B2 |
| installer + docs | 3 | **ours wins** 4/4 (B1, B2, B9 + rules); DMG from a fresh clone mounts with layout | — |
| icon | 1 | bar wins: I1 pass, I2 marginal, I3 pass | centre emboss ring reads as a nose at 128 px and below |
| icon | 2 | bar wins: I1 FAIL (icns still the ring draft: my build was cut short by a `\| head` pipe), I2 marginal, I3 pass | icns not rebuilt from the ring-free source |
| icon | 3 | icns rebuilt from `gpt-icon-v4-noring.png`, 1024 member pixel-identical to `design/icon-1024.png`; I2 stays marginal by design (two lit dots read as eyes next to object icons; the identity accepts that) | — |

Rounds append below as they land.

## Stall

At about 01:20 the account hit its session limit (reset 05:00). Lost: installer round 2 builder, settings round 2 critic, smoothing, acceptance, 25 audit verifiers, the completeness critic. Resumed from cache at 07:55.

## Audit fix wave 1

Ten confirmed findings fixed on ten branches, each accepted by a fresh critic who reverted the fix to prove the test flips; merged with no conflicts, 408 tests, referee byte-identical. See `reports/audit/FIXES.md`.
