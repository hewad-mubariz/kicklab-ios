#!/bin/bash
set -euo pipefail
PROBE_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$PROBE_ROOT"
PROBE_BUILD=artifacts/ball-gpu-probe/build
mkdir -p "$PROBE_BUILD"
# Change only an ignored copy. Disable the tiny pose cache in both arms: a moving
# ball normally has a new pose; repeated benchmark rounds must not become cache hits.
python3 - <<'PY'
from pathlib import Path
p=Path('kicklab/Effects/BallSkinSphereRenderer.swift')
s=p.read_text()
needle='        guard let texture = materials.texture(for: skin) else { return nil }\n'
assert s.count(needle)==1
s=s.replace('if cached, let image', 'if false, let image').replace('if cached {', 'if false {')
s=s.replace(needle,needle+'''        if GPUProbe.enabled {
            return GPUProbe.renderer.image(skin: skin, time: time, size: rasterSize,
                orientation: orientation, rgba: texture.rgba, normals: texture.normals)
        }
''')
Path('artifacts/ball-gpu-probe/build/BallSkinSphereRenderer.swift').write_text(s)
PY
xcrun swiftc -O -whole-module-optimization -D DEBUG -parse-as-library \
    scripts/ball-preparation-benchmark/Support.swift scripts/ball-preparation-benchmark/Frames.swift \
    scripts/ball-pair-audit/ModelSupport.swift scripts/ball-gpu-probe/Main.swift scripts/ball-gpu-probe/GPUSphere.swift \
    kicklab/Detection/BallMask.swift kicklab/Effects/BallPreparationTiming.swift \
    kicklab/Effects/BallSurfaceTimeline.swift kicklab/Effects/BallSurfaceMotion.swift kicklab/Effects/BallReplacementFootprint.swift \
    kicklab/Effects/BallEffectTrack.swift kicklab/Effects/BallReplacementCoverage.swift \
    kicklab/Effects/BallReplacementMotionBlur.swift kicklab/Effects/EffectVideoGeometry.swift \
    kicklab/Effects/BallReplacementBackground.swift kicklab/Effects/BallMaterialRenderer.swift \
    "$PROBE_BUILD/BallSkinSphereRenderer.swift" kicklab/Effects/BallSkin.swift kicklab/Effects/BallCollectionMaterial.swift \
    -o "$PROBE_BUILD/probe"
