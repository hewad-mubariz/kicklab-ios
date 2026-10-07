# Ten distinct ball effects

The material pass in `EffectShaders.metal` now dispatches Fire to the existing advected flow and the other nine styles to distinct geometry. This supersedes the shared recoloring described in `flow-effects.md`.

| Effect | Shape and behavior |
| --- | --- |
| Fire | Existing temperature-based flow, plus sparse detached flame flecks and embers |
| Ice | Fractured collar, cold mist and faceted ice shards that tumble outward |
| Neon | Bright tilted green loops and narrow woven trails |
| Galaxy | Three spiral arms, violet nebula and orbiting, twinkling stars |
| Electric | Five irregular branching bolts, fast discharge and radial sparks |
| Aura | Thin silver rings, soft trailing light and sparse shimmer |
| Shadow | Charcoal smoke with violet edges and expanding wisps |
| Rainbow | Seven spectral strands and colored particles |
| Pixel | Separate square fragments, grid-aligned cyan particles and stepped motion |
| Nature | Loose vine loops and fluttering, veined leaves |

The four added styles are exposed through `BallStyle.allCases` in both pickers and supported by the shared preview/live/export adapter. Existing string identifiers and shader IDs 0–6 stay stable; additions use 7–10. `scripts/render-effect-cards.swift` generates their thumbnails with the actual shipping renderer and the existing ball photo.

All motion is evaluated from video time and fixed-age emitter history. Trails reject missing intervals. Current-ball masks keep the photographic center visible, including under particles. Shadow retains an independent absorption alpha; its darkness is not lost in bloom. Pixel, Shadow and Nature use restrained bloom. Particle budgets vary from 16 for Aura to 100 for Galaxy; the counter keeps its existing 210-particle treatment. The region size cap remains 640 pixels.

## Validation

- 21 simulator tests pass, including all ten material silhouettes compared using normalized alpha rather than palette differences.
- Every material is tested for pause/seek determinism, animation, zero intensity/visibility and premultiplied preview/export equivalence.
- Simulator and unsigned iPhone Release builds compile the actual Metal shaders.
- `scripts/review-distinct-effects.py` checks the app's ten 1080p exports for dimensions, duration, frame count, full decoding and unchanged source AAC, then generates a review page and motion contact sheets.
- [Visual review](../artifacts/distinct-effects/index.html) and [media results](../artifacts/distinct-effects/verification.json).

Physical-iPhone frame rate/thermal performance and person-depth occlusion are not validated by these simulator checks.
