# Ball per touch, change moments and replay sounds

Branch `feature/ball-swaps-and-sounds`, 29 October 2026.

The replay editor can now put a different ball on any touch, play a visible moment
where the ball changes, and add a sound to every touch and every change. All three
are Pro tools, like the single-ball picker, and all three export exactly as previewed.

## What the user sees

**Ball tool.** A segmented control at the top: *One ball* (the existing 4×4 grid) or
*Per touch*. Per touch shows:

- a strip of every counted touch, numbered, each with a thumbnail of the ball on screen
  from that touch; a mint dot marks the touches where the ball changes;
- one row of balls, which picks the ball for the selected touch (the existing flight
  animation plays, and the pick lands on the clip after it);
- a *Change effect* row of eleven moments (None, Pop, Flash, Burst, Ripple, Sparkle,
  Shatter, Halo, Pixel, Smoke, Lightning). Tapping one plays a short run through the
  nearest change so it is seen on the real ball;
- *Cycle* (every 1, 2, 3, 5 or 10 touches) rotates the balls already in use, topped up
  with Volt, Lava and Chrome; with nothing picked, the real ball leads the rotation.
  *Clear* removes every per-touch pick.

Tapping a touch holds the clip paused a quarter second after that touch, when the change
moment has cleared and the new ball is in flight. Switching back to *One ball* clears the
per-touch picks.

**Sound tool** (new tile in the Customize grid). Two rows of chips: a touch sound (ten
cues plus none) and a ball-change sound (ten cues plus none). Each tap plays the cue once.
During playback cues fire as the clip passes each touch; scrubbing stays silent.

## Model

`SessionEditState` gains:

| Field | Meaning |
| --- | --- |
| `ballChanges: [Int: BallSkin]` | sorted-touch position → the ball shown from that touch until the next change; `ballSkin` stays the base ball |
| `swapEffect: BallSwapEffect` | the moment drawn at every change (`.pop` by default) |
| `swapSound: BallSwapSound` | the cue at every change (`.whoosh` by default; silent without changes) |
| `touchSound: TouchSound` | the cue on every touch (`.none` by default) |

`ballSkin(at:touchTimes:)` resolves the ball for a frame; `ballSwaps(touchTimes:)` lists
the real changes; `usesBallMaterial` tells the preview and export whether any print is
ever on screen. The touch index space is the sorted touch time list, the same one the
counter timeline and `BallEffectTrack` use.

## Rendering

The change moment is drawn with Core Graphics into the same material canvas as the ball
(`BallSwapRenderer`), in output pixels around the tracked ball, for half a second after the
contact. Replay (`EffectVideoView.materialTexture`) and export (`BallStyleBurnIn.render`)
resolve the ball per frame, draw the print, scale it by the effect's `ballScale(age:)`, then
draw the moment. Everything is a deterministic function of the event and its age, so seeks,
loops and the export agree. No shader changed.

## Sounds

`ReplaySoundSynth` synthesizes every cue from formulas (no bundled audio), at 44.1 kHz,
each under 0.65 s, normalized and soft-limited. `ReplaySoundtrack` lays cues against the
touch times. In the editor `ReplaySoundPlayer` plays them through a small pool of
`AVAudioPlayerNode`s. On export the soundtrack is mixed with the clip's own audio into one
AAC track (`ReplaySoundtrack.mixedAudio`), because most players ignore a second parallel
audio track; a silent clip with cues gets that one track.

## Tests

- `BallSwapTests`: per-touch resolution, change listing, timeline ages, cycling, edit
  flags and Pro gating, and every effect drawing deterministically and fading out.
- `ReplaySoundTests`: every cue bounded and audible, soundtrack placement, and an export
  that mixes cues into a saved video with exactly one audio track.
- `BallSwapsUITests` (JuggleDude-StoreKit scheme, Pro purchased): the per-touch flow,
  change effect, sound tool, mode switch, cycle and clear.

## Results, 29–30 October 2026 (iPhone 18 Pro Simulator)

| Run | Result |
| --- | --- |
| New unit suites (`BallSwapTests`, `ReplaySoundTests`) | all pass, including a real export with mixed cues |
| Related existing unit suites (ball material, export, scenes, Metal, lifecycle, overlays) | 71 Swift Testing + 42 XCTest cases pass |
| `BallSwapsUITests` (2), `NewBallEffectsUITests`, `BallCollectionUITests`, `ReplaySpinStatusUITests` | pass |
| `MotionStylesUITests` | 3 of 4 pass |

`testMotionPreviewPlaysAndPausesTheClip` fails because XCUITest's slider `adjust` never
ends the scrub, so the editor clock stays frozen; this branch does not change that path.
In the Simulator the editor's Metal video area renders black in screenshots and screen
recordings; the unchanged starting commit shows the same, so on-video checks of the change
moments need a device or an exported file.

## Not done

- No new analytics events for the sound and per-touch choices.
- Ball Distance videos (no touches) keep the single-ball picker and have no Sound tile.
- The two detection files `NativeBallPixelTrack.swift` and `RFBufferedPixelTrack.swift`
  carry a three-line split of one expression that the current compiler could not type-check
  in time on a clean build; behaviour is unchanged.
