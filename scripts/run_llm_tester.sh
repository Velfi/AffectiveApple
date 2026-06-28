#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_ROOT="$(cd "$ROOT/../AffectiveCore" && pwd)"
PACKAGE_ROOT="$ROOT/scripts/llm_tester"
MANIFEST_PATH=""
OUTPUT_PATH=""
PROVIDER="random"
OPEN_REPORT=0

usage() {
  cat <<'EOF'
Usage: run_llm_tester.sh [--provider openai|anthropic|google|local|random] [--output PATH] [--open]

Generates an LLM tester manifest from AffectiveCore, runs live host completions, and writes an HTML report.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      PROVIDER="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --manifest)
      MANIFEST_PATH="$2"
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

if [[ -z "$MANIFEST_PATH" ]]; then
  MANIFEST_PATH="$(mktemp -t llm_tester_manifest).json"
  GENERATED_MANIFEST=1
else
  GENERATED_MANIFEST=0
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_PATH="$ROOT/llm_tester_report-$STAMP.html"
fi

cleanup() {
  if [[ "${GENERATED_MANIFEST:-0}" -eq 1 && -f "$MANIFEST_PATH" ]]; then
    rm -f "$MANIFEST_PATH"
  fi
}
trap cleanup EXIT

(
  cd "$CORE_ROOT"
  zig build llm-tester-manifest -- --output "$MANIFEST_PATH"
)

ARGS=(--manifest "$MANIFEST_PATH" --output "$OUTPUT_PATH" --provider "$PROVIDER")
(
  cd "$PACKAGE_ROOT"
  swift run -c release LlmTester "${ARGS[@]}"
)

echo "Report: $OUTPUT_PATH"

if [[ "$OPEN_REPORT" -eq 1 ]]; then
  open "$OUTPUT_PATH"
fi
