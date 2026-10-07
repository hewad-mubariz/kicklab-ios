# Procedural Fire · input 4

## Fire v9 · solid flame, matched to the Grok reference video

The target moved to a generated reference video (solid, opaque flame sheets hugging the ball, a ribbon along the kick path, warm light on the surroundings). v8's thin strands over a see-through veil read as neon next to it. v9 keeps v8's motion model and tracking, but changes the material:

- A tight shell clings to the ball (thicker downwind, short leaning tail) instead of a tall plume. Tongues come from a higher-frequency radial field, so the rim has many small jagged licks.
- The wake is a ribbon that stays on the recorded path for 0.8 s, drifting up only slightly.
- Each tongue is filled and coloured by its depth (red-orange edge, yellow body, white-hot only near the ball), with soft fold bands for internal contrast. Strong tongues cross the ball's rim translucently, and a light warm glaze lights its face.
- The far bloom is wider and stronger so warm light spills onto legs and grass; it stays off the ball face.

Review: [vs reference video](../artifacts/fire-v9/vs-grok-video.jpg), [before / after](../artifacts/fire-v9/before-after.mp4) (v8 left, v9 right), [motion detail](../artifacts/fire-v9/motion-detail.jpg), [full frame](../artifacts/fire-v9/full-frame.jpg). The ported Fire assertions pass on the Mac GPU; the Xcode suite and iPhone build were not run.

## Fire v8 (superseded) · a leaning fireball drawn with strands

v7 shaded a soft density cloud, so it read as a blurry orange blob floating above the ball. The reference gets its look from thin, bright contour strands and tongue edges with see-through gaps, a hot fringe hugging the ball, and tongues that lick outward and bend with the motion. v8 (`proceduralFireFX`) draws exactly that:

- A teardrop envelope wraps the ball and leans away from its velocity (buoyancy plus the air the ball runs through). A wake released at the recorded emitter positions rises and narrows over 0.6 s, so a fast ball leaves a tapering flame trail in video space.
- Rising, domain-warped value noise erodes the envelope into separate tongues; cooler gas erodes more, so tips taper.
- Light lives in strands: contour lines of a smooth two-octave field, anti-aliased by its gradient so they stay one or two pixels wide at any scale. Near the ball the field is radial (flames leave the surface at every angle and bend into the wind), further out it is the rising world-space field. Flat extrema carry no strands, which avoids closed "topographic" loops.
- The body is a faint red-orange veil; coverage follows brightness so cool regions never darken daylight video. Bloom is kept off the ball face so its pattern stays readable.
- Noise is anchored to the frame height, not the detected radius, so detector jitter never slides the pattern.
- Embers are fine sparks streaked along their own velocity.

Review: [before / after](../artifacts/fire-v8/before-after.mp4) (v7 left, v8 right, input 4, 3.0–4.5 s), [still](../artifacts/fire-v8/before-after.jpg), [motion detail](../artifacts/fire-v8/motion-detail.jpg). Rendered with the real engine on the Mac GPU; the Fire assertions of `MetalEffectsTests` were ported and pass there. The Xcode test suite and the iPhone build were not run for this pass.

## Fire v7 (superseded) · buoyant gas drawn as burning sheets

The v5 field below has been replaced in `EffectShaders.metal` (`proceduralFireFX`). The approved mockup is the appearance target: translucent flame tongues made of bright strands with see-through gaps, orange-dominant, white only against the ball.

- Fuel is released at the 33 recorded emitter positions (25 ms apart, 0.8 s). Each puff rises with buoyant acceleration (`4.2·age + 4.6·age²` radii), sways, widens and cools; nothing bridges a missing detection. A sheath wraps the ball, thickest above it.
- Tongue silhouettes come from the fuel envelope eroded by contrast-stretched, domain-warped 3D value noise (time is the third axis). Cold gas erodes more than hot gas, so tips taper and gaps open; the erosion is strong enough to keep gaps even at full fuel density.
- Inside the tongues, brightness lives on ridged turbulence at three scales (`fireRidge3`), giving the wavy strand structure of real flame, over a weak translucent body. Strand cores are yellow, bodies orange-red, a thin corona at the ball rim is near white. Blackbody-style HDR ramp, tone-mapped in `resolveFX`; no dark fringe or smoke in daylight.
- 240 soft glowing embers leave the sheath, ride the plume with wobble, flicker, and every fourth one drifts far sideways. The ball keeps its own contrast with a light warm blend toward the rim.
- In the export/replay composite only, hot air refracts the video around and above the flames. The transparent live overlay omits this.
- The render region follows the rising column and ember spread; the fire render target may be up to 832 px. The far bloom band is wider than for other effects.

