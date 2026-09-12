# Copy review: tunk.dev

**Verdict: three blockers. The page contradicts itself about whether you can download
Tunk, and about what it has measured. Fix those before any style work.**

Severity: **BLOCKER** cannot ship as is. **WARNING** likely rework, not blocking.
**OBS** worth noting.

Reviewed against the deployed page, 2797 words, by three independent readers plus a
check of every disputed number against the source that produces it.

---

## BLOCKER 1. The FAQ says the app does not exist

`site/index.html:632` and `site/index.html:101`

> No. Tunk is in development and there is no release to download.

The page carries three Download buttons, a 4.6 MB DMG, a sha256, a four step install
and a v0.2.0 release. The same sentence also sits in the JSON-LD at line 101, so search
engines are served the contradiction too.

Fix, both places:

> Yes. 0.2.0 is on this page, signed ad hoc. Detection on a lap is 80 % against a 98 %
> bar, so read the numbers below before you rely on it.

Confidence: certain. Verified verbatim in both locations.

---

## BLOCKER 2. "Not measured yet" lists three things the page measures

`site/index.html:495-497` against `site/index.html:728-745`

Claimed unmeasured:

- "Detection rate on deliberate taps. No percentage is published because no held-out tap set has been scored."
- "End-to-end latency from your second tap to the action firing."
- "False positives while typing, on a dedicated typing recording."

Published lower down the same page: held-out detection 100 %, 100 %, 80 % over 20
gestures each; response time p95 209 ms; false triggers while typing 0 over 11.7
minutes. A held-out set exists, and the page scores against it.

Fix: move those three rows into Measured with their real values. Leave in the unknown
column only what is genuinely unknown: other surfaces, other MacBooks, battery cost.

Confidence: certain for detection and typing. See WARNING 2 for the latency wording.

---

## BLOCKER 3. The join window is stated twice, with different numbers

`site/index.html:242` says "a join window of about 220 ms".
`site/index.html:270` says "Two taps inside 400 ms, the window the detector joins".

The detector ships `maxInterTapNs` and `confirmWindowNs` at 220 ms
(`Sources/TunkCore/Types.swift:290-291`). The 400 comes from the web demo's own
constant (`site/js/tap-demo.js:21`), which is deliberately lenient for mouse clicks.
So the hint attributes the demo's number to the detector, and is false.

Fix:

> Knock twice on the photograph. The demo joins taps inside 400 ms; the detector uses 220.

Confidence: certain. Both numbers traced to source.

---

## WARNING 1. 100 % from 20 trials reads as a rate

`site/index.html:729, 733`

Twenty for twenty is a count, not a rate. Its confidence interval runs down to roughly
83 %. A page that publishes a failing lap number should not round the good ones up.

Fix: "20 of 20" and "16 of 20", with the bar stated as now.

## WARNING 2. The latency number does not say what it excludes

`site/index.html:741`

209 ms comes from replay, so it measures the detector, not the key reaching the app.
The page elsewhere clocks the URL scheme path at up to 345 ms on its own.

Fix: "Detector latency, 95th percentile, replayed. Dispatch not included."

## WARNING 3. The honesty standard is applied unevenly

`site/index.html:480` publishes "0 in 28 min" with no disclosure. The typing zero
volunteers that the gate muted 86 % of the window. The desk zero deserves the same
treatment or the disclosure looks selective.

## WARNING 4. Sentences that read as machine written

Each quoted verbatim, with a fix that keeps the meaning.

| Location | Quote | Defect | Fix |
|---|---|---|---|
| :461 | "Everything in the right column is unknown, and stays unlabelled until it is not." | self negating inversion | "The right column is unknown, and stays blank until it isn't." |
| :475 | "Tunk is a detector, and detectors invite made-up percentages." | pull quote, category noun acting | "Detectors are easy to lie about. Here is what we measured." |
| :328 | "Whatever a key can do, a knock can do" | chiasmus built for quoting | "A knock does what the key does" |
| :358 | "Five steps, and one of them is the hard one" | rhetorical setup | "Five steps. Step two is the hard one." |
| :404 | "The cost is real and deliberate" | empty doublet | "The tradeoff:" |
| :477 | "the latency budget is spent on deciding, not on plumbing" | binary contrast, passive | "the budget goes to the decision" |
| :719 | "The sensor works, the actions fire, the recordings are stacking up." | triad where two would carry it | "The sensor works and the actions fire. Recordings are stacking up." |
| :357 | "Three screens, no manual." | negative listing as fragment | "Three screens." |

## WARNING 5. One section repeats another

"Whatever a key can do, a knock can do" re-teaches hotkey or Shortcut, already covered
by "A key combination, or anything you have built in Shortcuts", with a worked card
each. Keep the VoiceInk paragraph, drop the rest.

---

## OBS

- `:397` "796 Hz, one sample every 1.25 ms" and `:471` "samples exactly 1.25 ms apart".
  1250 microseconds is the requested report interval; the measured rate of 796.3 Hz is
  one sample every 1.256 ms. Drop "exactly", or state the interval as configured.
- The mug set down appears three times (`:64, :145, :360`). Keep it on the Single tap card.
- Ad hoc signing is explained twice, in the hero note and at the download. Keep the long one.
- `:723` "That page said the numbers would go here" speaks about the page in third person,
  as if quoting a predecessor. "This page said".
- `:203` the hero button says "See the screens" while the nav says "Screenshots".

---

## What is good, and should not be touched

The page publishes a number that fails its own bar (80 % against 98 %), records a claim
it had to retract about sensor bandwidth, and volunteers that 86 % of the typing window
was muted by the gate, which destroys its own headline zero. Marketing copy does not do
that. The voice is the builder's throughout, and it is the reason the page is credible.
The two slips into ad copy are both section headings, listed above.
