# Indoor Arena material

Generated with the built-in imagegen tool. The room, roof, lights, signage, court markings and reflections are native renderer code. Only the concrete base-color material uses this generated bitmap.

Asset: `kicklab/Assets.xcassets/arena-concrete-v1.imageset/arena-concrete-v1.png`

The tool returned a 1254 × 1254 PNG, retained at its original resolution. The requested resolution in the prompt below was 2048 × 2048. This is a base-color texture; the renderer derives subtle surface variation from it rather than treating it as a calibrated set of PBR maps.

Final prompt:

Use case: photorealistic-natural. Asset type: seamless square albedo material texture for a native Metal 3D indoor football training arena floor. Produce one 2048x2048 top-down orthographic physically plausible dark charcoal polished concrete/resin sports floor material tile, filling the entire image. Fine irregular mottled aggregate, subtly worn resin, tiny mineral flecks, fine multidirectional scuffs, subdued micro scratches and subtle tonal variation at two scales. Dense realistic physical surface detail as if from a high-quality scanned material. Neutral cool charcoal grayscale, middle-dark gray, consistent even diffuse illumination across the full image. Seamlessly tileable left-right and top-bottom. This is a flat PBR base color texture, not a perspective room illustration: no lights, no baked reflections or glints, no directional shadows, no vignetting, no floor lines, no seams, no large cracks, no puddles, no objects, no borders, no lettering or watermark. Surface is polished sealed concrete, not marble with white veins, not metal, not wet asphalt. The shader will add the court lines, actual light reflections, roughness and lighting.
