# Latest iPhone recording: event-level review

Reviewed the 35.065-second recording started on 24 October 2026 at 21:25:47 Berlin time, from Touch Counting Debug on iPhone 17 Pro Max, build 2026102402.

**The live counter saved 18. Visual review finds 19 legal foot contacts across the separate attempts: 16 counted correctly, three missed, and two extra counts.** The two extras partially conceal the three misses. This is not a single uninterrupted 19-touch streak.

| Approximate source time | Visible action | Saved live behavior | Finding |
| --- | --- | --- | --- |
| 20.80 s | Ball held in both hands, then raised for another attempt | Counted, frame 623 | False count from hand handling |
| 22.79 s | Raised right foot contacts the ball; hands do not touch it | Rejected, frame 683: `handsNearBall`; hand contact not confirmed | Legal touch missed |
| 23.38 s | Ball strikes the carpet while both feet remain separate from it | Counted, candidate frame 700 at 23.366 s | Floor bounce counted |
| 30.56 s | Raised right foot makes a clear contact | Rejected, frame 916: `insufficientContactViews`; hand contact not confirmed | Legal touch missed |
| 31.33–31.35 s | Left foot contacts the ball; it rebounds slightly upward and sideways | No candidate reaches the contact verifier | Legal touch missed upstream |

## What is wrong

### 1. A foot is mistaken for a wrist

At 22.8 s, fresh pose inference on the exact saved frame places the right wrist on the raised foot and the right ankle near the actual right hand. The estimated wrist has confidence about 0.62; the misplaced ankle is weak, about 0.17. This is a concrete limb-identification failure, not an actual hand touch.

The saved live decision is `disallowedBodyContact / handsNearBall`, with `handConfirmed=false`. Both replay arms reproduce the underlying body rejection, and the arm that bypasses only body eligibility counts this event. The replay pose explains how a legal raised-foot touch can trigger the clearance rule while the separate hand-contact check remains negative. Low-confidence leg evidence also makes the existing recovery paths ineffective here.

[View pose overlay](../../../artifacts/latest-recording-20261024-2126/pose-683.jpg) · [View consecutive contact frames](../../../artifacts/latest-recording-20261024-2126/detail-missed-high-foot.jpg)

Relevant code: `JugglingContactVerifier.allowsBodyContact`, `ClearHandsContactRules.failure`, and the raised-leg recovery rules. The distinction between “a wrist estimate is near the ball” and “a hand physically contacts the ball” matters here.

### 2. The held-ball check has a brittle boundary

At 20.8 s, the body gate permits the event, the hand veto is false, and the handling check returns `uncertain`. The counter only vetoes handling classified as `held`, so this visible hand movement increments the count.

Re-evaluating the exact saved handling samples with the current Swift implementation confirms `uncertain`. At the proposed contact, the left wrist-to-ball distance is about **1.153 ball diameters**, just outside the grip limit of **1.15**. The contact grip test therefore fails despite adjacent samples showing both wrists around the ball. The replay also counts this hand movement.

The fresh replay returns from the immediate body-region eligibility path without collecting the later clear-hands samples. Proximity to a legal body region can establish eligibility, but that is not proof of a kick; downstream handling checks need to resolve this case reliably. Simply increasing the distance threshold has not been validated and could reject legitimate nearby foot touches.

[View held-ball overlay](../../../artifacts/latest-recording-20261024-2126/pose-623.jpg) · [Saved handling samples](../../../artifacts/latest-recording-20261024-2126/live-623-handlingEvidence.json)

### 3. The floor checks remain inconclusive and the event passes

The 60 fps sequence clearly shows the ball hitting the carpet at about 23.38 s. There is no intervening foot contact. The trace records `footConfirmed=false`, `plantedFeetConfirmed=false`, `bodyContactAllowed=true`, and `handRejected=false`.

The numeric evidence explains the escape through the ground checks:

