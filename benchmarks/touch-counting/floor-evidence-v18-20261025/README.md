# Floor evidence V18: bounces beside the feet and one dropped approach exposure

Date: 2026-10-25. Branch `codex/touch-counter-improvements-v17`. Opt-in only:
`--floor-evidence-v18` in debug builds; the production default stays `footEvidenceV15`.
V18 includes everything in V16 and V17.

## Why

Six reviewed false floor counts remained after V17: five in the frozen corpus
(`normal_juggling_4` 27.183 s and 27.600 s, `nomral_juggling_6` 10.291 s and
10.708 s, `juggling_second_ball_very_far` 4.083 s) and one in the 25 October
live recording at 22.88 s. The saved ground evidence for each was evaluated on
macOS with the production rules (`artifacts/floor-evidence-v18-20261025/ground-evidence-*.txt`).

Two mechanisms explain three of the six:

- **Bounce beside the feet.** At 27.183 s and 4.083 s the ball reaches the floor
  line about one ball width outside the stance, with its center at the ankle
  line, after a clear drop from above the ankles. The planted-feet proof failed
  on ordinary ankle jitter (0.2 ball heights over 350 ms), and the below-feet
  proof requires the ball between the ankles. Nothing else could reject them.
- **One dropped approach exposure.** At 22.88 s live the ball hit the carpet
  between planted feet, but three approach frames had no ball. The below-feet
  proof allows at most 110 ms between confident views; this gap was 133 ms.

## Rules added

- `GroundContactEvidence.confirmsBallBesideFeet`: at least seven confident
  stance views spanning −200 to +25 ms, ball center at least half a ball width
  outside the ankle span in two views within ±67 ms and at contact, ball center
  no higher than 0.25 ball heights above the lowest ankle, at least two
  approach views with the ball bottom above both ankles, and a rebound of at
  least 0.2 ball heights. The counter applies it only when its own stabilized
  floor line is reached by the observed ball bottom. A confirmed kick still rescues.
- `toleratesApproachGap`: the below-feet proof accepts one gap of up to 134 ms.

Both are flags on saved evidence, nil in old traces, so historical replays are unchanged.

## Offline evidence replay, all saved traces

Every saved V17 trace was replayed twice on macOS with the production counting
sources: once unchanged (exact match to the saved touches in all 24 traces) and
once with the V18 flags injected into every saved ground record
(`artifacts/floor-evidence-v18-20261025/offline-flag-replay.txt`).

| Trace set | Touches changed |
| --- | --- |
| 20 corpus clips | `normal_juggling_4` 33 → 32 (27.183 s now groundBounce), `juggling_second_ball_very_far` 23 → 22 (4.083 s now groundBounce) |
| walkthrough, latest (19 Oct) | none |
| 24 Oct 21:26 and 23:06 takes | none |
| 25 Oct live recording | 27 → 26 (22.88 s now groundBounce) |

Corpus totals move from 568 valid / 5 false to 568 valid / 3 false. No labelled
legal contact is lost in any trace. This replays saved pose evidence; it does not
rerun Vision or the detector, and does not measure live cost.

## Still open from the six

- 27.600 s: foot trap of a ball on the floor; `FootContactRules` confirms foot motion.
- 10.291 s and 10.708 s: hand pushes the ball down between bounces; weak ankles,
  handling evidence uncertain. These are hand cases, not floor-rule cases.

## Tests

Simulator run of the five counting suites (GroundHeightEvidence, FootContactEvidence,
CountingPipeline, ContactEvidenceReplay, ContactRecheckPolicy): 40 tests, 0 failures
(`artifacts/floor-evidence-v18-20261025/unit-tests.log`). New fixtures are the saved
ground records for 27.183 s, 4.083 s, the two legal low-corpus contacts beside one foot
(`low` frames 388 and 785, which must stay accepted) and the 22.88 s live bounce.
The V16 and V17 before/after trace fixtures still replay identically.

## Not yet done

- On-device replay with fresh Vision (`comparison: floorEvidence` in `TouchContactReplay`)
  before V18 can be promoted; the offline replay reuses saved pose samples.
- iPhone 11 paced run; V18 adds no new inference, but the V17 rechecks it inherits are unmeasured there.
