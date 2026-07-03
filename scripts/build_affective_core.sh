set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AFFECTIVE_APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AFFECTIVE_CORE_ROOT="${AFFECTIVE_CORE_ROOT:-/Users/zelda/Documents/AffectiveCore}"
ZIG="${ZIG:-zig}"

if [ -z "${DERIVED_FILE_DIR:-}" ]; then
    DERIVED_FILE_DIR="${AFFECTIVE_APP_ROOT}/.derivedData/AffectiveCore-manual"
    echo "note: building outside Xcode; output goes to ${DERIVED_FILE_DIR}" >&2
fi
PLATFORM_NAME="${PLATFORM_NAME:-iphonesimulator}"
ARCHS="${ARCHS:-arm64}"

OUTPUT_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/${PLATFORM_NAME}"
HEADER_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/include"
STAGE_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/stage/${PLATFORM_NAME}"
ZIG_CACHE_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/zig-cache/${PLATFORM_NAME}"
ZIG_GLOBAL_CACHE_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/zig-global-cache"
OUTPUT_LIB="${OUTPUT_ROOT}/libaffective-core-session.a"
OUTPUT_EXE="${OUTPUT_ROOT}/affective-core-session"
SESSION_HEADER="${AFFECTIVE_CORE_ROOT}/include/affective_core_session.h"

if ! command -v "${ZIG}" >/dev/null 2>&1; then
    if [ -x /opt/homebrew/bin/zig ]; then
        ZIG=/opt/homebrew/bin/zig
    elif [ -x /usr/local/bin/zig ]; then
        ZIG=/usr/local/bin/zig
    else
        echo "error: zig was not found. Install Zig or set ZIG to the Zig executable path." >&2
        exit 1
    fi
fi

mkdir -p "${OUTPUT_ROOT}" "${HEADER_ROOT}" "${STAGE_ROOT}" "${ZIG_CACHE_ROOT}" "${ZIG_GLOBAL_CACHE_ROOT}"
if [ ! -f "${SESSION_HEADER}" ]; then
    echo "error: AffectiveCore BSP session header is missing at ${SESSION_HEADER}." >&2
    echo "error: implement/build the affective-core-session target; the embedded callback ABI is no longer supported." >&2
    exit 1
fi
cp "${SESSION_HEADER}" "${HEADER_ROOT}/affective_core_session.h"
if ! grep -q "affective_session_start" "${HEADER_ROOT}/affective_core_session.h"; then
    echo "error: AffectiveCore BSP session header is missing affective_session_start." >&2
    exit 1
fi
if ! grep -q "affective_session_stop" "${HEADER_ROOT}/affective_core_session.h"; then
    echo "error: AffectiveCore BSP session header is missing affective_session_stop." >&2
    exit 1
fi

build_arch() {
    arch="$1"
    zig_extra_args=""
    case "${PLATFORM_NAME}:${arch}" in
        macosx:arm64)
            zig_target="aarch64-macos"
            apple_sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
            zig_extra_args="--search-prefix ${apple_sdk_root}/usr"
            ;;
        macosx:x86_64)
            zig_target="x86_64-macos"
            apple_sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
            zig_extra_args="--search-prefix ${apple_sdk_root}/usr"
            ;;
        iphonesimulator:arm64)
            zig_target="aarch64-ios-simulator"
            apple_sdk_root="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            zig_extra_args="--search-prefix ${apple_sdk_root}/usr"
            ;;
        iphonesimulator:x86_64)
            zig_target="x86_64-ios-simulator"
            apple_sdk_root="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            zig_extra_args="--search-prefix ${apple_sdk_root}/usr"
            ;;
        iphoneos:arm64)
            zig_target="aarch64-ios"
            apple_sdk_root="$(xcrun --sdk iphoneos --show-sdk-path)"
            zig_extra_args="--search-prefix ${apple_sdk_root}/usr"
            ;;
        *)
            echo "Unsupported AffectiveCore core target: ${PLATFORM_NAME}/${arch}" >&2
            exit 1
            ;;
    esac

    prefix="${STAGE_ROOT}/${arch}"
    cache_dir="${ZIG_CACHE_ROOT}/${arch}"
    mkdir -p "${prefix}"
    cd "${AFFECTIVE_CORE_ROOT}"
    "${ZIG}" build session \
        -Dtarget="${zig_target}" \
        -Doptimize=ReleaseSmall \
        ${zig_extra_args} \
        --prefix "${prefix}" \
        --cache-dir "${cache_dir}" \
        --global-cache-dir "${ZIG_GLOBAL_CACHE_ROOT}"

    if [ -f "${prefix}/include/affective_core_session.h" ] && \
        ! cmp -s "${SESSION_HEADER}" "${prefix}/include/affective_core_session.h"; then
        echo "error: staged AffectiveCore BSP session header differs from source header for ${PLATFORM_NAME}/${arch}." >&2
        exit 1
    fi

    normalize_archive "${prefix}/lib/libaffective-core-session.a" "${STAGE_ROOT}/${arch}-normalized.a"
}

normalize_archive() {
    input="$1"
    output="$2"
    object_dir="${output}.objects"
    rm -rf "${object_dir}"
    mkdir -p "${object_dir}"
    (
        cd "${object_dir}"
        xcrun ar -x "${input}"
        chmod u+rw ./*.o
        xcrun libtool -static -o "${output}" ./*.o
    )
}

libs=""
for arch in ${ARCHS}; do
    build_arch "${arch}"
    libs="${libs} ${STAGE_ROOT}/${arch}-normalized.a"
done

if [ "$(echo ${libs} | wc -w | tr -d ' ')" = "1" ]; then
    cp ${libs} "${OUTPUT_LIB}"
else
    xcrun lipo -create ${libs} -output "${OUTPUT_LIB}"
fi

if [ "${PLATFORM_NAME}" = "macosx" ]; then
    executables=""
    for arch in ${ARCHS}; do
        executable="${STAGE_ROOT}/${arch}/bin/affective-core-session"
        if [ ! -x "${executable}" ]; then
            echo "error: staged AffectiveCore BSP session executable is missing at ${executable}." >&2
            exit 1
        fi
        executables="${executables} ${executable}"
    done

    if [ "$(echo ${executables} | wc -w | tr -d ' ')" = "1" ]; then
        cp ${executables} "${OUTPUT_EXE}"
    else
        xcrun lipo -create ${executables} -output "${OUTPUT_EXE}"
    fi
    chmod 755 "${OUTPUT_EXE}"

    if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
        resources_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
        bundled_executable="${resources_dir}/affective-core-session"
        mkdir -p "${resources_dir}"
        cp "${OUTPUT_EXE}" "${bundled_executable}"
        chmod 755 "${bundled_executable}"
        if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
            /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${bundled_executable}"
        fi
    fi
fi
