# Ball preparation, without a phone

This command-line harness compiles the production source-spin, outline, lighting,
blur and video-composition code with `swiftc -O`. It consumes retained source video
and an appearance track saved as `[StoredFrame]` in a plist. It does **not** run the
model, render the replacement, exercise iOS lifecycle/thermal policy, or change a
counter. `Support.swift` supplies CLI-only app/cache types; appearance algorithms
come from the application sources. App caches are deliberately bypassed.

```sh
bash scripts/ball-preparation-benchmark/run.sh source.mov visual.plist result.json 3
```

The JSON includes every timestamp, measured quaternion, acceptance/visibility
flag, lighting sample and exposure estimate. Compare those fields exactly before
making any performance claim. Timings are Mac wall time and include host load.

To compile the old implementation against the same harness, export
`BallSurfaceTimeline.swift` and `BallSurfaceMotion.swift` from the desired Git
revision to temporary files, then set `BALL_BENCH_TIMELINE`, `BALL_BENCH_MOTION`,
`BALL_BENCH_BASELINE=1` and a separate `BALL_BENCH_BUILD`. The baseline flag only
omits the newer timing field. `BALL_BENCH_FOOTPRINT` can also select a frozen fitter.
Run the resulting `benchmark` binaries directly to alternate repetitions without
recompilation. Do not run multiple measurements or builds concurrently.

```sh
python3 scripts/ball-preparation-benchmark/compare.py baseline.json result.json
```

The geometry experiment samples every twelfth source frame by default:

```sh
bash scripts/ball-preparation-benchmark/run.sh \
  --geometry source.mov visual.plist geometry.json 12
```

It compares fresh fits at 720 and 1080 short-edge decoding (capped to native
resolution), and checks whether enabling texture measurement changes geometry
on the same pixels. Coordinates are normalized to 720 for comparison. This is
an experiment, not an enabled geometry cache. Identical timestamps alone are
insufficient for safe reuse: decoded size, colour conversion, source identity
and guide must also match. No full-resolution pixel buffers are retained.

On iPhone, Debug source-spin preparation writes
`Documents/ball-preparation-timing.json`. `origin` distinguishes computation from
memory/disk cache hits or shared work. `requestSeconds` is the current wait;
`computation` describes the original analysis, even on cache hits. Existing caches
can legitimately have no stage measurements. Release does not collect or write
these stage timings. The existing `--effects-memory-probe` diagnostic separately
records dense detection, mask repair, spin, export, memory and thermal stages.
The capture-preparation review also saves `surface-motion-timing.json` in its
review folder, including when `--analysis-ignore-cache` bypasses the cache. Export
reports distinguish `surface_motion_post_export_lookup_s` from
`surface_motion_original_compute_s`; the latter must not be added to export time.
