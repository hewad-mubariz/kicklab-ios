# Wall Arcade consolidated into main

20 November 2026. Source integration only; the user explicitly requested no build.

## Shared base

Continue Wall Arcade development from `main`. Its existing V2 navigation, counter,
saved-session analytics, editor, notification routing and app shortcuts are the
base. The main checkout began at `2a89b3f9`. Unrelated working-tree and staged
editor changes were preserved and excluded from this integration commit.

The latest wall implementation was the working tree of
`codex/wall-games-release` (committed base `d462a8c6`), including its previously
uncommitted changes. Comparison with `codex/keeper-wall-games` found no later
differing wall/keeper source files there. The source worktrees remain intact.

The imported code includes camera/impact tracking, setup reuse, corner recovery,
projector and phone interfaces, display-delay measurement, bounded recording,
replays, audio, artwork, shaders, game assets, existing tests and fixtures.
The keeper worktree also supplied its existing qualification notes and wall
diagnostic scripts. Generated builds, test output and raw recordings were not
copied into main.

## Existing game scope

The consumer preview retains its nine entries: Brick Blast, Clear the Wall,
Memory Strike, Meteor Defence, Top Bins, Cross & Circle, Four in a Row,
Territory Duel and Copy My Shot. Goal Duel, Virtual Penalties and Find the Space
remain in the research source; they are not newly added to that menu.

## Entry point and configuration

The existing `WallGamesPreview` scheme/configuration now uses the current main
app and its native Wall Game tab. Back from the arcade selects Home. The preview
retains its separate `com.juggledude.wallarcade.preview` identity and iOS 26.5
minimum. Its app, tests and embedded widget all have matching configurations;
current Debug configuration settings supply the modern dependencies and model
exclusions. No old production project file was substituted.

`WALL_GAMES_PREVIEW` still gates the consumer arcade UI, and the existing
`DEBUG`/`BALL_DETECTION_DEBUG` gates remain on the research runtime. Normal Debug
and Release keep the existing Wall Game placeholder and their iOS 18 minimum.
This commit consolidates the source; it does not qualify or enable the games for
the production release. Promoting the feature and checking its bundled assets,
localization and supported OS/device behavior are subsequent work.

The main app delegate keeps push registration and quick-action handling. Only
the wall preview delegates external-display connections and orientation to the
wall runtime. Main's normal counter implementation is retained; the imported
detector additions are the existing physical-ball size filter and model-load
diagnostic used by the wall code.

## Verification and remaining work

Performed without compilation: project/plist and scheme XML validation, config
reference checks, resource/header and fixture checks, source-manifest comparison,
duplicate top-level symbol inspection, diff whitespace checking, and preservation
checks for the pre-existing staged and unstaged changes.

No Xcode build, Swift compilation, XCTest execution, archive, installation or
TestFlight upload was run. Historical test notes describe the earlier wall
branches, not validation of this combined main revision. The next device/build
pass must check current detector compatibility, projector connection/reconnection,
tab transitions, setup, all menu games, interruption, recording and replay.
