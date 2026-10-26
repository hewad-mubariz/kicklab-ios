# Fresh corpus inputs from the production live pipeline, 26 October 2026

Scope: re-process the 20 frozen corpus clips on the iPhone 17 Pro Max with the
production live pipeline (RF-DETR small FP16, rf-v1 association, motion recovery,
the live 30 fps analysis throttle) at real-time pacing, default counting policy
`footEvidenceV15`. Harness: `CadenceBenchmark` with the new `paced` and
`sourceFolder` options, driven by `scripts/device/cadence-corpus.py`; scoring by
`scripts/score-cadence-corpus.py` (time-based label matching, 200 ms tolerance).
Per-clip summaries are in `summaries/`; the score report is `score-v15-fresh.json`.

## Why this run exists

The 14 October corpus inputs were produced by `KickLabYOLO26MotionSegmentation`
through the file-analysis path at the source frame rate. Thirteen of the twenty
clips are 120 fps, so those inputs do not represent the app's live counting:
the detector differs, the association guard did not exist, and the counter
decided 42 ms after each apex with at most 25 ms of future evidence. The holding
check could never fire on them (`hand-evidence-audit-20261025`).

## Harness corrections made on the way

- An unpaced decode outruns the asynchronous RF worker; every reply arrives
  after its frame was consumed and the 30 fps clips got zero detections. The
  benchmark now feeds frames on the source clock with real deadlines and the
  same newest-frame skip policy as the camera.
- One 4K clip stalled the decoder (444 late skips, 3.7 fps); it was re-run alone.
- `normal_juggling_7` failed twice at preparation with a generic error and
  succeeded after a cold relaunch; the failure message now carries details.

## Result against the frozen baseline (same labels)

| | Frozen inputs, V15 | Fresh live pipeline, V15 |
| --- | ---: | ---: |
| Labelled legal contacts | 615 | 615 |
| Counted | 568 | 491 |
| Confirmed false counts | 5 | 4 |
| Accepted uncertain | 5 | 4 |
| Misses before 1.0 s (pipeline warm-up) | 0 | 12 |

The live pipeline needs 0.45 to 0.65 s before its first analysed frame, so
labelled contacts in the first second of a clip cannot be counted by this path.
Those 12 are a harness artifact, not a rule failure.

Per clip, the fresh run is worse wherever the ball stays low or small:
`low` 175 → 135, `eighteen` 15 → 12, `normal_juggling_8` 37 → 29,
`normal_juggling_7` 29 → 21. It is better on the two-ball clip
(`juggling_second_ball_in_video` 19 → 27, 0 false): the rf-v1 association
removes the ball switches that produced the old false counts.

## Cause of the low-juggling losses: the stationary candidate gate

Per-frame pipeline reports for `low` and `eighteen`
(`artifacts/cadence-corpus-20261026/{low,eighteen}-report/report.json`) show
long detector dropouts of 300 to 500 ms where every RF reply reads
`stationary_initial_candidates_rejected`. `StationaryCandidateGate` turns every
candidate of the first RF reply into a permanent background anchor and rejects
any later candidate within half a diameter of it. On these clips the first reply
is the juggling ball itself, so each time the ball returns to its starting spot
it is thrown away. In `low`, 23 of the 56 misses after warm-up sit inside such a
stretch; in `eighteen`, 22 frames are rejected this way plus 25 with no RF result.

The gate is commented as a fixed-camera diagnostic, but `beginRecording()` in the
production live engine passes `stationaryGate: true`. This affects every in-app
recording whose first analysed frame already contains the ball near where it will
be juggled, which is the normal case for low juggling.

## Holding-evidence coverage is now real

On the fresh traces, 334 of 482 accepted touches have an evaluable holding
record (span at least 150 ms, both wrists confident in four or more views),
against 469 of 869 on the frozen traces and zero on any 120 fps clip.

## Stationary gate V2: A/B on the same clips, same pipeline, same labels

`StationaryCandidateGate` version 2, opt-in by `--stationary-gate-v2` (cache
signature suffix `|stationary-gate-v2`, production signature unchanged): an anchor
is released after two consecutive RF replies with nothing at its spot and never
returns; an occupied anchor (a spare ball on a sofa) persists. Three unit tests in
`StationaryCandidateGateTests` cover V1 behaviour, V2 release and persistence, and
the opt-in. Score report: `score-gate2-fresh.json`; summaries in `summaries-gate2/`.

| | Fresh V15, gate V1 | Fresh V15, gate V2 |
| --- | ---: | ---: |
| Counted of 615 labelled | 491 | 527 |
| Confirmed false counts | 4 | 4 |
| Accepted uncertain | 4 | 5 |
| Negative controls (ball in hand, four dribbling clips) | 0 | 0 |

Per clip: `low` 135 → 154, `normal_juggling_7` 21 → 27 (clean 30 fps pass after
the clock fix), `normal_juggling_8` 29 → 33, `normal_juggling_3` 57 → 60,
`juggling_second_ball_very_far` 17 → 19, `juggling_second_ball_in_video` 27 → 28.
Three clips lose one touch each; a paced live pipeline is not bit-exact between
runs, so single-touch differences are noise. The extra uncertain event is a
single accepted touch inside an interval the labels mark uncertain.

Remaining misses under gate V2, after the 11 warm-up misses: no candidate 27,
handsNearBall 13, amplitudeTooSmall 10, outsidePersonRegion 7, missingBall 7,
handsUncertain 4, missingPose 3, invalidGeometry 2, groundBounce 2, trackLost 1,
handContact 1. In `low`, 29 of the 41 remaining misses are candidates with raw
vertical travel of only 0.26 to 0.67 ball heights within ±200 ms: the small
rebounds of plan step 4, now separated from the pipeline problem.

## Harness notes

- `normal_juggling_7` failed at preparation whenever the app started cold: the
  pacing clock began before the reader produced its first frame, every frame was
  late and skipped (`selected=0, late=806`). The clock now starts at the first
  decoded exposure. One earlier gate V2 pass of that clip ran degraded (22.6 fps,
  198 late skips) and was repeated cleanly (30 fps, 0 late).
- Mid-run the app lost GPU access once ("background execution not permitted");
  the phone must stay unlocked and in the foreground for the whole run.
- 4K 120 fps clips decode near real time on the iPhone 17 Pro Max; a slower
  phone would need a non-paced source clock or pre-transcoded inputs.

## What this supports

The gate change is a specific, measured pipeline fix for the user's first
priority (low touches): +36 counted legal contacts on the corpus with no new
false count and clean negative controls. It is still opt-in. Before it becomes
the default it needs one live in-app recording of low juggling with the flag,
and an iPhone 11 paced run. The body-gate relaxation (V19) must now be measured
on these fresh traces, where the holding record is finally evaluable.
