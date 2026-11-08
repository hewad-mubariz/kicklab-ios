# Effects Lab assets

The Crystal effect and the Gold Polish skin, ported from the Effects Lab (accepted 1 November 2026), ship three third-party sources. All three are CC0 1.0, so no attribution is required. They are recorded here so their origin stays traceable.

| App file | Source | Licence |
| --- | --- | --- |
| `kicklab/Effects/Lab/Skins/gold-environment.bin.lzfse` | [Photo Studio Loft Hall](https://polyhaven.com/a/photo_studio_loft_hall), Sergej Majboroda / Poly Haven, 1K Radiance HDR, downloaded 2026-11-01 | [CC0 1.0](https://polyhaven.com/license) |
| `kicklab/Effects/Lab/Crystal/studio-environment.bin.lzfse` | [Studio Small 09](https://polyhaven.com/a/studio_small_09), Sergej Majboroda / Poly Haven, 1K Radiance HDR, downloaded 2026-10-29 | [CC0 1.0](https://polyhaven.com/license) |
| `kicklab/Effects/Lab/Crystal/ice-normal.jpg`, `ice-roughness.jpg`, `ice-detail.jpg` | [Ice003](https://ambientcg.com/view?id=Ice003), ambientCG, 1K JPG set, downloaded 2026-10-29 | [CC0 1.0](https://docs.ambientcg.com/license/) |

The lab converted each HDR into linear RGBA16F mip levels (`scripts/gold/prepare-environment.py` and `scripts/prepare-studio.py` in `kicklab-effects-lab`). The originals and their licence notes are kept under that repository's `references/` folder. The ice fracture meshes (`ice-fracture-*.bin`) are procedural, built by the lab's `scripts/footage/build-fracture-mesh.py` from no outside source.

## Lossless bundle storage

The two environments and the triangle/BVH files now ship as `.bin.lzfse`. `LabAssetData`
decodes them once when their renderer resources are prepared. The Metal texture formats,
1024 × 512 resolution, every precomputed mip level, and all geometry bytes stay identical.
The 32-byte roots file and the three existing JPEG textures stay unchanged. No raw duplicate
of a packed asset should be included in the app. Raw `.bin` inputs are still supported for
external Effects Lab directories.

| Resources | Original bytes | Packed bytes |
| --- | ---: | ---: |
| Two reflection maps | 11,184,816 | 4,840,286 |
| Crystal triangles, BVH and roots | 3,452,624 | 917,008 |
| Three ice JPEG textures | 2,341,620 | 2,341,620 |
| Total | 16,979,060 | 8,098,914 |

This saves 8,880,146 bytes of unpacked app resources. It adds a one-time decode when an
effect's resources are loaded; frame rendering and GPU memory use are unchanged. Download
packages already compress raw files, so this is not an 8.88 MB download-size claim.

Repack or recover an asset with the system Foundation LZFSE codec:

```sh
xcrun swift scripts/pack-lab-assets.swift pack input.bin output.bin.lzfse
xcrun swift scripts/pack-lab-assets.swift unpack input.bin.lzfse output.bin
```

The packer verifies exact round-trip bytes before writing. `LabAssetStorageTests` checks the
decoded hashes against build 77's original data, resource packaging, failure handling and skin
rendering. `scripts/verify-lab-asset-renders.swift` compares the production Gold/surface/Crystal
renderers with raw and packed resources; all 36 original-versus-packed frame hashes matched
on the Mac. Crystal preparation tests also exercise the app's actual preview/export renderer.
