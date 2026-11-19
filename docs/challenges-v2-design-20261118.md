# Juggle Dude challenge system proposal

Build a catalogue of **52 solo challenges and 8 friend formats**. Put short, achievable challenges beside timed competition: a beginner can do three touches with one foot, while a returning player can chase a 30-second score or invite a friend. These are 60 content entries across reusable rule types, including difficulty ladders, rather than 60 unrelated game engines.

The current [Challenges screen](../kicklab/Navigation/JugglingChallengesView.swift) contains four practice goals and opens the existing camera with a numeric target. It does not yet award challenge completion, score a timed window, or run friend matches. The proposal below defines that next product step.

## What players see

The Challenges tab starts with three useful choices: **Try a challenge**, **Today's pick**, and **Challenge a friend**. Show four featured cards, then filters for Streaks, One foot, Footwork, Timed, Speed, Consistency and Friends. Include search and an All challenges list so 60 entries remain easy to find.

Each card shows the goal, duration or target, difficulty and how the result is judged. Use “Practice” for technique goals until the relevant detection is qualified. Do not show invented popularity or completion counts; today's pick can be an editorial rotation.

Every detail screen explains the exact rule, offers a short demonstration when available, and has **Try solo** plus **Challenge a friend** when that rule is supported for a match. An unfinished challenge stays available. A completed challenge keeps its best result and offers Retry; completion and winning are separate outcomes.

Suggested featured rotation:
- **Right Foot 3** or **Left Foot 3** for a quick beginner success.
- **Touch Sprint 30** for maximum counted touches in 30 seconds.
- **Best Streak 30** for the longest uninterrupted streak inside 30 seconds.
- **Race to 20** for a short time trial.
- **Rising Ladder** for structured practice.
- **Team Hundred** for cooperative play.

## Rules players can understand

A **streak** is consecutive valid touches. A hand, catch or ground contact ends that streak. A **total** adds valid touches across a fixed window even if the player drops the ball and restarts. The interface must name these differently: a 30-second total is not a 30-second best streak.

For timed rounds, show a three-second countdown, then **Go**. The authoritative round window begins at Go, and only contact timestamps within that window count. Touches before Go and at or after the end are excluded. A time trial measures from Go to the target touch, without rounding before comparison. Keep an uninterrupted result only when its full streak lies inside the window.

Endurance has a different, explicit rule: time runs from the first counted touch to a counted touch at or after the requested duration. There must be no intervening streak break. It is not judged from standing with the ball or from video duration alone.

A timer continues through drops in total-count and best-streak timed modes. It cannot pause during a scored round. Backgrounding or an interrupted capture produces an interrupted result, not a completed score. Tracking uncertainty produces **Review needed**, not a guessed success or a zero. Allow replay review before submitting a result.

Practice can retry freely. Official friend attempts use fresh in-app recordings after the match starts; imported clips remain useful for ordinary practice and sharing. A source restriction does not by itself verify a score. Label automatic results “Auto-counted”, not “Verified”.

For foot-specific challenges, left and right mean the player's anatomical feet, regardless of camera mirroring. Lock a declared weaker foot before starting. Wrong-foot or other-body-part touches break an exact technique attempt. The main app has not qualified automatic left/right-foot or sequence judging, so these start as practice or explicit shared-video review.

## Complete challenge catalogue

Judging labels describe the intended rule type, not an already shipped capability:
- **Counted streak** can reuse existing streak results but needs challenge completion tracking.
- **Timed scoring** needs a bounded timer, saved contact-window scoring and interruption handling.
- **Round scoring** adds series state and per-round results.
- **Practice or video review** needs technique detection validation before automatic competitive judging.
- **Friend match** adds invitation and shared-result state on top of its underlying rule.

### Streaks

