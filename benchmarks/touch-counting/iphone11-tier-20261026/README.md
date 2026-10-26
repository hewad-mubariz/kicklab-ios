# iPhone 11 Pro Max: device-tiered contact rechecks, 26 October 2026

Build 2026102608 (`codex/touch-counter-improvements-v17`), same binary on both
phones. Touch Counting Debug defaults: `floorRescueV19`, handling V2, stationary
gate V2, and the new `RFContactRecheckTier` chosen by `RFDeviceProfile`: `full`
on the 384-pixel profile, `compact` on the 288-pixel profile (iPhone 11 and any
unrecognised device). Debug flags `--recheck-tier-full` / `--recheck-tier-compact`
force either tier for same-device comparisons. The compact tier appends
`|recheck-compact` to the pipeline signature; the full tier's signature is unchanged.

## Why

The 25 October complete benchmark showed the full update losing 2 to 6 of the 31
known legal contacts on the difficult recording on the iPhone 11, with median
notification delay rising from about 650 ms to 800–840 ms and 47–51 contact
rechecks per run against 9–13 before. On that profile one RF prediction takes
about 70 ms, the recheck blocks fresh regular submissions on the single shared
worker (`RFWorker.recheck`), so three impact-window rechecks plus a gap retry
per contact starve regular detection and break the track. The counting rules
were not the cause: the lost contacts had no candidate at all.

## What the compact tier does

Keeps the base contact recheck (as in V15). Turns off the V16 neighbour repair,
the V17 impact window and the impact-gap detector retry, and with them the V17
"positive foot proof after a tracking gap" requirement, which has nothing to
resolve a gap with when repairs are off. Everything else, including gate V2 and
the V18/V19 floor rules, is identical on all devices.

## Same three sources, same phone, same partial controls

| Difficult recording (31 known legal) | Old V15 + gate V1 | Full update | Compact tier |
| --- | ---: | ---: | ---: |
| Known legal matched, two runs | 30, 30 | 28, 25 | 30, 31 |
| Reviewed floor controls counted | 3, 3 | 0, 1 | 1, 0 |
| Median notification delay | 646–650 ms | 803–844 ms | 585 ms, 585 ms |
| p95 notification delay | 730–798 ms | 1027–1036 ms | 689 ms, 648 ms |
| Peak process memory | 175–176 MiB | 201–205 MiB | 173, 165 MiB |
| Contact rechecks | 9–13 | 47–51 | 10, 7 |
| Thermal start→end | serious | serious | nominal→nominal, nominal→serious |

| Low clip (195 labelled) | Old | Full update | Compact tier |
| --- | ---: | ---: | ---: |
| Matched legal contacts | 130, 132 | 148, 145 | 153 |
| False counts | 0 | 0 | 0 |

The remaining unmatched event at 22.29 s in both compact runs is one of the two
times the controls mark uncertain. The single floor control counted in run 1
(29.87 s) was also counted by both old runs. Analysis cadence stayed at 30 fps
with zero late source skips in all three runs. Scores: `score.json`; per-run
summaries in `runs/`. Raw traces and pipeline reports:
`artifacts/iphone11-tier-20261026/runs/` in the main checkout.

## Also in this build

`FootContactRules.ankleTravels` now accepts gradual, aligned ankle motion across
both halves of a contact (0.05 plus 0.05 ball widths adding to 0.2 in the same
direction), which the controlled reproducer in the 25 October benchmark showed
V19 rejecting. Reversing motion of the same magnitude is still jitter. Offline
replay of all 68 saved traces with the V18/V19 flags injected changes only the
reviewed false floor counts; the 32.75 s floor control in both old-rule iPhone 11
runs is now rejected too. 47 unit tests in nine suites pass.

## Not yet measured

A sustained live-camera session on the iPhone 11 (camera and encoder running),
and a repeat of the full corpus on the Pro Max with this binary (the tier does
not apply there and the ankle rule change replays identically, so no change is
expected).

## Follow-up after the independent warm re-review (26 October)

