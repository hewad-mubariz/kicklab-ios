# Effects Lab assets

The Crystal effect and the Gold Polish skin, ported from the Effects Lab (accepted 1 November 2026), ship three third-party sources. All three are CC0 1.0, so no attribution is required. They are recorded here so their origin stays traceable.

| App file | Source | Licence |
| --- | --- | --- |
| `kicklab/Effects/Lab/Skins/gold-environment.bin` | [Photo Studio Loft Hall](https://polyhaven.com/a/photo_studio_loft_hall), Sergej Majboroda / Poly Haven, 1K Radiance HDR, downloaded 2026-11-01 | [CC0 1.0](https://polyhaven.com/license) |
| `kicklab/Effects/Lab/Crystal/studio-environment.bin` | [Studio Small 09](https://polyhaven.com/a/studio_small_09), Sergej Majboroda / Poly Haven, 1K Radiance HDR, downloaded 2026-10-29 | [CC0 1.0](https://polyhaven.com/license) |
| `kicklab/Effects/Lab/Crystal/ice-normal.jpg`, `ice-roughness.jpg`, `ice-detail.jpg` | [Ice003](https://ambientcg.com/view?id=Ice003), ambientCG, 1K JPG set, downloaded 2026-10-29 | [CC0 1.0](https://docs.ambientcg.com/license/) |

The lab converted each HDR into linear RGBA16F mip levels (`scripts/gold/prepare-environment.py` and `scripts/prepare-studio.py` in `kicklab-effects-lab`). The originals and their licence notes are kept under that repository's `references/` folder. The ice fracture meshes (`ice-fracture-*.bin`) are procedural, built by the lab's `scripts/footage/build-fracture-mesh.py` from no outside source.