| No. | Challenge | Difficulty | Goal and scoring | Judging |
| --- | --- | --- | --- | --- |
| 1 | First 3 | Starter | Reach 3 consecutive counted touches. A hand, catch or ground contact ends the streak. | Counted streak |
| 2 | Find Five | Starter | Reach 5 consecutive counted touches. A hand, catch or ground contact ends the streak. | Counted streak |
| 3 | First 10 | Starter | Reach 10 consecutive counted touches. A hand, catch or ground contact ends the streak. | Counted streak |
| 4 | Twenty Club | Build | Reach 20 consecutive counted touches. A hand, catch or ground contact ends the streak. | Counted streak |
| 5 | Thirty Flow | Build | Reach 30 consecutive counted touches. A hand, catch or ground contact ends the streak. | Counted streak |
| 6 | Half Century | Advanced | Reach 50 consecutive counted touches. A hand, catch or ground contact ends the streak. | Counted streak |
| 7 | Century Club | Expert | Reach 100 consecutive counted touches. A hand, catch or ground contact ends the streak. | Counted streak |
| 8 | Beat Your Best | Build | Reach one more than your recorded personal best. Freeze the target when you enter; use 3 if there is no prior streak. | Counted streak |

### One foot

| No. | Challenge | Difficulty | Goal and scoring | Judging |
| --- | --- | --- | --- | --- |
| 9 | Right Foot 3 | Starter | Complete 3 consecutive touches with only your right foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 10 | Left Foot 3 | Starter | Complete 3 consecutive touches with only your left foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 11 | Right Foot 10 | Build | Complete 10 consecutive touches with only your right foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 12 | Left Foot 10 | Build | Complete 10 consecutive touches with only your left foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 13 | Right Foot 25 | Advanced | Complete 25 consecutive touches with only your right foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 14 | Left Foot 25 | Advanced | Complete 25 consecutive touches with only your left foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 15 | Right Foot 50 | Expert | Complete 50 consecutive touches with only your right foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 16 | Left Foot 50 | Expert | Complete 50 consecutive touches with only your left foot. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 17 | Weaker Foot 10 | Build | Complete 10 consecutive touches with only your weaker foot. Choose left or right before starting and keep that choice fixed. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |
| 18 | Weaker Foot 30 | Advanced | Complete 30 consecutive touches with only your weaker foot. Choose left or right before starting and keep that choice fixed. The other foot, another body part, a hand or the ground breaks the attempt. | Practice or video review |

### Footwork patterns

| No. | Challenge | Difficulty | Goal and scoring | Judging |
| --- | --- | --- | --- | --- |
| 19 | Switch Six | Starter | Complete 6 consecutive foot touches in this exact pattern: LR, repeated 3 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |
| 20 | Switch Twelve | Build | Complete 12 consecutive foot touches in this exact pattern: LR, repeated 6 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |
| 21 | Switch Thirty | Advanced | Complete 30 consecutive foot touches in this exact pattern: LR, repeated 15 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |
| 22 | Double Step | Build | Complete 8 consecutive foot touches in this exact pattern: RRLL, repeated 2 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |
| 23 | Double Step Twenty | Advanced | Complete 20 consecutive foot touches in this exact pattern: RRLL, repeated 5 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |
| 24 | Triple Switch | Advanced | Complete 12 consecutive foot touches in this exact pattern: RRRLLL, repeated 2 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |
| 25 | Right Lead | Advanced | Complete 16 consecutive foot touches in this exact pattern: RRRL, repeated 4 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |
| 26 | Left Lead | Advanced | Complete 16 consecutive foot touches in this exact pattern: LLLR, repeated 4 times. L = left foot; R = right foot. Wrong foot, another body part or a drop breaks the pattern. | Practice or video review |

### Against the clock

