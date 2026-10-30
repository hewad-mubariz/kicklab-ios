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
writes from Settings › Apps › Juggle Dude › Language, so both places stay in step. iOS reads
it at launch: the list tells the player to close and reopen the app, and the change applies
then. `UIApplication.openSettingsURLString` was not used because on iOS 26.5 it opened the
Settings root rather than the app's page.

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
`String(localized:)`. Write whole sentences rather than joining fragments, and let counts
go through the catalog's plural rules instead of choosing "touch"/"touches" in code. Keep
identifiers, raw values that are stored or sent, and status codes out of localization.

After adding strings, build in Xcode so the catalog picks them up, then translate the new
entries in each language.
