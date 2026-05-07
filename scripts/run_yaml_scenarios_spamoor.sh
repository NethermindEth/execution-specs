#!/usr/bin/env bash
# Run selected scenarios from a spammer-export YAML through the upstream
# spamoor binary checked out at .lab/spamoor. Sibling of
# scripts/run_yaml_scenarios.sh, which drives the same YAML through EST's
# pytest harness. Used to compare vanilla spamoor with EST.
#
# Usage:
#   ./scripts/run_yaml_scenarios_spamoor.sh [<config-file>] \
#       [--index N[,N|N-N]...] [--rebuild] [--verbose]
#   CONFIG_FILE=<path> SCENARIO_INDEX=0,2-3 REBUILD=1 VERBOSE=1 \
#       ./scripts/run_yaml_scenarios_spamoor.sh
#
# Default config: tests/benchmark/spammers-export-2026-04-24.yaml
# Default index : 0  (run a single scenario; pass --index to override)
#
# Env overrides:
#   SKIP_KURTOSIS=1, SKIP_KURTOSIS_STOP=1, KURTOSIS_RPC, SIGNER_KEY
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EST_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LAB_DIR="$EST_ROOT/.lab"
SPAMOOR_DIR="$LAB_DIR/spamoor"
SPAMOOR_BIN="$SPAMOOR_DIR/bin/spamoor"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$LAB_DIR/run-yaml-spamoor/$RUN_STAMP"
mkdir -p "$LOG_DIR"

START_TS="$(date +%s)"

fmt_duration() {
  local s="$1"
  printf '%dh%02dm%02ds' "$((s/3600))" "$(((s%3600)/60))" "$((s%60))"
}

DEFAULT_CONFIG="$EST_ROOT/tests/benchmark/spammers-export-2026-04-24.yaml"

CONFIG_FILE="${CONFIG_FILE:-}"
INDEX_SPEC="${SCENARIO_INDEX:-}"
REBUILD="${REBUILD:-0}"
VERBOSE="${VERBOSE:-0}"

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --index|-i)
      INDEX_SPEC="$2"; shift 2 ;;
    --index=*)
      INDEX_SPEC="${1#*=}"; shift ;;
    --rebuild)
      REBUILD=1; shift ;;
    --verbose|-v)
      VERBOSE=1; shift ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

if [ -z "$CONFIG_FILE" ] && [ "${#POSITIONAL[@]}" -gt 0 ]; then
  CONFIG_FILE="${POSITIONAL[0]}"
fi
if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE="$DEFAULT_CONFIG"
fi
if [ ! -f "$CONFIG_FILE" ]; then
  echo "error: config file not found: $CONFIG_FILE" >&2
  exit 2
fi
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

# Default to running just the first scenario when no index is specified —
# the export YAML has dozens of multi-hour bloat entries; "execute at
# least one" is the safer default.
if [ -z "$INDEX_SPEC" ]; then
  INDEX_SPEC="0"
fi

yaml_entry_count() {
  CONFIG_FILE="$CONFIG_FILE" "$EST_ROOT/.venv/bin/python" -c '
import os, sys, yaml
with open(os.environ["CONFIG_FILE"]) as f:
    data = yaml.safe_load(f) or []
if not isinstance(data, list):
    sys.exit("top-level YAML is not a list")
print(len(data))
'
}

expand_indices() {
  local spec="$1"
  local IFS=','
  read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      echo "$part"
    else
      echo "error: invalid index token '$part' in '$spec'" >&2
      exit 2
    fi
  done
}

mapfile -t INDICES < <(expand_indices "$INDEX_SPEC")
if [ "${#INDICES[@]}" -eq 0 ]; then
  echo "error: no indices selected" >&2
  exit 2
fi

# Sanity-bound the indices against YAML length.
N_ENTRIES="$(yaml_entry_count)"
for idx in "${INDICES[@]}"; do
  if [ "$idx" -ge "$N_ENTRIES" ]; then
    echo "error: index $idx out of range (yaml has $N_ENTRIES entries)" >&2
    exit 2
  fi
done
INDEX_CSV="$(IFS=,; echo "${INDICES[*]}")"

# Spamoor pre-validates every entry in the YAML on `run`, including ones not
# selected via --spammers. The export YAML can contain scenarios this build
# of spamoor doesn't know about (e.g. custom-ported variants), which would
# fatally fail the run before our chosen indices ever execute. Sidestep that
# by writing a filtered YAML containing only the requested entries, then run
# spamoor with -s 0,...,N-1 against the filtered file.
FILTERED_CONFIG="$LOG_DIR/config-filtered.yaml"
CONFIG_FILE="$CONFIG_FILE" INDEX_CSV="$INDEX_CSV" OUT="$FILTERED_CONFIG" \
  "$EST_ROOT/.venv/bin/python" -c '
import os, re
src = os.environ["CONFIG_FILE"]
out = os.environ["OUT"]
indices = [int(x) for x in os.environ["INDEX_CSV"].split(",")]
with open(src) as f:
    text = f.read()
