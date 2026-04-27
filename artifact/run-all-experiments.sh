#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

default_image() {
  printf '%s\n' ghcr.io/symbolicsafety/lf-mc:v1.2
}

IMAGE=${IMAGE:-$(default_image)}
RUNS=${RUNS:-1}
WARMUP=${WARMUP:-0}
TESTS_CSV="$SCRIPT_DIR/tests.csv"
LOG_DIR="$SCRIPT_DIR/logs"
HYPERFINE_JSON="$SCRIPT_DIR/hyperfine-report.json"
RESULTS_CSV="$SCRIPT_DIR/results.csv"
OVERWRITE=0

case "${1:-}" in
-f | --force | --overwrite)
  OVERWRITE=1
  shift
  ;;
-h | --help)
  echo "Usage: $0 [--overwrite]"
  echo
  echo "Environment overrides:"
  echo "  IMAGE=ghcr.io/symbolicsafety/lf-mc:v1.2"
  echo "  WARMUP=0"
  echo "  RUNS=1"
  exit 0
  ;;
esac

if [ "$#" -gt 0 ]; then
  echo "Error: unknown argument: $1" >&2
  echo "Usage: $0 [--overwrite]" >&2
  exit 1
fi

confirm_overwrite() {
  target=$1
  if [ -e "$target" ] && [ "$OVERWRITE" != 1 ]; then
    printf '%s already exists. Overwrite? [y/N] ' "$target" >&2
    read -r ans
    case "$ans" in
    y | Y | yes | YES) ;;
    *)
      echo "Aborted." >&2
      exit 1
      ;;
    esac
  fi
}

if [ ! -f "$TESTS_CSV" ]; then
  echo "Error: missing $TESTS_CSV" >&2
  exit 1
fi

confirm_overwrite "$HYPERFINE_JSON"
confirm_overwrite "$RESULTS_CSV"

if [ -d "$LOG_DIR" ] && [ -n "$(ls -A "$LOG_DIR" 2>/dev/null || true)" ]; then
  if [ "$OVERWRITE" = 1 ]; then
    rm -f "$LOG_DIR"/*
  else
    printf '%s is not empty. Overwrite its contents? [y/N] ' "$LOG_DIR" >&2
    read -r ans
    case "$ans" in
    y | Y | yes | YES) rm -f "$LOG_DIR"/* ;;
    *)
      echo "Aborted." >&2
      exit 1
      ;;
    esac
  fi
fi

mkdir -p "$LOG_DIR"

docker run --rm -i \
  -e RUNS="$RUNS" \
  -e WARMUP="$WARMUP" \
  -e SCRIPT_DIR="$SCRIPT_DIR" \
  -v "$SCRIPT_DIR:/artifact" \
  "$IMAGE" \
  sh -s <<'SCRIPT'
set -eu

TESTS_CSV=/artifact/tests.csv
LOG_DIR=/artifact/logs
HYPERFINE_JSON=/artifact/hyperfine-report.json
RESULTS_CSV=/artifact/results.csv

RUNS=${RUNS:-1}
WARMUP=${WARMUP:-0}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

sanitize_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

format_time() {
  awk -v value="$1" 'BEGIN { if (value < 0.0005) print "<0.001"; else printf "%.3f", value }'
}

maude_time() {
  logfile=$1
  ms=$(
    grep 'rewrites:' "$logfile" 2>/dev/null \
      | tail -n 1 \
      | sed -nE 's/.*\(([0-9]+)ms real\).*/\1/p'
  )

  if [ -z "${ms:-}" ]; then
    printf '0'
  else
    awk "BEGIN { printf \"%.6f\", $ms / 1000 }"
  fi
}

csv_quote() {
  printf '%s' "$1" | sed 's/"/""/g; s/.*/"&"/'
}

require_cmd awk
require_cmd grep
require_cmd hyperfine
require_cmd jq
require_cmd lfc
require_cmd sed

MAX_LEN=0
while IFS=, read -r name testcase rest; do
  name=$(trim "${name:-}")
  testcase=$(trim "${testcase:-}")

  [ -n "$name" ] || continue
  case "$name" in
  \#* | pretty_name | name | pretty) continue ;;
  esac
  [ -n "$testcase" ] || continue

  len=$(printf '%s' "$name" | awk '{print length}')
  if [ "$len" -gt "$MAX_LEN" ]; then
    MAX_LEN=$len
  fi
done <"$TESTS_CSV"

if [ "$MAX_LEN" -eq 0 ]; then
  echo "Error: no test cases found in $TESTS_CSV" >&2
  exit 1
fi

printf '%s\n' "Program,LF-mc Gen.,LF-mc Solving,LF-mc Total" >"$RESULTS_CSV"

while IFS=, read -r name testcase rest; do
  name=$(trim "${name:-}")
  testcase=$(trim "${testcase:-}")

  [ -n "$name" ] || continue
  case "$name" in
  \#* | pretty_name | name | pretty) continue ;;
  esac
  [ -n "$testcase" ] || continue

  stem=$(sanitize_name "$name")
  log="$LOG_DIR/$stem.log"
  test_json="$LOG_DIR/$stem.hyperfine.json"

  echo "Running $name..." >&2
  hyperfine \
    --runs "$RUNS" \
    --warmup "$WARMUP" \
    --export-json "$test_json" \
    "lfc '$testcase' > '$log' 2>&1"

  total=$(jq -r '.results[0].mean' "$test_json")
  solving=$(maude_time "$log")
  gen=$(awk -v total="$total" -v solving="$solving" 'BEGIN { value = total - solving; if (value < 0) value = 0; printf "%.6f", value }')

  gen_fmt=$(format_time "$gen")
  solving_fmt=$(format_time "$solving")
  total_fmt=$(format_time "$total")

  printf '%s,%s,%s,%s\n' "$(csv_quote "$name")" "$gen_fmt" "$solving_fmt" "$total_fmt" >>"$RESULTS_CSV"
done <"$TESTS_CSV"

jq -s '{results: map(.results[0])}' "$LOG_DIR"/*.hyperfine.json >"$HYPERFINE_JSON"

echo
printf "%-${MAX_LEN}s   %-12s   %-15s   %-12s\n" "Program" "LF-mc Gen." "LF-mc Solving" "LF-mc Total"
printf "%-${MAX_LEN}s   %-12s   %-15s   %-12s\n" "$(printf "%${MAX_LEN}s" "" | tr " " "-")" "------------" "---------------" "------------"
awk -F, -v max="$MAX_LEN" '
  NR == 1 { next }
  {
    name = $1
    gsub(/^"|"$/, "", name)
    gsub(/""/, "\"", name)
    printf "%-*s   %-12s   %-15s   %-12s\n", max, name, $2, $3, $4
  }
' "$RESULTS_CSV"
SCRIPT

echo "Done." >&2
echo "  Hyperfine report:  $SCRIPT_DIR/hyperfine-report.json" >&2
echo "  CSV summary:       $SCRIPT_DIR/results.csv" >&2
echo "  Logs directory:    $SCRIPT_DIR/logs" >&2
