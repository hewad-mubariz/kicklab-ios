# Motion styles, v2

Kept: Ball Motion (default) and Comet. Rebuilt: Bounce Run. Retired: Flight Path, Peak Bars, Motion Scan and Direction Fan (technical readouts that did not explain much). Seven new styles turn measured data into something playful. Every style reads only measured data up to the playhead: ball height, confirmed touches, completed bounces. Scaling uses the session's own range, so scrubbing never shifts the picture.

| Style | Shows | How |
| --- | --- | --- |
| Ball Motion | Height over time | The original line graph. |
| Comet | Height over time | Line graph with a glowing tail behind the ball. |
| Bounce Run | Every touch | A mini platformer: the ball hops pad to pad at its measured height; the landing pad lights up with "+1" and dust, pads are numbered, and two layers of hills scroll behind. |
| Heartbeat | Rhythm | Heart monitor: each touch is a beat, its spike sized by the bounce it launched. A ♥ pulses on every touch beside touches per minute. A long pause flatlines. |
| Melody | Bounce height | Each completed bounce is a note at its apex, pitched by height across the session's range. Stems and beams follow printed music; the note in the air is an open head following the ball. |
| Fireworks | Bounce height | The rocket climbs with the ball; at the top it bursts. Higher bounces burst higher and wider; a new best bursts gold with "BEST". |
| Sky Meter | Height vs best | Altimeter: the ball climbs with a contrail against a gold BEST line (your highest completed bounce). Live percentage of best; earlier bounces stand as ghosts. The line flashes "NEW BEST!" when beaten. |
| Combo | Rhythm streak | A touch at roughly the usual pace (½ to 1.75× the recent median gap, at most 1.5 s) extends the streak. Every ten raises the multiplier (x2, x3…) with "LEVEL UP!". A long wait or a very uneven gap shatters the bar ("COMBO LOST"). |
| Metronome | Tempo | The pendulum reaches each side exactly on a touch, so it swings at your tempo; the weight rides higher when slower. Touches per minute and its Italian marking (Largo … Presto). |
| Rainbow Arcs | Every bounce | Each completed bounce is a glowing rainbow arc from touch to touch, peaking at its apex; the live arc grows with the ball. |

Narrow layouts (picker thumbnails) switch to compact versions of Heartbeat, Sky Meter, Combo and Metronome.

Renders (shipping SwiftUI renderers; 18 real touch times from the test clip, with modelled flights between them):

- `hud-over-footage.png`: all ten at HUD size over a frame of the clip, at two moments.
- `picker-thumbnails.png`: the ten picker cards.
- `retired-styles.png`: the previous seven, for comparison.