| No. | Challenge | Difficulty | Goal and scoring | Judging |
| --- | --- | --- | --- | --- |
| 27 | Best Streak 15 | Build | Build your longest uninterrupted streak inside 15 seconds. After a drop you may start a new streak, but the clock keeps running. Only your longest streak is the score. | Timed scoring |
| 28 | Best Streak 30 | Build | Build your longest uninterrupted streak inside 30 seconds. After a drop you may start a new streak, but the clock keeps running. Only your longest streak is the score. | Timed scoring |
| 29 | Best Streak 45 | Advanced | Build your longest uninterrupted streak inside 45 seconds. After a drop you may start a new streak, but the clock keeps running. Only your longest streak is the score. | Timed scoring |
| 30 | Best Streak 60 | Advanced | Build your longest uninterrupted streak inside 60 seconds. After a drop you may start a new streak, but the clock keeps running. Only your longest streak is the score. | Timed scoring |
| 31 | Touch Sprint 15 | Build | Count as many valid touches as possible in 15 seconds. Drops are allowed; pickups and hand contacts do not count. The timer never resets. | Timed scoring |
| 32 | Touch Sprint 30 | Build | Count as many valid touches as possible in 30 seconds. Drops are allowed; pickups and hand contacts do not count. The timer never resets. | Timed scoring |
| 33 | Touch Sprint 60 | Advanced | Count as many valid touches as possible in 60 seconds. Drops are allowed; pickups and hand contacts do not count. The timer never resets. | Timed scoring |
| 34 | Keep It Up 10 | Starter | Keep one uninterrupted streak alive for at least 10 seconds, measured from the first counted touch to a counted touch at or after 10 seconds. A drop or catch ends the attempt. | Timed scoring |
| 35 | Keep It Up 20 | Build | Keep one uninterrupted streak alive for at least 20 seconds, measured from the first counted touch to a counted touch at or after 20 seconds. A drop or catch ends the attempt. | Timed scoring |
| 36 | Keep It Up 30 | Advanced | Keep one uninterrupted streak alive for at least 30 seconds, measured from the first counted touch to a counted touch at or after 30 seconds. A drop or catch ends the attempt. | Timed scoring |

### Speed goals

| No. | Challenge | Difficulty | Goal and scoring | Judging |
| --- | --- | --- | --- | --- |
| 37 | 3 in 3 | Starter | Reach 3 consecutive touches within 3 seconds after Go. A drop ends the attempt. Completion is the goal; saved elapsed time can be used for an identical-rule friend race. | Timed scoring |
| 38 | 5 in 5 | Starter | Reach 5 consecutive touches within 5 seconds after Go. A drop ends the attempt. Completion is the goal; saved elapsed time can be used for an identical-rule friend race. | Timed scoring |
| 39 | 10 in 10 | Build | Reach 10 consecutive touches within 10 seconds after Go. A drop ends the attempt. Completion is the goal; saved elapsed time can be used for an identical-rule friend race. | Timed scoring |
| 40 | 15 in 15 | Build | Reach 15 consecutive touches within 15 seconds after Go. A drop ends the attempt. Completion is the goal; saved elapsed time can be used for an identical-rule friend race. | Timed scoring |
| 41 | Race to 10 | Build | Reach 10 consecutive touches as quickly as possible, within 30 seconds. Score is the time from Go to touch 10; lower is better. A drop or timeout is an unfinished attempt. | Timed scoring |
| 42 | Race to 20 | Build | Reach 20 consecutive touches as quickly as possible, within 45 seconds. Score is the time from Go to touch 20; lower is better. A drop or timeout is an unfinished attempt. | Timed scoring |
| 43 | Race to 30 | Advanced | Reach 30 consecutive touches as quickly as possible, within 60 seconds. Score is the time from Go to touch 30; lower is better. A drop or timeout is an unfinished attempt. | Timed scoring |
| 44 | Race to 50 | Advanced | Reach 50 consecutive touches as quickly as possible, within 90 seconds. Score is the time from Go to touch 50; lower is better. A drop or timeout is an unfinished attempt. | Timed scoring |

### Consistency

