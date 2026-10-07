# Fire material sources

Rejected for runtime animation: the user requires procedural, code-generated Fire. These images were removed during artifact cleanup and must not be used as flame sprites or atlases. These prompts are retained only as design history. See `docs/procedural-fire.md` for the active implementation.

Generated with the built-in image generation tool from the approved [input 4 concept](fire-input4-v1.png). These black-background emission plates are sampled, warped and keyed in the runtime shader; they are not frames composited over the source video offline.

## Plume prompt

Use case: stylized-concept.
Asset type: production VFX emission texture for an animated Metal fire shader, portrait 2:3.
Reference image: use ONLY the realistic flame material in the supplied soccer mockup.
Generate ONE isolated ascending flame plume on a pure solid black RGB 0,0,0 background. No person, ball, field, floor, smoke, objects, reflections or text. This is the fire element itself for additive compositing.
The flame occupies the middle 80% width and 90% height, fully contained with black margin on every edge. At the bottom, a narrow root near (50%,90%) splits into golden orange curling flame sheets. The plume widens through lower-middle then tapers into thin winding tips near (42%,7%). Height about twice width. Richly folded, extremely detailed, photoreal fire with many hollow curls, translucent orange membranes, fine bright yellow-white edges, dark airy gaps, delicate branching red-orange outer filaments. Match the intricate curling flame material in the reference exactly. Luminous thin edges, NOT a solid white/yellow blob or opaque orange mass. Root is gold-yellow, tips are orange and fade to black naturally. Several distinct overlapping flame tongues with asymmetric organic folds and holes. Crisp filigree fire detail suitable for close-up real-time rendering. Do not add sparks: those will be separate animated particles. Keep all four edges perfectly black, no clipping, no checkerboard, no watermark.

## Corona prompt

Use case: stylized-concept.
Asset type: production VFX emission texture for an animated Metal fire shader, square image.
Reference image: use ONLY the realistic flame material wrapping the ball in the soccer mockup.
Generate ONE isolated hollow crown of FIRE viewed straight on, on perfectly pure solid black RGB 0,0,0. No ball, person, objects, ground, stars, sparks, smoke, text or interface. This is the fire element alone. Completely EMPTY BLACK circular center centered exactly at (50%,50%), radius 24% of image width, so a football can later show through. Fine uneven flame roots begin immediately outside this hole. Layered realistic yellow-white flame edges and thin golden-orange translucent membranes curl and lick outward, swirling asymmetrically into longer tips on the upper left and shorter curls along lower right. Intricate 3D folded fire tongues, tiny filigree folds, airy black gaps, warm red-orange disappearing tips. Maximum outer radius 45% of width, all flame fully inside frame with black margin. Root is bright yellow-gold, several near-white hot edges, vivid orange outer folds. Match reference flame fidelity. Avoid a neat geometric ring, neon line, outline stroke, perfectly uniform doughnut, smooth halo, blurred blob or solid yellow flame mass. Hollow irregular flame wreath, no solid material in the middle. The center hole must remain pure black. No global background glow. No checkerboard.
