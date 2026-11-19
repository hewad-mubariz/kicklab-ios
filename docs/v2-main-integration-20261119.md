# V2 main-app integration — 19 November 2026

The main Juggle Dude project combines the V2 design checkout with the qualified
Counter V2 counting and preparation implementation. Use the normal `JuggleDude`
scheme and app entry point. This is a local source integration, not an App Store
submission or a new timing/accuracy qualification of the combined app.

## Included

- V2 Home, five tabs, challenges catalogue, profile flow, widgets, shortcuts,
  translations and the current replay tools, ball skins and effect bridge.
- The selective Full-model toe provider used by Counter V2 in both live recording
  and Gallery. The existing native hand/body/floor checks, observed-player matching
  and bounded contact windows remain. Short observed rebounds request measured
  foot proof; unresolved edge contacts require positive foot evidence. The counter
  identity separates new analyses from historical native-only decisions.
- Exact-input prediction reuse in the asynchronous dense preparation pass,
  including the normal RAM cache. No changed frame cadence, model resolution,
  output mask policy or inference runtime.
- Shared crop repair and motion preparation by default on `iPhone18,2`
  (iPhone 17 Pro Max), with the existing separate-pass safety fallback. Other
  hardware retains separate passes unless explicitly selected in the research app.
- Original-source replay first, readiness monitoring, a single compatibility
  conversion fallback, and reusable validated conversion files. Export and scene
  rendering retain their existing explicit preparation contracts.
- The RF/pose disk stores and PowerShot reuse implementation are present but keep
  their existing research-only activation gates. Normal completed session/motion
  caching remains active. This does not enable durable partial-job recovery.

The replay editor combines the V2 graph picker with the playback-monitor changes.
Its optional analytics worker now cancels when disabled or the editor closes;
generation checks prevent a cancelled worker from publishing into a later editor.
Video storage is held for that reader's lifetime and incomplete reads cannot be
published as completed analytics. These new analytics views still have their own
body-pose preparation; this merge does not make that work durably reusable across
editor visits or certify its long-video cost. These views are previews; their
export integration is separate work.

## Deliberately separate

The counted-mask quick preview, fixed provisional spin/lighting, progressive
preparation, alternate inference runtimes, benchmark entry points, saved-input
fixtures, fresh-run namespace hooks and the research app's guest-onboarding bypass
are not enabled in the main app. The earlier 0.68–0.72-second provisional-preview
timings do not describe this main-app build. Full preparation still needs work.

## Dependencies and build destinations

Install the existing approved RF package with `scripts/install-rf-model.py`, and
run `python3 scripts/install-counter-pose-model.py`. The latter downloads the
unmodified Google Full model and verifies SHA-256
`5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1`.
An unexpected existing model is rejected rather than overwritten. Model binaries
remain ignored by Git; the SDK wrapper and checksums are versioned under
`Vendor/MediaPipeTasks`. Heavy is not bundled. The app force-loads the same graph
archive as the qualified research build; it does not restore the retired
per-frame `ShoeContactRecovery` implementation.

The design checkout previously replaced its 29 bundled `.metallib` files when
switching between Simulator and iPhone. `Vendor/LabShaders` now retains both sets
with hashes. The app's build phase copies only the selected platform's set,
without editing source files. Environments and artwork stay in the normal app
resources. Shader-source development remains in the separate effects-lab project.

## Validation and preservation

The final unsigned Release device build passed. **162 tests passed, zero failed
and zero skipped** on an isolated iOS 27.0 Simulator (164 parameterized executions).
This includes actual pose-graph inference, all bridged effect/skin draws and the
V2 navigation smoke test. Home and challenge screenshots were inspected. The
all-skin check took 359.308 seconds in the unoptimized Simulator; a stack sample
identified Coral’s one-time distance-field generation as the dominant work. That
is a separate first-use cost to check on a phone, not a preparation-speed result.

Build/test evidence is retained under
`artifacts/main-integration-20261119/`; the compact result record is
`benchmarks/integration/20261119-main-v2.json`. It distinguishes the unsigned
Release device build, Simulator logic/rendering/navigation checks, and tests that
cannot be qualified on Simulator. No phone is used for this integration; in
particular the iPhone 11 remains untouched at the user's request.

Before combining changes, the research source, V2 source and existing main edits
were snapshotted with file hashes. Original recordings, saved analysis, phone
backups and pinned restore apps remain outside the commit. Existing main edits
and the separate design checkout are preserved. Research evidence and generators
remain in their original worktree; their previously archived generated sources
describe the historical builds, not the newly integrated main source.

Before distributing this combined build, exercise real camera/Gallery, Photos
save, widgets/App Group provisioning, background handling and the new effects on
the intended phones. No new speedup, complete one-hour support, or public-release
readiness is inferred from this merge.
