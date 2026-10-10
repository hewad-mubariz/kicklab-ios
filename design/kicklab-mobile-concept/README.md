# Juggle Dude mobile design reference

Six portrait iPhone concepts in two PNG boards, generated with the built-in image generation tool.

- core-screens.png: Home, Setup, Live juggling, Result replay.
- replay-and-share.png: touch-detail sheet and annotated-video export.

These are raster design references. Copy, numerical examples and footage are illustrative.

## Visual system

Charcoal and dark olive atmospheric surfaces; chalk-white text; electric yellow-lime primary actions and ball annotations. Condensed expressive display typography, oversized tabular live count, restrained utilitarian labels. The Juggle Dude wordmark anchors entry screens. Single-column layouts and generous primary controls keep each screen focused.

## Interaction notes

- Home: Juggling is available. Power shot, target practice, free kick, dribbling and first touch are labelled Soon.
- Setup: guide one player and one ball into frame. Show one actionable instruction at a time. Replace the instruction with “Cannot see ball”, “Camera moving too much”, or “Too dark” when appropriate. Suggested supporting copy: “Place the ball inside the frame”, “Prop your phone on a stable surface”, and “Move to a brighter area”. Start capture only once framing is ready.
- Live: use a brief ring pulse for each detected legal touch; allow the count to update about 100 ms after contact. The displayed capture state uses a large stop control. Before capture, the same control is Record. Detection failure must show honest status without inventing touches.
- Result: make replay immersive through the expand action. Ball trail, touch ticks and height chart should follow the actual recorded measurements. The example session has 84 touches over 72 seconds, giving 70 touches/min; the longest uninterrupted streak is 47.
- Detail: selecting a row seeks replay to that exact event. Foot, knee, thigh, head and chest are legal touches.
- Export: save an annotated video locally or invoke the native share sheet. Do not imply a public post or upload during capture.
- Keep frame rate and confidence behind the information action; on-device/offline status stays quiet.

## Production handoff

Use the boards for composition and visual direction. Rebuild labels and controls as native UI; do not extract generated typography as app text. Confirm contrast outdoors and the live count at approximately three metres on a real device. Tracking paths and touch classifications in these mockups are illustrative, not computer-vision validation.

Generation prompts are preserved in prompts.md.

