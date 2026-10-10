# Environments and counter export

Replay & Effects → **Environment** now starts with Classic Stadium and Indoor Arena image cards. Each image comes from the shipping Metal scene, rendered without a player by `scripts/render-environment-cards.swift`. Tap a card, adjust the view, then choose **Use Classic Stadium** or **Use Indoor Arena**. **Original background** removes the replacement. The separate Original / Nightfall options control color grading.

**Counter** sits beside Environment in the editor tabs and is also available beside the scene's Apply button. The same counter state is shared across replay, scene preview, the counter editor and Save & Share. Its ten styles, visibility, position, size and rotation carry into the exported video. There is no timer overlay.

## Scene branding

All six scene previews and their rendered signs use Juggle Dude. `StadiumSignage.swift` draws the stadium boards with native typography; `ArenaSignage.swift`, `UrbanSignage.swift`, and `ForestSignage.swift` draw the other signs (Forest is shared by Snow and Beach). The old branded stadium PNG has been removed. Regenerate picker images from the app's Metal renderer with `zsh scripts/render-environment-cards.sh`.

## Export and playback

`SessionEditState.scene` stores the environment, look direction, zoom and recorded-camera-follow choice. Applying a view sets a fixed framing offset; follow uses the measured camera motion over the clip. Phone look captures the currently displayed orientation when applied. Live gestures are not recorded as an animated camera path.

`StadiumPreviewModel` lives at the session-flow root. It reuses the full-length foreground cache across screens, then caches a rendered movie per scene and camera choice. `SceneMovieRenderer` decodes every timestamp-paired color/alpha frame and uses the same `StadiumPreviewRenderer` camera/shader as the interactive preview. `SceneSelection` projects ball-effect coordinates through that camera, including hiding effects behind the viewer.

The resulting scene movie feeds replay, counter editing, the Save & Share thumbnail and `BallStyleBurnIn`. The final pass adds selected ball effects/material, grading and the counter at each video timestamp. Edited exports include the environment; Original exports keep the source background with the counter if enabled. Both 720p and 1080p use the same normalized counter layout.

Preparation now covers the whole clip, at the existing maximum of 30 fps. An incomplete older 12-second cache is rejected for export. Export failure remains an error; it never silently shares the original. Source audio passes through unchanged. Audio assembly retains its source asset until completion and intersects time ranges with the actual encoded track, which can have a coarser timescale than the source.

## Validation

All **53 tests in eight suites** pass. `SceneExportTests` checks scene state persistence, camera-aligned ball effects, rejection of truncated caches, and a 14-second scene plus rotated-counter export with audio and fractional duration. Both video and audio remain available after the old 12-second boundary. Existing cutout, effect and counter tests remain passing.

The normal simulator UI flow was checked with the prepared iPhone cutout of the real park clip: image-card selection, Apply, replay, Counter editing and Share. `artifacts/environment-export/indoor-counter.mp4` is the actual Share-button output: Indoor Arena, Pixel Burst counter rotated 29°, 1080×1920, 212 frames, 7.04 seconds. The AAC packet hash matches the original (`938eadcd2f04392cfb22ebaac7559b5717ab33c2a0fc314b363759f1b8098064`). The foreground/model was prepared on an iPhone; the simulator renders that cache and does not run Vision inference.

`artifacts/environment-export/classic-counter-720p.mp4` verifies Classic Stadium at 720×1280 with camera zoom 1.129 and the same transformed counter. Both real exports fully decode, contain 212 frames, retain the full duration and match the original AAC packet hash. See `verification.json`.

A signed iPhone build is available in `build/stadium-device/Build/Products/Debug-iphoneos/kicklab.app`. Device installation was attempted, but the phone was unavailable to CoreDevice; see `artifacts/environment-export/device-install.json` and `devices.json`.

The person remains a 2D cutout in a 3D room. Scene export does not change segmentation or recover unseen sides of the recorded person. Long-clip preparation time, storage and thermal behavior still need measurement on the target phone.
