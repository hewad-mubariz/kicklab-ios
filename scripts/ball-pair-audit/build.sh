#!/bin/bash
set -euo pipefail
PAIR_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$PAIR_ROOT"
PAIR_BUILD=artifacts/ball-pair-audit-tools
mkdir -p "$PAIR_BUILD"
xcrun swiftc -O -whole-module-optimization -D DEBUG -parse-as-library \
    scripts/ball-preparation-benchmark/Support.swift scripts/ball-preparation-benchmark/Frames.swift \
    scripts/ball-pair-audit/ModelSupport.swift scripts/ball-pair-audit/Main.swift scripts/ball-pair-audit/Geometry.swift \
    kicklab/Detection/BallMask.swift kicklab/Detection/RFInputNormalization.swift kicklab/Detection/RFSegBridge.swift \
    kicklab/Effects/BallPreparationTiming.swift kicklab/Effects/BallSurfaceTimeline.swift \
    kicklab/Effects/BallSurfaceMotion.swift kicklab/Effects/BallReplacementFootprint.swift \
    kicklab/Effects/BallEffectTrack.swift kicklab/Effects/BallReplacementCoverage.swift \
    kicklab/Effects/BallReplacementMotionBlur.swift kicklab/Effects/EffectVideoGeometry.swift \
    kicklab/Effects/BallReplacementBackground.swift kicklab/Effects/BallMaterialRenderer.swift \
    kicklab/Effects/BallSkinSphereRenderer.swift kicklab/Effects/BallSkin.swift kicklab/Effects/BallCollectionMaterial.swift \
    -o "$PAIR_BUILD/audit"
