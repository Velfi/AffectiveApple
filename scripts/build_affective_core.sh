set -eu

AFFECTIVE_CORE_ROOT="${AFFECTIVE_CORE_ROOT:-/Users/zelda/Documents/AffectiveCore}"
ZIG="${ZIG:-zig}"
OUTPUT_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/${PLATFORM_NAME}"
HEADER_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/include"
STAGE_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/stage/${PLATFORM_NAME}"
ZIG_CACHE_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/zig-cache/${PLATFORM_NAME}"
ZIG_GLOBAL_CACHE_ROOT="${DERIVED_FILE_DIR}/AffectiveCore/zig-global-cache"
OUTPUT_LIB="${OUTPUT_ROOT}/libaffective-core-embedded.a"

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
cp "${AFFECTIVE_CORE_ROOT}/include/affective_core_embedded.h" "${HEADER_ROOT}/affective_core_embedded.h"
if ! grep -q "AffectiveCoreEmbeddedHostServices" "${HEADER_ROOT}/affective_core_embedded.h"; then
    echo "error: AffectiveCore header is missing host-services ABI. Rebuild or update ${AFFECTIVE_CORE_ROOT}." >&2
    exit 1
fi
if ! grep -q "const AffectiveCoreEmbeddedHostServices \\*host_services" "${HEADER_ROOT}/affective_core_embedded.h"; then
    echo "error: AffectiveCore create/api_e2e ABI does not match the Swift bridge." >&2
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
    "${ZIG}" build embedded \
        -Dtarget="${zig_target}" \
        -Doptimize=ReleaseSmall \
        ${zig_extra_args} \
        --prefix "${prefix}" \
        --cache-dir "${cache_dir}" \
        --global-cache-dir "${ZIG_GLOBAL_CACHE_ROOT}"

    if [ -f "${prefix}/include/affective_core_embedded.h" ] && \
        ! cmp -s "${AFFECTIVE_CORE_ROOT}/include/affective_core_embedded.h" "${prefix}/include/affective_core_embedded.h"; then
        echo "error: staged AffectiveCore header differs from source header for ${PLATFORM_NAME}/${arch}." >&2
        exit 1
    fi

    normalize_archive "${prefix}/lib/libaffective-core-embedded.a" "${STAGE_ROOT}/${arch}-normalized.a"
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
