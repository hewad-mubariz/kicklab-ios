# Six effects and Nightfall

Replay → Effects offers Fire, Ice, Neon, Galaxy, Electric and Aura. “View all” opens the artwork picker; Apply Effect commits the selection. The compact carousel still supports direct selection and None. Ball materials remain independent.

Environment → Nightfall applies a cool, darker grade and a subtle vignette to the existing footage. Original restores the natural lighting. This is a color treatment, not a background replacement. Nightfall works even with no effect or no detected ball. The export cache includes the environment so changing it cannot return the previous version.

## Rendering

`MetalVideoSurface` pulls BGRA frames from `AVPlayerItemVideoOutput` on the display clock. It passes the actual decoded frame's display timestamp to `EffectFrame.video`; one command buffer presents the source frame, optional ball material, background grade, effects, particles and bloom. The player's periodic observer updates only the slider and time label. No SwiftUI timer drives the effect position.

The existing HDR-to-SDR preview proxy is retained. A video composition applies orientation before sampling. Metal's aspect-fill mapping and the track adapter use the same crop. `MetalStillSurface` handles the edited Save & Share thumbnail through the same compositor. Exports use `BallStyleBurnIn` with the same uniforms and shaders, preserving the source audio.

Fire has a stable upward combustion volume, tapered flames below the ball, finer flame sheets and drifting embers. Ice uses a noisy frozen rim and faceted particles; Neon uses tilted green ribbons; Galaxy combines a two-arm spiral, gas and stars; Electric has irregular golden branches; Aura has thinner silver-white ribbons. An eight-radius render region accommodates the larger effects. Coordinates stay attached to the current track sample without an additional position-smoothing delay.

Rendering goes through MTKView's draw callback to release the presented drawable correctly. Changing edits while paused requests a new draw using the retained decoded frame. GPU work is limited to two pending frames. Seeking uses video-relative deterministic noise, so returning to the same timestamp restores the same effect.

## Review artifacts

- `artifacts/six-effects/index.html`: actual clip exports, daylight/Nightfall comparison, screenshots and artwork.
- `artifacts/six-effects/verification.json`: frame, dimensions, duration, decode and audio verification.
- `artifacts/six-effects/tests.log`: 14 passing tests, including all six shaders, deterministic seek behavior, alpha compositing, background-only grading and crop alignment.
- `artifacts/six-effects/image-prompts.json`: built-in imagegen generation prompts, source images and installed asset paths. Generated images are picker illustrations; the videos are actual app rendering.
- `scripts/review-six-effects.py`: verifies the app-produced exports and rebuilds the review page.

The test source is `/Users/hewadmubariz/Downloads/input/input-positive/input.mp4`, using the existing 409-detection track over 422 frames. Detector and counting logic are unchanged. This pass addresses rendering synchronization, not detection accuracy. The effect does not yet have person-depth occlusion. Physical-device thermal/frame-rate profiling remains; the iPhone Release build is compiled but simulator runtime testing cannot establish device performance.

Apple references: [display-clock conversion](https://developer.apple.com/documentation/avfoundation/avplayeritemoutput/itemtime(forhosttime:)) and [decoded frame/display time](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput/copypixelbuffer(foritemtime:itemtimefordisplay:)).
