# Juggle Dude — Juggling flow design pass

Scope: SwiftUI styling and screen composition, as confirmed by the user. Existing recording, tracking, calculation, playback, selection and export behavior stays in place. Debug-review data and footage are illustrative.

## Shared visual system

Use the supplied six-screen reference as the primary direction, together with the mint branding established on Home.

- Canvas: 402 × 874 pt; respect the status bar and bottom home-indicator area.
- Background: near-black teal #041114 with restrained stadium atmosphere. Video is the hero on recording, replay and export; charts and numbers lead elsewhere.
- Panels: #0B2226 to #071719; fine #254448 edges. Avoid flat neutral gray cards.
- Accent: mint #57F5A6; deeper selected green #08784D. White text on selected tabs, dark forest text on mint primary buttons.
- Gold #FFD75A is reserved for completion and milestones. Recording controls use red #FF484D.
- Insets: 20 pt. Spacing scale: 4, 8, 12, 16, 24, 32 pt. Panel radius: 12 pt; preview radius: 16 pt; CTA radius: 18 pt.
- Header: one 44 pt row with circular outline Back on the left, centered 17 pt semibold title, and a balanced right slot. Summary uses Home on the right.
- Typography: system sans-serif, less rounded than the current screens. Tabular numbers. Summary total 76 pt; card values 21 pt; body 14 pt; captions 11–12 pt.
- Primary actions: consistent 52 pt height. Secondary actions: 48 pt height, mint hairline, translucent dark fill. Do not use large glowing capsule tabs.
- Segmented controls: dark rounded rectangle, 4 pt inset, 8 pt selected radius, deep-green fill, mint rim and restrained inner glow.
- Glow is local to an active control, effect or celebratory accent. Body text stays crisp.

## 01 — Recording

Full-height recorded scene. Top-left Close, top-right REC/time pill. Center the large touch count near the top with “Touches in a row” and a small Next: 50 milestone chip below. Three compact translucent HUD cards sit on the right: touches, height and combo. Keep the player and ball unobstructed. Bottom controls are Sound, a dominant red Stop Recording button, and Flip. No main app tab bar inside capture.

## 02 — Processing

Blur and darken the same scene to preserve continuity. Center a realistic football inside thin mint orbital rings; use a football rather than the Home mascot. Below: “Processing Your Session”, a short two-line explanation, progress track with the percentage on the right, and a four-step checklist. Complete/current/pending steps use distinct check/ring/muted states. The handwritten-style encouragement sits low and quiet.

## 03 — Session Summary

Keep Back and Home visible. A small gold crown sits above “Session Complete!”; scattered short gold flecks frame the hero area rather than forming a large radial sunburst. The total leads, with “Total Touches” immediately underneath. “New Best!” is a small green rounded-rectangle badge.

Follow with a compact two-by-two metric grid: Duration / Max Height; Best Combo / Avg. Height. Every card uses a left icon and right-aligned content group with value above label. Height values always include metres; the reference’s unitless “112 Avg. Height” is replaced by an illustrative “0.6 m”.

“Milestones Reached” has two small gold-edged cards. Keep all three actions visible: Watch Replay & Effects, View Detailed Stats, Save & Share. Primary action is mint; the other two are outlined.

Celebration direction: brief 700–900 ms outward drift of a few gold rectangles and diamonds, followed by a quiet static state. No looping confetti. Reduce Motion uses a static crown and flecks.

## 04 — Replay & Effects

Consistent header, then a tall portrait-oriented video pane with central play control and a slim bottom playback strip. The editor is one compact region below the video.

Effects / Ball Style / Environment use the shared rectangular segmented control. Keep the preview and CTA stationary when changing sections.

- Effects: five compact image tiles visible together — None, Fire, Ice, Neon, Galaxy. Selected tile has a thin mint outline; label sits below. Effect Intensity and percentage appear above a slim slider. Avoid the current oversized 86 × 112 tiles and double outer glow.
- Ball Style: same tile geometry, spacing and selection treatment, using actual rendered football thumbnails — Classic, Gold, Matrix, Chrome. No generic repeated SF Symbol balls. Optional selected-style description occupies the same control area as intensity; final control behavior is deferred.
- Environment: four scene thumbnails — Original, Night Pitch, Stadium, Studio. Keep imagery, captions and selected rim consistent with the other sections. Do not substitute large generic moon/building icons.

Bottom action: Save / Share with arrow. This is an editing flow, not the five-tab Home dock.

## 05 — Detailed Stats

Title must be “Detailed Stats”. Use the same selected-tab treatment as Replay: Overview / Touches / Height / Combo.

Overview: three rows of two compact cards, then chart, then consistency card. Metrics are Total Touches / Best Combo; Duration / Max Height; Avg. Height / Drops. Use a trophy, combo/timer, stopwatch, height arrow, bars and x-circle, respectively.

Chart: fine horizontal and vertical grid, readable axis labels, thin mint line, subtle area fill and a small anchored peak tooltip. Avoid a floating pill in the chart title and heavy neon bloom. If the series rises and falls, label it “Touch Pace” with a touches-per-window unit; reserve “Total Touches” for a monotonic cumulative series.

Consistency: smaller ring on the left with only the percentage inside. To its right: Consistency, a mint assessment, and two lines of supporting copy.

Alternate states:
- Touches: touch chart plus clean timestamp rows; no raw normalized x/y coordinates in the main presentation.
- Height: chart with a metre axis plus Max and Average cards. Unavailable estimates use an em dash and concise explanation.
- Combo: best-combo hero and a compact session streak breakdown.

Use a subtle Save & Share continuation below content. Do not let it displace the overview’s chart and consistency panel.

## 06 — Save & Share

Centered “Save & Share” header. Directly beneath it: Original / Edited segmented control. Remove “Ready to Share?” and the second introductory line.

Preview follows immediately. Use the same footage as Replay, with a small Juggle Dude watermark in the edited design state. Original and edited remain clearly distinct.

Then: Video Quality row with 1080p and chevron; mint Save to Device button; outlined Share button; compact Share to row with Instagram, TikTok, YouTube and More; bottom Record Another Session and Done controls. Secondary bottom actions have dark panels, not a competing second bright primary button.

Design states to specify before implementation: exporting/progress, saved confirmation, share sheet, and recoverable export error. Maintain the same layout while busy; replace the primary label with progress rather than adding another large panel.

## Flow

Recording → Processing → Session Summary.
Summary → Replay & Effects → Save & Share.
Summary → Detailed Stats → Save & Share.
Summary → Save & Share directly.
Save & Share → Record Another Session or Done.

Back returns to the previous screen, retaining the design selections in the proposed flow. Home/Done ends the flow. Navigation behavior implementation is out of scope for this design pass.

## Original visual differences addressed in this styling pass

- SessionCompleteView: 32 pt gutters, 120 pt crown region and widely spaced cards/actions produce a taller hierarchy than the reference.
- SessionConfetti: symmetrical long rays and mixed green/gold circles read as a sunburst rather than scattered gold celebration flecks.
- ReplayEffectsView: near-square video, large capsule tabs, oversized horizontal tiles and strong multi-layer glow diverge from the reference.
- ReplayStyleCatalog: Ball Style and Environment use placeholder symbols rather than coherent thumbnail artwork.
- DetailedStatsView: different title, native gray segmented picker, oversized shared stat cards and inconsistent icon language.
- TouchesChartView: axes and vertical grid are absent, peak label is detached, chart glow is too strong, and the consistency ring dominates its card.
- SaveShareView: no centered title, extra headings, oversized spacing and pill-shaped controls alter the reference’s information hierarchy.
