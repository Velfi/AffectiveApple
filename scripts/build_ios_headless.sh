#!/bin/sh
set -eu

# CoreSimulator is required by Xcode's asset catalog tool even for generic
# iphoneos builds. This headless build skips asset catalogs so restricted
# environments can still validate Swift compilation and linking.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.derivedData}"
CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="${SCHEME:-Affective}"

cd "${ROOT_DIR}"

xcodebuild \
    -project Affective.xcodeproj \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    EXCLUDED_SOURCE_FILE_NAMES="Assets.xcassets" \
    build
