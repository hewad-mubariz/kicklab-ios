**Completed body-gate assessment — 24 October 2026**

Bypassing the body rejection recovers genuine juggling contacts, but it also introduces confirmed false counts. The experiment is not enabled for ordinary recording. `Touch Counting Debug` build `2026102402` remains on the current `footEvidenceV15` rules.

All **22 clips / 44 complete replay passes** finished on the iPhone. Both arms used identical archived ball/player observations, current counter settings, fresh Vision evidence, and unchanged hand, holding and ground checks. Strict input/configuration/body-evidence checks passed for every pair. These are controlled development-footage results, not a claim about general live-camera accuracy.

| Measure on the 20 labelled corpus clips | Current rules | Body rejection bypassed |
|---|---:|---:|
| Labelled legal contacts | 615 | 615 |
| Legal contacts counted | 568 | 592 |
| Legal contacts missed | 47 | 23 |
| Confirmed false counts | 5 | 10 |
| Accepted uncertain events | 5 | 7 |
| Unmatched predictions needing review | 0 | 2 |

The bypass recovered **24 additional labelled legal contacts** and introduced **5 additional confirmed false counts**. Recall on the labelled legal contacts was 92.4% → 96.3%. Uncertain and unmatched events receive no true-positive credit. The frozen corpus labels and original scorer were preserved.

Concrete evidence:

- `eighteen`: 15 → 18, recovering all three missed labelled leg contacts (3.740, 6.312 and 13.861 seconds).
- `latest`: 12 → 13 in this frozen-input replay, adding a visible foot contact at 6.885 seconds. Its hand toss at 3.784 seconds remains rejected: body rejection before, independent hand rejection after. This replay does not rerun live detector/contact rechecks; do not compare its total directly with the original live total.
- `normal_juggling_4`: 33 → 36. The three additions consist of one labelled legal touch, one uncertain event and one false count at 34.241 seconds while the ball is being moved along the turf.
- `juggling_second_ball_in_video`: 19 → 34. Nine additional labelled legal contacts, four confirmed false counts while the foreground player holds the ball (19.041, 19.916, 20.541 and 20.725 seconds), and two unmatched events. Source-image review confirms the hand holds; the unmatched events remain excluded from correctness credit.
- The ball-in-hand and two requested dribbling controls remain 0 → 0. However, their proposals are rejected before the body gate, so those zeros alone cannot establish that the independent hand check is sufficient.

The five-minute walkthrough rises **201 → 239**. Of the 38 additions, source-frame review found **24 clear legal contacts, one visible hand catch and 13 uncertain contacts**. The catch at 144.360 seconds is a concrete failure of the existing independent hand/holding checks after the body gate is removed. Among the 20 previously reviewed misses, current rules count 10 and the bypass counts 18. That is a selected positive subset, not whole-clip recall. Ground rejections remain 41 in both arms, as expected for a body-only experiment.

The separate review of 20 historical body rejections found seven legal contacts, eight hand events and five uncertain contacts. Current rules already recover five of those seven legal contacts; the bypass recovers the remaining two. All eight sampled hand events remain rejected by the independent hand check. This coexistence of passing sampled controls and a failing catch elsewhere is why broad claims need full event-level review.

The separate review of 20 historical ground rejections found two clear legal contacts, one clear invalid event and 17 uncertain events. Many exact impacts are cropped at the lower edge of the image. One of the two legal contacts is already accepted under current rules; the other now fails the player-region check. This sample cannot support a reliable ground false-rejection percentage, nor justify rewriting all ground checks.

The original assessment was right that uncertain body evidence can lose legal touches, and that hand/ground safeguards must be evaluated before relaxing it. Its proposed measurement-first approach makes sense. The experiment does not support accepting every missing-pose/missing-ball/invalid-geometry event, or inferring a toe touch from horizontal alignment over a foot. Missing evidence also hides hand holds and non-juggling activity. The 7.667-second toe-flick issue was already fixed in the 19 October work; today's passing ground-evidence fixture verifies that existing rule. Rejection-to-acceptance ratios are not miss rates. Part labels and confidence flags may help explain outcomes, but they are not evidence that an extra count is correct and should not silently alter leaderboard streaks.

