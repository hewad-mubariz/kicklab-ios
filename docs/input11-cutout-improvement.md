# input11 mask and ball improvement

Retained selected-player guide filtering and post-inference protection of agreed player interiors. The experimental ball recovery, size constraints and expanded mask support were removed at the user's request. The pre-experiment ball path is restored; model weights are unchanged.

[Current detector-versus-pipeline findings](../artifacts/input11-model-boundary/REPORT.md) · [Source-aligned fault examples](../artifacts/input11-model-boundary/fault-localization.jpg) · [Retained player changes](../artifacts/input11-model-boundary/retained-player-changes.patch)

The links below describe the **withdrawn ball experiment**. Its videos and ball-loss improvements are historical evidence, not current-build validation. The restored build passes 69 app tests; this rollback has not been rerendered across the full clip.

[Full implementation report](../artifacts/input11-fix/REPORT.md) · [Visual before/after review](../artifacts/input11-fix/index.html) · [Comparison video](../artifacts/input11-fix/comparison.mp4) · [New arena render](../artifacts/input11-fix/render/arena.mp4)

See the report for measured improvements, new/remaining misses, selected-frame regression coverage and runtime limitations. The original audit is preserved at [input11-cutout-audit.md](input11-cutout-audit.md).
