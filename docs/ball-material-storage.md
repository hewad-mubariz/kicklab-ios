# Ball material storage

The fourteen artwork skins retain their original 1024 × 512 colour, seam-distance
and object-space normal bytes. Storage is lossless; render size, lighting, spin,
masking, shader calculations and exported video quality are unchanged.

## Bundled catalog

`Resources/BallMaterials/ball-materials.json` is a versioned catalog. Each material
references three content-addressed `.jdmap` files: RGB colour, one-channel seam
distance, and XYZ normals. A map is stored once even when several skins use it.

The 42 original maps contain 29 unique maps: 14 colours, 5 seams and 10 normals.
Each map is optionally transformed by a reversible green-channel difference and
a reversible spatial predictor (none, left, above or Paeth), then LZFSE compressed.
These transforms improve compression; they never quantize or discard pixels.
The packer chooses the smallest encoding, verifies all candidate round trips,
and verifies every complete material through the production loader.

`BallMaterialStorage` validates format, dimensions, channel counts, references
and exact decompressed lengths. Output allocations are bounded. Unknown or
broken catalogs fail rather than falling back to different artwork. Legacy
`.jdmaterial` files remain supported for offline tools, but are not shipped as
duplicates. No extra third-party library or network connection is required.

| Resource group | Previous bytes | New bytes |
| --- | ---: | ---: |
| Fourteen artwork skins, including catalog | 37,187,220 | 20,083,815 |
| Gold/Crystal reflection maps, geometry and ice textures | 8,098,914 | 8,098,914 |
| Total skin/effect resources | 45,286,134 | 28,182,729 |

The saving is 17,103,405 bytes. These are uncompressed app resource sizes, not an
App Store download-size measurement. Shared shader code and renderer executable
code are not counted in this resource subtotal.

The signed Release archive fell from **188,358,354 to 171,278,307 bytes** after
including the decoder and signature overhead. Model files, Metal shader library
and Lab effect assets are byte-identical to the preceding archive. Asset catalog
renditions are unchanged (its build timestamp/header metadata was regenerated).
See `benchmarks/releases/20261109-ball-material-storage.json` for measured results.

## Runtime trade-off and validation

Loading reconstructs the same arrays accepted by the existing CPU and Metal
renderers. There is no new work per rendered frame. The CPU material cache still
holds at most four materials (14,680,064 bytes); the Metal renderer retains at most
two material buffer pairs. There is no additional decoded-map cache. Thus this
change reduces disk/install size, not steady-state renderer RAM or export time.

On this M1 Max, optimized direct loads with warmed filesystem caches measured a
median 5.77 ms for legacy storage and 11.51 ms for the new storage, over ten loads
per material after warm-up. Maximum new load was 13.85 ms. This is an uncached
material-load cost, not a phone benchmark or a per-frame cost. Phone cold-picker
responsiveness should be checked before release, especially on iPhone 11.

All fourteen decoded SHA256 values match the original materials. The production
CPU renderer produced 112 pixel-identical frames across both 144px/256px sizes
and four orientations. `BallMaterialStorageTests` checks original hashes and
packaging, known predictor vectors, malformed/oversized output, and legacy-tool
compatibility. Existing collection and Metal tests cover rendering, bounded
caches, background/failure fallback and actual encoded exports.
All ten targeted tests passed on the iOS 26.5 simulator. The signed device Release
archive also passed strict signature verification. Unpacking and repacking the
shipping catalog reproduced every packaged file byte-for-byte.

## Adding or rebaking artwork

Use a new temporary output directory; the packer refuses to overwrite one.
Run from the repository root:

```sh
xcrun swiftc -O kicklab/Effects/BallMaterialStorage.swift scripts/pack-ball-materials.swift -o /tmp/pack-ball-materials
/tmp/pack-ball-materials unpack kicklab/Resources/BallMaterials /tmp/juggle-material-sources
```

The unpack step restores the exact legacy material bytes in their original
layout. Add/rebake a skin into that temporary source directory using the existing
macOS baker (`JUGGLE_DUDE_BAKE_MATERIALS` and optional `JUGGLE_DUDE_BAKE_SKINS`).
Then pack the **whole catalog** so that existing maps are deduplicated and obsolete
maps are omitted:

```sh
/tmp/pack-ball-materials pack /tmp/juggle-material-sources /tmp/juggle-material-pack
```

After validation, replace the contents of `Resources/BallMaterials` with the new
pack. Do not add source `.jdmaterial` files beside the shipping catalog. Existing
skin raw IDs stay unchanged, preserving saved selections. Updating an intentional
design also requires updating its original-data hash in the storage tests.

To compare the actual renderer before/after a storage change:

```sh
xcrun swiftc -O -whole-module-optimization -D DEBUG kicklab/Effects/BallMaterialStorage.swift kicklab/Effects/BallCollectionMaterial.swift kicklab/Effects/BallSkin.swift kicklab/Effects/BallSkinSphereRenderer.swift scripts/verify-ball-material-storage.swift -o /tmp/verify-ball-material-storage
KICKLAB_BALL_MATERIALS_DIR=/tmp/juggle-material-sources /tmp/verify-ball-material-storage /tmp/juggle-original-renders
KICKLAB_BALL_MATERIALS_DIR=/tmp/juggle-material-pack /tmp/verify-ball-material-storage /tmp/juggle-packed-renders
```

Both reports' `decoded` and `frames` dictionaries must match exactly. The renderer
runs separately to avoid carrying cached materials between inputs.

## Future catalog delivery (recommendation, not implemented)

Lossless packing and deduplication help each new skin, but cannot keep an unlimited
catalog from increasing the app size. Current packed colour maps range from
0.37–1.09 MB. A new colour design that uses an existing seam and normal map adds
mainly that artwork; a new surface needs its unique maps too.

For a larger catalog, retain a small starter set and lightweight previews in the
app, and offer optional full-quality downloadable packs:

1. Download a pack once on selection with progress, retry and offline availability
   clearly shown. Keep the exact production bytes; downloading is not a quality
   downgrade. Downloaded packs still consume device storage.
2. Store immutable versions and hashes. Saved edits keep their skin ID/version so
   future catalog updates cannot silently change an existing replay.
3. Finish and verify required downloads before starting an export. Pin packs used
   by an active preview/export so cache cleanup cannot remove them mid-job.
4. Include downloaded-effect storage in Manage Storage, allowing removal and later
   download without removing saved sessions. Keep the starter set available offline.
5. Keep downloads independent of Pro entitlement checks; access to a file does not
   itself grant permission to use a paid effect.

[Apple's managed asset packs](https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs/)
support iOS 26+. The app's minimum remains iOS 18, so that feature alone cannot
serve all supported users. An HTTPS/CDN downloader using
[background URLSession](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)) can
support the existing minimum; alternatively use managed packs on newer OS versions
with a compatible older-OS delivery path. Choose one catalog/storage interface
before adding those delivery backends. This work has not enabled downloads or
published assets.

Avoid a new dependency on Apple's older On-Demand Resources: Apple documents its
[deprecation starting in iOS 27](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits/).
Keep procedural generation for designs that are created procedurally; replacing
existing prints with approximations would not meet the no-quality-loss requirement.
