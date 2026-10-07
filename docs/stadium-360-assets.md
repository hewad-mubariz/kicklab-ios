# Stadium asset provenance

Built-in image-generation tool, with the user's stadium image as an art-direction reference. No third-party stadium photograph was downloaded. The shipped texture is `kicklab/Assets.xcassets/stadium-panorama-v2.imageset/stadium-panorama-v2.png`. It provides distant architecture and turf detail; native Metal supplies projection, ground contact, pitch markings, goal and branded boards.

Generation prompt: “Production 360-degree equirectangular environment texture for a native Metal football app. Deep navy night sky, continuous oval bowl, detailed occupied dark blue seats, two tiers, warm recessed concourse lights, convincing steel canopy trusses, cool-white roof-mounted floodlights, restrained mist and bloom. Standing eye-height camera near the penalty arc. Full-sphere 360×180 latitude-longitude panorama, 2:1, horizon at vertical midpoint, matching left/right edges. Photographic materials and muted turf. Blank dark LED fascia for native branding. No pitch-side people, ball, captions or watermark.”

Refinement prompt: “Remove both white football goals and white pitch markings, filling with the original black boards and turf. Keep stadium geometry, viewpoint, panorama, sky, roof, lights, crowd, exposure, colors and dimensions unchanged. The app renders its own goals and lines.”

The generated stadium bitmap is 1774 × 887. It is an artistic backdrop, not a surveyed reconstruction, geometrically accurate equirectangular photograph, or recovered stadium geometry. Its architecture repeats twice around the azimuth; the native bowl, pitch, boards and goals provide world-space placement. Repeated KICKLAB branding is a deterministic 2048 × 512 native text asset (`stadium-boards-v2`), rather than generated lettering.

The generated turf albedo is saved as `kicklab/Assets.xcassets/stadium-turf-v2.imageset/stadium-turf-v2.png`. Art direction: seamless overhead short-cut football turf, dense fine blades, natural muted greens, even neutral illumination, no lines, objects, horizon, cast shadows or perspective. The shader repeats it in world space, selects mip levels explicitly for distance filtering, and adds mowing, illumination, near-field blades and contact shadows. The stadium bitmap does not supply the playable ground.

Final bundled assets:

- `kicklab/Assets.xcassets/stadium-panorama-v2.imageset/stadium-panorama-v2.png`
- `kicklab/Assets.xcassets/stadium-turf-v2.imageset/stadium-turf-v2.png`
- `kicklab/Assets.xcassets/stadium-boards-v2.imageset/stadium-boards-v2.png`
