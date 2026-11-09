# Paywall hero assets

The Pro hero uses an intrinsic vertical layout: the brand, three actual ball-skin
previews, headline and subtitle each have their own space above the feature and
purchase controls. There is no fixed photo crop or negative overlap with the
feature row. Feature labels can wrap to two lines on narrow screens.

The old hero decoded both `home-juggling` and `pro-hero-player` at 1024 × 1536.
It also animated a photo zoom, player entrance and five-step touch counter with
a blurred motion line. The new hero has three static 256 × 256 transparent
previews, native gradients and one short entrance sequence. The small accent
behind the previews uses the existing native curve shape. It does not instantiate
the material loader, Metal renderer, pose model, video player or a repeating timer.

`pro-skin-stealth`, `pro-skin-gold` and `pro-skin-volt` are lossless PNG snapshots
from the production `BallSkinSphereRenderer`, using the original material data
and a zero-angle source pose. Their display sizes stay at or below 84 points,
so they have sufficient native pixels on 3× screens. Regenerate through
`scripts/verify-ball-material-storage.swift` (build/run instructions in
[ball-material-storage.md](ball-material-storage.md)); copy the corresponding
`<skin>-256-0.png` outputs into these three image sets when an accepted skin design
changes. No AI approximation or extra texture generation runs in the paywall.

The paywall-only cutout image set has been removed. `home-juggling` is still used
by Home and capture design screens, so it remains in the app.

| Compiled iPhone rendition | Bytes |
| --- | ---: |
| Old paywall-only player cutout | 346,624 |
| Three new previews together | 263,231 |
| Saving | 83,393 |

The hero's image surfaces fall from 3,145,728 to 196,608 pixels (16× fewer).
This is a texture/image-work comparison, not a measured reduction in whole-app
RAM or power. Asset rendition savings are not an App Store download-size claim.
See `benchmarks/releases/20261109-paywall-hero-assets.json` for asset hashes and
measurement details.

Navigation, closing after scrolling, and both plan selections were checked with
the existing UI tests. The purchase-completion test encountered the simulator's
Apple Account sign-in sheet; no completed transaction is claimed. Visual checks
use both the iPhone 17 Pro Max and a short iPhone SE simulator. Phone builds with
the outdoor test overlay are not replaced by this design preview.
