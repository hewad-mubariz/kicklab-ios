# V2 lab shader libraries

These are the existing V2 lab bridge's 29 separately compiled Metal libraries,
captured from the design checkout on 19 November 2026. `manifest.json` records
the SHA-256 of both platform variants. Environment textures remain under
`kicklab/Effects/Lab/Bridge/Resources`.

The app's **Copy Lab Metal Libraries** phase selects `iphoneos` or
`iphonesimulator` using Xcode's build platform and copies only that set into
the app. The resource filenames and renderer entry points are unchanged.
Switching build destinations must not rewrite the source checkout's binaries.
`LabBridgeTests` exercises all bridged effects and skins on the built destination.

The original shader sources live in the user's `kicklab-effects-lab/EffectLab`
project. Changes to those sources require regenerating and validating both sets;
this snapshot does not add that separate project's development harness to the app.
