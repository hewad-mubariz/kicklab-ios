**Body gate experiment — 24 October 2026**

The experiment compares current `footEvidenceV15` counting rules with the same rules while bypassing only the final body-eligibility rejection. It is compiled only for debugging and cannot be selected by ordinary live counting or saved-video analysis.

Both arms still evaluate body evidence. This preserves the verifier's aligned physical-contact timing and allows an audit of what the original gate would have decided. Hand contact, sustained holding, ground checks, trajectory thresholds and all input observations remain unchanged. Simply selecting the old `unrestricted` policy would also alter the ground evidence timing and would confound the comparison.

The dataset comprises the 20 clips in the frozen 14 October development corpus, the five-minute 17 October walkthrough and the latest 19 October recording. SHA-256 identities tie videos to archived observations. The phone rereads source pixels and runs fresh Vision evidence. Each arm must finish, flush, and pass numeric trace replay. The scorer also requires identical input operations, current configuration, verifier flags and original body evidence wherever both arms evaluated it. A mismatch aborts scoring.

Older imported-video archives used the nominal-FPS composition clock. The harness now supports an explicit `legacyCompositionClock` flag to reproduce that clock for these 20 archives. It retains the strict source-frame and 2 ms timestamp checks. The two camera captures use the original sample clock. This is a replay compatibility change, not a live detector change.

The corpus uses the existing one-to-one event matcher with a 200 ms tolerance. Invalid events/intervals, uncertain events and unreviewed predictions remain separate. The original labels are unchanged. The walkthrough's 20 prior positive labels are a selected set of known misses, not a complete ground truth. All 38 additional walkthrough predictions also received source-image review.

Two additional samples were selected independently of the new outcomes: 20 equally spaced original body rejections and 20 equally spaced original ground rejections. These samples audit the old assessment; their labels are cross-referenced to current decisions. Most low contacts sit at or beyond the source image boundary, so uncertainty is retained rather than interpreted as a correct touch or false rejection.

These are development-footage results reviewed by the assistant, pending human confirmation. Frozen observations isolate rule behavior; they do not measure the current live detector, frame scheduling, latency, power use or general accuracy. In particular, this harness does not rerun the live RF detector/contact-recheck pipeline. Historical live totals and today's frozen-observation baseline are therefore not interchangeable. Chest-specific behavior also needs new labelled footage before drawing a chest-specific recall conclusion.

**Validation and device build**

The two new counting tests verify that the bypass changes only body eligibility, preserves original diagnostic evidence, and cannot evade hand, holding or ground rejection. The targeted device run passed 42 tests in six suites, with no failures or skips. Existing scorer tests passed (six tests), the new Python scorer compiled, and the final signed device build succeeded. The toe-flick ground-evidence fixture and reviewed floor-bounce fixtures were included in the passing device run.

`Touch Counting Debug`, bundle `com.juggledude.touchcounting.debug`, build `2026102402`, contains the experiment and uses the current production counting policy during ordinary recording. The production policy was not relaxed. Source snapshots, build/test logs, raw before/after traces, source hashes and visual contact sheets are under `artifacts/body-gate-review-20261024`.

The full-source 7.667 s toe-flick clip was not locally available for this experiment. Its prior 19 October device report already records the fix and retained rejection of the 13.703 s floor bounce. Today's fixture pass is additional rule-level verification, not a claim that that full clip was rerun today.

**Reproduce scoring from downloaded results**

```sh
python3 scripts/compare-body-gate-replay.py \
  artifacts/body-gate-review-20261024/sources.json \
  artifacts/body-gate-review-20261024/results \
  --output benchmarks/touch-counting/body-gate-review-20261024/comparison.json
```

The command refuses incomplete datasets. Device replay can be resumed with only unfinished clips; completed pairs retain their original output. Interrupted attempts are excluded.
