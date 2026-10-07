# Classic Stadium: first lighting and turf pass

The native Metal preview now uses a blue-hour stadium with visible floodlight banks, soft bloom, a small amount of illuminated haze, warm concourse windows, a roof canopy with ribs and braces, and two tiers of seating. The goal has separate side, top and back net planes. Field markings include the goal area, penalty area, spot and arc.

The turf has world-space color variation, softened mowing bands and short tapered blades with a little wind. Blade intersections run only in the near field; distant detail fades into filtered turf shading. The stripe, seat and net patterns account for the pixel footprint to reduce aliasing during camera movement. Lighting is calculated in linear color and the stadium's highlights are compressed before the original video is composited, preserving the player's source exposure.

The existing calibrated camera, foreground masks and visible-foot contact tracker are shared with the app. The contact shadow now includes a faint elongated penumbra. This remains an approximation, not a reconstructed body shadow. Grass is rendered behind the foreground and cannot occlude the feet. Segmentation can still lose toes already hidden by the source grass, and the ball edge can retain some source background.

## References

- [Arunabh Verma's grass demo](https://x.com/iamarunabh/status/2043040195336114488): visually reviewed the blade depth and movement. No implementation was available in the post; the turf implementation here is original.
- [Motion Lab gallery](https://github.com/hewad-mubariz/react-native-motion-lab/tree/main/src/scenes/gallery): reviewed its WGSL light falloff, warm/cool balance and separation of visible fixtures from surface illumination. The stadium is a separate native Metal design; it does not copy the gallery or the React Native stadium scene.

## Review and verification

`artifacts/stadium-lighting/` contains the previous shader, three still-image iterations, a full shared-pipeline render, the new physical-device render, and build/test diagnostics. `scripts/review-stadium-art.swift` re-renders cached source/matte pairs for fast visual iteration without repeating segmentation. It uses the same app renderer and camera.

The signed iPhone Debug build succeeds and all 27 existing tests pass, including camera projection and foot-contact cases. The Mac shared-pipeline check produced 212 frames at 720 × 1280 / 30 fps, with the 7.04-second source-audio excerpt; the movie fully decodes. This is a bounded prepared preview, not a real-time or thermal-performance benchmark.

The updated iPhone app also generated all three new movies (212 frames, 720 × 1280, 7.04 seconds, AAC source audio); each movie fully decodes. The updated scene is visibly verified in the simulator playing those explicitly labelled iPhone movies. See `device-status.json`, `media-verification.json`, `iphone-render/moving.mp4` and `before-after.png` (old stadium on the left, new stadium on the right).

The entry point remains **Replay & Effects → Environment → Preview Classic Stadium**. Save / Share integration and improved foreground matting are separate follow-up work.