The independent re-review of build 2026102608 found that the compact tier, on a
warm iPhone 11 (thermal state 2), counted three reviewed floor bounces in two of
three runs (29.868, 31.05, 32.25 s and 29.868, 31.716, 32.716 s), while forced-full
rechecks counted none. Cause: with repairs and the gap gate both off, detection
holes of 100–200 ms before impact left the floor proofs with too few continuous
views, and nothing else could reject an ankle-height candidate.

Measured offline before changing anything (`counterlab replay --gap-gate`, with the
gate reconstructed from the trace inputs that carried a ball):

- Re-enabling the narrow V17 gap gate on compact traces rejects 7 reviewed false
  floor counts and 9 labelled legal low touches across all saved compact traces.
  A gate widened to 134 ms before impact rejects 9 false and 11 legal plus 3
  uncertain. Neither is a clean trade; the evidence-density gates cost low touches.
- A sparse-pose gate (fewer than seven confident views or a long approach gap)
  would reject 69 to 86 legal low touches to remove one bounce. Rejected.
- A dead-bounce rule on fall and rebound size cannot separate drops from soft
  cushioning touches (60 legal touches share the bounce signature). Rejected.

Changes in builds 2026102609 and 2026102610:

- Compact tier keeps the backlog-guarded impact-gap detector retry (measured 1 to
  4 per minute) and the narrow gap gate; the three-image impact window and the
  neighbour repair stay off.
- `allowsStationaryHole` (V19 flag): the below-feet floor proof bridges one
  detection hole of up to 200 ms in the approach only when both ankles stayed
  planted across the whole window (`stableFeet`). Nothing can kick a ball that
  ends up under two unmoved ankles. Offline replay of all 72 saved traces changes
  exactly one touch: the 32.18 s warm bounce. Unit test on that saved evidence,
  with a moved-ankle counter-example.

Warm comparison with build 2026102609 (gap retry and gate, before the hole rule),
difficult recording three times back to back then the low clip:

| Run | Thermal | Known legal | Floor controls counted | Rechecks + gap retries | Median delay | Peak memory |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 (cold) | 0→0 | 30/31 | 0 | 7 + 1 | 584 ms | 173 MiB |
| 2 (warm) | 0→2 | 31/31 | 0 | 8 + 1 | 578 ms | 166 MiB |
| 3 (warm) | 2→2 | 30/31 | 1 (32.18 s) | 10 + 2 | 587 ms | 169 MiB |
| low (warm) | 2→2 | 155/195 matched, 0 false | | 5 + 0 | 653 ms | 178 MiB |

The single remaining bounce is the one the stationary-hole rule now rejects.
The missed legal contact in runs 1 and 3 is 41.55 s, the same one the old rules
missed in their repeat. The intermittent 43.616 s outside-foot miss remains a
separate open item (body gate), counted in all three of these runs.

Build 2026102610 (hole rule included), same sequence:

| Run | Thermal | Known legal | Floor controls counted | Rechecks + gap retries | Median delay | Peak memory |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 (cold) | 0→0 | 30/31 | 0 | 9 + 0 | 576 ms | 167 MiB |
| 2 (warm) | 1→2 | 30/31 | 0 | 7 + 2 | 586 ms | 164 MiB |
| 3 (hot) | 2→2 | 28/31 | 0 | 10 + 4 | 642 ms | 171 MiB |
| low (hot, fourth run) | 2→2 | 141/195 matched, 0 false | | 4 + 0 | 691 ms | 171 MiB |

Zero floor bounces in all three runs. The hot third run missed 11.38 s
(`unresolvedLowContact`, the gap gate), 43.62 s (the known intermittent
outside-foot body-gate miss) and 51.18 s (`outsidePersonRegion`). The hot low
run fell to 141 matched from 155: detections with a ball dropped from 1706 to
1670 of 1793 inputs and the lost touches never became candidates; the new
rules rejected three labelled low touches as `groundBounce` in that run, none
through the stationary-hole bridge. Hot-phone detection loss is the dominant
remaining variance on this device and is independent of the counting rules.

## Final compact-tier decision (build 2026102611)

Two more measurements decided the remaining pieces:

