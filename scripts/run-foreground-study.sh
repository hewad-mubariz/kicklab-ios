#!/bin/zsh
set -euo pipefail
STUDY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$STUDY_ROOT"
STUDY_OUT="$STUDY_ROOT/artifacts/foreground-study"
mkdir -p "$STUDY_OUT"
STUDY_METAL="$(xcrun --find metal 2>/dev/null || true)"
if [[ ! -x "$STUDY_METAL" ]]; then
  STUDY_COMPILERS=(/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain*/Metal.xctoolchain/usr/bin/metal(N))
  if (( ${#STUDY_COMPILERS} == 0 )); then
    print -u2 'The Xcode Metal compiler is required.'
    exit 1
  fi
  STUDY_METAL="$STUDY_COMPILERS[1]"
fi
"$STUDY_METAL" -fmodules-cache-path=/tmp/kicklab-metal-cache -c -target air64-apple-macos26.0 \
  kicklab/Environments/StadiumPreview.metal -o "$STUDY_OUT/study.air"
"$STUDY_METAL" "$STUDY_OUT/study.air" -o "$STUDY_OUT/study.metallib"
swiftc -O -module-cache-path /tmp/kicklab-swift-cache \
  kicklab/Environments/ForegroundMaskProcessor.swift kicklab/Environments/BallForegroundMask.swift \
  kicklab/Environments/SceneCameraRig.swift kicklab/Environments/VisibleFootContact.swift kicklab/Effects/EffectVideoGeometry.swift \
  kicklab/Environments/PreviewEnvironment.swift kicklab/Environments/StadiumSignage.swift \
  kicklab/Environments/ArenaSignage.swift kicklab/Environments/UrbanSignage.swift kicklab/Environments/ForestSignage.swift \
  kicklab/Environments/StadiumPreviewRenderer.swift kicklab/Environments/StadiumSceneCalibration.swift scripts/review-foreground.swift -o "$STUDY_OUT/review-foreground"
STUDY_PARK="$(python3 -c 'import json; print(json.load(open("artifacts/export-counter/analysis.json"))["source"])')"
STUDY_INDOOR="$(python3 -c 'import json; print(json.load(open("artifacts/flow-effects/indoor-analysis.json"))["source"])')"
"$STUDY_OUT/review-foreground" "$STUDY_PARK" artifacts/export-counter/analysis.json \
  "$STUDY_OUT/study.metallib" "$STUDY_OUT/park" 0 7
"$STUDY_OUT/review-foreground" "$STUDY_INDOOR" artifacts/flow-effects/indoor-analysis.json \
  "$STUDY_OUT/study.metallib" "$STUDY_OUT/indoor" 9 7
python3 scripts/assemble-foreground-study.py