- The smoothed ball center is 0.54575 in normalized image coordinates, above the original ground rejection boundary of 0.55374. The observed ball bottom crosses the ground estimate, but this extra lower-edge check requires additional evidence.
- The below-feet check rejects its own evidence because ball height varies by a factor of 1.419, exceeding its allowed 1.35.
- The planted-feet window includes the right foot settling after the preceding kick. Its raw image movement spans about 0.543 ball heights, exceeding the 0.5 stability bound.
- The separate short-window stationary-foot check is also false. A foot-contact confirmation is false as well, yet the remaining body eligibility path permits the event.

Re-running the actual Swift rules on the saved numeric evidence confirms all four ground/foot booleans are false. This is a gap between individually conservative checks: uncertain ground evidence and permissive body proximity combine into a false positive.

[View every floor-impact frame](../../../artifacts/latest-recording-20261024-2126/detail-floor.jpg) · [Numeric verification](../../../artifacts/latest-recording-20261024-2126/numeric-evidence-check.json)

### 4. Missing tracked-ball observations remove contact evidence

At 30.565 s, the input has a high-confidence ball observation. The next five analysis inputs, at approximately 30.598–30.732 s, have no ball. The next available observation is about 200 ms after contact.

`ClearHandsContactRules` requires a before/after bracket with each neighbor within 100 ms and a total span no greater than 150 ms. The immediate replay window contains only pre-contact samples and the contact itself. The saved live and replay decisions both report `insufficientContactViews`. A wider recovery window contains the later sample, but the available recovery rules still do not confirm the touch.

`ContactObservationStore.store` retains contact images only when a ball observation is present. A usable recorded image therefore does not automatically become a usable verifier sample. The saved video visibly contains the kick; the analysis evidence is incomplete.

[View this contact and rejection](../../../artifacts/latest-recording-20261024-2126/decisions-review/10.jpg)

### 5. A small rebound never becomes a candidate

At approximately 31.34 s, the left foot makes a visible contact, with a small upward and sideways rebound. The analysis loses the ball on both immediate post-impact inputs (31.332 and 31.365 s), then again on three inputs from 31.432 through 31.498 s.

Only a very small vertical rise survives in the recorded coordinates: ball y is about 0.328 at 31.398 s and 0.322 at 31.532 s. The state machine requires a resolved rising run and minimum rise of 0.007. No contact candidate is recorded around this foot touch in live or either replay arm. The later `trackLost` decision at 31.898 s belongs to the subsequent low trajectory, not a body-gate rejection of the earlier kick.

The evidence supports an upstream tracking/trajectory failure. It does not isolate a single tracker-internal reason: the ordinary recording does not preserve the full per-frame tracker failure log. Bypassing the body gate cannot recover an event that never reaches that gate.

[View every final-contact frame](../../../artifacts/latest-recording-20261024-2126/detail-last-foot.jpg)

## Recording and replay verification

- Source SHA-256: `536dc21ae695775e23ba35c38d5a035b0e82bebe386b6bbb5142d74a9731a912`.
- Full video decode passed; 2,101 saved frames match final capture diagnostics. Writer drops: zero. Capture-drop counter remains three throughout the sampled telemetry, with no increase during the reviewed action.
- Complete live trace: 1,051 analysis inputs plus final flush. Median processed cadence is about 29.98 fps. Recorded video is approximately 60 fps. All sampled thermal states are `fair`.
- Reviewed the full chronology at 6 fps and every saved decision in a 12 fps contact window. Ambiguous raised-foot, floor, and final-foot actions were checked using every saved frame and exact source presentation timestamps.
- Fresh on-device replay completed both arms with strict frame/time matching. Current-policy replay counted 15; body-eligibility bypass counted 20. The original live count remains 18. Fresh Vision replay does not reconstruct every live contact recheck, so these replay totals must not replace the saved live result. It reproduces the four named candidate-level errors above; the last foot touch still produces no candidate.
- Precision on this manually reviewed clip: 16/18 (88.9%). Recall: 16/19 (84.2%). These are results for this clip, not overall product accuracy.