Review: [actual app export](../artifacts/fire-v7/fire.mp4) (original daylight, 85 %, 720 × 1280, 456 frames), [mockup vs export](../artifacts/fire-v7/mockup-vs-v7.jpg) and [detail](../artifacts/fire-v7/mockup-vs-v7-detail.jpg), [before / after](../artifacts/fire-v7/before-after.mp4) (v6 left, v7 right), [consecutive frames](../artifacts/fire-v7/motion-detail.jpg), [GPU tests](../artifacts/fire-v7/tests.log) (22 passed), [iPhone Release build](../artifacts/fire-v7/device-build.log). The intermediate v6 (filled gas volume) is kept in `artifacts/fire-v6`. The simulator launch command below with `--effects-folder fire-v7-input4` reproduces the export. Physical-device frame time is still not measured.

## Fire v5 (superseded)

Fire must be generated in code. The user rejected flame images, atlases and warped-image layers because their silhouettes move like cutouts. The approved [mockup](../design/fire-mockup/fire-input4-v1.png) remains an appearance reference, not a runtime asset. This pass supersedes the Fire implementation described in `reference-effects.md`; other effects retain their existing implementation.

`EffectShaders.metal` rebuilds the earlier procedural flow. Each output point is traced backward through 32 steps of a time-varying curl field with buoyancy and limited inherited ball velocity. Fuel comes from the corresponding recorded ball position. Missing tracking intervals emit nothing. The field reconstructs 0.8 seconds of emission, so previous material stays in video space as the ball moves. Heat and density decay separately.

Smoother seeded noise, larger rolling eddies, finer advected reaction detail, warmer translucent regions and localized hotter folds replace the soft original material. The noise volume is generated from a seeded PRNG in Swift; no flame pictures are sampled. Fire has 144 finite-lived embers, a larger render region and a 960-pixel render-target ceiling to retain fine detail. Bloom is restrained to keep the folds visible. The original ball center stays masked through the effect.

The strength adjustment widens the emitting shell slightly, slows cooling modestly, increases flame emission by 22%, and lifts local bloom and ember visibility. The velocity field and animation timing are unchanged. The prior strength is saved under `artifacts/fire-procedural/before-strength` for comparison.

Live, replay, still rendering and video export share this code. Video time controls every calculation; pausing or seeking does not accumulate independent simulation state. This is prescribed-flow advection, not a pressure-projected fluid solver or a 3D combustion simulation. It does not implement person-depth occlusion or physical scene relighting, and it is not claimed to reproduce every detail of the generated concept.

## Review

- [Actual app export on input 4](../artifacts/fire-procedural/fire.mp4): original daylight, 85% intensity, 720 × 1280, 456 frames.
- [Before / after](../artifacts/fire-procedural/before-after.mp4): previous strength on the left, stronger Fire on the right.
- [Consecutive-frame detail](../artifacts/fire-procedural/motion-detail.jpg): eight frames at 125 ms intervals starting at 3.5 seconds.
- [Validation](../artifacts/fire-procedural/verification.json), [GPU tests](../artifacts/fire-procedural/tests.log), [iPhone build](../artifacts/fire-procedural/device-build.log).

The tests cover deterministic pause/seek, temporal continuity, world-space birth positions, ball-path response (now explicitly including Fire), independence from person detections, missing-track handling, zero-intensity clearing and matching preview/export compositing. The iPhone Release build is checked; physical-device frame time and thermals have not been measured.

The rejected image materials were removed during artifact cleanup. Their prompts remain in `design/fire-mockup/fire-material-prompts.md`; the approved mockup is retained as a visual reference. Effect-picker artwork is separate from the runtime renderer.

To repeat the media checks and build the comparison:

```sh
python3 scripts/review-procedural-fire.py
```

To export again from a Debug simulator build:

```sh
xcrun simctl launch --terminate-running-process booted hewad.kicklab \
  --effects-video /Users/hewadmubariz/Downloads/input/input-positive/input4.mp4 \
  --effects-track /Users/hewadmubariz/Desktop/projects/kicklab/artifacts/reference-effects/analysis.json \
  --effects-folder fire-procedural-input4-stronger --effects-quality 720 \
  --effects-environment original --effects-only fire --effects-style fire --effects-export
```

Wait for that run's `status.txt` to read `COMPLETE`, then copy `fire.mp4` from its Documents folder to `artifacts/fire-procedural`.
