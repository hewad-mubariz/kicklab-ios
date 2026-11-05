# Streak absence rule: evidence, 4 November 2026

If the player or the ball is out of sight for 3 seconds between two counted touches, a new streak starts. Total touches stay. New sessions report `-streak-v4`; scores already synced are unchanged.

The priority is not ending a valid streak. A missed stop only leaves a streak slightly longer than it should be, and in this release a player can't ask for a check on a wrong break.

## What the rule does

The code is `kicklab/Counting/StreakVisibilityEvidence.swift`. The limit alone was not enough. Each of these came from a measured failure:

| Rule | What it fixes |
|---|---|
| Only checked when no touch was counted for 3 s | Normal juggling costs nothing. The 56-minute session has one such gap in 6,844 touches |
| A lone detection doesn't count without a second within 600 ms | False boxes in an empty frame restarted the clock. `normal_juggling_8`'s real exit measured anywhere from 1.77 to 3.5 s across runs, and now measures 3.27 to 3.5 s |
| A counted touch counts as a sighting, and the 300 ms around it never counts as missing | The simulation found high kicks that ended a valid streak when the only sightings were beside the touches |
| Every live absence needs the saved video to agree | The detector can miss something live. Video that can't be read proves nothing, so the streak carries on |

A missing player and a missing ball use the same check. If both are gone the stop usually reads as the player, and in rare cases as the ball.

The older "could not be checked" stop is unchanged: if no frames were analysed for 3 s and the saved video can't be read either, the streaks stay separate. This is the one path left that can split a valid streak without proof of an absence.

## Results

### Real recordings replayed through the rule ([replay-results.txt](replay-results.txt))

219 runs of 107 clips, 15,020 counted touches, 345 gaps of 3+ s, 50 breaks.

- **Hand-labelled clips:** 76 runs of 15 clips, 3,014 touches. 12 breaks, all at labelled stops, none in valid juggling.
- **56-minute session:** 6,844 touches, no breaks.
- **Same answer every run:** `normal_juggling_4` 7 of 7, `normal_juggling_8` 5 of 5, and the two walkthrough stops 5 of 5 each.

The 50 breaks come from 8 distinct stops:

| Stop | Checked by |
|---|---|
| `normal_juggling_4`, 12 s | Label: ball then player outside the frame |
| `normal_juggling_8`, 28 s | Label: ball outside the frame |
| Walkthrough, 56 s | Watched: ball rolled out below the frame |
| Walkthrough, 130 s | Watched: player stands without the ball and picks it up |
| Hand clip, 50 s | Watched: ball left, player walked off and came back holding it |
| Recording of 25 October, 14 s | Watched: player walked out of the room |
| iPhone 11 recording, 24 s | Video not on this Mac. No known valid touch falls in the gap, and the next touch is marked a floor bounce |
| `sparse-floor-bounces`, 68 s | **Not checked.** Video not on this Mac; it comes from a floor-bounce test clip |

These traces hold the counter's ball input, which includes the pixel tracker, so they see slightly more of the ball than the raw model replies the app records. 21 of the runs hold the raw replies.

### Touches removed from real valid juggling ([stress-results.txt](stress-results.txt))

Only 4 real gaps of 3+ s exist in strictly valid juggling, which is too few to prove anything. So this removes the counted touches between two points in valid stretches, as if the counter had missed them.

85,409 forced gaps of 3 to 30 s on 16 clips: **no wrong breaks**, and the live check never even reached 3 s. Of these, 4,500 gaps use raw iPhone 11 replies on the `low` clip, also with none.

### Simulation ([simulation-100k.txt](simulation-100k.txt))

100,000 sessions per scenario at 7 to 30 replies per second, ball detection of 75 to 100% (the iPhone 11 measured 87 to 100% in play), and up to 0.6 false boxes per second.

| Must stay one streak | Wrong breaks |
|---|---|
| Touches missed by the counter | 0 |
| High kick, up to 11 m | 0 |
| Ball hidden by the body for up to 2.5 s | 0 |
| Player at the edge of the frame | 0 |
| Phone falling behind | 0 |
| Live detector blind, saved video clear | 0 |
| Saved video unreadable | 0 |
| Two very high kicks in a row, with the touch between missed | 3, all at 75% detection on 7 to 8 replies per second |

| Must end | Ended |
|---|---|
| Player and ball gone | 100% |
| Player gone, ball in view | 99.99% |
| Ball gone | 93.8% |

False boxes cause the missed ball stops, because two close together can still restart the clock ([ball-gone-breakdown.txt](ball-gone-breakdown.txt)). With no false boxes, 99.9% end. At 0.1 per second it's 98 to 99%, at 0.3 it's 86 to 96%, and at the worst measured 0.6 it's 61 to 87%, with short exits missed most. On real footage the affected clip still ended on all 5 runs. That is the accepted direction of error: a stop is missed, and no valid streak is lost.

The margin table in the results file shows where this starts to fail. Below about 60% detection on 5 to 10 replies per second, wrong breaks begin to appear, mostly with two very high kicks in a row.

### Real model on real videos (`StreakAbsenceRealModelTests`)

The live detector is forced to report nothing, and the real model then reads the real saved frames, as the phone does after a session. This ran on the simulator, not on a phone.

- **Valid juggling:** 34 stretches from 15 videos. The model found the ball and the player in every one, so all 34 streaks were kept.
- **Real exits:** 5 stretches from 4 videos. The model agreed each time, so the streak ended.

