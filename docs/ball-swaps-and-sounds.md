# Looks, change moments, replay sounds and timer looks

Branch `feature/leaderboard-editor-upgrade`, built on the leaderboard branch
(`codex/post-launch-signin-leaderboard-ball-edges` at 4d0c3d1), 29–30 October 2026.

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

## Milestones

The counter celebrates the 10th, 25th, 50th, 75th and 100th touch, then every 50th: the
badge swells and springs back, a flash, two rings and rays burst behind it, confetti is
thrown up and falls, and a lime "★ 25 TOUCHES" tag rises under the count, all within
1.3 s (`MilestoneAppearance`, drawn by the export renderer and the replay overlay alike).
A short four-note fanfare plays on the milestone touch, replacing that touch's touch or
change sound. The Counter page has a *Milestones* switch and a fanfare button; both default
on, are free, and are remembered with the counter settings (`milestones`, `milestoneSound`).

## My style

A Pro row under the Looks tile saves the replay's ball, effect and intensity, the recipe
behind its looks, the change moment, and the sounds and original-sound setting. Every new
session (`PostSessionFlowView`) starts from it; the recipe is laid again for that session's
touch count, so Power-up still lands on its 10th and 25th touch. Custom runs stay with their
replay. The row shows *Save*, *Saved* or *Update*, with a menu for *Use My style on this
replay* and *Stop using My style*. Counter, timer and graph settings already persist on
their own. Design reviews and UI tests keep My style in memory only.

## Phone check (iPhone 11 Pro Max, 30 October 2026)

`EditorPhoneCheckTests` runs on the phone with the juggling fixture (18.6 s, 18 touches),
the current detector for the ball track, a Broadcast or Pill timer and the counter.

| Case | Export | Preview frames over 33 ms |
| --- | --- | --- |
| One look, glow trail, no ball print | 9.2 s | 0 of 558 |
| One look, Lava + Fire (possible before this branch) | 22.1 s | 240 |
| Power-up looks with Electric and Galaxy | 20.4 s | 243 |
| Power-up looks, lighter effects (now used on older phones) | 13.7 s | 102 |

Per-frame GPU cost of each effect there, slowest 5 %: Heat Pulse 7 ms, Nature 11, Ember
Wake 14, Glow Trail 15, Lab Flame 20, Fire 23, Galaxy, Electric, Ice, Aura, Rainbow, Blue
Flame and Flame Ribbon 30 to 32, Neon 46. The change moment, timer and counter cost 3 ms or
less. Recipes on phones the app treats as older (iPhone 13 and earlier, SE) use the effects
up to Fire. The remaining slow frames come from the ball print raster, up to about 24 ms of
CPU on frames with a print; that cost predates this branch and is the next thing to move off
the main thread.

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
- `MilestoneTests`: milestone touches, the celebration window and pulse, deterministic
  drawing, the export overlay, settings defaults and the fanfare's priority.
- `MyStyleTests`: saving the recipe and refitting it, custom runs, unknown saved values,
  persistence and memory-only stores.
- `EditorPhoneCheckTests`: export time and per-frame preview cost, and per-effect GPU cost,
  on the phone it runs on.
- `ReplaySoundTests`: every cue bounded and audible, waveform shapes, soundtrack placement,
  an export that mixes cues into a saved video with exactly one audio track, and muted
  exports (no track without cues; cues only with cues; both when kept).
- `TimerStyleTests`: every look distinct, reproducible after seeking and visible; motion within
  a second; settings migration; Pro rules; placement shape; export placement.
- `TimerStickerUITests`: every look selectable, tap to select, drag, pinch, reset, style pill,
  done and remove.
- `BallSwapsUITests` (JuggleDude-StoreKit scheme, Pro purchased): Power-up, split, a run's
  ball and effect, change moment, merge, remix, clear, the Ball page's link to Looks, the
  Auto change sound and its override, original-sound muting, the Milestones switch and
  fanfare, and My style save, update and stop.

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
