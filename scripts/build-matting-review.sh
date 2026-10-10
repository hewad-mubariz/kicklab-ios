#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
STUDY_OUT=artifacts/matting-strategy-study
mkdir -p "$STUDY_OUT"
STUDY_METAL="$(xcrun --find metal 2>/dev/null || true)"
if [[ ! -x "$STUDY_METAL" ]]; then
  STUDY_COMPILERS=(/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain*/Metal.xctoolchain/usr/bin/metal(N))
  STUDY_METAL="$STUDY_COMPILERS[1]"
fi
"$STUDY_METAL" -fmodules-cache-path=/tmp/kicklab-metal-cache -c -target air64-apple-macos26.0 \
  kicklab/Environments/StadiumPreview.metal -o "$STUDY_OUT/study.air"
"$STUDY_METAL" "$STUDY_OUT/study.air" -o "$STUDY_OUT/study.metallib"
swiftc -O -module-cache-path /tmp/kicklab-swift-cache \
  kicklab/Environments/ForegroundMaskProcessor.swift \
  kicklab/Environments/DetailedForegroundMaskProcessor.swift \
  kicklab/Environments/PersonMatteRefiner.swift \
  kicklab/Environments/LosslessAlphaCache.swift \
  kicklab/Environments/ForegroundEdgeProcessor.swift \
  kicklab/Environments/BallForegroundMask.swift \
  kicklab/Environments/BallCutoutTracker.swift \
  kicklab/Environments/BallImageLocator.swift \
  kicklab/Environments/SceneCameraRig.swift \
  kicklab/Environments/VisibleFootContact.swift \
  kicklab/Effects/EffectVideoGeometry.swift \
  kicklab/Environments/StadiumPreviewRenderer.swift \
  kicklab/Environments/StadiumSceneCalibration.swift \
  kicklab/Environments/StadiumPreviewPreparer.swift \
  kicklab/Environments/StadiumCameraMotion.swift \
  kicklab/Environments/PreviewEnvironment.swift \
  kicklab/Environments/StadiumSignage.swift \
  kicklab/Environments/ArenaSignage.swift \
  kicklab/Environments/UrbanSignage.swift \
  kicklab/Environments/ForestSignage.swift \
  "${1:-scripts/check-stadium-preview.swift}" -o "$STUDY_OUT/${2:-prepare}"
