# KickLab — Juggling flow motion

Scope: capture → processing → replay editor → tool sheets → Save & Share. Presentation only; recording, tracking, playback and export behavior are unchanged. Pre-change copies of every touched file are in `original/`.

## Tokens (kicklab/Record/SessionMotion.swift)

| Token | Curve | Used for |
| --- | --- | --- |
| `snap` | snappy 0.28 s, +0.12 bounce | control morphs, symbol swaps, selection |
| `pop` | spring 0.36 s, damping 0.7 | panels, stickers, toolbox, placement glides |
| `settle` | spring 0.44 s, damping 0.86 | large surfaces (preview blur) |
| `fade` | ease-out 0.18 s | every animation under Reduce Motion |
| `stagger` | 45 ms per sibling | entrances |

Helpers: `.sessionEntrance(shown, order:)`, the `.sessionPop` / `.sessionRise` / `.sessionDrop` / `.sessionTuck` transitions, `.sessionKick(trigger)`, `SessionPressStyle` (fast dip, springy release), and `.exportZoomSource(ns)`.

Rules: things move only when they arrive or when their state changes. They do not keep moving afterwards. Exceptions that show work in progress: the REC dot pulses while recording, and spinners turn while busy. Reduce Motion keeps every opacity change and drops every offset, scale, blur, rotation and kick. Home keeps `HomePressStyle` (160 ms); the session flow uses `SessionPressStyle`.

## Choreography

- **Capture HUD**: top bar drops in, metrics rise, controls rise last.
- **Record**: the red mark twists −90° while squeezing from circle to stop-square. One red ring bursts outward. Gallery and Flip tuck in toward the shutter and spring back out on Stop. The record button stays fixed in the center. Heavy haptic on Record and Stop, selection haptic when the button returns to ready.
- **Session badge**: "REC ·" slides in and the glass capsule grows to fit it. The dot turns red and pulses.
- **Counter**: digits roll. Each touch kicks the number (+8 %, leading anchor) and floats a +1 up and away.
- **Processing**: the background appears instantly (no black gap after Stop). The orb pops, then the copy, progress bar and steps stagger in. Checks pop in and the arc drifts while work runs. At 100 % the ring closes, glows, kicks, and gives a success haptic; then the content lifts away (fade + 1.05 scale).
- **Hand-off**: the editor cover appears without the modal slide. The video settles from 1.04× and the chrome builds in. On "Record another session" the camera HUD builds back in.
- **Editor**: Customize and the toolbox share one glass ID inside a `GlassEffectContainer`, so the pill morphs into the panel and back. Tiles land in order. Selecting the counter snaps the handles inward from 1.3×. Play/pause, undo/check and the Customize label morph in place. Reset and the position presets glide the sticker with `pop`. Removing or restoring the counter pops it at its own center.
- **Sheets**: cards stagger in. The chosen effect card lifts (others sit at 0.97). The chosen ball bounces to 1.12×. Checkmarks pop. Selection haptics.
- **Export**: Save & Share zooms out of the Export pill and shrinks back into it (iOS 18 zoom navigation transition). Sections stagger in. The segmented selection slides between options. Switching Original/Edited blurs the old frame until the new one crossfades in. The Save or Share button turns into its own progress bar ("Exporting 42 %") and the layout never shifts. A finished save shows "Saved to Photos" with a bouncing check and a success haptic for 2.2 s.

## Verification

- Debug build succeeded (iPhone 17 / iOS 26.5 simulator).
- All four `CaptureFlowUITests` pass.
- Recorded the simulator during the tests and checked frame by frame: shutter morph and burst, side controls tucking, editor entrance, toolbox glass morph open and close, counter selection snap, Save & Share zoom, and the processing orbit.
- Not exercised in the simulator, because they need a camera or a real export: the Stop → processing → editor hand-off, the live counter kick, and the Save button's progress and saved states.
