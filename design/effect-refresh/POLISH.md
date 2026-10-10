# Effect studies — polish pass

Compared each new effect with `effects-concepts-v1.png`. Renders below are from the shipping shaders (each effect at three moments; the fourth column of the "before" sheet is Heat Pulse just after a touch):

- `polish-before.png` is the state before this pass.
- `polish-after.png` is the state after it.

| Effect | Before | Change |
| --- | --- | --- |
| Lab Flame | Dark brown, smoky blotches over the wake; an orange cast | Coverage now follows brightness, so the cool edges fade instead of reading as smoke. Heat ramps orange → yellow-white at the roots and cools only at the tips. The wake keeps a soft floor, so the noise shapes it without carving holes. |
| Glow Trail | Needle-thin line | Tapered ribbon, full width at the ball. White-hot core, soft cyan halo, more visible dust. |
| Blue Flame | Good; rim slightly cartoonish | Hot white-blue thread where each tongue leaves the ball; tongues a little wider and brighter near the ball; calmer rim wobble. |
| Ember Wake | Sparks too small and faint to read | Larger, longer, hotter sparks that keep more of the ball's motion, so they streak along the path. A faint warm glow along the recent path ties them to the ball. |
| Flame Ribbon | Good | Hot inner core, soft glow and flickering tips. |
| Heat Pulse | Blobby fringe, plain rings | Tighter fire corona; rings get a soft amber glow, and older rings fade further. The picker icon holds the ball still just after a touch, so the rings sit around it. |

Files touched: `kicklab/Effects/Metal/EffectStudies.h`, the Ember Wake call and the study particle block in `EffectShaders.metal`, and `kicklab/Effects/EffectIconRenderer.swift` (Heat Pulse icon only). Shader IDs, identifiers and the tracking logic are unchanged.