| No. | Challenge | Difficulty | Goal and scoring | Judging |
| --- | --- | --- | --- | --- |
| 45 | Three Fives | Starter | Complete three separate streaks in order: 5, 5, 5 touches. Rest between rounds. Solo practice can retry a failed round; a scored series has one attempt per round. | Round scoring |
| 46 | Three Tens | Build | Complete three separate streaks in order: 10, 10, 10 touches. Rest between rounds. Solo practice can retry a failed round; a scored series has one attempt per round. | Round scoring |
| 47 | Three Twenties | Advanced | Complete three separate streaks in order: 20, 20, 20 touches. Rest between rounds. Solo practice can retry a failed round; a scored series has one attempt per round. | Round scoring |
| 48 | Rising Ladder | Build | Complete three separate streaks in order: 5, 10, 15 touches. Rest between rounds. Solo practice can retry a failed round; a scored series has one attempt per round. | Round scoring |
| 49 | Big Ladder | Advanced | Complete three separate streaks in order: 10, 20, 30 touches. Rest between rounds. Solo practice can retry a failed round; a scored series has one attempt per round. | Round scoring |
| 50 | Control Pyramid | Build | Complete three separate streaks in order: 5, 10, 5 touches. Rest between rounds. Solo practice can retry a failed round; a scored series has one attempt per round. | Round scoring |
| 51 | Steady Twenty | Build | Play three 20-second rounds. Achieve a best streak of at least 10 in every round. Your lowest round best is the series score. | Round scoring |
| 52 | Steady Thirty | Advanced | Play three 30-second rounds. Achieve a best streak of at least 20 in every round. Your lowest round best is the series score. | Round scoring |

### Friends

| No. | Challenge | Difficulty | Goal and scoring | Judging |
| --- | --- | --- | --- | --- |
| 53 | Streak Duel | Build | Both players get three separate 30-second attempts. Compare each player's highest valid uninterrupted streak; higher wins. | Friend match |
| 54 | Sprint Duel | Build | Both players get three separate 30-second attempts. Compare their highest total of valid touches in one attempt; higher wins. Drops do not reset the clock. | Friend match |
| 55 | First to Twenty | Build | Both players try Race to 20, with three attempts each. Compare the fastest finished attempt within 45 seconds; lower time wins. | Friend match |
| 56 | Best of Three | Build | Play three paired 30-second best-streak rounds in order. Compare round 1 with round 1, and so on. Each round is recorded once; most round wins decides the match, with equal round scores drawn. | Friend match |
| 57 | Mirror Me | Build | Pick an eight-touch left/right foot sequence and ask a friend to reproduce it. Both review the shared attempt video; matching the sequence completes the challenge. | Practice or video review |
| 58 | Weak Foot Faceoff | Build | Each player locks their own weaker foot before starting and tries 10 uninterrupted touches. Completion is confirmed by shared-video review; both can complete. Treat this as a friendly skill challenge, not a verified ranking. | Practice or video review |
| 59 | Team Hundred | Build | Work together: each player's best 30-second total contributes to a shared target of 100 touches. Three attempts per player; add the two best totals. The outcome is a team completion, not a winner. | Friend match |
| 60 | Consistency Duel | Build | Each player records three 20-second best-streak rounds, once per round. Compare each player's lowest round score; the higher minimum wins. Equal minima draw. | Friend match |

## Challenge a friend

Start with asynchronous matches: both players can participate at different times. Live simultaneous duels can follow later.

1. **Choose the rule.** For example, Touch Sprint 30. The invitation freezes the rule version, duration, permitted contacts, source eligibility and score direction.
2. **Create the invitation.** Default: three attempts per player, with the match ending 24 hours after acceptance. The unaccepted invitation expires after 48 hours. Show these terms before sharing.
3. **Share explicitly.** Open the phone's share sheet with an invite link. Do not automatically send a message or request the user's contacts. A recipient can read the rules before signing in to accept.
4. **Accept and record.** Acceptance starts the shared deadline. Both players receive the same rule and attempt budget. Each recording uses the countdown and its own timer; players need not be online simultaneously.
5. **Review and submit.** Show the counted result and attempts remaining. Scores stay between the participants. Replays remain private unless the player chooses to share them; technique-review matches explain that the attempt video must be shared with the opponent before recording that entry.
6. **Finish the match.** Finalize when both players finish their permitted attempts, both lock their results, or the deadline passes. Until then show “Leading”, not “Won”. Higher wins for counts; lower wins for completed time trials. Equal scores are a draw. A player with no valid submitted attempt is shown as “No result”, not zero and not a completed win for the opponent.
7. **Offer the next action.** Show Rematch with the same frozen rule, Try another challenge, and an optional shareable result card. A rematch is a new match and needs the other player's acceptance again.

