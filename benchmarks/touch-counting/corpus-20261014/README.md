# Touch-counter corpus baseline — 14 October 2026

All **20 non-intake clips** were processed individually on the connected iPhone using the current production file-analysis path and reviewed against source footage. The three intake recordings were excluded. This freezes the existing counter; no production rule, model, build or upload was changed during this audit.

**615 visually labelled valid contacts: 554 counted, 61 missed.** There were **5 confirmed ground-bounce false counts** and **5 accepted events whose validity remains uncertain**. Total app counts were 564. These separate numbers matter: an extra bounce can conceal a missed kick in the total.

These are assistant-reviewed development labels, pending human confirmation, not independent held-out accuracy or a release certification. The sources cover 491.06 seconds. Most contacts are feet; this corpus does not establish chest/head/knee or outside-foot accuracy.

## Per-clip results

“Valid” means visible legal airborne leg contact, including a failed sideways kick. Holding, ground rolls/bounces and ground dribbling are not juggling. A dribbling filename alone does not invalidate an isolated airborne foot touch. Off-camera or ambiguous contacts stay uncertain. Counts are whole-clip totals, not uninterrupted streaks.

| Source | Labelled valid | App total | Valid counted | Valid missed | False counted | Uncertain counted |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [normal_juggling_1.mov](results/normal_juggling_1.json) | 25 | 24 | 24 | 1 | 0 | 0 |
| [normal_juggling_2.mov](results/normal_juggling_2.json) | 24 | 21 | 21 | 3 | 0 | 0 |
| [normal_juggling_3.mov](results/normal_juggling_3.json) | 64 | 63 | 62 | 2 | 0 | 1 |
| [normal_juggling_4.mov](results/normal_juggling_4.json) | 32 | 32 | 29 | 3 | 2 | 1 |
| [normal_juggling_5.mov](results/normal_juggling_5.json) | 38 | 37 | 37 | 1 | 0 | 0 |
| [nomral_juggling_6.mov](results/nomral_juggling_6.json) | 34 | 36 | 34 | 0 | 2 | 0 |
| [normal_juggling_7.mov](results/normal_juggling_7.json) | 31 | 29 | 29 | 2 | 0 | 0 |
| [normal_juggling_8.mov](results/normal_juggling_8.json) | 38 | 37 | 37 | 1 | 0 | 0 |
| [34dd.mov](results/34dd.json) | 18 | 17 | 17 | 1 | 0 | 0 |
| [ball_in_hand.mov](results/ball_in_hand.json) | 0 | 0 | 0 | 0 | 0 | 0 |
| [dribbling_with_ball_1.mov](results/dribbling_with_ball_1.json) | 0 | 0 | 0 | 0 | 0 | 0 |
| [dribbling_with_ball_2.mov](results/dribbling_with_ball_2.json) | 0 | 0 | 0 | 0 | 0 | 0 |
| [dribbling_with_ball_3.mov](results/dribbling_with_ball_3.json) | 0 | 1 | 0 | 0 | 0 | 1 |
| [dribbling_with_the_ball_1.mov](results/dribbling_with_the_ball_1.json) | 0 | 0 | 0 | 0 | 0 | 0 |
| [eighteen.mov](results/eighteen.json) | 18 | 11 | 11 | 7 | 0 | 0 |
| [juggling.mp4](results/juggling.json) | 38 | 35 | 35 | 3 | 0 | 0 |
| [juggling_second_ball_in_video.mov](results/juggling_second_ball_in_video.json) | 28 | 19 | 19 | 9 | 0 | 0 |
| [juggling_second_ball_very_far.mov](results/juggling_second_ball_very_far.json) | 22 | 23 | 20 | 2 | 1 | 2 |
| [low.mov](results/low.json) | 195 | 171 | 171 | 24 | 0 | 0 |
| [raw-juggling.mov](results/raw-juggling.json) | 10 | 8 | 8 | 2 | 0 | 0 |

Ten individual possible contacts remain labelled uncertain, plus uncertain intervals such as a ball leaving the frame. Five accepted events fall into those event/interval labels. They are excluded from definitive true/false totals. Every accepted event has been assigned to valid, false or uncertain; none remains unmatched and unreviewed.

## Demonstrated gaps and next work