The implemented changes are a debug-only, auditable comparison provider, a replay mode that isolates the body gate, explicit legacy video-clock compatibility, two counting regression tests, and a scorer that refuses incomplete or mismatched comparisons. No production counting threshold, detector or leaderboard rule was relaxed. The targeted device run passed 42 tests with zero failures/skips; six existing Python scorer tests passed; the signed final build succeeded.

For a useful new live recording, keep your full body, both feet and a clear margin of floor visible. Record 30–45 seconds of normal juggling and low toe taps, adding a few knee/chest contacts if comfortable. Then separately record roughly 15 seconds of holding/tossing the ball, floor bounces and rolling it near a foot. Save both clips and report the displayed totals. These will test current capture behavior and provide clearer positive/negative examples than the cropped walkthrough.

[Method and limitations](/Users/hewadmubariz/Desktop/projects/kicklab/benchmarks/touch-counting/body-gate-review-20261024/method.md) · [Full machine-readable comparison](/Users/hewadmubariz/Desktop/projects/kicklab/benchmarks/touch-counting/body-gate-review-20261024/comparison.json) · [Summary](/Users/hewadmubariz/Desktop/projects/kicklab/benchmarks/touch-counting/body-gate-review-20261024/summary.json) · [Walkthrough added-event labels](/Users/hewadmubariz/Desktop/projects/kicklab/benchmarks/touch-counting/body-gate-review-20261024/walkthrough-added-review.json) · [Additional visual review](/Users/hewadmubariz/Desktop/projects/kicklab/benchmarks/touch-counting/body-gate-review-20261024/additional-visual-review.json)

| Clip | Current count | Bypass count | Legal matches, before → after | False counts, before → after |
|---|---:|---:|---:|---:|
| 34dd | 17 | 18 | 17 → 18 | 0 → 0 |
| ball_in_hand | 0 | 0 | 0 → 0 | 0 → 0 |
| dribbling_with_ball_1 | 0 | 0 | 0 → 0 | 0 → 0 |
| dribbling_with_ball_2 | 0 | 0 | 0 → 0 | 0 → 0 |
| dribbling_with_ball_3 | 1 | 1 | 0 → 0 | 0 → 0 |
| dribbling_with_the_ball_1 | 0 | 0 | 0 → 0 | 0 → 0 |
| eighteen | 15 | 18 | 15 → 18 | 0 → 0 |
| juggling | 37 | 37 | 37 → 37 | 0 → 0 |
| juggling_second_ball_in_video | 19 | 34 | 19 → 28 | 0 → 4 |
| juggling_second_ball_very_far | 23 | 25 | 20 → 22 | 1 → 1 |
| low | 175 | 177 | 175 → 177 | 0 → 0 |
| nomral_juggling_6 | 36 | 36 | 34 → 34 | 2 → 2 |
| normal_juggling_1 | 25 | 25 | 25 → 25 | 0 → 0 |
| normal_juggling_2 | 21 | 22 | 21 → 22 | 0 → 0 |
| normal_juggling_3 | 63 | 65 | 62 → 63 | 0 → 0 |
| normal_juggling_4 | 33 | 36 | 30 → 31 | 2 → 3 |
| normal_juggling_5 | 37 | 38 | 37 → 38 | 0 → 0 |
| normal_juggling_7 | 29 | 31 | 29 → 31 | 0 → 0 |
| normal_juggling_8 | 37 | 38 | 37 → 38 | 0 → 0 |
| raw-juggling | 10 | 10 | 10 → 10 | 0 → 0 |
| walkthrough | 201 | 239 | Selected-event review only | No whole-clip total |
| latest | 12 | 13 | Selected-event review only | No whole-clip total |
