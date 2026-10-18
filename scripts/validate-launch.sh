#!/bin/bash
# Usage: scripts/validate-launch.sh backend|release|logic|all
# Logic requires TEST_DESTINATION='platform=iOS Simulator,id=...' (or a device).
# DENO_BIN may point to an existing Deno executable outside PATH.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
lane="${1:-all}"
validation_dir="${VALIDATION_DIR:-/tmp/juggledude-launch-validation}"
mkdir -p "$validation_dir"
case "$lane" in backend|release|logic|all) ;; *) echo "Use backend, release, logic, or all"; exit 2 ;; esac

if [[ "$lane" == backend || "$lane" == all ]]; then
  bash scripts/test-account-backend.sh > "$validation_dir/backend-sql.log" 2>&1
  (cd supabase/functions && "${DENO_BIN:-deno}" test --allow-env --allow-net \
    delete-account/index_test.ts reconcile-account-deletions/index_test.ts) \
    > "$validation_dir/backend-functions.log" 2>&1
  echo "PASS: backend SQL and function checks"
fi

if [[ "$lane" == release || "$lane" == logic || "$lane" == all ]]; then
  if ! python3 scripts/install-rf-model.py --check; then
    echo "INCOMPLETE: install the manifest-pinned shared RF package with scripts/install-rf-model.py SOURCE.mlpackage"
    exit 2
  fi
fi

if [[ "$lane" == release || "$lane" == all ]]; then
  xcodebuild -project kicklab.xcodeproj -scheme JuggleDude -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$validation_dir/release" \
    CODE_SIGNING_ALLOWED=NO build > "$validation_dir/release.log" 2>&1
  echo "PASS: Release build"
fi

if [[ "$lane" == logic || "$lane" == all ]]; then
  : "${TEST_DESTINATION:?Set TEST_DESTINATION to an available simulator or physical device}"
  xcodebuild -project kicklab.xcodeproj -scheme JuggleDude -configuration Debug \
    -destination "$TEST_DESTINATION" -derivedDataPath "$validation_dir/tests" \
    -parallel-testing-enabled NO \
    -only-testing:kicklabTests/LaunchReliabilityTests \
    -only-testing:kicklabTests/PlayerStoreTests \
    -only-testing:kicklabTests/AccountStoreTests \
    -only-testing:kicklabTests/SessionHistoryTests \
    -only-testing:kicklabTests/ScenePreparationTests \
    -only-testing:kicklabTests/VideoBackgroundWorkTests \
    -only-testing:kicklabTests/VideoAnalysisWorkloadTests \
    -only-testing:kicklabTests/ShotCameraExportTests \
    -only-testing:kicklabTests/ShotBackgroundExportTests \
    test > "$validation_dir/logic.log" 2>&1
  if rg -i 'Test Case .* skipped|Test .* skipped|[1-9][0-9]* tests? skipped' "$validation_dir/logic.log"; then
    echo "INCOMPLETE: required checks skipped; inspect $validation_dir/logic.log"
    exit 3
  fi
  echo "PASS: selected reliability and media checks"
fi
echo "Logs: $validation_dir"
echo "DEVICE GATE STILL REQUIRED: camera, phone lock/background, Photos save/playback, low storage, sign-in, purchase/restore, and account deletion on the release candidate."
