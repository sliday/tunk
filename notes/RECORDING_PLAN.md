# Recording plan

The one thing no agent can do. Everything else in this build is verifiable by
machine; the ground truth is not. `tunk-capture guide` walks you through each
block hands-free — it speaks the instructions and beeps when it wants a tap, so
you never need to look at the screen or touch the keyboard mid-block.

Ordered by value. **Block A alone unblocks the loop.** If you stop after it, the
run continues on desk-only data and the critics will say so explicitly rather
than quietly pretending the other surfaces passed.

## Block A — desk, the core set (~14 min)

The minimum that lets tuning start.

| # | Command | Time |
|---|---|---|
| A1 | `tunk-capture guide --category tap_palmrest --surface desk` | 2 min |
| A2 | `tunk-capture guide --category tap_deck --surface desk` | 2 min |
| A3 | `tunk-capture guide --category tap_bottom --surface desk` | 2 min |
| A4 | `tunk-capture guide --category typing --surface desk --duration 300` | 5 min |
| A5 | `tunk-capture guide --category trackpad --surface desk --duration 120` | 2 min |
| A6 | `tunk-capture guide --category idle --surface desk --duration 60` | 1 min |

A4 is the make-or-break recording. Type real prose, at your normal speed, with
your normal force. No deliberate taps. If you tap by accident, say so out loud —
the tool records an operator mark — and keep going.

## Block B — confounds, desk (~9 min)

Every one of these must produce zero triggers. This is where a naive detector dies.

| # | Command | What to do |
|---|---|---|
| B1 | `... --category confound_mug --surface desk --duration 90` | set a mug down near, then on, the desk. Vary how hard. |
| B2 | `... --category confound_lid --surface desk --duration 90` | slam a browser tab shut, hard Return presses, nudge the lid |
| B3 | `... --category confound_phone --surface desk --duration 90` | phone on the same desk, ring it a few times |
| B4 | `... --category confound_music --surface desk --duration 120` | bass-heavy track, loud enough to feel through the desk |
| B5 | `... --category confound_footfall --surface desk --duration 90` | someone walks past on the timber floor. Stamp if alone. |
| B6 | `... --category confound_handling --surface desk --duration 90` | reposition, lift, put down, plug and unplug a cable |

## Block C — soft surface (~11 min)

Laptop on a bed or cushion. Coupling changes a lot here; this is where a fixed
threshold falls apart.

C1–C3: the three tap categories. C4: typing, 240 s. C5: idle, 60 s.
C6: `confound_handling`, 90 s.

## Block D — lap (~11 min)

Same six as Block C, `--surface lap`. Your body damps the chassis heavily. If
detection turns out to be physically unreachable here, the critic reports that
with the data rather than relaxing the number.

## Block E — holdout (~12 min)

**Recorded last, and I never look at it during tuning.** Same shape as Block A
plus one confound, but written to `data/holdout/` with `--split test`. Every
number that decides pass or fail comes from these recordings.

| # | Command |
|---|---|
| E1 | `tunk-capture guide --category tap_palmrest --surface desk --split test` |
| E2 | `tunk-capture guide --category tap_deck --surface soft --split test` |
| E3 | `tunk-capture guide --category tap_bottom --surface lap --split test` |
| E4 | `tunk-capture guide --category typing --surface desk --duration 300 --split test` |
| E5 | `tunk-capture guide --category typing --surface lap --duration 180 --split test` |
| E6 | `tunk-capture guide --category confound_music --surface desk --duration 120 --split test` |

## Ground rules

- **Tap the way you actually would.** Do not perform an exaggerated tap to help
  the detector. A dataset of theatrical taps produces a detector that only fires
  for theatrical taps, and the felt-reliability test at the end will fail.
- One beep, one double-tap. Rest between prompts is randomised so the labeller
  cannot cheat off a fixed period.
- If a prompt goes wrong, say what happened out loud and carry on. The tool logs
  an operator mark and that group gets dropped rather than mislabelled.
- Note the surface in `--notes` if it is unusual (glass desk, thick duvet).

## Total

Roughly 57 minutes of recording, in blocks you can spread out. Block A is 14 of
those and is the one that matters most.
