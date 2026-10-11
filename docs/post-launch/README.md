# Four-week post-launch plan

Documented: 2026-10-11. Status: planned; no implementation is completed by this document.
Week 1 starts after the first public release, rather than on the documentation date.

The first month's priorities are trustworthy counting, better ball detection and
tracking, dependable sessions on older devices, and a fair leaderboard. Replay quality
and shot-camera improvements follow.
Google/email rollout is a small early release alongside that work. TikTok sign-in,
additional effects and production trick recognition can follow later.

## Schedule and scope

Assume one primary developer and 20 working days, including five days for device
verification, fixes and release preparation. Ship smaller updates as they are ready;
App Store review and external provider approvals are outside the engineering estimate.
These are planning allocations, not guarantees that every investigation will succeed.

| Week | Implementation allocation | Verification / fixes | Intended release |
| --- | --- | --- | --- |
| 1 | 4 days: detection baseline, contact accuracy, older-device reliability and provider setup | 1 day | Core reliability update |
| 2 | 1 day: Google/email; 3 days: reviewed leaderboard beta | 1 day | Sign-in rollout and a gated leaderboard beta |
| 3 | 3 days: detection/tracking and ball replacement; 1 day: essential effects/UI fixes | 1 day | More continuous tracking and cleaner replays |
| 4 | 1 day: shot camera; 2 days: far-ball detection and measurement validation if time permits | 2 days | Camera/detection improvements; measurement beta only if validated |

The dependency order is detection/contact accuracy and session reliability, then
ranked streak validation, then the public leaderboard. Authentication must work before
ranked submissions. Far-ball detection and tracking must be validated before expanding
shot measurements. Measurement validity determines the supported camera setup.

The added detection work uses the same four-week budget: cosmetic UI work and broader
effect enhancements become stretch scope, and measurement expansion is conditional.
Full model retraining is not a guaranteed first-month deliverable; ship bounded,
validated improvements and carry larger experiments into the next cycle.

## Prioritized backlog

The original item numbers refer to the launch follow-up list. Google/email and TikTok
are separated because their priority and release scope differ.

| Order | Original item | Task | Priority | Difficulty | First-month commitment |
| --- | --- | --- | --- | --- | --- |
| 1 | 4 | One-hand touches mistaken for chest/head | Critical | High | Fix known cases while preserving valid touches. |
| 2 | 3 | iPhone 11/12 live counting | Critical | High | Improve live performance and provide reliable record-then-analyse fallback. |
| 3 | Added follow-up | Model accuracy, far-ball detection and continuous tracking | High | High | Benchmark in Week 1; bounded accuracy/continuity improvements in Week 3 and far-ball work in Week 4. |
| 4 | 1 | Google and email sign-in | High | Low–medium | Complete production rollout and verify account continuity. |
| 5 | 2 | Fair leaderboard | High | High | Small opt-in beta with reviewed scores after counting validation. |
| 6 | 8 | Ball masking and replacement | High | Medium–high | Remove original-ball edge leakage and improve preview/export consistency. |
| 7 | 6 | UI edge cases and transitions | Medium | Low–medium | Address usability problems throughout the month; cosmetic work is stretch scope. |
| 8 | 9 | Existing fire/rainbow effects and execution cost | Medium | Medium | Fix essential performance issues; broader enhancements and new effects are stretch work. |
| 9 | 10 | Distance-shot camera experience | Medium | Medium | Improve placement guidance, framing and recording feedback. |
| 10 | 5 | Real speed and distance travelled | Medium | High | Validate a defined measurement mode if detection work leaves time; ship only with supporting evidence. |
| 11 | 7 | Around the World recognition | Later | High | Optional feasibility prototype; no production commitment this month. |
| 12 | 1 | TikTok sign-in | Low | Medium | Defer until there is clear demand. |

An edge case that blocks recording, loses a session or prevents saving is a critical
fix regardless of the general UI priority above.

## Model improvements: accuracy, far balls and continuous tracking

Treat these as three related goals. Improving the detector and improving continuity
across frames both matter; a visually smooth prediction is not proof the ball was detected.

| Goal | Planned work | Evidence of improvement |
| --- | --- | --- |
| Better ball detection | Collect and label missed balls and false positives across ball designs, lighting, backgrounds, fast motion and partial occlusion. Compare detector tuning and targeted fine-tuning candidates against the current model. | Higher detection recall without an unacceptable rise in false positives; stable ball location/size and no counting regression. |
| Far-ball detection | Add small/distant-ball examples and confusing background objects. Evaluate targeted crops, selective higher-resolution analysis and distant-ball recovery within device budgets. | Better recall for visible small balls, fewer false detections on background objects and a documented supported range. |
| Continuous ball detection/tracking | Reduce flickering detections, short dropouts and switches to another ball/object. Improve short-gap recovery and reacquisition after occlusion or leaving/re-entering the frame. | Fewer and shorter gaps while the ball is visible, fewer identity switches and faster correct reacquisition. |

- [ ] Establish a versioned baseline in Week 1, covering both live capture and imported
  video. Include iPhone 11/12 and a newer device, near/far balls and difficult negatives.
