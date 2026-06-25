#!/bin/sh
set -eu

show_help() {
    cat <<'EOF'
Usage: scripts/lint_module_size.sh

Checks Swift source module/file size and prints the top offenders.

Environment:
  MODULE_SIZE_MAX_LINES  Maximum allowed lines per Swift file. Default: 1000
  MODULE_SIZE_TOP        Number of offenders to print. Default: 5
  MODULE_SIZE_ROOTS      Space-separated roots to scan. Default: Affective AffectiveTests AffectiveUITests
EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        show_help >&2
        exit 2
        ;;
esac

MAX_LINES="${MODULE_SIZE_MAX_LINES:-1000}"
TOP_COUNT="${MODULE_SIZE_TOP:-5}"
SOURCE_ROOTS="${MODULE_SIZE_ROOTS:-Affective AffectiveTests AffectiveUITests}"

case "${MAX_LINES}" in
    ''|*[!0-9]*)
        echo "error: MODULE_SIZE_MAX_LINES must be a positive integer" >&2
        exit 2
        ;;
esac

case "${TOP_COUNT}" in
    ''|*[!0-9]*)
        echo "error: MODULE_SIZE_TOP must be a positive integer" >&2
        exit 2
        ;;
esac

if [ "${MAX_LINES}" -eq 0 ]; then
    echo "error: MODULE_SIZE_MAX_LINES must be greater than zero" >&2
    exit 2
fi

if [ "${TOP_COUNT}" -eq 0 ]; then
    echo "error: MODULE_SIZE_TOP must be greater than zero" >&2
    exit 2
fi

tmp_file="$(mktemp "${TMPDIR:-/tmp}/affective-module-size.XXXXXX")"
trap 'rm -f "${tmp_file}"' EXIT INT TERM

for root in ${SOURCE_ROOTS}; do
    if [ -d "${root}" ]; then
        find "${root}" \
            -type d \( -name .git -o -name .derivedData -o -name DerivedData -o -name build \) -prune \
            -o -type f -name '*.swift' -print
    fi
done | while IFS= read -r file; do
    lines="$(wc -l < "${file}" | tr -d ' ')"
    printf '%s\t%s\n' "${lines}" "${file}" >> "${tmp_file}"
done

if [ ! -s "${tmp_file}" ]; then
    echo "Module size lint: no Swift files found in: ${SOURCE_ROOTS}"
    exit 0
fi

echo "Module size lint"
echo "Limit: ${MAX_LINES} lines per Swift file"
echo
echo "Top ${TOP_COUNT} largest Swift modules/files:"
sort -rn "${tmp_file}" | head -n "${TOP_COUNT}" | awk -F '\t' -v limit="${MAX_LINES}" '{
    status = ($1 > limit) ? "over limit" : "ok"
    printf "  %5d lines  %-10s  %s\n", $1, status, $2
}'

offender_count="$(awk -F '\t' -v limit="${MAX_LINES}" '$1 > limit { count++ } END { print count + 0 }' "${tmp_file}")"

if [ "${offender_count}" -gt 0 ]; then
    echo
    echo "error: ${offender_count} Swift module/file(s) exceed ${MAX_LINES} lines."
    echo "Set MODULE_SIZE_MAX_LINES to adjust the threshold if needed."
    exit 1
fi

echo
echo "All Swift modules/files are within the size limit."