Set `TEST_RUNNER_STREAK_FOOTAGE` to a folder holding the videos, or the test skips. `normal_juggling_*`, `walkthrough.mov` and the others come from `artifacts/body-gate-review-20261024/inputs`. `left-the-room.mov` is `artifacts/latest-recording-20261025-2212/source.mov`.

### Live warning ([live-warning-results.txt](live-warning-results.txt))

The recording screen counts down once the ball or player has been unseen for 1.5 s after the first touch. `LiveAbsenceClock` uses the rule's detections and limits as replies arrive. It only warns, because the saved video still decides after the session.

The wait comes from replaying 92 minutes of valid juggling (10,846 touches) through the same clock:

| Wait | Player warnings | Ball warnings |
|---|---|---|
| 1.0 s | 10 | 1 |
| 1.5 s | 2 | 1 |
| 2.0 s | 1 | 0 |

At 1 s, 8 of the 10 came from 16 minutes of iPhone 11-class runs, with the player in view. The ball column uses the counter's input, which includes the pixel tracker, so it may read low. Only 4 minutes of raw replies exist, with no warnings at any wait.

On the 135 real cases in `LiveAbsenceClockTests`, all 12 stops reach the "ended" state and none of the 123 valid stretches do. Three valid cases show the warning, all from one real moment of 1.6 s.

### Floor calls in unbroken juggling ([ground-calls-results.txt](ground-calls-results.txt))

A session on 4 November counted 274 touches of non-stop low juggling, but 41 floor calls cut its best streak to 23. The pose check can't tell a low toe tap from a floor bounce, because the ankle barely moves in either. Rebound height doesn't separate them either: real floor bounces also came back about 89% as high in the saved traces.

A floor call no longer ends a streak if any of these holds. None of them changes what the counter counts.

| Rule | Calls removed in that session |
|---|---|
| The same contact was counted one frame later | 6 |
| The foot check confirmed the foot | 11 more |
| The ball fell at most 2 ball heights, with a counted touch within 1.2 s either side | 24 more |

Three floor calls in a row with one touch between them still stand, because kick, bounce, kick, bounce isn't low juggling.

- **That session:** 274 touches, unchanged. Best streak 274, up from 23. Test: `StreakGroundCallTests`, fixture `session-274-counter-v9.plist`.
- **Real floor-bounce clips:** all 7 stops in `sparse-floor-bounces` stand.
- **Other saved stops:** 5 of 34 no longer end a streak. Three are in the results file and two were foot-confirmed. Walkthrough at 209 s and the long video at 1,239 s and 2,995 s were checked by eye as low foot touches. The two from `IMG_8878` are reviewed toe contacts.

**Known gap:** a real bounce from a low kick, with the next touch in rhythm, no longer ends the streak. No saved recording shows this, so it needs a phone test.

### Whole test target (iOS 27 simulator)

This run came before the floor-call rule. After that rule, the 464 Swift tests and the 93 streak and counter XCTests were run again and pass; the other XCTests were not.

- **Swift tests:** 464 of 464 pass when run one at a time. Run in parallel, about ten tests build `StadiumPreviewRenderer` at once and `MTKTextureLoader` never returns, so the run sticks and neighbouring tests fail their deadlines. The app builds one per export and one per preview. Use `-parallel-testing-enabled NO`.
- **XCTest:** 880 tests. 827 pass, and 49 skip because they need footage or a phone, including the 3 real-model tests above, which ran separately.
- **4 failures, none in this rule:** three in `SubscriptionStoreTests`, which pass on the iOS 18 simulator, and `testEditorUpgradeCostOnThisPhone`, which hit the 15-minute limit set for this run and passed in 20 minutes without one.

## Not tested

- The live path on a phone, including the warning. `RFBufferedLivePipeline.recordVisibility` has only been compiled. The plan is in [docs/streak-absence-phone-tests.md](../../../docs/streak-absence-phone-tests.md).
- How long the saved video check takes on a phone. It stops at 6 s per session; if it runs out, the rest of that session's stops are skipped and the streak is kept, except for gaps with no live frames at all, which become "could not be checked".
- Real high kicks and outdoor light. High kicks are calculated, not filmed.
- The iPhone 17's detection rates.

## Known gaps

- Stops shorter than 3 s rely on the hold and floor checks. Most recordings here are older than the hold check (26 October), so they don't show whether it catches them.
- Another person or a second ball in frame counts as seen.
- `supabase/migrations/202610220001_leaderboard_touch_review.sql` allows a fixed list of stop types that has none of `playerOutOfView`, `ballOutOfView` or `visibilityUnverified`. Normal score syncing doesn't send them. Add them before touch checks are turned back on, or those sessions may not send.

## Rerun

```sh
python3 extract.py runs.jsonl
swiftc -O -swift-version 5 ../../../kicklab/Counting/StreakVisibilityEvidence.swift stub.swift replay.swift -o replay   # replay.swift must be named main.swift
./replay runs.jsonl > rows.jsonl && python3 score.py rows.jsonl
python3 prepare-stress.py runs.jsonl ../corpus-20261014/labels/ valid.jsonl   # then build stress.swift the same way
python3 live_warning.py valid.jsonl   # warning counts at each wait
python3 ground_calls.py <folder with saved traces> ../../../kicklabTests/Fixtures   # floor calls that stop ending a streak
```

`simulate.swift` also needs `kicklabTests/StreakAbsenceSimulator.swift`, with its `@testable import` line removed. `fixture.py` builds the two fixtures in `kicklabTests/Fixtures`.
