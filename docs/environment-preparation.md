# Environment preparation progress and device performance

The normal Xcode Debug configuration compiled the app with `-Onone`. Earlier physical-device cutout checks explicitly supplied `SWIFT_OPTIMIZATION_LEVEL=-O`, so they did not represent the normal Run configuration. The difference matters for the per-pixel Swift mask processing used during calibration and foreground preparation.

On the connected iPhone 17 Pro Max, the standard unoptimized build was still in the initial player scan roughly four minutes after launch for the existing 7.04-second, 4K park clip. The instrumented status reached 12.87% overall at that point, before the detailed foreground pass began. No native failure was returned in that run. This reproduces a substantial slowdown, though it does not establish the exact state of every user-reported 0% stall.

## Changes

- The app target's Debug configuration now uses `-O` for `iphoneos` builds. Simulator debugging keeps its inherited settings. Debug features and symbols remain enabled; optimized device builds can make local-variable inspection and stepping less precise.
- Preparation reports opening, cutout setup, player calibration, cutout model loading, foreground processing, encoding and audio stages. Startup uses an indeterminate spinner until measurable progress is available. Foreground progress updates after every completed frame rather than every sixth frame. No timer fabricates progress.
- A delayed stage displays an explanation after 20 seconds without an update. Native failures include the stage in the retryable error message. Development builds save the most recent status, progress, stage and timestamp to the app's `Documents/stadium-preview-status.json`, including normal gallery imports; OSLog records stage transitions and failures.
- The preparation worker belongs to the session, rather than the lifetime of one environment sheet. Closing/reopening the sheet continues the same work, and completed cutouts remain shared across environment choices.
- Explicit cancellation retains the worker until it exits, preventing a second expensive native operation from starting while the cancelled one unwinds. Late results from a cancelled worker are discarded and their files removed. Cleanup resets preparation state on every exit path.

## Verification

`ScenePreparationTests` covers sheet cancellation/reopening without duplicate work, reuse of a completed preparation, explicit cancellation while a native call finishes late, and a stage-specific failure followed by successful retry. These tests and the existing `SceneExportTests` pass; see `artifacts/preparation-stall/tests.log`.

The same existing phone clip was run with the corrected build. At roughly 39 seconds it had passed calibration and reached 28.86% overall; by roughly 127 seconds it had reached 82.89%. It completed at approximately 139 seconds from launch, reporting ready with no error: 422 frames, 1080 × 1920 output, and the full 7.0403667-second duration. The final status is `artifacts/preparation-stall/phone-final-status.json`. Baseline and optimized snapshots, build output and installation logs are in the same directory. The source resolution, frame cadence, full clip duration, foreground quality and audio behavior were not reduced to achieve this improvement.

The first high-quality cutout is still an offline operation. This fix does not make it real-time, and these measurements are for one clip on one iPhone. Switching environments within the same session reuses that cutout.

## Removing unused preview movies without changing the cutout

New preparations now save `original.mp4`, `foreground.mp4`, the lossless alpha cache and scene metadata. They no longer render or encode the two baked Classic Stadium views (`locked.mp4` and `moving.mp4`) that the interactive viewer does not use. Preparation creates the Metal device needed for the existing mask processing without loading environment textures or compiling the scene pipeline. The selected environment is rendered when displayed or exported. Older samples with the baked movies remain supported.

The calibration scan, source decode size, maximum 60 fps cadence, person/ball models, refinement, cache crop/resolution, lossless masks and codec settings are unchanged. No faster or lower-quality preview tier was introduced.

The same iPhone and park clip completed in 124.45 seconds in the new run, compared with approximately 139 seconds from app launch in the previous run. This is a modest observed improvement, not a controlled multi-run benchmark. The new stage timings show approximately 17.85 seconds for calibration and 106.09 seconds for the foreground/frame-processing loop. Almost all remaining work is in those stages.

The original and new device outputs are retained under `artifacts/preparation-no-extra-renders/before/` and `after/`. Verification found:

- All 422 masks have exactly identical values: **zero differing pixels out of 522,300,960**. `scripts/compare-prepared-cutouts.swift` decompresses and compares every mask; its report is `mask-comparison.json`.
- All frame timestamps, crop and camera records, and cutout diagnostics match exactly.
- The full decoded foreground video has the same SHA-256, as do the original audio packets. Video sizes, frame counts and duration match. See `decoded-video-comparison.json` and `media-comparison.json`.
- Prepared storage fell from 101,615,021 to 65,840,863 bytes (about 35% less), excluding the local review manifest added afterward.
- Preparation, lossless alpha, and scene export regression suites passed. Scene export tests now explicitly omit both baked movies. The simulator successfully played the actual new phone cutout in Beach Field, captured in `app-preview.png`.

The updated build is installed on the test iPhone. Quality equivalence is measured for this complete reference clip; the production change removes downstream rendering only and leaves the cutout calculations intact.