# Each scenario is a top-level list entry that begins with "- " at column 0.
# Slice the file by these entry boundaries so we preserve the original
# string formatting verbatim — round-tripping through PyYAML coerces
# unquoted hex values like contract_address into integers.
starts = [m.start() for m in re.finditer(r"(?m)^- ", text)]
ends = starts[1:] + [len(text)]
entries = [text[s:e] for s, e in zip(starts, ends)]
selected = [entries[i] for i in indices]
with open(out, "w") as f:
    f.write("".join(selected))
' || { echo "error: failed to filter config" >&2; exit 1; }
FILTERED_RANGE=()
for i in $(seq 0 $(( ${#INDICES[@]} - 1 ))); do FILTERED_RANGE+=("$i"); done
FILTERED_INDEX_CSV="$(IFS=,; echo "${FILTERED_RANGE[*]}")"

# --- Build spamoor on demand ----------------------------------------------
if [ ! -x "$SPAMOOR_BIN" ] || [ "$REBUILD" = "1" ]; then
  echo ">>> building spamoor in $SPAMOOR_DIR"
  (cd "$SPAMOOR_DIR" && make build) || {
    echo "error: spamoor build failed" >&2; exit 1;
  }
fi
if [ ! -x "$SPAMOOR_BIN" ]; then
  echo "error: spamoor binary still missing at $SPAMOOR_BIN" >&2
  exit 1
fi

# --- Kurtosis lifecycle ---------------------------------------------------
KURTOSIS_RPC="${KURTOSIS_RPC:-http://127.0.0.1:8648}"
SIGNER_KEY="${SIGNER_KEY:-0xbcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31}"

cleanup() {
  if [ "${SKIP_KURTOSIS_STOP:-0}" != "1" ] && [ "${KURTOSIS_STARTED:-0}" = "1" ]; then
    echo ">>> stopping kurtosis enclave"
    "$EST_ROOT/scripts/kurtosis/run_kurtosis_local.sh" stop || \
      echo "warn: kurtosis stop returned non-zero"
  fi
}
trap cleanup EXIT INT TERM

wait_for_rpc() {
  local url="$1" label="$2" tries="${3:-60}"
  for i in $(seq 1 "$tries"); do
    if curl -fsS -X POST -H 'content-type: application/json' \
         --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
         "$url" >/dev/null 2>&1; then
      echo ">>> $label RPC ready at $url"
      return 0
    fi
    sleep 2
  done
  echo "error: $label RPC at $url did not become ready in $((tries * 2))s"
  return 1
}

KURTOSIS_STARTED=0
if [ "${SKIP_KURTOSIS:-0}" != "1" ]; then
  echo ">>> ensuring kurtosis devnet is up"
  "$EST_ROOT/scripts/kurtosis/run_kurtosis_local.sh" start || {
    echo "error: failed to start kurtosis"; exit 1;
  }
  KURTOSIS_STARTED=1
fi
wait_for_rpc "$KURTOSIS_RPC" "kurtosis-EL"

# --- Invoke spamoor -------------------------------------------------------
RUN_LOG="$LOG_DIR/run.log"
echo ">>> spamoor:  $SPAMOOR_BIN"
echo ">>> config:   $CONFIG_FILE"
echo ">>> filtered: $FILTERED_CONFIG"
echo ">>> indices:  $INDEX_CSV (from source YAML)"
echo ">>> rpc:      $KURTOSIS_RPC"
echo ">>> log:      $RUN_LOG"
echo

VERBOSE_ARG=()
if [ "$VERBOSE" = "1" ]; then
  VERBOSE_ARG=(--verbose)
fi

set +e
"$SPAMOOR_BIN" run "$FILTERED_CONFIG" \
  --rpchost "$KURTOSIS_RPC" \
  --privkey "$SIGNER_KEY" \
  --spammers "$FILTERED_INDEX_CSV" \
  "${VERBOSE_ARG[@]}" 2>&1 | tee "$RUN_LOG"
RC="${PIPESTATUS[0]}"
set -e

END_TS="$(date +%s)"
ELAPSED="$((END_TS - START_TS))"

echo
echo "=============================================================="
echo ">>> summary"
echo "=============================================================="
echo "  config:      $CONFIG_FILE"
echo "  indices:     $INDEX_CSV (${#INDICES[@]} scenario(s))"
echo "  rpc:         $KURTOSIS_RPC"
echo "  log:         $RUN_LOG"
echo "  exit code:   $RC ($([ "$RC" -eq 0 ] && echo PASS || echo FAIL))"
echo "  elapsed:     $(fmt_duration "$ELAPSED") (${ELAPSED}s)"

# Per-scenario tx-confirmed totals from spamoor's own block log lines.
if [ -s "$RUN_LOG" ]; then
  TOTAL_BLOCKS="$(grep -cE 'processed block [0-9]+:' "$RUN_LOG" || true)"
  TOTAL_TX="$(grep -oE '[0-9]+ tx confirmed' "$RUN_LOG" \
    | awk '{s+=$1} END{print s+0}')"
  echo "  blocks seen: $TOTAL_BLOCKS"
  echo "  tx confirmed: $TOTAL_TX"
fi

exit "$RC"