Example: **Sprint Duel**. You score 28, 32 and 30 touches; Alex scores 29, 25 and 27. The final result is **32–29**, because each player's best single 30-second total counts. You win after the match closes. A session total from outside that window cannot enter this comparison.

Single-foot and Mirror Me results are marked **Agreed after video review** when both players accept the evidence. They do not appear as automatically verified scores. Team Hundred is cooperative: add the two players' best totals and show whether the team reached 100, without a winner/loser screen.

The friendly result belongs to that challenge. Do not mix timed totals, one-foot completions or cooperative scores into the existing global best-streak leaderboard.

## Attempt and match states

Use separate states for **Draft**, **Invited**, **Accepted**, **In progress**, **Review needed**, **Finished**, **Declined**, **Expired** and **Cancelled**. Explain the state on the match screen and preserve progress across relaunch.

Each attempt has one stable identifier and one immutable rule snapshot. Retrying an upload must not create another score. Cancelling before Go does not use an attempt; deliberately ending a round after Go does. A technical failure should show a recoverable or reviewable state rather than quietly granting an extra scored attempt. Keep the practice video and unrelated sessions intact.

Once accepted, neither participant can silently change the rule, foot restriction, target or deadline. For Beat Your Best, freeze the creator's target before inviting and show the same target to both players; a personal improvement result is distinct from a head-to-head ranking.

Use the existing account identity and private recording lifecycle where appropriate. Add participant-scoped invitations, attempts and result access. A shared link is an invitation, not permission to expose every replay. Joining a match never publishes a clip to a public feed.

## Delivery order

1. **Challenge catalogue and practice UI.** Load the 60 definitions, filters, details and demonstrations. Save explicit practice progress. Existing streak goals can become counted completions after their result wiring is tested.
2. **Timed and series engine.** Implement the fixed scoring window, race timing, drop policies, countdown, interruption recovery and saved round results. Verify boundary contacts and replay agreement on iPhone 11.
3. **Friend match loop.** Invitation, acceptance, frozen rule, attempt budget, private submissions, deadline, result and rematch. Use two test accounts end to end before opening this to real matches.
4. **Technique judging.** Qualify anatomical left/right-foot and sequence classification on reviewed recordings before turning practice or peer-reviewed technique goals into automatically scored competition.

This expands the product catalogue without describing unimplemented judging as available. It also preserves the existing V2 plan's distinction between ordinary counted challenges and foot-specific detection.

## First acceptance checks

- Every catalogue entry has an unambiguous target or score, duration where needed, failure rule and judging type.
- Solo result and replay agree for streak, fixed-window total, target race and multi-round modes.
- Contacts at Go and at the cutoff, simultaneous contact events, drops and uncertain tracking follow the same versioned rule on both phones.
- Deadline handling, equal scores, unfinished attempts and no-result matches have explicit outcomes.
- Two accounts complete invite, accept, record, submit and rematch without exposing unrelated videos.
- Failed uploads resume without duplicate attempts; app relaunch and account changes cannot attach a result to the wrong match.
- Technique practice cannot accidentally award an auto-counted competitive win.

## Design assets

The [structured catalogue](../design/challenges-20261118/catalogue.json) contains all 60 entries and their parameters. The [static screen sheet](../design/challenges-20261118/challenges-and-friends.png) illustrates the proposal with sample players and scores; it does not represent implemented screens. The sheet was generated with the built-in image tool from the [saved prompt](../design/challenges-20261118/mockup-prompt.md).
