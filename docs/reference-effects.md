# Ball-driven effects · input 4

Fire has since been revised in the [procedural Fire pass](procedural-fire.md), following the user's requirement for code-generated moving flames. The other nine effects and their review below remain unchanged.

This pass supersedes `player-effects.md`. The attached ten-card artwork is the visual reference. The ball is the emitter: energy and debris can spread beside the player, but no effect is anchored to the person's body or feet.

The person rectangle, extra GPU uniform, body field and body particle population introduced in the previous pass have been removed. Live/replay/export use the original seven-vector frame contract. The Debug detector report still records person boxes as diagnostic data, and a regression test proves they cannot change effect geometry.

## Materials

- Fire retains its existing flowing volume and embers.
- Ice uses a fractured glass-like shell, uneven crystal spires, tumbling faceted shards and a cold settling wake.
- Neon uses bright emerald arcs and detached open coils. Coils originate at recorded ball positions, expand and drift downward, then fade. It has saturated jackets and fine pale cores, with small green sparks.
- Galaxy uses a turbulent inclined vortex, rising blue/violet nebula and scattered stars with brighter glints.
- Electric uses unequal, curved, branching discharges and a jittering corona, with pale cores and yellow light spill.
- Aura uses open silver arcs, thin trailing filaments and restrained shimmer.
- Shadow uses opaque charcoal clouds and torn violet edges drifting upward from ball history.
- Rainbow uses seven separate spectral bands, an open ball curl and a bending wake. White additive cores are excluded so the bands retain their color.
- Pixel uses loose cyan blocks emitted around the ball and along its path, with stepped drift.
- Nature uses an organic green eddy, winding stems and rotating veined leaves.

A finite 0.8-second ball history provides births. Older ribbon positions are smoothed locally and sampled at 80 Hz; gaps remain empty and the current ball center stays exact. Emitted materials have different transport directions. The original ball remains visible through a radial mask. Pause, seek and export use video time rather than accumulated simulation state.

## Evidence and limits

`artifacts/reference-effects/index.html` is the synchronized original/effect review. Full videos use input4.mp4, original daylight, 85% intensity and native 720 × 1280 output. `analysis.json` contains the real recorded track: 456 analyzed frames. Coverage is not an accuracy score.

The regression run covers distinct alpha silhouettes, ball movement, wake direction, independence from person boxes, missing-track clearing, pause/seek repeatability, crop geometry, and preview/export compositing. The iPhone Release build is checked separately. Physical-device frame rate and thermals remain unprofiled.

These are 2D effects, without depth occlusion. The existing audio mux passes AAC payloads through, but on input 4 it drops a priming packet and approximately 0.1 seconds of the audio tail. Media reports record this explicitly; complete bit-identical audio is not claimed. Audio export code was not changed in this graphics pass.

To rebuild the media review after app exports are copied into the artifact folder:

```sh
python3 scripts/review-reference-effects.py
```

Debug simulator launch:

```sh
xcrun simctl launch --terminate-running-process booted com.juggledude \
  --effects-video /Users/hewadmubariz/Downloads/input/input-positive/input4.mp4 \
  --effects-track /absolute/path/artifacts/reference-effects/analysis.json \
  --effects-folder reference-effects-input4 --effects-quality 720 \
  --effects-environment original --effects-export
```

Wait for the new run's `Documents/reference-effects-input4/status.txt` to say `COMPLETE` before copying the exports.
