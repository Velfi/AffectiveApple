#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_ROOT="$(cd "$ROOT/../AffectiveCore" && pwd)"
OUTPUT_PATH="$ROOT/reports/brain_quality_live.json"
HTML_PATH="$ROOT/reports/brain_quality_live.html"
MODELS="${AFFECTIVE_E2E_MODELS:-openai:gpt-4.1-nano}"
HOST="live"
OPEN_REPORT=0

usage() {
  cat <<'EOF'
Usage: run_brain_quality_e2e.sh [--output PATH] [--html PATH] [--models SPEC] [--host live|mock] [--open]

Runs the live brain-quality E2E scenarios through AffectiveCore, writes snapshot JSON,
then renders the HTML snapshot report.
EOF
}

abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PWD/$1" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$(abspath "$2")"
      shift 2
      ;;
    --html)
      HTML_PATH="$(abspath "$2")"
      shift 2
      ;;
    --models)
      MODELS="$2"
      shift 2
      ;;
    --host)
      HOST="$2"
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

mkdir -p "$(dirname "$OUTPUT_PATH")" "$(dirname "$HTML_PATH")"

set +e
(
  cd "$CORE_ROOT"
  zig build brain-quality-e2e -- --host "$HOST" --models "$MODELS" --output "$OUTPUT_PATH"
)
RUN_STATUS=$?
set -e

REPORT_STATUS=0
if [[ -f "$OUTPUT_PATH" ]]; then
  set +e
  "$ROOT/scripts/run_e2e_snapshot_report.sh" --snapshot "$OUTPUT_PATH" --output "$HTML_PATH"
  REPORT_STATUS=$?
  set -e
  echo "HTML report: $HTML_PATH"
  if [[ "$OPEN_REPORT" -eq 1 ]]; then
    open "$HTML_PATH"
  fi
else
  echo "Brain quality E2E did not write snapshot JSON: $OUTPUT_PATH" >&2
  REPORT_STATUS=1
fi

if [[ "$RUN_STATUS" -ne 0 ]]; then
  exit "$RUN_STATUS"
fi
exit "$REPORT_STATUS"
