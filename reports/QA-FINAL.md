# Product QA, 2026-09-11

Branch `worktree-qa-finalize-ux`. Everything below was measured on this machine
in this session. Where something was not measured, it says so.

## The short version

The app a person installs is a different product than it was this morning. It
now has a first-run window that walks a non-technical owner through both
permissions, an installer they can double-click, a settings window with an
information architecture instead of one long scroll, and an icon that is not a
smiling face. Twenty-one defects in the shipped code path were found by fresh
critics, nineteen survived three-lens verification, fourteen are fixed.

The detector did not move. The held-out report is byte-identical to the
baseline, which is the point: none of this touched the numbers the PRD grades.

## What the owner still has to do

1. **The screen in front of you.** The freshly installed `/Applications/Tunk.app`
   is a new ad-hoc signature, so both permissions read as not granted even where
   the System Settings switch looks on. The window that just opened says which
   one is missing and offers Relaunch. If a switch is already on and the window
   still says not granted, take Tunk out of that list with the minus button and
   add `/Applications/Tunk.app` again.
2. **The tap runs.** Detection rate, latency and typing false triggers on live
   hardware need hands on the machine. `notes/RESUME.md` has the three commands.
3. **Lap still fails the bar** at 16 of 20 held out. Nothing here addressed that,
   and nothing here claims to.

## Verified numbers

| Measure | Baseline (34bcef2) | Now |
|---|---|---|
| Tests | 387, 0 failures | 413, 0 failures, none skipped |
| Held-out desk | 20/20 | 20/20 |
| Held-out soft | 20/20 | 20/20 |
| Held-out lap | 16/20 | 16/20 |
| False triggers | 0 | 0 |
| Latency p95 | 208.9 ms | 208.9 ms |
| Harness verdict | FAIL | FAIL |

The referee report is byte-identical across every merged fix except the two
lines that print the worktree path.

## The defect the owner hit, and why the app could not see a grant

Reported live: permissions granted in System Settings, no reaction from the app.
Three separate causes, all now closed.

| Cause | Evidence | Fix |
|---|---|---|
| The menu never redrew on a permission change | `AppDelegate` subscribed to `status`, `lastActionFailed` and `brokenBinding`, never to `permissions` | a fourth subscription |
| The menu never said which permission was missing | one string, "Blocked: permissions needed", for both | the status line names Input Monitoring or Accessibility |
| macOS answers Input Monitoring once per process | `IOHIDCheckAccess` is fixed for the life of the process, so a grant made while Tunk runs cannot arrive | the first-run window offers Relaunch whenever Input Monitoring reads as missing, and says why |

A fourth cause is macOS behaviour rather than a defect: a grant is keyed to the
app's signature, and an ad-hoc signed Tunk gets a new signature on every build.
The switch in the list then belongs to the copy that was replaced. The window
says so in the same card, with the two clicks that fix it.

`tunk --permissions [seconds]` prints both answers once a second. It carries its
own warning that a terminal launch reads the terminal's grants, not Tunk's,
because that reading is confidently wrong and nothing in the numbers reveals it.

## What was built

| Piece | Rounds | Final verdict | Evidence |
|---|---|---|---|
| First-run window and menubar | 2 | ours, 8 of 8 | 18 rendered states, live window, menu read through System Events |
| Settings information architecture | 2 | ours, 6 of 6 | 30 rendered panel states, General fits 611 pt |
| Installer and docs | 3 | ours, 4 of 4 | DMG built from a fresh clone, mounted, verified |
| Icon | 3 | two of three items pass | alpha, shelf test against system icons, 16 px read |

The icon's remaining mark is that two lit dots read as eyes beside object icons.
Both critics said it, both preferred it to the previous mark, which was a smile.

## The audit

Five fresh critics, one per subsystem, demonstrated defects only. Each finding
then went to three independent verifiers with different lenses: reproduce,
refute, and does-a-user-hit-it. Majority decided.

| Subsystem | Found | Confirmed |
|---|---|---|
| Detector | 4 | 4 |
| Key emission | 4 | 4 |
| Engine and sensor | 3 | 3 |
| Scoring harness | 6 | 4 |
| Settings persistence | 4 | 4 |
| Completeness critic | 2 | 2 (its own demonstrations) |

Two harness findings were rejected on measurement: sorted replay is not silent,
and latency charged against the label is the contract working as written.

Fourteen are fixed. Ten went through a builder and a fresh critic who reverted
each fix to prove its test flips; all ten were accepted and merged. Four more
were built when the account hit its session limit, so **their independent check
never ran**: the typing-exposure pass line, cancelling calibration with the
resonator on, the onset ceiling round trip, and the renamed draft keys. Each
carries its own test, and the full suite and the referee agree, but no critic
verified them.

Five confirmed findings have no fix yet: two harness ones, the calibration
review readout, and the two the completeness critic raised, including the one
that matters most, that a keystroke eaten by secure input reads as a fired tap
on the sensor path.

## Files worth opening

| Path | What it holds |
|---|---|
| `reports/gauntlet-ux/BAR.md` | the 19-item checklist every critic graded against |
| `reports/gauntlet-ux/PROGRESS.md` | round by round, including the two stalls |
| `reports/gauntlet-ux/renders/` | the rendered windows the critics read |
| `reports/audit/findings-final.json` | every finding with its three verifier votes |
| `reports/audit/FIXES.md` | one row per merged fix |
| `design/mockups/` | the GPT image 2.5 drafts the layout was graded against |
