# Working on Tunk

Read `tunk-prd.md` for what we are building and the pass line. Read `FORMAT.md`
for the data and replay contract — it is frozen; if you need it changed, say so
in your report instead of editing it.

## Build and test

```bash
# Build. Use your own scratch path so parallel agents do not fight over the lock.
swift build --scratch-path .build-<yourname>

# Tests need Xcode's toolchain for XCTest. Command Line Tools alone lack it.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path .build-<yourname>
```

`xcodebuild` is not on the default path (`xcode-select` points at the CLT
instance and changing it needs sudo). Prefer SwiftPM. Xcode 26.6 lives at
`/Applications/Xcode.app` if you need its toolchain.

## Verified sensor facts

Do not re-derive these; they were measured on this machine. See the table at the
top of `FORMAT.md` and the spikes in `spike/`.

- The accel service matches `PrimaryUsagePage 0xFF00` / `PrimaryUsage 3`.
- It stays **idle** until you set `ReportInterval`. That is the one gotcha.
- At `ReportInterval = 1250` it delivers **796 Hz**, unbatched, p95 callback lag
  0.34 ms. Values are in g.

## File ownership

One agent per area. Do not edit files outside your area; if you need a change
there, report it and the lead will route it.

| Area | Files |
|---|---|
| sensor IO | `Sources/CTunkHID/**`, `Sources/TunkIMU/**` |
| dataset IO | `Sources/TunkFormat/**` |
| detector | `Sources/TunkCore/Detector*.swift`, `Sources/TunkCore/DSP*.swift` |
| shared types | `Sources/TunkCore/Types.swift` (frozen — lead only) |
| capture tool | `Sources/TunkCapture/**` |
| scoring harness | `Sources/TunkScore/**` |
| key emission | `Sources/TunkEmit/**` |
| menubar app | `Sources/TunkApp/**` |
| progress page | `web/**` |
| tests | `Tests/**` — add files, do not rewrite others' tests |

`Package.swift` is lead-owned. Ask rather than edit.

## Rules that are not negotiable

1. **The detector never reads a clock.** It advances only on `ingest(sample:)`
   and `ingest(input:)`. No `Date()`, no timers, no `asyncAfter` in the decision
   path. Live and replay must be the same code producing identical triggers.
2. **Never read `data/holdout/`** unless you were told you are a critic. Builders
   tune on `data/raw/` only. Leaking the test set invalidates the whole run.
3. **No stuck modifiers.** Every synthetic key-down is followed by its key-up,
   including on every error path.
4. Report what you measured, not what you expect. If something is untested, say
   it is untested.
