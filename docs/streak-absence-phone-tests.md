# Streak absence rule: phone tests

The rule: if the player or the ball is out of sight for 3 seconds between two counted touches, a new streak starts. Total touches stay the same.

The automated tests can't cover real light, real high kicks or a hot phone, so these need a person and a phone. Run them on the iPhone 11 first, because it sees the fewest frames, then on the iPhone 17.

For each test, write down the clip's time and what the session screen shows: total, best streak, and any "new streak started" notice.

## Must stay one streak

A split here is a bug. Keep the recording.

| # | What to do | How long |
|---|---|---|
| 1 | Normal juggling, with the camera about 3 m away | 5 min |
| 2 | Kick high enough that the ball leaves the top of the frame, 10 times. Do this outdoors | 2 min |
| 3 | Two very high kicks straight after each other, 5 times | 1 min |
| 4 | Turn your back and keep juggling, so your body hides the ball for 1 to 2 seconds at a time | 1 min |
| 5 | Juggle at the side of the frame with half your body out | 1 min |
| 6 | Move close to the camera until only your legs and the ball show | 1 min |
| 7 | Juggle far from the camera, so the ball looks small (6 to 8 m) | 2 min |
| 8 | Dim room in the evening | 2 min |
| 9 | Bright sun, with the ball passing in front of trees or a busy background | 2 min |
| 10 | White ball, then a dark ball | 1 min each |
| 11 | Someone walks behind you, then between you and the camera | 1 min |
| 12 | Long session until the phone gets warm | 15 min |
| 13 | Juggle low with small toe taps close to the ground. The session on 4 November had 274 touches and a best streak of 23 from this | 3 min |

## Must start a new streak

The total should stay the same, and the best streak should be the longest part.

| # | What to do | Expected notice |
|---|---|---|
| 14 | Knock the ball out of the side of the frame, leave it out for 5 seconds, then bring it back with your foot and continue | Ball out of sight |
| 15 | Walk out of the frame with the ball for 5 seconds, then come back and continue | Player not visible |
| 16 | Walk out of the frame and leave the ball in view for 5 seconds | Player not visible |
| 17 | Catch the ball and hold it for 3 seconds in view | Ball held |

## Should not end on this rule

These stops are shorter than 3 seconds or don't involve anything leaving the frame, so another check has to catch them. Note what happens.

| # | What to do | What should happen |
|---|---|---|
| 18 | Knock the ball out of the frame, fetch it in under 2 seconds and hold it | Ball held ends the streak |
| 19 | Let the ball drop and bounce on the floor in view | Ground contact ends the streak |
| 20 | Knock the ball out of the frame for about 2 seconds and bring it back with your foot, without using your hands | The streak carries on, and this is the known gap |

## The live warning

While recording, if the ball or player has been out of sight for 1.5 seconds after the first touch, the counter turns orange and a countdown appears under it. It reads 2, then 1, then "New streak when you continue". It clears on the next counted touch or when the ball or player is back in view. It only warns: the saved video still decides after the session, so it can say the streak ended and the saved video can keep it.

- **Tests 14 to 16:** the countdown should appear before the streak ends. A stop with no warning first is a bug.
- **Tests 1 to 13:** write down each time it appears and whether the ball or player was really gone. A short flash on a high kick is expected, but in the 92 minutes measured it fired 3 times.
- **From where you juggle:** can you notice and read it from 3 m without looking away from the ball for long?
- **Before the first touch:** press record and walk to your spot. It should not appear.

## Low kicks that really bounce

A floor bounce inside unbroken juggling is the case the rule can get wrong, so these two matter.

- **One low bounce:** kick the ball low, about knee height, let it bounce once and carry on in rhythm. This is the known gap: the streak carries on. Note whether it happens often in real play.
- **Repeated low bounces:** kick, bounce, kick, bounce, six times. The streak should end from the third bounce on.

## Also check while you have the phone

On the iPhone 17, open the Pro page and look at the yearly plan. It should say "Save 50%". The automated price test fails on the iOS 27 simulator with "Save 40%" and passes on the iOS 18 one, so this confirms a real phone reads the right prices.

## What I can read afterwards

For each recorded session, the app saves a small file with no video in it, in `Caches/StreakVisibility`. It lists every stop the rule made, how many times the saved video was checked, and how many times the saved video overruled the live check. With a phone connected, I can read these files and match them to your notes.
