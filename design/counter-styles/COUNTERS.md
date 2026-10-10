# Touch counter styles

Normal and Classic are unchanged. The ten earlier alternatives (Particle Burst, Fire, Ice, Lightning, Galaxy, Neon Ring, Ripple, Flipboard, Pixel Burst, Golden Sparks) are retired: all ten shared one Helvetica number with a decoration around it, and a touch barely registered. A saved retired style now falls back to Normal and keeps its position, size and rotation.

The ten replacements live in `kicklab/Effects/CounterArt.swift`. Each has its own lettering and a signature move on every touch. All motion comes from the count, the time since the last recorded touch and media time, so the editor, scrubbing and exported video match frame for frame.

| Style | Look | On every touch |
| --- | --- | --- |
| Odometer | Gunmetal housing, black drums, lime ones digit | Drums roll up to the new number with motion blur and overshoot; carries roll a beat later; a glint sweeps the glass. Lime glow on every 10th. |
| Broadcast | Sports scorebug: slanted navy bar, lime tab, match clock from the video time | A lime wipe sweeps the new number in; a "+1" tab drops out from behind the bar and tucks back. Turns gold on every 10th. |
| Comic | Halftone starburst, chunky outlined number, caption box | Burst pops, the number squashes and springs, speed lines, and a sound word (POW!, BAM!, WHAM!…) spins in. |
| Neon Sign | Pink glass-tube digits, cyan script "touches", wall glow | The new number buzzes on with a two-step flicker and an over-bright flash; an occasional idle buzz. |
| Molten | Cast-metal digits with a dark edge | Flashes white-hot with embers and heat haze, then cools through orange to crusted steel over ~3 s. Juggle fast and it never cools. Drips run while hot. |
| Glitch | Cyan HUD digits with scanlines, corner brackets, blinking cursor | The digits tear into slices with a wide red/blue split and noise blocks; brackets snap in. Rare idle micro-glitches. |
| Graffiti | Pink-to-orange bubble letters, black outline, 3D drop, overspray, tape label | Sprayed in with a mist burst; paint drips run down over the next second. |
| Jelly | Glossy blue-raspberry candy digits | Wobbles tall then squashes and settles; bubbles rise and pop. |
| Gold Coin | Medal on a mint ribbon, reeded rim, engraved number | Tosses and flips edge-on to the new number, lands with sparkles and a shine sweep (12 sparkles on every 10th). Idle shine every ~4 s. |
| Chalkboard | Wooden slate, chalk number, tally marks in fives | The old number is wiped, the new one written, and the next tally stroke drawn with a chalk-dust puff; the fifth strikes the group. |

Review renders (drawn by the shipping renderer over a frame of the test clip):

- `picker.png`: the twelve picker thumbnails (`CounterArt.previewAge` picks each style's thumbnail moment).
- `touch-strips.png`: each new style from the moment of a touch (29 → 30, a milestone) to settled.
- `retired-styles.png`: the previous set, for comparison.
