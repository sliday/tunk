# Recording plan

The one thing no agent can do. Everything else in this build is verifiable by
machine; the ground truth is not.

> Every command below was run against the shipped CLI before being written down.
> An earlier version of this file invented `--category` and `--duration` flags
> that `guide` does not accept — it swallowed them and silently recorded all 12
> phases instead of the one asked for. If a command here ever errors or does
> something unexpected, stop and say so; the plan is wrong, not you.

**Wear headphones.** The tool speaks the prompts and plays the beeps. Through the
laptop speakers those shake the chassis and land in the accelerometer stream as
fake transients, which poisons exactly the data we are collecting.

Check the rig first, once:

```bash
cd /Users/stas/Playground/tunk
./bin/tunk-capture doctor
```

It needs **Input Monitoring** granted to your terminal app. If `input tap` comes
back anything but OK, the session records no keyboard or trackpad activity, the
harness cannot reproduce the typing suppression gate, and the false-positive
numbers become meaningless.

Ordered by value. **Block A alone unblocks the loop.** If you stop after it, the
run continues on desk-only data and the critics will say so explicitly rather
than quietly pretending the other surfaces passed.

## Block A — desk, the core set (~14 min)

`guide` runs one phase per `--only` entry, with `--taps` prompted double-taps and
a randomised rest between them.

```bash
cd /Users/stas/Playground/tunk

# three tap locations, 20 prompted double-taps each
./bin/tunk-capture guide --surface desk --only tap_palmrest --taps 20
./bin/tunk-capture guide --surface desk --only tap_deck     --taps 20
./bin/tunk-capture guide --surface desk --only tap_bottom   --taps 20

# five minutes of real prose, no intended taps. The make-or-break recording.
./bin/tunk-capture guide --surface desk --only typing --typing-sec 300

# trackpad clicks and hard taps
./bin/tunk-capture guide --surface desk --only trackpad --trackpad-sec 120

# machine untouched
./bin/tunk-capture guide --surface desk --only idle --confound-sec 60
```

## Block B — confounds, desk (~9 min)

Every one of these must produce zero triggers. This is where a naive detector
dies. One command, six phases, prompts you through each:

```bash
./bin/tunk-capture guide --surface desk --confound-sec 90 \
  --only confound_mug,confound_lid,confound_phone,confound_music,confound_footfall,confound_handling
```

What each wants: set a mug down near then on the desk, varying force; slam a
browser tab shut and hit Return hard, nudge the lid; let a phone buzz on the same
desk; play something bass-heavy loud enough to feel through the desk; have
someone walk past on the timber floor, or stamp if you are alone; reposition,
lift, set down, plug and unplug a cable.

## Block C — soft surface (~11 min)

Laptop on a bed or cushion. Coupling changes a lot here; this is where a fixed
threshold falls apart.

```bash
./bin/tunk-capture guide --surface soft --taps 20 \
  --only tap_palmrest,tap_deck,tap_bottom
./bin/tunk-capture guide --surface soft --typing-sec 240 --only typing
./bin/tunk-capture guide --surface soft --confound-sec 90 --only idle,confound_handling
```

## Block D — lap (~11 min)

Same shape, `--surface lap`. Your body damps the chassis heavily. If detection
turns out to be physically unreachable here, the critic reports that with the
data rather than relaxing the number.

```bash
./bin/tunk-capture guide --surface lap --taps 20 \
  --only tap_palmrest,tap_deck,tap_bottom
./bin/tunk-capture guide --surface lap --typing-sec 240 --only typing
./bin/tunk-capture guide --surface lap --confound-sec 90 --only idle,confound_handling
```

## Block E — holdout (~12 min)

**Recorded last, and never read during tuning.** Every number that decides pass
or fail comes from these. `--out data/holdout` plus `--split test` keeps them
apart, and `tunk-score` refuses to touch them without an explicit critic flag.

```bash
H="--out data/holdout --split test"

./bin/tunk-capture guide --surface desk $H --taps 20 --only tap_palmrest
./bin/tunk-capture guide --surface soft $H --taps 20 --only tap_deck
./bin/tunk-capture guide --surface lap  $H --taps 20 --only tap_bottom
./bin/tunk-capture guide --surface desk $H --typing-sec 300 --only typing
./bin/tunk-capture guide --surface lap  $H --typing-sec 180 --only typing
./bin/tunk-capture guide --surface desk $H --confound-sec 120 --only confound_music
```

## After each block

```bash
./bin/tunk-capture verify        # checks the newest session
```

PASS or PASS WITH WARNINGS is fine. A FAIL means that session is unusable and
worth re-recording while you are still set up.

## Ground rules

- **Tap the way you actually would.** Do not perform an exaggerated tap to help
  the detector. A dataset of theatrical taps produces a detector that only fires
  for theatrical taps, and the felt-reliability test at the end will fail.
- One beep, one double-tap. Rest between prompts is randomised so the labeller
  cannot cheat off a fixed period.
- If a prompt goes wrong, say what happened out loud and carry on. The tool logs
  an operator mark and that group gets dropped rather than mislabelled.
- Ctrl-C at any point flushes and writes a valid session. Nothing is lost.
- Note anything unusual about the surface with `--notes "glass desk"`.

## Total

Roughly 57 minutes, in blocks you can spread out. Block A is 14 of those and is
the one that matters most.
