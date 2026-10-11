# Four-week post-launch plan

Documented: 2026-10-11. Status: planned; no implementation is completed by this document.
Week 1 starts after the first public release, rather than on the documentation date.

The first month's priorities are trustworthy counting, dependable sessions on older
devices, and a fair leaderboard. Replay quality and shot-camera improvements follow.
Google/email rollout is a small early release alongside that work. TikTok sign-in,
additional effects and production trick recognition can follow later.

## Schedule and scope

Assume one primary developer and 20 working days, including five days for device
verification, fixes and release preparation. Ship smaller updates as they are ready;
App Store review and external provider approvals are outside the engineering estimate.
These are planning allocations, not guarantees that every investigation will succeed.

| Week | Implementation allocation | Verification / fixes | Intended release |
| --- | --- | --- | --- |
| 1 | 4 days: contact accuracy, older-device reliability and provider setup | 1 day | Core reliability update |
| 2 | 1 day: Google/email; 3 days: reviewed leaderboard beta | 1 day | Sign-in rollout and a gated leaderboard beta |
| 3 | 2 days: ball replacement; 1 day: effects; 1 day: UI | 1 day | Cleaner replays and smoother effects |
| 4 | 1 day: shot camera; 2 days: measurement validation | 2 days | Camera improvements; measurement beta only if validated |

The dependency order is contact accuracy and session reliability, then ranked streak
validation, then the public leaderboard. Authentication must work before ranked
submissions. Measurement validity determines which camera setup the shot feature supports.

## Prioritized backlog

The original item numbers refer to the launch follow-up list. Google/email and TikTok
are separated because their priority and release scope differ.

| Order | Original item | Task | Priority | Difficulty | First-month commitment |
| --- | --- | --- | --- | --- | --- |
| 1 | 4 | One-hand touches mistaken for chest/head | Critical | High | Fix known cases while preserving valid touches. |
| 2 | 3 | iPhone 11/12 live counting | Critical | High | Improve live performance and provide reliable record-then-analyse fallback. |
| 3 | 1 | Google and email sign-in | High | Low–medium | Complete production rollout and verify account continuity. |
| 4 | 2 | Fair leaderboard | High | High | Small opt-in beta with reviewed scores after counting validation. |
| 5 | 8 | Ball masking and replacement | High | Medium–high | Remove original-ball edge leakage and improve preview/export consistency. |
| 6 | 6 | UI edge cases and transitions | Medium | Low–medium | Address usability problems throughout the month; bound cosmetic work. |
| 7 | 9 | Existing fire/rainbow effects and execution cost | Medium | Medium | Optimize current effects; additional effects are stretch work. |
| 8 | 10 | Distance-shot camera experience | Medium | Medium | Improve placement guidance, framing and recording feedback. |
| 9 | 5 | Real speed and distance travelled | Medium | High | Validate a defined measurement mode; ship only if supported by evidence. |
| 10 | 7 | Around the World recognition | Later | High | Optional feasibility prototype; no production commitment this month. |
| 11 | 1 | TikTok sign-in | Low | Medium | Defer until there is clear demand. |

An edge case that blocks recording, loses a session or prevents saving is a critical
fix regardless of the general UI priority above.

## Week 1: Core session reliability

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

## Week 3: Replay quality, effects and UI

- [ ] Remove visible original-ball edges during replacement, especially in fast
  movement and partial occlusion; do not hide leakage by indiscriminately enlarging
  the replacement over the player's body.
- [ ] Check replacement shape, size and timing across consecutive frames.
- [ ] Align preview and saved-video ball coverage and placement. Verify both paths.
- [ ] Profile fire/rainbow effects, remove unnecessary work, reuse rendering resources
  and support lighter quality on slower devices.
- [ ] Set performance targets using Week 1's baseline and record before/after results.
  Improved rendering must not worsen counting accuracy or session completion.
- [ ] Fix loading feedback, cancellation, retries, back navigation, save confirmation
  and interrupted flows. Polish transitions after the functional issues.

**Release gate:** representative clips show cleaner ball coverage in preview and
export, effects stay within the measured device budgets, and saving still succeeds.
Additional effects are optional only after these checks pass.

## Week 4: Shot camera and measurement validation

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
  first. Preserve counting accuracy, older-device verification and leaderboard fairness.
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
