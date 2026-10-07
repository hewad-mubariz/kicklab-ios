# Natural effects pass

Historical pass, superseded by [the flow renderer](flow-effects.md). The flame atlas is now archived at `artifacts/natural-effects/fire-wisps-atlas.png` and is no longer part of the app renderer.

This pass replaces Fire's smooth procedural volume and thin orange wire shapes with detailed flame textures animated in Metal. The existing Replay & Effects controls, ball material, detector, counting logic and optional export counter remain unchanged.

## Rendering

- `EffectShaders.metal`: six overlapping flame layers, four above the tracked ball and two extending below it. Two complementary animation phases fade between four atlas variants, with two scales of continuous noise distortion. Layers lean with horizontal ball velocity. The center is masked to preserve the actual ball.
- The broad fire wake is quieter so it does not cover the new flame detail. Fire has 128 drifting ember instances, with fading births and new seeds on each particle lifetime.
- Ice has irregular frost and cracks; Neon and Aura have tapered, broken arcs; Galaxy has warped spiral structure and variable density; Electric has varying charge and an irregular rim. These remain stylized energy effects.
- `MetalEffectEngine.swift`: shares the immutable fire atlas between renderers and increases the effect render target ceiling from 640 to 1024 pixels for Fire, 768 for the other effects. This retains texture detail around larger, closer balls. Replay, still preview and export use the same shaders.
- Animation is a deterministic function of video time. Seeking and pausing do not advance an independent simulation.

The new image asset is `kicklab/Effects/Textures/FireWisps.png`, a four-tile atlas created with built-in imagegen. The exact prompt, mode and source/installed paths are in [fire-texture-prompt.json](../artifacts/natural-effects/fire-texture-prompt.json). This is generated raster artwork, animated at runtime; it is not a filmed fire sequence or a fluid simulation. When running the standalone Metal frame renderer, place `FireWisps.png` beside its `.metallib`.

## Review and verification

Open [the review page](../artifacts/natural-effects/index.html) for actual app-produced videos, a park before/after video and an indoor comparison rendered with both shaders on the same source frame and detector position.

- Park: `/Users/hewadmubariz/Downloads/input/input-positive/input.mp4`, all six effects with Nightfall. Each export is 1080 × 1920, 422 frames, 7.04 seconds.
- Indoor: `input5.mp4` in the same folder, Fire with original lighting. 1080 × 1920, 572 frames, 19.0667 seconds. This is an available indoor clip, not the black-jacket clip shown in the user's screenshot.
- All seven videos fully decode, retain the source frame count/duration and preserve original AAC audio bit for bit. See [verification.json](../artifacts/natural-effects/verification.json).
- 17 tests passed, including GPU determinism under pause/seek, clearing at zero intensity, distinct effect output, premultiplied alpha, preview/export agreement, tracking geometry and export counter behavior.
- iPhone Release build passed. Simulator playback was checked with the new texture loaded. Exported frame sequences were inspected for ball alignment and evolving flame shapes.
- `python3 scripts/review-natural-effects.py` reruns media verification and regenerates the comparison page and filmstrips from the app exports.

## Limits

There is no person-depth occlusion, physically simulated combustion or fire-driven relighting of the player's body. The effect inherits the existing detector track; missed detections and motion blur can still affect alignment. The reference's cinematic lighting cannot be reproduced solely by an overlay. Physical-iPhone thermal and frame-time performance has not been profiled; the higher render target ceiling and texture layers need that device check.
