#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TESTS=(
  "AffectiveTests/AffectiveTests/testLiveCameraHardwareCaptureReturnsVisibleImage"
  "AffectiveTests/AffectiveTests/testLiveCameraPullSenseFulfillmentEndToEnd"
  "AffectiveTests/AffectiveTests/testLiveCameraCaptureProducesDetectableFace"
)

ONLY_TESTING=()
for test in "${TESTS[@]}"; do
  ONLY_TESTING+=("-only-testing:$test")
done

echo "Running live camera e2e tests (requires macOS camera permission for the test runner)..."
echo "Tip: if capture fails with black frames, try scripts/camera_capture_matrix.swift --list-devices"

print_latest_xcresult_summary() {
  local latest_result
  latest_result="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Affective-*/Logs/Test/*.xcresult 2>/dev/null | head -1 || true)"
  if [[ -z "$latest_result" ]]; then
    echo "No Affective xcresult bundle found under Xcode DerivedData." >&2
    return
  fi

  echo
  echo "Latest test result: $latest_result" >&2
  echo "Failure summary:" >&2
  xcrun xcresulttool get test-results summary --path "$latest_result" >&2 || {
    echo "Could not read concise xcresult summary. Inspect manually with:" >&2
    echo "xcrun xcresulttool get object --legacy --path \"$latest_result\" --format json" >&2
  }
}

# xcodebuild does not inherit shell exports into the test runner; launchctl does.
launchctl setenv AFFECTIVE_RUN_CAMERA_HARDWARE_E2E 1
trap 'launchctl unsetenv AFFECTIVE_RUN_CAMERA_HARDWARE_E2E' EXIT

set +e
xcodebuild test \
  -scheme Affective \
  -destination 'platform=macOS' \
  "${ONLY_TESTING[@]}"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  print_latest_xcresult_summary
fi
exit "$STATUS"
