# Floor rescue V19: two counted bounces in the first V18 live recording

Date: 2026-10-25. Branch `codex/touch-counter-improvements-v17`. Opt-in by
`--floor-rescue-v19` (debug), default in the Touch Counting Debug app from build
2026102607, production default unchanged. V19 includes V16 to V18.

## The recording

61 s in-app recording on the iPhone 17 Pro Max with the Touch Counting Debug app
running V18 and stationary gate V2 (build 2026102606), indoor, exposure 1/500 s at
ISO 3042. The user reported: low juggling counted well, rolling the ball around
caused no false counts, knee touches counted, two floor bounces counted at about
35 s and 39 s. The live trace (`live-20261025-2212-counter.json`) has 25 touches
and 25 rejections, of which 7 are `groundBounce` in the 22 to 39 s floor-bounce
segment. Frame strips at 35.81 s and 39.01 s show a drop from the hands, a carpet
bounce between the feet and a catch, no foot involved.

## Why each one passed

- **35.81 s (frame 1073).** The planted-feet proof had ten confident views and a
  clear approach, but one approach exposure was dropped: 133 ms between the
  −266 and −133 ms views against the 110 ms continuity limit, so the usable
  window started at −133 ms and failed the 200 ms approach requirement. The
  below-feet proof had only one view with the ball center under both ankles.
  V18 added a 134 ms tolerance to the below-feet proof only.
- **39.01 s (frame 1169).** The floor was confirmed (`plantedFeetConfirmed`), but
  the foot-motion rescue overturned it. The confirming "kick" was 0.010 of frame
  height of left-ankle movement combined with 0.005 of hip movement, which the
  hip-relative travel rule read as 0.185 ball heights. The ball center sat 0.43
  ball heights below the lowest ankle.

Across all 2,775 accepted decisions in every saved trace (frozen corpus, both
fresh corpus runs, the two 24 October takes and the live clips), the
floor-confirmed-then-foot-rescued path fired exactly twice: this bounce, and a
legitimate low touch at 5.22 s in the same recording whose ankle moved 0.59 ball
widths into the contact.

## Rules added (flags on saved evidence, nil in old traces)

- `toleratesPlantedApproachGap`: the planted-feet proof accepts one gap of up to
  134 ms, the same as the below-feet proof since V18.
- `requiresMovingAnkleForRescue`: when the floor is positively confirmed, the
  kick rescue also needs `FootContactRules.ankleTravels`: an ankle within 0.75
  ball sizes of the ball moved at least 0.2 ball widths in image space on the way
  in or out. Hip-relative jitter no longer qualifies.

## Offline replay, every saved trace, V18 and V19 flags injected

| Trace set | Touches changed |
| --- | --- |
| 20 frozen corpus clips | the two V18 beside-feet bounces only (unchanged from V18) |
| Fresh corpus, gate V1 and gate V2 runs (40 traces) | `normal_juggling_4` 27.18 s in each run, the labelled false floor count |
| 24 Oct takes, 19 Oct clip, walkthrough | none |
| 25 Oct 17:42 live | 22.88 s (V18, unchanged) |
| 25 Oct 22:12 live | 35.81 s and 39.01 s now `groundBounce`; the 5.22 s low touch stays |

58 traces are byte-identical. No labelled legal contact changes anywhere.

## Tests

`FloorRescueTests` (two tests on the saved evidence of 35.81 s, 39.01 s and 5.22 s),
plus the policy test pinning V19 as the debug default and V15 as the released
policy. Fixtures: `floor-planted-gap-1073-20261025.json`,
`floor-rescue-jitter-1169-20261025.json`, `floor-rescue-kick-156-20261025.json`.