- [ ] Split training/tuning and evaluation by recording/session, and by player where
  practical; do not place adjacent frames from the same recording in both sets.
- [ ] Measure precision, recall and location/size error. Break results down by the
  ball's pixel size at detector input, visibility, lighting and device. Do not promise
  a distance in metres unless camera setup and ball size are controlled.
- [ ] Measure visible-ball coverage, gap duration, identity switches and reacquisition
  time. Label full occlusions/out-of-frame intervals separately from missed visible balls.
- [ ] Keep observed detections distinct from predictions. Bound any gap recovery and
  stop or mark tracking uncertain when evidence is insufficient; do not invent touches,
  bridge ranked streaks or calculate speed/distance from unsupported predictions.
- [ ] Compare model changes and tracking-policy changes separately so the source of
  an improvement or regression is clear. Include masks/replacement quality in evaluation.
- [ ] Record model/data versions and evaluate inference latency, memory, dropped frames
  and thermal behaviour on physical devices before replacing the shipped model.
- [ ] Keep the existing model available for rollback. Ship a candidate only after
  held-out accuracy, counting and device-performance checks pass.

**Release gate:** set numerical targets and acceptable tradeoffs after the Week 1
baseline, before evaluating candidates. Ship only measured improvements within the
older-device budget. Broad retraining or a larger model moves to the next cycle if
the bounded experiments do not meet those checks.

## Week 1: Core session reliability

- [ ] Establish the detection and tracking baseline described above and identify the
  highest-impact missed-ball, far-ball and dropout cases.
- [ ] Assemble labelled recordings of one-hand taps near the face/chest, catches,
  throws, ground bounces, genuine chest/head touches and normal foot juggling.
  Include different lighting, camera angles and partial occlusion; hold back some
  recordings for validation rather than tuning against every example.
- [ ] Fix contact decisions using movement before and after the contact. A nearby
  hand alone must not invalidate a genuine chest/head touch.
- [ ] Measure false accepted touches and missed legitimate touches separately.
- [ ] Profile sustained live sessions on physical iPhone 11 and 12 devices, plus a
  newer reference device: processing time, dropped frames, memory and thermal state.
- [ ] Reduce optional rendering work before sacrificing counting accuracy. When live
  analysis cannot keep up, preserve the recording and finish analysis afterward with
  clear progress and completion feedback.
- [ ] Start any outstanding Google/email production setup and recheck provider status.

**Release gate:** known hand-contact failures improve without regression on valid
touches in held-out recordings. Older devices consistently complete and retain a
usable session, with a clear fallback wherever live counting remains unreliable.
Record device-specific results and remaining limitations before shipping.

## Week 2: Sign-in and a fair leaderboard beta

- [ ] Enable Google/email after production setup and end-to-end verification of new
  sign-in, cancellation, expired links, retries, sign-out and restored sessions.
- [ ] Verify guest history survives sign-in and that account changes do not
  unexpectedly split or overwrite player progress.
- [ ] Implement the ranked streak rules below, distinct from total session touches.
- [ ] Add explicit submission, pending, approved and rejected states with useful
  explanations and a review route.
- [ ] Support deliberate submission of original recordings for private review.
  Explain who can access the recording and how long it is retained.
- [ ] Make approval a trusted backend operation; clients cannot approve their own scores.
- [ ] Start with a small opt-in beta where every published score has been reviewed.
  Bound participation to the review capacity available.
- [ ] Test that known hand/ground exploit recordings cannot appear as valid streaks,
  retries cannot create duplicate entries, and unapproved submissions remain private.

**Release gate:** authentication works for ordinary users and approved leaderboard
scores are supported by their recordings. If counting or review is not ready, ship
authentication separately and keep the leaderboard beta private.

### Initial leaderboard rules

| Topic | Rule |
| --- | --- |
| Score | Longest uninterrupted valid streak, not accumulated session touches. |
| Valid contacts | Feet, head and chest. Thighs/knees are excluded unless the ranked rules are deliberately expanded. |
| Hands, arms and ground | End the current streak. Subsequent juggling starts a new streak; do not merely omit the invalid contact and keep adding. |
| Initial hand release | A normal setup release earns no points; the streak begins at the first valid contact. |
| Uncertain contact or tracking gap | Keep the attempt pending review. Never silently bridge uncertainty into a verified streak. |
| Source | Original, unedited in-app recordings initially. Gallery imports remain available for personal analysis. |
| Older devices | In-app recordings analysed afterward use the same scoring and review rules. Live processing speed does not determine eligibility. |
| Board | One best approved score per account, a weekly board, your rank, nearby players and a personal best. |
| Week / ties | Retain the existing Monday 00:00 UTC boundary and earlier-result tie break, and explain them in the rules. |
| Suspicious results | Review implausible touch rates, unusually high scores and duplicate recordings. A legitimate 1,000-touch run can still qualify. |
| Disputes | Provide reporting and re-review, with a clear reason when an attempt does not qualify. |
| Participation | Opt-in; ordinary training remains available without entering the leaderboard. |
| Excluded initially | Prizes, paid score advantages, trick multipliers, multiple divisions and numerous separate boards. |

