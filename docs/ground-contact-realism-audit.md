# Ground contact and scene realism — 28 September 2026

The large buried-foot appearance in the reviewed park footage is primarily a source-visibility and compositing problem. It is distinct from the raised-leg crop defect fixed in the previous pass. A small floor-anchor lag also exists, but the measured lag does not explain missing toes.

## Evidence

[Source / decoded alpha / neutral-background comparison](../artifacts/ground-contact-study/feet-source-mask.jpg) at 0, 3.0 and 6.5 seconds shows that grass already hides the lower toes and soles in the original image. The extracted silhouette ends at that visible grass boundary. Placing that shape on a smooth indoor floor exposes the truncation. Improving segmentation can retain visible skin and remove grass contamination; it cannot reveal the hidden underside from this frame alone.

The current `foregroundStudy` shader renders the room first, then places the person over it. It has no floor-depth test that clips the person below the floor, and no later floor layer paints over the feet. Therefore the missing visible foot shape is not caused by a floor occluder in this renderer.

`VisibleFootContact` estimates the lowest connected lower-leg boundary above alpha 64/255. `FootContactTracker` smooths its vertical position. The preparer measures contact before final boundary refinement, so the stored anchor and delivered sole can disagree. An audit of all 212 newly prepared iPhone frames found a maximum of approximately 0.78 virtual centimeters below the plane: about four pixels in the 3840-high source, or two pixels in the 1920-high original preview. These virtual units depend on the rig's assumed 1.75m person height; they are not a measured real-world foot depth. The audit does not assess faint alpha below 64/255 or unseen skin.

The reproducible geometry check is `scripts/audit-ground-contact.swift`; results are in [phone-before.json](../artifacts/ground-contact-study/phone-before.json). This compares the decoded delivered alpha with the actual saved camera/contact, rather than assuming that an anchor on the mathematical floor proves the whole sole is above it.

## Why the environment still looks composited

1. **Different illumination:** the foreground retains the source park's light direction, exposure, green bounce and shadows. Version-2 edge decontamination does not relight the body. The arena has its own cool/warm lamps and dark reflective materials.
2. **Simplified contact:** there is one support point and an elliptical contact shadow, not independently classified left/right planted feet. Its smoothing is not a jump/contact classifier. A shadow can strengthen the visual connection, but cannot restore missing toes.
3. **Flat foreground geometry:** all person and ball pixels lie on one vertical plane. Camera height/FOV are estimated from a person rectangle and a fixed assumed height, not recovered from a source ground plane and lens calibration. Virtual viewpoint changes cannot reveal the recorded body's unseen sides.
4. **Approximate reflection:** the floor reflects that same flat cutout with a fixed fade/blur. It does not have the actual underside geometry of the feet or lighting/material interaction with the person.
5. **Remaining edge defects:** grass-colored fringes and boundary fluctuations remain visible in the prior phone review and reinforce the pasted-on impression.

Preview and export share `StadiumPreviewRenderer`, `SceneSelection.camera`, and the saved scene recording. No separate export-only floor placement was found in the code path. This is a code-path finding; no new user-provided export file was available to compare pixel for pixel with its preview.

## Recommended next implementation

Treat scene integration as its own stage, with a realistic matched-scene baseline before increasing camera freedom:

- Establish visible-foot contact from the final person matte and add regression checks against the rendered floor, while preserving independent evidence for planted versus lifted feet. Distinguish a small anchor correction from recovery of source-occluded toes.
- Match the replacement scene's lighting and camera perspective to the source. Daylight park footage is a more natural initial fit for a daylight/turf environment than a dark polished indoor arena. Keep virtual movement restrained while the person is a flat layer.
- Add temporal exposure/white-balance matching and a restrained scene-dependent foreground grade, then contact/cast shadows consistent with the chosen lighting. A color grade is not full physical relighting; directional lighting changes require additional scene/body information or a validated relighting model.
- Validate with visible feet on a hard surface as well as grass footage, stationary and walking/juggling clips, and the exact saved exports. Check contact, lighting, shadows, reflections and matte quality separately.

No production settings were changed by this follow-up audit. Lowering the whole person or hiding more of the feet would conceal the symptom without recovering the missing shape. Reconstructing occluded anatomy would be a separate synthesis feature and should not be introduced silently into a faithful sports replay.
