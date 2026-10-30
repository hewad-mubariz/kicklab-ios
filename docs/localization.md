# Juggle Dude localization

The interface ships in English, German, Spanish, French and Brazilian Portuguese.
`kicklab/Localizable.xcstrings` holds the app's strings and `kicklab/InfoPlist.xcstrings`
the camera, motion and Photos permission prompts. Both live in the synchronized app folder,
so Xcode compiles them into every lproj with no extra project setup.

## Which language the app uses

iOS picks the first language in the iPhone's list that the app supports. Region doesn't
matter: an English iPhone in Germany stays in English. When nothing in the list matches,
the app falls back to English.

Profile → Settings → Language lists "Same as iPhone" and the five languages, each written
in its own name. A choice writes the app's `AppleLanguages` default, the same value iOS
writes from Settings › Apps › Juggle Dude › Language, so both places stay in step. The app
now applies this choice immediately, including on the language page itself, with no loader
or restart. Navigation, account, purchases, recording and replay objects are not recreated.
Choosing "Same as iPhone" removes the app override and resolves the defaults search list
again. Returning to the foreground also refreshes externally changed language preferences.
Apple-owned interfaces and permission prompts follow iOS's own localization lifecycle.

`AppLanguageEnvironment` supplies the selected locale to SwiftUI. Plain strings use the
selected `.lproj` bundle and locale explicitly; changing only the locale argument of
`String(localized:)` would format substitutions but leave the actual wording in the launch
language. `LanguagePreferences` publishes one observed, locked snapshot so existing views
invalidate when they read localized model labels, and background video work can read it
safely. Country choices are cached per language, and processing tips are computed instead
of caching the first language forever. Prices still come unchanged from StoreKit.

## What stays in English

- The brand and product names: Juggle Dude, Pro, Power Shot.
- Effect, ball, trail, graph-style, counter-style and camera-move names, their descriptions
  and each move's own tuning labels (for example "Whip blur").
- Text drawn into exported videos and motion-graph overlays.
- Debug, lab and design-review screens. Their catalog entries are marked "Don't translate".

Editor controls around those names are translated (Customize, Intensity, Speed, Delete,
"Pick a move below…").

## Wording

German uses du, Spanish tú (neutral wording for Spain and Latin America: video, teléfono,
"la configuración"), French tu with French spacing before ! ? : ;, and Brazilian Portuguese
você. Keep these terms consistent:

| English | German | Spanish | French | Portuguese (Brazil) |
| --- | --- | --- | --- | --- |
| touches | Kontakte | toques | jongles | toques |
| juggling | Jonglieren | toques | jonglage | embaixadinhas |
| session | Training | sesión | séance | treino |
| streak | Serie | racha | série | sequência |
| leaderboard | Rangliste | ranking | classement | ranking |
| shot / strike | Schuss | disparo / golpeo | frappe | chute |
| touch check | Kontaktprüfung | revisión | vérification | verificação |

## Adding strings

SwiftUI literals (`Text("…")`, `Button("…")`, `Label("…")`) are extracted automatically.
A helper that takes a title should accept `LocalizedStringKey` (or `LocalizedStringResource`
when it also needs a plain string), not `String`. Messages built outside views use
`String(localized: "…", bundle: AppLanguage.bundle, locale: AppLanguage.locale)` so they
follow live changes while remaining extractable by Xcode. For an existing
`LocalizedStringResource`, pass it through `AppLanguage.resource(_:)` before displaying or
resolving it. Don't store a resolved translation in a static constant. Write whole sentences
rather than joining fragments, and let counts
go through the catalog's plural rules instead of choosing "touch"/"touches" in code. Keep
identifiers, raw values that are stored or sent, and status codes out of localization.

After adding strings, build in Xcode so the catalog picks them up, then translate the new
entries in each language.

## Leaderboard candidate — 30 October 2026

The language work is integrated into `codex/post-launch-signin-leaderboard-ball-edges`.
The translations originate from uploaded 1.0.4 (31). This branch adds immediate language
switching on top, uploaded as TestFlight 1.1.0 (32). Leaderboard-specific view helpers and
messages are localized as well. The subsequent release-wording cleanup also translates
the opt-in, automatic-streak, local-video and Apple/email messages in all five languages;
that cleanup is not part of build 32.
`LeaderboardLocalizationUITests` exercises Apple/email choices, email entry,
weekly/all-time tabs, rules and automatic-score details in all five languages,
alternating light and dark appearances. Google and postponed touch-check actions
remain hidden. This test sends no sign-in email and writes no public score.

`testLanguageSwitchUpdatesOpenScreensWithoutRestartAndPersists` changes all five languages
in one app process, checks the open picker/settings, home, sign-in and leaderboard, then
checks persistence on relaunch and switching back to the iPhone language. `AppLanguageTests`
covers preference reset, observation, externally changed preferences, resolved resources,
cached labels and preserving StoreKit's price in translated purchase wording.

30 October validation: 29 distinct focused simulator checks pass after fixing the open
Profile presentation's retained locale/navigation titles. Both in-process switching and
launch-time localization cover all five languages. See the
[live-language validation report](../benchmarks/releases/20261030-live-language-switch.json)
for the initial failure, corrected rerun and the separately interrupted StoreKit test.
The owner subsequently confirmed immediate switching on iPhone 11; the same source was
packaged as 1.1.0 (32), available to internal testers. It was not submitted to App Store
review. See [TestFlight record](../benchmarks/releases/20261030-testflight-1.1.0-32.json).

The replay-editor upgrade is deferred to a later release. Its new Looks, Sound,
My style and milestone controls are not included in this candidate; their text
will need a separate translation pass when that work is brought back.
