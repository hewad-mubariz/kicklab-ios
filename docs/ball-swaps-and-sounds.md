# Ball per touch, change moments and replay sounds

Branch `feature/ball-swaps-and-sounds`, 29 October 2026.

The replay editor can now put a different ball on any touch, play a visible moment
where the ball changes, and add a sound to every touch and every change. All three
are Pro tools, like the single-ball picker, and all three export exactly as previewed.

## What the user sees

**Ball tool.** The 4×4 grid stays the default. A *Ball per touch* switch sits above it; on,
the page becomes:

- a **touch dial**: every counted touch on a snapping horizontal dial under a fixed mint
  lens with a playhead notch. Swiping snaps touch to touch with a haptic tick and holds the
  clip a quarter second after that touch, when the change moment has cleared. Touches shrink
  and fade away from the lens. A coloured **run bar** under the balls, in each ball's accent,
  shows which ball plays across which touches, broken by a white dot at every change;
- a line naming the touch and its run ("Lava · since touch 3"), with *Cycle* (every 1, 2,
  3, 5 or 10 touches, rotating the balls in use topped up with Volt, Lava and Chrome; with
  nothing picked the real ball leads) and *Clear*;
- one row of balls for the touch under the lens, with the existing flight animation;
- **change effect tiles** for the eleven moments (None, Pop, Flash, Burst, Ripple, Sparkle,
  Shatter, Halo, Pixel, Smoke, Lightning). Each tile draws its moment on a small ball with
  the clip's own renderer; the chosen tile loops it, a tap plays it on the tile and plays a
  short run through the nearest change on the clip.

Turning the switch off sets the per-touch picks aside and the clip shows one ball again;
turning it back on in the same session restores them. The dial returns to the last touch
worked on, and reopening the page holds the clip on it.

**Sound tool** (new tile in the Customize grid, showing the chosen sound's waveform).

- *Original sound* switch, on by default. Picking the first touch sound turns it off and
  says "Muted for your touch sounds"; choosing no touch sound again restores it. Turning
  the switch by hand always wins. It applies to the replay and the saved video.
- Touch sound and ball change sound tiles show each cue's real waveform; a tap plays the
  cue and sweeps a mint playhead across the waveform in the cue's own time.

During playback cues fire as the clip passes each touch; scrubbing stays silent. The first
sound puts the editor in media playback, so cues are audible with the ring switch on.

## Model

`SessionEditState` gains:

| Field | Meaning |
| --- | --- |
| `ballChanges: [Int: BallSkin]` | sorted-touch position → the ball shown from that touch until the next change; `ballSkin` stays the base ball |
| `swapEffect: BallSwapEffect` | the moment drawn at every change (`.pop` by default) |
| `swapSound: BallSwapSound` | the cue at every change (`.whoosh` by default; silent without changes) |
| `touchSound: TouchSound` | the cue on every touch (`.none` by default) |
| `clipAudio: Bool` | keep the sound recorded with the video (`true` by default) |

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
audio track; a silent clip with cues gets that one track. With `clipAudio` off the clip's
audio is left out: cues alone, or no audio track at all when no cue plays.

## Tests

- `BallSwapTests`: per-touch resolution, change listing, timeline ages, cycling, edit
  flags and Pro gating, and every effect drawing deterministically and fading out.
- `ReplaySoundTests`: every cue bounded and audible, waveform shapes, soundtrack placement,
  an export that mixes cues into a saved video with exactly one audio track, and muted
  exports (no track without cues; cues only with cues; both when kept).
- `BallSwapsUITests` (JuggleDude-StoreKit scheme, Pro purchased): the switch, dial,
  per-touch picks, change effect tiles, automatic and manual original-sound muting, restoring
  picks with the switch, cycle and clear.

## Results (iPhone 18 Pro Simulator)

Redesign, 30 October: the new suites and the existing export, scene, collection, effect,
lifecycle and Metal unit tests pass (61 Swift Testing + 12 XCTest cases);
`BallSwapsUITests` (2), `NewBallEffectsUITests`, `BallCollectionUITests` and
`ReplaySpinStatusUITests` pass.

First version, 29–30 October:

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
