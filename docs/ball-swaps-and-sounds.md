# Looks, change moments, replay sounds and timer looks

Branch `feature/ball-swaps-and-sounds`, 29 October 2026.

The replay editor can now put a different ball on any touch, play a visible moment
where the ball changes, and add a sound to every touch and every change. All three
are Pro tools, like the single-ball picker, and all three export exactly as previewed.

## What the user sees

**Looks tool.** A wide tile under the Customize grid shows the clip's looks in order. A
look is a ball plus an effect; the clip is a sequence of runs of touches, each with one
look. The first run is the clip's own ball and effect, which the Ball and Effects pages set;
with looks on, those pages say so and link to Looks. The Looks page has:

- **Recipes**, one tap each: *Power-up* levels up on the 10th, 25th, 50th and 100th touch
  (Volt + Electric, Lava + Fire, Gold + Galaxy, Chrome + Rainbow), or at quarters on short
  clips, with Burst; *Finale* keeps the clip's look until the last few touches, then Gold +
  Fire with Lightning; *Every 5* rotates three looks and the clip's own every 5 touches,
  with Pop; *Remix* lays a seeded random mix with Sparkle, and tapping it again shuffles.
  *Clear* returns to one look.
- the **touch dial**: every touch snaps under the lens with a haptic tick and holds the clip
  just after that touch. Each touch shows its ball with a badge for its effect; the bar
  under them is the runs, in each look's effect colour, with a white dot where a run starts.
  The run under the lens is lit, because edits apply to all of it. Changes ripple outward
  from the lens.
- the **run line**: "Look 3 of 6 · Touches 15 to 24 · Pearl + Ice", with *Split* (start a
  new run at the lens, same look until changed) and *Merge* (join the run to the one before).
- three chips, *Ball*, *Effect* and *Change*, switching one picker row: the balls with the
  pick flight, the effects drawn on the run's ball, and the change-moment tiles with the
  change sound beside them.

Every change of look plays the change moment and its sound. Picking a ball or effect plays a
short run through that run's start on the clip.