The current backend calls scores device-reported. Submission limits catch some
obvious abuse, but plausible numbers do not prove legitimate contacts. Automatic
verification beyond the reviewed beta requires separate validation; reviewing only
top scores would leave lower positions less protected.

## Week 3: Detection continuity, replay quality, effects and UI

- [ ] Address the highest-impact detection and short-gap tracking failures from the
  baseline; compare held-out results before and after each candidate change.
- [ ] Remove visible original-ball edges during replacement, especially in fast
  movement and partial occlusion; do not hide leakage by indiscriminately enlarging
  the replacement over the player's body.
- [ ] Check replacement shape, size and timing across consecutive frames.
- [ ] Align preview and saved-video ball coverage and placement. Verify both paths.
- [ ] Fix essential fire/rainbow performance problems using profiling. Broader resource
  reuse, lighter quality options and visual enhancements follow if the detection work
  leaves capacity.
- [ ] Set performance targets using Week 1's baseline and record before/after results.
  Improved rendering must not worsen counting accuracy or session completion.
- [ ] Fix loading feedback, cancellation, retries, back navigation, save confirmation
  and interrupted flows. Polish transitions after the functional issues.

**Release gate:** visible-ball tracking improves without unsupported gap filling;
representative clips show cleaner ball coverage in preview and export, effects stay
within the measured device budgets, and saving still succeeds.
Additional effects are optional only after these checks pass.

## Week 4: Shot camera and measurement validation

- [ ] Prioritize far-ball detection/recovery on the supported shot setup. Validate
  visible small-ball recall and false positives before extending measurement range.
- [ ] Improve camera placement guidance, framing, ball visibility, setup readiness
  and tracking-loss feedback.
- [ ] Define each result precisely: distance from the starting point, total distance
  travelled, average speed and peak speed are different quantities.
- [ ] Start with a narrow supported capture setup. The existing experimental
  ground-ball geometry and speed estimator do not establish accurate airborne-shot
  measurement; document the supported surface, camera setup and motion range.
- [ ] Compare against measured distances and independent timing/reference measurements.
  Define the acceptable error before the final evaluation and record the observed range.
- [ ] Withhold measurements when calibration, visibility or tracking is insufficient.
- [ ] Release a limited measurement beta only if its accuracy is supported; otherwise
  keep measurement experimental and ship the completed camera improvements.

**Release gate:** camera guidance works on the target devices. Any released speed or
distance result has an explicit definition, supported conditions and measured accuracy.

## Around the World: optional investigation

The trick is **Around the World (ATW)**: the foot circles the airborne ball before
the player continues juggling. See the [Online Soccer Academy demonstration](https://www.onlinesocceracademy.com/soccer-training-videos/tricks-skills/how-to-do-around-the-world-john-farnworth).

A constrained replay prototype is medium–hard. Reliable live recognition across
camera angles and older devices is hard: it must follow the foot around the ball,
handle occlusion and confirm a successful continuation.

If the committed work finishes early, spend at most 1–2 days on a feasibility
experiment using one camera angle, one variation and analysis after recording.
This is an investigation budget, not a production-delivery estimate. Keep any trick
recognition separate from ranked scoring until independently validated.

## Delivery rules and follow-up

- Ship completed improvements early; do not wait for the end of four weeks.
- Review actual failure rates, device results and user feedback after each update.
  Existing opt-in analytics can track session, import, sign-in and export outcomes;
  those events do not establish counting accuracy and do not represent every user.
- If ahead of schedule, pull forward one lightweight effect or the ATW experiment.
- If behind schedule, cut new effects, cosmetic transitions and measurement expansion
  first. Preserve detection/counting accuracy, older-device verification and leaderboard fairness.
- Keep TikTok sign-in, broad automatic anti-cheat, unrestricted airborne measurements
  and production trick recognition in the follow-up backlog.
- Mark checkboxes only after verification. Record each shipped version, evidence and
  any deferred scope in this document as implementation progresses.

## Existing implementation references

These describe the checkout inspected on 2026-10-11, not newly verified production status.

- [Account rollout and provider setup](../auth-setup.md): Google/email flows exist;
  their production readiness must be rechecked before enabling the hidden controls.
- [Sign-in controls](../../kicklab/Account/SignInView.swift): launch exposes Apple and guest.
- [Contact rules](../../kicklab/Counting/JugglingContactRules.swift): existing practice
  counting accepts broader body contacts; the ranked feet/head/chest rule needs its own validation.
- [Current leaderboard schema](../../supabase/migrations/202610090001_profiles_and_juggling.sql)
  and [submission limits](../../supabase/migrations/202610100001_submission_limits.sql).
- [Device performance instrumentation](../../kicklab/Detection/DetectorPerformance.swift).
- [Experimental ground-ball geometry](../../kicklab/Detection/ShotRollDistance.swift).
- [Existing product analytics and consent](../product-analytics.md).

This roadmap documents future work only. It does not enable features, change scoring,
change analytics collection or alter the release configuration.