## What should change next

1. Preserve and repair real image evidence around short tracking gaps, with exact frame identity, so contact checks have a post-impact view. Do not invent detections to fill those gaps.
2. Detect implausible wrist/ankle assignments across time, and use positive foot-contact evidence to resolve raised-foot cases. The 22.8 s overlay is a strong regression example.
3. Make sustained hand handling robust to a marginal wrist-distance failure. Keep genuine catches and throws as negative cases.
4. Reconcile the ground/body decision paths so a visible floor reversal cannot pass purely through body proximity after every ground/foot check is inconclusive.
5. Evaluate small sideways foot rebounds with adequate observed motion; do not globally lower trajectory thresholds based on this one example.

Use event-level labels and the existing regression corpus to evaluate changes. A larger final number alone would not demonstrate improvement. The app's production counting logic was not changed during this review. The debug app was returned to its ordinary launch state for another manual recording.

[Machine-readable labels and results](review.json) · [Original video](../../../artifacts/latest-recording-20261024-2126/source.mov)

## Follow-up: pending entry and the section after 19 seconds

At 21:46 Berlin time, pulled the newest durable history movie and its metadata directly from the phone, rather than relying on the earlier temporary-file copy. Session ID: `F191C09B-E972-4AB5-B20C-1A6FBDBAF335`. The downloaded movie has the identical SHA-256 listed above. Both debug and main-app temporary recordings and durable histories were inspected; no later saved recording was present. This is another copy of the same recording, not an independent second test. Its local history sync state is `deviceOnly`; this inspection does not establish any remote review status.

The user's description matches the saved count numbering precisely:

| App touch number | Time | Follow-up finding |
| --- | --- | --- |
| 1–8 | 8.433–17.233 s | All eight are valid foot contacts. No counting errors identified before 19 s. |
| 9 | 20.099 s | Valid foot contact |
| 10 | 20.799 s | Invalid: hand-held movement |
| 11–12 | 21.466, 22.066 s | Valid foot contacts |
| No increment | 22.799 s | Additional valid foot contact missed |
| 13 | 23.366 s candidate / approximately 23.38 s impact | Invalid: floor bounce |
| 14–18 | 24.532–28.399 s | Valid foot contacts, with a catch separating touch 14 from touches 15–18 |
| No increments | 30.565 and approximately 31.34 s | Both final foot contacts missed |

The missed final contacts are different failure paths: the first reaches the verifier and fails the required before/after evidence window; the second never becomes a trajectory candidate. The extra missed contact at 22.799 s is the limb-identification/body-eligibility failure described above.

The history metadata also stores `rankedProposal = {count: 6, startMS: 19949, endMS: 24682}`. Its six counted events are app touches 9–14. That is not a valid continuous six-touch streak: the interval includes the hand catch around 20.5–20.8 s and the floor bounce around 23.38 s, followed by another hand reset.

The visual legal runs contain **3, 1, 1, 3, 1, 3, 1, 4, 2** touches, totaling 19. The longest is **four**, at approximately **26.165, 27.065, 27.732, and 28.399 s**. The true runs inside the proposed six-touch interval are one, three, and one, separated by physical interruptions.

`RankedStreakProposal.suggest` splits only at supplied interruption boundaries. `TouchReviewEvidence.append` ignores accepted decisions, and `LeaderboardTouchReview.streakBoundaries` includes confirmed hand/hold/ground calls. Because these two invalid events were accepted, the required boundaries are absent, allowing separate attempts to join. Fixes must evaluate streak segmentation as well as total count. No phone history, score, or counting code was modified during this follow-up.

[Freshly pulled history metadata](../../../artifacts/pending-recording-review-20261024-2146/history.json) · [File identity verification](../../../artifacts/pending-recording-review-20261024-2146/identity-check.json)
