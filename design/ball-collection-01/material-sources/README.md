# Ball collection surface refinement

The reference PNG/JPG files and resource backups described here are local inputs
excluded from Git. Obtain those inputs before regenerating materials; reviewing
the existing bundled runtime materials does not require regenerating them.

The approved sheet is `../approved-sheet.png`. The first implementation used low-detail procedural colour only. The second pass uses generated surface textures for Lava and Volt, object-space relief normals, recessed panels, finer Metal grain and softer steel reflections. Pearl retains a procedural pearlescent finish with rounded panel relief.

The generated images are surface references, not billboard images of a ball. The app uses the same rotating sphere material for its picker, replay and saved video. Full-frame masks, tracking and ball registration remain unchanged.

## Source assets and prompts

Both raster sources were generated with the built-in image-generation tool, using the approved sheet as a material reference, on 2026-10-10. PNGs preserve original outputs; JPGs are format conversions used by the offline baker.

- `lava-rock.png` / `ball-surface-lava.jpg`: “Use case: photorealistic-natural. Asset type: seamless tileable game material texture. Reference image: only the rough BLACK VOLCANIC ROCK surface of ball 02 LAVA is the material reference. Generate a square full-bleed flat orthographic macro texture of exactly that charcoal volcanic rock, irregular chipped sharp layered dense stone, slightly reflective silicate flakes, craggy basalt relief, photogrammetry quality. Neutral soft cross-polarized illumination, no shadows or highlights baked from a sphere, uniform tonal range dark gray to medium gray. Edge-to-edge rock; no seams, no panels, no lava, no glowing cracks, no orange, no ball silhouette, no background, no perspective, no letters or labels. Medium-scale chunks 15-35 pixels across in a 1024px square with much finer grain layered on top. Avoid sandy/gravel/crumpled paper look. Material will wrap onto football panels in code.”
- `volt-rubber.png` / `ball-surface-volt.jpg`: “Use case: photorealistic-natural. Asset type: seamless tileable game material texture. Reference image: only the NEON LIME RAISED RUBBER GRAIN on ball 04 VOLT is the material reference. Generate a square full-bleed orthographic macro of this premium lime rubber sports-ball material. Closely packed rounded irregular hexagonal pebble embossing, each pebble a gently raised dome, shallow darker crevices between grains, very fine stipple on each dome. Pebbles roughly 15-25 pixels across at 1024px, visible rounded surface relief. Electric yellow lime, almost chartreuse; no darker green mottled blobs. Uniform diffuse neutral lighting, micro occlusion only. NO ball, NO panels, NO large seams, NO sphere shading, NO directional lights, NO background, NO letters. This is a repeating material swatch for wrapping onto a real-time 3D football. Photoreal detail, matching reference's tactile rubber.”

## Reproduce the materials

From the repository root:

```sh
swiftc -O kicklab/Effects/BallSkin.swift kicklab/Effects/BallCollectionMaterial.swift kicklab/Effects/BallSkinSphereRenderer.swift scripts/review-ball-collection.swift -o /tmp/juggledude-review-ball-collection
JUGGLE_DUDE_BAKE_MATERIALS="$PWD/kicklab/Resources/BallMaterials" JUGGLE_DUDE_SURFACE_SOURCES="$PWD/design/ball-collection-01/material-sources" KICKLAB_BALL_MATERIALS_DIR="$PWD/kicklab/Resources/BallMaterials" JUGGLE_DUDE_PRINT_SOURCES="$PWD/resource-backups/20261010-shipping-cleanup/BallMaterialSources" /tmp/juggledude-review-ball-collection artifacts/ball-collection-02
```

Omit the first two environment variables to review the actual bundled materials without regenerating them.

Each `.jdmaterial` contains LZFSE-compressed, 1024×512 material data: RGBA colour/seam distance followed by packed RGB object-space normals. Its decoded length is validated before use. The alpha channel is metadata, not transparency. Generation code is excluded from iOS; only decompression and sampling run on the phone. Detailed ball raster is 256px, animated picker raster 144px. Images in `artifacts/ball-collection-02` are actual production renderer outputs, not generated mockups.

The approved source is a static concept render; moving materials match its material direction and detail but do not reproduce every highlight or panel placement pixel for pixel.

## Original catalogue adoption

All ten earlier ball styles now use the same material/normal-map renderer. Their existing JPG print assets remain the colour sources in `resource-backups/20261010-shipping-cleanup/BallMaterialSources/` (outside the app target), with their existing UV alignment and seam-edge blending. No new AI artwork was generated for these ten styles. Surface normals come from small material-grain and recessed-panel height fields; printed ink brightness is deliberately not interpreted as physical height.

Classic, Crimson, Graffiti and Aurora use a fine sports-ball grain. Stealth has a matte finish, Matrix has a restrained green emission, Gold and Chrome receive metallic reflections, Arctic has a glossier finish, and Galaxy retains its dark print with a very subtle clear coat and rim. The four newer materials are unchanged by this adoption.

Only four recently used material maps are retained (14 MiB total), guarded by a lock for concurrent picker/replay/export access. Rendered sphere images use a separate 2 MiB cache. In-flight render calls may temporarily retain evicted maps until their work completes. Original video, tracking, contour fitting, occlusion, motion smear and Pro access rules are unchanged.

To rebuild and review only the earlier ten styles after compiling the review tool:

```sh
JUGGLE_DUDE_BAKE_SKINS=classic,stealth,matrix,gold,arctic,crimson,galaxy,chrome,graffiti,aurora JUGGLE_DUDE_BAKE_MATERIALS="$PWD/kicklab/Resources/BallMaterials" KICKLAB_BALL_MATERIALS_DIR="$PWD/kicklab/Resources/BallMaterials" JUGGLE_DUDE_PRINT_SOURCES="$PWD/resource-backups/20261010-shipping-cleanup/BallMaterialSources" /tmp/juggledude-review-ball-collection artifacts/ball-catalog-detail/after --original-catalog
```

Omit `JUGGLE_DUDE_BAKE_SKINS` to rebuild every material used by the selected review sheet. The `before` and `after` sheets in `artifacts/ball-catalog-detail` compare the same production-renderer pose. Tests exercise rotation/seek determinism, concurrent material eviction, transparent edges, encoded video export for all 14 skins, contour preservation and Free/Pro access.