1. **Fix the ground evidence duration first.** All five false ground counts are in 120 fps recordings. Each trace supplies only **−75 to +25 ms** of ground evidence. `JugglingContactVerifier.groundEvidence` selects indices −9 through +3, while `GroundContactEvidence.confirmsPlantedFeet` requires at least **200 ms before** contact. The ground veto cannot establish its required approach in these cases; all five record `plantedFeetConfirmed = false` and `bodyContactAllowed = true`. This is a measured evidence-window defect, not a reason to reject every low ball. Select a bounded window by elapsed time, then replay both these ground negatives and all 195 low touches before accepting a fix. Satisfying the window alone does not guarantee the remaining ground conditions will pass.
2. **Recover the low-touch proposals.** `low.mov` has 195 visible contacts, of which 171 count. All 24 misses were checked with closer source stills. Seventeen have no nearby recorded candidate diagnostic, four fail `amplitudeTooSmall`, and three fail `missingPose`. The first missed contact is near the start boundary. The other no-candidate misses need detector/continuity/smoothing/state tracing; the available output does not identify a particular rejecting filter. Do not loosen body validation to fix a proposal that never reached it.
3. **Separate raised feet from hand uncertainty.** Across the corpus, 22 missed valid foot contacts have `handsNearBall` or `handsUncertain` as the nearest first body failure. Several are high kicks with the hands visibly away. `eighteen.mov` is especially useful: 18 visible contacts, only 11 counted. Preserve real-hand negatives while checking whether observed foot motion and ball/foot geometry are being overridden by uncertain or projected arm landmarks. A diagnostic `handConfirmed = true` is a heuristic result, not ground truth.
4. **Handle a second person and maintain ball identity.** In `juggling_second_ball_in_video.mov`, all nine foreground contacts from about 12.94–18.01 s are missed after the second person enters. Six nearest diagnostics report `missingPose`, two `invalidGeometry`, one `outsidePersonRegion`. `ContactObservationStore.pose` explicitly returns an empty pose unless Vision finds exactly one body; that explains why another visible person can disable useful pose evidence. The ball trace also switches toward the background ball around 16.0 s (x ≈ 0.93 while the foreground player is centered around x ≈ 0.44). Investigate both player association and ball continuity; choosing the first returned pose would not solve identity reliably.
5. **Keep the remaining edge cases explicit.** One visible sideways contact in `normal_juggling_2` ends with `trackLost`; `raw-juggling` has one `insufficientContactViews` and one hand-uncertainty miss. The final visible contact in `juggling.mp4` occurs just before the recording ends and has no nearby diagnostic. End-boundary misses and off-camera uncertainty should not be mixed into the same bucket.

The five ground false counts are at **27.183 and 27.600 s** in `normal_juggling_4`, **10.291 and 10.708 s** in `nomral_juggling_6`, and **4.083 s** in `juggling_second_ball_very_far`. Their measured evidence windows are saved in [findings.json](findings.json). In particular, `nomral_juggling_6` counting 36 is not 36 legitimate juggles: it matches 34 visible legal contacts and adds two bounces.

The hand-holding clip and three ground-dribbling clips correctly produce zero. `dribbling_with_ball_3` produces one event at 3.950 s. Dense review shows a brief ankle-height airborne pop during a turn; its foot/ground origin is ambiguous, so it is **uncertain**, not a claimed ground-bounce failure.

## Missed-contact diagnostic breakdown

These are the nearest recorded **first failures**, within the matching tolerance. They are not an exhaustive list of every failed fallback. In a multi-ball scene, a nearby diagnostic can concern the other ball. “No nearby candidate” means no matching acceptance or rejection was recorded, not proof that the detector lost the ball.

| First diagnostic / outcome | Missed valid contacts |
| --- | ---: |
| `no_nearby_candidate` | 18 |
| `handsNearBall` | 12 |
| `missingPose` | 11 |
| `handsUncertain` | 10 |
| `amplitudeTooSmall` | 4 |
| `invalidGeometry` | 3 |
| `outsidePersonRegion` | 1 |
| `trackLost` | 1 |
| `insufficientContactViews` | 1 |

## Contact times to inspect

Times below are visual label times in seconds, with the nearest logged failure in parentheses. Exact counter decision times and frame indices are in each linked result JSON. Labels intentionally remain separate from predictions.