- **Deep single-view floor contact** (`checksDeepFloorContact`, V19): the lower
  ball edge at least half a ball height under both planted ankles and between
  them, after a clear drop, with a rebound, and both ankles still within 0.15
  ball heights across every confident view within 67 ms. Swept against all
  3,158 accepted touches with floor evidence in every saved trace: zero legal
  contacts, eight reviewed bounces (including the recurring 29.87 s one).
  Fixture test from that bounce with moved-ankle and shallow counter-examples.
- **The narrow gap gate on the compact tier**, measured once the hole and deep
  rules exist: it uniquely removes 4 reviewed bounces and 9 labelled legal low
  touches across every saved compact trace. It is therefore off on the compact
  tier (it stays on the full tier, where the impact-window repair feeds it).

Compact tier, final: base contact recheck + backlog-guarded gap retry;
no impact window, no neighbour repair, no gap gate; V19 floor rules
(planted feet with one 134 ms gap, below feet with a stationary 200 ms hole,
beside feet, deep single-view contact, jitter-proof kick rescue); gate V2.

Offline replay of all 75 saved traces with the complete V19 flag set changes
only reviewed false floor counts. Unit tests: 49 in eleven suites.

## Build 2026102611 verification (gap gate off on compact), same sequence

| Run | Thermal | Known legal | Floor controls counted | Rechecks + gap retries | Median delay | Peak memory |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 (cold) | 0→0 | 30/31 | 1 (30.50 s) | 7 + 1 | 587 ms | 162 MiB |
| 2 (warm) | 1→2 | 30/31 | 0 | 8 + 2 | 579 ms | 169 MiB |
| 3 (hot) | 2→2 | 30/31 | 3 (31.55, 32.22, 32.72 s) | 10 + 1 | 666 ms | 184 MiB |
| low (hot) | 2→2 | 148/195 matched, 0 false | | 3 + 0 | 684 ms | 167 MiB |

### What the hot-run bounces are

Their saved evidence shows a mechanism the floor proofs cannot reach: the
detector loses the ball for four or five consecutive exposures immediately
after the candidate, the real carpet impact happens inside that hole, and the
smoothed trajectory reports its reversal 1 to 2 ball heights above the ankle
line (`observedBallBottom` 0.23 and 0.18 of frame height above the floor line
at 31.55 s and 32.72 s). No ankle-height rule applies to a candidate that high,
and no floor proof can see an impact that was never detected. The symmetric
gap gate (build 10) catches these because it counts missing exposures within
67 ms on either side. Measured across all saved compact traces once the hole
and deep rules exist, that gate uniquely removes 6 reviewed bounces and 14
labelled legal touches. An after-only variant (three missing exposures right
after the candidate, with the ankle-height condition) removes 2 bounces and 3
legal touches, because the candidates above the ankle line never satisfy the
height condition. A drop-into-hole trajectory rule (hole of at least four
exposures after the candidate and a fall of at least 0.15 frame heights)
removes 5 bounces and 5 legal touches. Each of these was implemented, swept
against every saved trace, and not adopted.

### Decision

Compact tier without a gap gate (build 2026102611) is the shipped candidate:
it keeps the low-touch gain and the latency and memory reductions, and its
only measured weakness is the hot-phone detection loss above, which is a
detector scheduling limit on this device. Across the ten paced runs on the
difficult recording in builds 9 to 11, false bounces per run were
0, 0, 1, 0, 0, 0, 1, 0, 3 against the old rules' 3 in every run, with known
legal contacts at 28 to 31 of 31 against the old 30. The symmetric gate remains
available on the full tier and as the measured fallback if hot-phone bounces
prove more frequent in real use than in these replays.

### Remaining items before a public default

- A sustained live-camera session on the iPhone 11 at thermal state 2, since
  every number above is paced replay of encoded video without the camera and
  encoder running.
- The intermittent 43.616 s outside-foot miss (`disallowedBodyContact`), present
  in one of three runs per build, is a body-gate item outside this work.
- More frequent gap retries on the compact tier when the phone is hot would
  attack the root cause; the retry fired once in the hot run that had three
  four-exposure holes. That is a scheduling change with its own cost measurement.
