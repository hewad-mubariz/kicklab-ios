# Lab Flame

Lab Flame (`labFlameFX` in `kicklab/Effects/Metal/EffectStudies.h`, style 11) is the warm flame with a clear ball. Fire (style 1) is a separate effect and is unchanged.

## v2 · living plume (11 October 2026)

The plume above the ball read as one static yellow sheet. Its length only changed with ball speed, so the outline held one shape, and its texture scrolled in one direction while evolving slowly, so it slid like a sticker.

- Plume length varies across its width and flickers several times a second, so the tip splits into licks of different heights.
- The texture evolves about three times faster, so it changes as it moves instead of sliding.
- The side-to-side sway has a second, faster wave, so it is less regular.
- Tongue tips cool further toward orange-red, and overall brightness flickers slightly.

Review: [before / after video](../artifacts/lab-flame-v2/before-after.mp4) (v1 left, v2 right), [falling-ball frames](../artifacts/lab-flame-v2/before-after-drop.png) (v1 top, v2 bottom). Rendered with the real engine on the Mac GPU over a synthetic juggle using the home-screen photo. The shader was compiled from source at runtime because the Metal toolchain isn't installed. The Xcode suite and iPhone build were not run.
