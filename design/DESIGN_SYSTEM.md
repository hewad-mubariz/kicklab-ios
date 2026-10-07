# KickLab design system

This implementation follows the supplied day/night home mockup.

## Foundations

- Brand mint: #7DFA8F. Daytime green: #1FA840. Deep forest: #0F3B21.
- Light surfaces: warm ivory, near-black green text, subtle white rims.
- Dark surfaces: deep teal-black, off-white text, mint actions.
- 16 pt page margins, 9 pt grid gaps, 15 pt card corners.
- Bold italic wordmark; condensed card titles; simple system body text.
- Three columns at standard text sizes; two at accessibility text sizes.
- Day/night stadium artwork fills the screen. Card images crop within their column.
- Navigation reserves its own safe-area space, keeping the milestone reachable.
- Selection uses a mint circle with restrained glow in both appearances.
- Press motion: 160 ms. Tab selection: 320 ms spring. Reduce Motion removes movement. No continuous idle animation.

## Components and navigation

Theme.swift owns shared colors, spacing, surfaces and press feedback.
Home components own the header, wordmark/mascot, mode cards and milestone.
The five dock destinations share these same tokens. Profile offers a persisted System / Light / Dark appearance picker.
Juggling opens the existing capture flow. Other shooting modes open an explicit coming-soon preview. The milestone opens Progress; the avatar opens Profile; the bell opens Notifications.

Home still uses the existing HomeSnapshot.preview sample name, streak and milestone.
Progress identifies this sample data. No session history or challenge backend was added.

## Artwork

Created with the built-in imagegen tool. Original assets retained.

- Day: ../kicklab/Assets.xcassets/pitch-day.imageset/pitch-day.png
- Night: ../kicklab/Assets.xcassets/pitch-night.imageset/pitch-night.png
- Avatar: ../kicklab/Assets.xcassets/avatar-player.imageset/avatar-player.png

### Day prompt

Use case: stylized-concept. Asset type: portrait 9:16 background image for KickLab mobile football training app, no UI or typography. Create a premium cinematic realistic 3D football pitch at sunny daytime, camera very low near vibrant fresh green grass. Clear pale blue sky occupies top 28 percent, softly out of focus leafy trees and small community stadium grandstands with tall floodlight poles at left and right occupy next 15 percent, field horizon at 43 percent down image, lower 57 percent lush vivid green football turf with sunlit blades and gentle bokeh in foreground. The center at 35 percent height is open and quiet for a mascot to be overlaid by the app. Warm natural sun from upper right. Rich natural green, blue sky, bright welcoming sports atmosphere, enough definition to feel like a real pitch, no fog or white haze. Edges slightly soft depth of field. No people, no balls, no text, no logos, no icons, no phone frame. This is a full bleed app background asset, not a mockup.

### Night prompt

Use case: lighting-weather. Asset type: portrait mobile football app background. Input image is the edit target, the daytime football pitch. Preserve camera position, exact composition, all structures, field horizon and grass. Change ONLY lighting and time of day to a cinematic night training session. Deep blue-black teal sky, bright white floodlights at left and right turned on with soft bloom, vibrant dark emerald green grass illuminated from the sides, gentle atmospheric blue-teal haze far away, subtly glowing pale green grass tips. Top 25 percent remains clean near-black teal negative space for white UI labels. Preserve bottom green field with bokeh, no new objects, no text, no people, no balls, no UI. Premium sports app backdrop. NOT sunset, no warm amber sky.

The day image was used as the night edit reference. Existing mascot and training card assets are reused.

### Avatar prompt

Use case: stylized-concept. Asset type: tiny circular avatar portrait for a friendly football training mobile app. Square image. Polished 3D animated movie style head and shoulders portrait of a friendly young adult male football player with medium tan skin, short wavy dark brown hair, warm brown eyes, soft smile, wearing a simple dark forest green football jersey with cream collar. Front facing, centered symmetrical composition, entire head and shoulders comfortably inside central 80 percent for circular crop. Soft pale blue-gray studio background. Rounded appealing stylization, high quality soft studio lighting, crisp silhouette that reads at 40 pixels. No text, no logos, no border, no ball, no additional objects.

## Verification

Verified on iPhone 17 Pro / iOS 26.5 simulator:

- Final Debug simulator build succeeded.
- HomeNavigationTests.testHomeRoutesAndAppearance passed (27.3 seconds).
- Verified milestone clearance, disabled unavailable cards, mode preview sheet, notifications, all five tabs, and appearance persistence across relaunch.
- Visually inspected light/dark Home and dark Train screenshots. Refined the goalkeeper crop and compact text after the initial check.
- Existing concurrency warnings remain in camera/video export code outside this design change.
- Physical-device camera behavior was not retested.

Screenshots: kicklab-refined-light.png and kicklab-refined-dark.png.
