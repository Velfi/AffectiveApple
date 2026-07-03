#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_ROOT="$ROOT/scripts/llm_tester"
SNAPSHOT_PATH=""
BASELINE_PATH=""
OUTPUT_PATH=""
OPEN_REPORT=0

usage() {
  cat <<'EOF'
Usage: run_e2e_snapshot_report.sh --snapshot PATH [--baseline PATH] [--output PATH] [--open]

Renders structured E2E snapshot JSON into a navigable HTML flow report.
When --baseline is supplied, changed steps and artifacts are annotated with expected/actual diffs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot)
      SNAPSHOT_PATH="$2"
      shift 2
      ;;
    --baseline)
      BASELINE_PATH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --open)
      OPEN_REPORT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$SNAPSHOT_PATH" ]]; then
  echo "Missing required --snapshot PATH." >&2
  usage
  exit 2
fi

absolute_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PWD" "$path"
  fi
}

SNAPSHOT_PATH="$(absolute_path "$SNAPSHOT_PATH")"
if [[ -n "$BASELINE_PATH" ]]; then
  BASELINE_PATH="$(absolute_path "$BASELINE_PATH")"
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_PATH="$ROOT/e2e_snapshot_report-$STAMP.html"
else
  OUTPUT_PATH="$(absolute_path "$OUTPUT_PATH")"
fi

ARGS=(--snapshot "$SNAPSHOT_PATH" --output "$OUTPUT_PATH")
if [[ -n "$BASELINE_PATH" ]]; then
  ARGS+=(--baseline "$BASELINE_PATH")
fi
(
  cd "$PACKAGE_ROOT"
  swift run -c release LlmTester "${ARGS[@]}"
)

echo "Report: $OUTPUT_PATH"

if [[ "$OPEN_REPORT" -eq 1 ]]; then
  open "$OUTPUT_PATH"
fi
