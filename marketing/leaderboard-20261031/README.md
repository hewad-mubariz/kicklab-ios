# Leaderboard screenshot — next release

Prepared on 31 October 2026. **Not uploaded to App Store Connect.** The existing
1.1.0 (36) submission was observed as **Waiting for Review**, with manual release
selected. No review/release action or store metadata change was made in this task.
The known public-profile moderation gap remains deferred; the keyword check does
not resolve that review risk.

## Artwork

- `contact-sheet.png`: the five localized compositions side by side.
- `screenshots/<storefront>/04-leaderboard-1320x2868.png`: opaque RGB PNGs ready
  for the existing large-iPhone screenshot slot, subject to owner approval.
- `screens/`: actual native simulator captures in English, German, French,
  Spanish and Brazilian Portuguese.
- `copy.json`: localized headlines, captions and storefront mappings.
- `sources/portraits/` and `prompts.json`: six fictional adult player portraits
  generated with the built-in `image_gen` tool; no real user images were used.
- `sources/iphone-17-pro-max-blue.png`: the same frame used by the current store
  screenshots. The device continues below the artwork's bottom edge, as before.

The fixture mixes European and Asian names: Maja Lind, Ren Takahashi, Arjun Mehta,
Luca Moretti, Jiwoo Park and Léa Martin. The current player's row reads the app's
localized “You”. Scores, durations and profiles are illustrative. The artwork
states this explicitly. Spin/height data and any verified-score claim are absent.

The actual app UI is used, including its pennants, avatars, weekly/all-time tabs,
score bars and duration/rhythm labels. No controls or statistics were painted
over the captured UI. The capture is from the supported iOS 18 interface on the
isolated iPhone 11 Pro Max simulator, framed consistently with the existing media.

## Language / region coverage

All **five supported app languages** are prepared. The files map to ten potential
App Store localizations: en-US, en-GB, en-AU, en-CA, de-DE, fr-FR, fr-CA, es-ES,
es-MX and pt-BR. Regional variants with identical app language/copy deliberately
share the same image. Only the four English listings and German currently exist
in App Store Connect; the remaining variants are staged for future localized
listings. This does not claim support for every world language or add new ones.

The headlines do not use “soccer” or “football”, avoiding that regional mismatch.
If the app's supported language set changes, add a matching capture and copy
entry before uploading new store localizations.

## Reproduction

The local Debug-only `storefront` fixture is selected with:

```sh
--session-design leaderboard --leaderboard-preview storefront
```

`capture.sh SIMULATOR_UDID` copies the portraits into that simulator's Documents
folder, launches each language and renders the artwork. Use an isolated booted
simulator with a Debug build of this branch installed. The fixture is in memory;
it does not create accounts, store history, upload photos or publish scores.
It is excluded from Release and is not persisted between ordinary app launches.

To re-render without launching the app:

```sh
xcrun swiftc marketing/leaderboard-20261031/render.swift -o /tmp/leaderboard-render
/tmp/leaderboard-render marketing/leaderboard-20261031
```

## Validation

Debug simulator build passed. All five localized captures and compositions were
visually inspected for names, portraits, localized UI, wrapping and frame crop.
The final exports are 1320 × 2868, RGB and opaque; `manifest.json` records their
hashes. No version increment, archive, TestFlight upload, device installation or
production leaderboard changes were made for these media assets.

Store keyword values and release status are recorded in `listing-check.json`.
The metadata check found no reason to withdraw the existing submission for
keyword changes. This is not a guarantee of App Review approval.