**Sound tool** (new tile in the Customize grid, showing the chosen sound's waveform).

- *Original sound* switch, on by default. Picking the first touch sound turns it off and
  says "Muted for your touch sounds"; choosing no touch sound again restores it. Turning
  the switch by hand always wins. It applies to the replay and the saved video.
- Touch sound and ball change sound tiles show each cue's real waveform; a tap plays the
  cue and sweeps a mint playhead across the waveform in the cue's own time.
- Every change effect has its own sound: Pop→Flip, Flash→Shimmer, Burst→Drop,
  Ripple→Warp, Sparkle→Sparkle, Shatter→Zap, Halo→Chime, Pixel→Glitch, Smoke→Whoosh,
  Lightning→Thunder; None is silent. The change sound row starts on *Auto*, which follows
  the effect and names its sound in a badge; picking any other tile overrides it until Auto
  is picked again. The Ball page shows the sound beside *Change effect* ("Drop · auto").
- A change touch plays one sound: the change sound replaces the touch sound there. With the
  change sound set to None, that touch keeps its touch sound.

During playback cues fire as the clip passes each touch; scrubbing stays silent. The first
sound puts the editor in media playback, so cues are audible with the ring switch on.

## Timer styles and placement

The elapsed-time sticker replaces the single grey box with a "TIME" caption. It has seven
looks, all drawn by `TimerOverlayAppearance` into one 240×120 canvas, so the replay, the
style thumbnails and the saved video show the same pixels. No look uses a caption; each says
"time" with an icon, a pulse or a moving dial. Every motion is a function of video time, so
seeking and export agree.

| Look | What it is |
| --- | --- |
| Pill (free, default) | dark glass capsule, mint live dot that breathes once a second |
| Clean | no box: lime stopwatch and big condensed digits like the Normal counter, with a shadow |
| Broadcast | match-clock bar: slanted lime tab with a stopwatch, time on ink, a lime line filling each minute |
| Stopwatch | analogue dial with a sweeping hand and a mint ring filling each minute, beside the time |
| Digital | lime seven-segment clock with ghost segments and a blinking colon |
| Flip | split-flap cards that fold over when a digit changes |
| Neon | pink tube digits in a cyan neon frame, with a rare flicker |

Digits sit in fixed-width cells so the time never jitters, and every look fits hour-long
times. The Timer page shows the looks three to a row; the chosen tile runs live.

The timer is a sticker like the counter: tap it on the video to drag, pinch and twist it, with
the same handles, remove button, reset and "Timer style" pill. Its placement uses the
counter's model with a wider `StickerShape` (2:1). Settings save under `clock`, because
`timer` belonged to a retired counter-style timer that migration still drops; `showTimer`
remains as the on/off switch for every existing caller and older builds. Looks past Pill are
Pro; placement and show/hide stay free.

## Model

`SessionEditState` gains:

| Field | Meaning |
| --- | --- |
| `lookChanges: [Int: TouchLook]` | run start (sorted-touch position) to the ball and effect shown until the next run; the first run is `ballSkin` and `style` |
| `swapEffect: BallSwapEffect` | the moment drawn at every change (`.pop` by default) |
| `swapSoundChoice: BallSwapSound?` | a change cue the person picked; nil follows the effect (`swapSound` resolves the cue heard) |
| `touchSound: TouchSound` | the cue on every touch (`.none` by default) |
| `clipAudio: Bool` | keep the sound recorded with the video (`true` by default) |

`look(at:touchTimes:)` resolves the ball and effect for a frame; `lookSwaps(touchTimes:)`
lists the run starts where the look really changes; `effectBlend` fades the effect across a
change and limits the new effect's trail to the path since the change; `usesBallMaterial`
and `usesEffects` tell the preview and export whether prints or effects are ever drawn.
`LookRecipes` builds the recipes deterministically from the touch count. The touch index space is the sorted touch time list, the same one the
counter timeline and `BallEffectTrack` use.

## Rendering

`EffectFrame.video` resolves the effect per frame from the runs, so the replay and the saved
video draw each run's own effect; the export enables the GPU whenever any run has one.

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

- `BallSwapTests`: run resolution, real look changes, the effect fade and trail cut,
  timeline ages, all four recipes on short and long clips, edit flags and Pro gating, and
  every change moment drawing deterministically and fading out.
- `LookExportTests`: a saved video draws fire for the first run and nothing after the
  change, and the reverse.
- `ReplaySoundTests`: every cue bounded and audible, waveform shapes, soundtrack placement,
  an export that mixes cues into a saved video with exactly one audio track, and muted
  exports (no track without cues; cues only with cues; both when kept).
- `TimerStyleTests`: every look distinct, reproducible after seeking and visible; motion within
  a second; settings migration; Pro rules; placement shape; export placement.
- `TimerStickerUITests`: every look selectable, tap to select, drag, pinch, reset, style pill,
  done and remove.
- `BallSwapsUITests` (JuggleDude-StoreKit scheme, Pro purchased): Power-up, split, a run's
  ball and effect, change moment, merge, remix, clear, the Ball page's link to Looks, the
  Auto change sound and its override, and original-sound muting.

## Results (iPhone 18 Pro Simulator)

Timer, 30 October: the timer, export, overlay, persistence, access and ball suites pass
(58 Swift Testing + 18 XCTest cases), including the free export whose timer text is read
back by text recognition. `TimerStickerUITests`, `BallSwapsUITests` (2),
`NewBallEffectsUITests`, `BallCollectionUITests`, `ReplaySpinStatusUITests` and the free
`FreeCounterUITests` case pass. `CaptureFlowUITests.testStoppedFlowOpensEditorAndToolboxThenExport`
passes its counter steps and then fails on a "Backgrounds, coming soon" tile that was
already hidden at the starting commit.

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

- No new analytics events for the sound, looks and timer choices.
- Ball Distance videos (no touches) keep the single-ball picker and have no Sound tile.
- The two detection files `NativeBallPixelTrack.swift` and `RFBufferedPixelTrack.swift`
  carry a three-line split of one expression that the current compiler could not type-check
  in time on a clean build; behaviour is unchanged.