- **normal_juggling_1.mov**: 8.890 (handsUncertain).
- **normal_juggling_2.mov**: 2.320 (handsNearBall); 12.150 (handsNearBall); 14.500 (trackLost).
- **normal_juggling_3.mov**: 17.570 (handsNearBall); 29.740 (handsNearBall).
- **normal_juggling_4.mov**: 7.120 (handsUncertain); 8.080 (handsUncertain); 20.280 (handsNearBall).
- **normal_juggling_5.mov**: 20.960 (handsNearBall).
- **normal_juggling_7.mov**: 10.360 (missingPose); 11.630 (missingPose).
- **normal_juggling_8.mov**: 56.890 (handsNearBall).
- **34dd.mov**: 14.450 (handsNearBall).
- **eighteen.mov**: 3.750 (handsUncertain); 6.320 (handsUncertain); 7.650 (invalidGeometry); 10.980 (handsUncertain); 11.860 (handsUncertain); 13.880 (handsUncertain); 14.590 (handsNearBall).
- **juggling.mp4**: 15.720 (handsUncertain); 20.970 (handsNearBall); 22.780 (no nearby candidate).
- **juggling_second_ball_in_video.mov**: 12.940 (missingPose); 13.530 (invalidGeometry); 14.220 (missingPose); 14.660 (missingPose); 15.430 (missingPose); 16.060 (invalidGeometry); 16.670 (missingPose); 17.390 (outsidePersonRegion); 18.010 (missingPose).
- **juggling_second_ball_very_far.mov**: 2.800 (handsNearBall); 10.880 (handsNearBall).
- **low.mov**: 0.125 (no nearby candidate); 4.060 (no nearby candidate); 5.250 (amplitudeTooSmall); 7.070 (no nearby candidate); 9.560 (amplitudeTooSmall); 15.740 (no nearby candidate); 18.750 (no nearby candidate); 20.600 (no nearby candidate); 21.250 (amplitudeTooSmall); 23.110 (missingPose); 24.650 (missingPose); 24.960 (no nearby candidate); 28.630 (no nearby candidate); 28.940 (no nearby candidate); 32.310 (no nearby candidate); 34.410 (no nearby candidate); 38.360 (no nearby candidate); 42.580 (no nearby candidate); 45.650 (no nearby candidate); 46.600 (no nearby candidate); 49.100 (no nearby candidate); 50.930 (missingPose); 51.220 (no nearby candidate); 59.310 (amplitudeTooSmall).
- **raw-juggling.mov**: 7.390 (insufficientContactViews); 8.550 (handsUncertain).

## Method, provenance and limits

- Source recordings were reviewed throughout using 6 fps still sequences, with denser checks of disputed contacts. `low.mov` was reviewed throughout at 12 fps because its contacts are roughly 0.3 s apart. Initial contact labels preceded inspection of that clip's counter outcome; a second pass refined ambiguous moments using denser source frames. All confirmed misses received closer review. Human review is still pending.
- Matching is chronological, one-to-one, maximizing the number of matches and then minimizing timing error. Tolerance is ±0.20 s normally and ±0.12 s for the rapid `low.mov`. Labels carry approximate timing uncertainty. No single acceptance can satisfy two contacts. Unmatched acceptances become false only when source review explicitly labels an invalid event or interval.
- Runtime: iPhone 17 Pro Max, reported OS `Version 27.0.1 (Build 24A446)`, existing Touch Counting Debug binary, production `VideoAnalyzer`, YOLO26-M revised masks + marginal retry, Apple Vision pose. Policies: `timedFootMotionV6`, `corroboratedFeet` / counter-v9, `sustainedGripV1`. Cache was bypassed, no frame limit, acceleration study, overlay or debug FPS simulation was enabled. Interrupted attempts were excluded; all saved runs completed and flushed their traces.
- The app processed **46,987 composition output image buffers**. Container metadata lists 47,290 frames/packets. Edit-list discard entries explain most differences; production `EffectVideoGeometry.composition` also sets cadence from nominal track FPS and can resample. For example `raw-juggling` produces 293 buffers versus 342 source packets, with roughly 39 ms output spacing after its held opening frame. This measures the actual production import pipeline, not one-to-one native packet decoding. Processing wall-clock speed is not camera FPS, and this does not substitute for an iPhone 11 live-capture test.
- [manifest.json](manifest.json) records source SHA-256 hashes, input metadata, completed-run status, packet accounting, policies, code hashes, app binary hash and original trace/report hashes. Counting/detection source hashes and the local build binary were checked unchanged. No source footage was modified.
- [labels/](labels/) contains the reviewed contact events, uncertain moments and invalid intervals. [predictions/](predictions/) contains compact baseline acceptances and diagnostic events. [results/](results/) contains event matches and discrepancies; [summary.json](summary.json) collects the clip results. Full phone traces/reports and review stills remain local under `artifacts/touch-corpus-review-20261014/` and are not intended for Git. No annotated videos were created.

Reproduce scoring from the compact saved baseline, from the repository root:

```sh
python3 -m unittest discover -s benchmarks/touch-counting/corpus-20261014 -p 'test_score.py'
python3 benchmarks/touch-counting/corpus-20261014/score.py
```

Six scorer checks cover one-to-one matching, maximum-cardinality matching, timing tolerance, uncertainty, negative intervals and missing diagnostics. A different prediction directory can be supplied with `--predictions`; source hashes must match. Keep this baseline frozen when comparing future rule changes, and reserve new recording sessions for evaluation rather than tuning everything against these clips.
