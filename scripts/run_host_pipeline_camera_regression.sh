#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UNIT_TESTS=(
  "AffectiveTests/AffectiveTests/testAutonomyTickCameraPullSenseDoesNotFalseDeadlock"
  "AffectiveTests/AffectiveTests/testAwaitingHostSenseWithoutEventEnqueuesPullSenseRecovery"
  "AffectiveTests/AffectiveTests/testHostPipelineHealthRecoversAwaitingCameraBeforeDeadlockOverlay"
  "AffectiveTests/AffectiveTests/testCanRunAutonomyTickAllowedWhilePullSenseFulfillmentInFlight"
  "AffectiveTests/AffectiveTests/testPullSenseFulfillmentDoesNotBlockHostPipeline"
  "AffectiveTests/AffectiveTests/testDuplicateCameraPullSenseScheduleReturnsBusyStatus"
  "AffectiveTests/AffectiveTests/testDuplicateCameraPullSenseScheduleSameRequestIDIsIdempotent"
  "AffectiveTests/AffectiveTests/testSuccessfulCameraObservationClearsAwaitingHostSenseDespiteStaleMetadata"
  "AffectiveTests/AffectiveTests/testPullSenseTimeoutUsesDefaultWhenEventOmitsTimeoutMS"
  "AffectiveTests/AffectiveTests/testHostPipelineHealthDetectsCoreAwaitingSenseWithoutHostWork"
  "AffectiveTests/AffectiveTests/testHostPipelineHealthIgnoresAwaitingSenseWhileHostIsCapturing"
  "AffectiveTests/AffectiveTests/testHostPipelineHealthIgnoresAnonymousPullSenseCounterWithoutHostWork"
  "AffectiveTests/AffectiveTests/testHostPipelineHealthDetectsConcretePullSenseTimeout"
)

ONLY_TESTING=()
for test in "${UNIT_TESTS[@]}"; do
  ONLY_TESTING+=("-only-testing:$test")
done

echo "Running host pipeline / camera deadlock regression tests..."
xcodebuild test \
  -scheme Affective \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.derivedData-codex" \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY_TESTING[@]}"

if [[ "${AFFECTIVE_RUN_CAMERA_HARDWARE_E2E:-}" == "1" ]]; then
  echo
  echo "Running live camera e2e (AFFECTIVE_RUN_CAMERA_HARDWARE_E2E=1)..."
  launchctl setenv AFFECTIVE_RUN_CAMERA_HARDWARE_E2E 1
  trap 'launchctl unsetenv AFFECTIVE_RUN_CAMERA_HARDWARE_E2E' EXIT
  xcodebuild test \
    -scheme Affective \
    -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/.derivedData-codex" \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:AffectiveTests/AffectiveTests/testLiveCameraPullSenseFulfillmentEndToEnd
fi
