#!/bin/bash
set -euo pipefail
BALL_BENCH_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$BALL_BENCH_ROOT"
BALL_BENCH_DIR=scripts/ball-preparation-benchmark
BALL_BENCH_BUILD=${BALL_BENCH_BUILD:-artifacts/ball-preparation-20261030/current}
mkdir -p "$BALL_BENCH_BUILD"
BALL_BENCH_FLAGS=(-D DEBUG)
if [[ -n ${BALL_BENCH_BASELINE:-} ]]; then BALL_BENCH_FLAGS+=(-D BENCHMARK_BASELINE); fi
xcrun swiftc -O -whole-module-optimization "${BALL_BENCH_FLAGS[@]}" -parse-as-library \
    "$BALL_BENCH_DIR/Support.swift" "$BALL_BENCH_DIR/Frames.swift" "$BALL_BENCH_DIR/Main.swift" "$BALL_BENCH_DIR/Geometry.swift" \
    kicklab/Detection/BallMask.swift kicklab/Effects/BallPreparationTiming.swift \
    "${BALL_BENCH_TIMELINE:-kicklab/Effects/BallSurfaceTimeline.swift}" \
    "${BALL_BENCH_MOTION:-kicklab/Effects/BallSurfaceMotion.swift}" \
    "${BALL_BENCH_FOOTPRINT:-kicklab/Effects/BallReplacementFootprint.swift}" \
    kicklab/Effects/BallEffectTrack.swift kicklab/Effects/BallReplacementCoverage.swift \
    kicklab/Effects/BallReplacementMotionBlur.swift kicklab/Effects/EffectVideoGeometry.swift \
    -o "$BALL_BENCH_BUILD/benchmark"
"$BALL_BENCH_BUILD/benchmark" "$@"
