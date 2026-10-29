# Outdoor toe contacts V20

27 October 2026. Counter-only branch `codex/touch-counter-outdoor-contact-fix`,
based on main `fdfc35e`. Debug build `2026102705`, iPhone 17 Pro Max. No TestFlight
upload or main merge was performed for this change.

## Problem and change

The three visible toe contacts in the 8.19-second `IMG_8878.MOV` were rejected
as floor bounces. Shoe rotation produced a real kick with too little estimated
ankle travel for the broad foot-motion rescue. The planted-feet and deep-floor
proofs treated that small movement as evidence against contact.

V20 recognizes a narrower contact pattern using the existing ground poses:
confident ankle overlap within 0.3 ball diameters, ball center no more than 0.2
ball heights below that ankle, an observed upward ankle displacement of at least
0.08 ball heights (and 0.003 image heights) before impact, a resolved ball
approach, and two immediate release views showing upward separation. A later
floor rebound cannot supply the release: the first usable release must be
within 50 ms and every usable 25–100 ms release view must show separation.
This pattern invalidates the stationary-floor classification; the remaining
body, hand, and holding gates still execute. A versioned optional evidence flag
keeps historical traces exactly replayable.

The raised kick in `IMG_8880 3.MOV` at 12.230 seconds was rejected because an arm
projected close to the ball. After all existing eligibility recovery paths fail,
V20 also permits the existing three-view foot-contact rule to establish body
eligibility. This uses the same measured approach, foot motion, and ball release
already used for low-foot contacts. It cannot bypass the hand or holding vetoes.

`toe-contact-v20` is the local default in both Debug and Release. V19 remains
selectable in the Debug comparison harness. The policy signature changes the
analysis cache key. Detector, model, frame sampling, resolution, buffer size,
trajectory thresholds, and lookahead are unchanged. The extra raised-foot check
runs only for a candidate that would otherwise fail body eligibility and can
request additional cached/buffered pose observations.

## Verification

Original files were matched by SHA-256, not filename. The 8.19-second IMG_8878
is different from an older corpus file bearing the same name. Full source hashes
and event comparisons are in `comparison.json`.

| Recording | Baseline | V20 | Recovered contact times |
| --- | ---: | ---: | --- |
| IMG_8878, 8.19 seconds | 13 | 16 | 2.958, 5.093, 5.618 seconds |
| IMG_8880 3, 15.65 seconds | 30 | 31 | 12.230 seconds |

The final installed build reran both sources through fresh on-device Vision
contact verification on identical frozen detector inputs. All four recovered
events retain the same decision operation: no extra frames were awaited.

The 22-clip comparison preserved all 792 previously accepted event identities.
One extra event was accepted: `normal_juggling_7`, frame 1395, 11.625 seconds.
It matches independently saved label e019 at 11.63 seconds and a new visual
review confirms a visible foot kick. No event was removed. Original inputs were
identical in every comparison. These older corpus traces use pre-RF detections;
this validates rule behavior, not fresh RF detector accuracy.

The saved ground sweep evaluated 1,618 evidence records. Only the three target
toe contacts changed (six records because each appears in a trace and fixture).
All historical traces in that sweep replayed exactly. The existing seventeen
visible floor-bounce cases and sparse floor-bounce tests still pass.

Final simulator results: **85 Debug tests and 76 Release tests passed**, zero
failures. Signed Touch Counting Debug builds and the final installation succeeded.
Artifacts, original evidence, logs, XCResults, and discarded timing experiments
remain in `artifacts/outdoor-contact-fix-20261027/` (ignored generated files).

## Remaining limits

- The probable turf bounce at IMG_8880 15.190 seconds (frame 1822) remains
  accepted before and after. The adjacent foot moves, defeating the existing
  stationary-floor proof. The video cannot completely exclude a brief shoe
  brush. Therefore 31 is not a claim of 31 clean legal touches.
- Four frozen 30 FPS sampling phases of IMG_8878 improve from 14/15/14/14 to
  15/15/15/16. Some sampled low contacts remain unresolved. Across eight sampled
  comparisons neither recording loses a previously accepted event. This does
  not replace a new live recording.
- iPhone 11 hardware throughput was not rerun. No inference model or capture
  workload changed, but the candidate-only eligibility fallback can do extra
  pose work. Historical corpus errors remain; unchanged accepted events are not
  a claim that every existing event was correct.
