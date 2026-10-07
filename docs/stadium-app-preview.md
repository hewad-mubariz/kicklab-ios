# In-app stadium preview

Open **Replay & Effects → Environment → Classic Stadium** after recording or importing a juggling clip.

The scene preparation processes the full clip on the device. It keeps the player and ball, replaces the background with the Metal-rendered Classic Stadium, and retains the source audio. Compare Original / Stadium, drag to look around, adjust zoom, or turn Follow recorded camera on or off. On an iPhone, Look around with phone adds device-attitude control. Reset view returns to the player. The player fits the full frame so the feet are not cropped by the preview container.

Preparation shows progress and can be cancelled. Closing an unfinished preparation cancels its view task; a completed foreground cache is reused across Replay, Counter and Save & Share. The preview’s temporary files are removed when its model is released. Errors are shown with a retry action rather than falling back to an unedited video and claiming success.

Choose **Use Classic Stadium** or **Use Indoor Arena** to apply the room and its view. Edited Save / Share includes the selected scene, ball effects/material, touch counter and original audio. The interactive camera preview displays the counter; ball effects/material appear in the applied replay and counter editor. The closer framing, stadium architecture, branded boards and interactive camera pass are described in [stadium-360.md](stadium-360.md). Sustained device measurements, hands-on phone rotation checks remain follow-up work.

## Shared implementation

- `StadiumSceneCalibration` supplies the crop and initial perspective for the app and the offline study.
- `StadiumPreviewRenderer` and `StadiumPreview.metal` supply the same cutout, contact shadow and camera projection in both places. The app loads its bundled Metal library; the standalone study accepts a compiled library path.
- `StadiumPreviewPreparer` renders full-length, deterministic Original / Locked / Moving preview movies at up to 1080p short edge and 30 fps. It retains up to 2160p source detail for the cut and caches a native action crop as synchronized side-by-side color/alpha in `foreground.mp4`, with timestamped camera/contact data in `scene.json`. It processes Vision away from the UI thread, checks cancellation between frames, and preserves original audio through a passthrough composition.
- `StadiumPreviewModel` handles progress, cancellation, retries and session-local reuse. Generation IDs prevent an abandoned worker from replacing a newer result.
- `StadiumPreviewView` and `StadiumInteractiveSurface` provide video playback, seeking, comparison and live Metal camera controls. Switching variants preserves the playback position. Reduce Motion defaults the camera toggle to off.

Run `zsh scripts/run-foreground-study.sh` for the separate comparison artifacts. The renderer and calibration now live under `kicklab/Environments/`; there is no second copy of the stadium shader in `scripts/`.

See [cutout-quality.md](cutout-quality.md) for the newer person/ball cutout pipeline and comparisons.

## Original preview verification (historical)

The current 1080p, four-movie and 38-test results are recorded in [stadium-360.md](stadium-360.md). The results below describe the earlier prototype.

- The signed development app was installed on the connected iPhone 17 Pro Max and opened with the real outdoor clip.
- The iPhone prepared all three 720 × 1280 movies: 212 frames, 7.04 seconds, with source audio. All three were copied back and fully decoded/checked. See `artifacts/stadium-app-preview/device-status.json` and `media-verification.json`.
- The simulator runtime reports `E5RT is not supported` when running this Vision request. Its walkthrough therefore plays the **actual iPhone-prepared movies**, explicitly labelled “Prepared iPhone sample.” It does not silently substitute a sample for an arbitrary clip.
- The debug-only sample loader checks the source filename/size and manifest, is activated only by `--stadium-preview-fixture`, and is excluded from Release. `--stadium-preview` opens the preview automatically in the existing real-video debug harness. `documents:` paths resolve inside the app’s own container.
- Original/Stadium switching, the camera toggle and native playback were checked in the simulator UI. The shared preparer’s cancellation path was exercised with actual Vision/Metal processing on the Mac; partial files were removed and no completed result was returned.
- 27 regression tests pass. Both the signed iPhone Debug build and iPhone Release build succeed. No sustained performance or thermal claim is made from this short clip.
