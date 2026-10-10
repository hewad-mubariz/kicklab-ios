# Flow effects, following the supplied motion reference

Reference inspected: `/Users/hewadmubariz/Downloads/ssstwitter.com_1790536386258.mp4`, 15.4667 seconds, 2160 × 2160, 60 fps. It shows bright moving fronts stretching into translucent curls and wisps around a card. The fading material continues to move, with a broad range of bright and dim densities. Its implementation cannot be determined from the video alone.

The relevant target is that evolving motion, not the reference's UI or its changing rainbow palette. Each Juggle Dude effect keeps its own colour family.

## What changed

The former four-image flame atlas, layered texture animation, explicit orbiting ribbons and electric wire paths are no longer used. The old atlas is archived at `artifacts/natural-effects/fire-wisps-atlas.png`, outside the app bundle.

`EffectShaders.metal` now reconstructs a flowing emission field by integrating backward along velocity characteristics for 32 steps of 25 ms. Each integration step samples the actual emitter position at that historical time. An analytic divergence-free curl field, buoyancy and limited inherited ball motion carry the material. Density and heat decay independently. This produces a fresh evolving shape rather than translating a picture with the ball. Fire uses temperature-dependent colour; the other five effects use the same transport with their own colour, cooling/rise and particle treatment.

The field is defined in video coordinates measured in ball radii. It is not attached to the current ball center. Current radius stabilization still affects that coordinate scale; it is not a calibrated physical simulation. The implementation is prescribed-flow advection, not a pressure-projected Navier–Stokes solver or a 3D flame simulation.

`EffectFrame.emissionHistory` resamples the existing trajectory into 33 fixed-age emitter positions. It interpolates short intervals, rejects missing tracking intervals and jumps, and prevents emission before the video starts. Replay/export request 0.84 seconds of history. Particle positions are computed from interpolated birth positions; the previous nearest-track-point snapping is removed. Particle count is reduced from 128/80 to 48 so the flowing material is the dominant effect.

The calculation is deterministic at a video timestamp: it does not depend on whether playback, a seek, a still preview or an export reached that frame. The finite reconstruction window avoids accumulating stale simulator state after a seek. The original ball is masked through the material. UI, detector, counting and export counter controls are unchanged.

## Validation

- 20 tests cover the existing GPU/compositing/counter behavior plus stable particle birth positions, interpolation and missing-data boundaries, different trail histories, and temporal continuity.
- iPhone Release build and simulator tests are recorded in `artifacts/flow-effects`.
- Actual app exports and before/after videos are on the [review page](../artifacts/flow-effects/index.html). The park uses the supplied `input.mp4` and Nightfall; the indoor test uses `input5.mp4` with original lighting.
- The [media verification report](../artifacts/flow-effects/verification.json) records full decode, dimensions, duration, frame counts and original AAC preservation for each export.

Physical-iPhone frame time and thermal behavior remain unprofiled. There is no player-depth occlusion or fire-driven scene relighting. Tracking gaps still remove the effect; the renderer does not invent a ball trajectory through an occlusion.
