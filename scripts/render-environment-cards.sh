#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

# Use the app's scene and sign renderers so picker artwork matches playback.
CARD_OUTPUT="${1:-kicklab/Assets.xcassets}"
CARD_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/juggle-dude-cards.XXXXXX")"
trap 'rm -rf "$CARD_BUILD"' EXIT
CARD_METAL="$(xcrun --find metal 2>/dev/null || true)"
if [[ ! -x "$CARD_METAL" ]]; then
  CARD_COMPILERS=(/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain*/Metal.xctoolchain/usr/bin/metal(N))
  if (( ${#CARD_COMPILERS} == 0 )); then
    print -u2 'The Xcode Metal compiler is required.'
    exit 1
  fi
  CARD_METAL="$CARD_COMPILERS[1]"
fi
"$CARD_METAL" -fmodules-cache-path=/tmp/kicklab-metal-cache -c -target air64-apple-macos26.0 \
  kicklab/Environments/StadiumPreview.metal -o "$CARD_BUILD/scenes.air"
"$CARD_METAL" "$CARD_BUILD/scenes.air" -o "$CARD_BUILD/scenes.metallib"
xcrun swiftc -O \
  kicklab/Environments/ForegroundMaskProcessor.swift \
  kicklab/Environments/BallForegroundMask.swift \
  kicklab/Environments/SceneCameraRig.swift \
  kicklab/Environments/VisibleFootContact.swift \
  kicklab/Environments/PreviewEnvironment.swift \
  kicklab/Environments/StadiumSignage.swift \
  kicklab/Environments/ArenaSignage.swift \
  kicklab/Environments/UrbanSignage.swift \
  kicklab/Environments/ForestSignage.swift \
  kicklab/Environments/StadiumPreviewRenderer.swift \
  scripts/render-environment-cards.swift -o "$CARD_BUILD/render-cards"
"$CARD_BUILD/render-cards" "$CARD_BUILD/scenes.metallib" "$CARD_OUTPUT"
print "Rendered all six environment cards into $CARD_OUTPUT"
