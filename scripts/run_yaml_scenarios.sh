#!/usr/bin/env bash
# Run selected scenarios from a spammer-export YAML against both the
# spamoor (kurtosis) and testing_build_block (lab Nethermind) test suites.
#
# Usage:
#   ./scripts/run_yaml_scenarios.sh <config-file> [--index N[,N|N-N]...] \
#       [--max-count N] [--clean] [--skip-assert]
#   CONFIG_FILE=<path> SCENARIO_INDEX=0,2-3 MAX_COUNT=10 CLEAN=1 \
#       SKIP_ASSERT=1 ./scripts/run_yaml_scenarios.sh
#
# --max-count/MAX_COUNT caps the effective per-scenario tx count,
# overriding the YAML ``total_count`` value.
# --clean/CLEAN=1 wipes .lab/nethermind-db before launching Nethermind.
# --skip-assert/SKIP_ASSERT=1 puts the tests in submit-only mode: txs
#   are still built and broadcast, but the "all mined" / "status==0x1"
#   / "commit succeeded" assertions are relaxed. Use for bloat runs.
#
# Without --index (or SCENARIO_INDEX) every entry in the YAML is run in
# file order. Infra is brought up once and reused across scenarios.
#
# Env overrides (same as scripts/run_all_bloat.sh):
#   SKIP_KURTOSIS=1, SKIP_NETHERMIND=1, SKIP_KURTOSIS_STOP=1,
#   KURTOSIS_RPC, LAB_RPC, SIGNER_KEY, SIGNER_ADDR, STOP_ON_FAIL=1
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EST_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LAB_DIR="$EST_ROOT/.lab"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$LAB_DIR/run-yaml/$RUN_STAMP"
mkdir -p "$LOG_DIR" "$LAB_DIR/nethermind-logs"

START_TS="$(date +%s)"

fmt_duration() {
  local s="$1"
  printf '%dh%02dm%02ds' "$((s/3600))" "$(((s%3600)/60))" "$((s%60))"
}

NM_PID_FILE="$LAB_DIR/.run-yaml.nm.pid"
NM_LOG_FILE="$LAB_DIR/nethermind-logs/run-yaml-$RUN_STAMP.log"

CONFIG_FILE="${CONFIG_FILE:-}"
INDEX_SPEC="${SCENARIO_INDEX:-}"
MAX_COUNT="${MAX_COUNT:-}"
CLEAN="${CLEAN:-0}"
SKIP_ASSERT="${SKIP_ASSERT:-0}"
SKIP_COMMITTED="${SKIP_COMMITTED:-0}"

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --index|-i)
      INDEX_SPEC="$2"
      shift 2
      ;;
    --index=*)
      INDEX_SPEC="${1#*=}"
      shift
      ;;
    --max-count)
      MAX_COUNT="$2"
      shift 2
      ;;
    --max-count=*)
      MAX_COUNT="${1#*=}"
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --skip-assert)
      SKIP_ASSERT=1
      shift
      ;;
    --skip-committed)
      SKIP_COMMITTED=1
      shift
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ -z "$CONFIG_FILE" ] && [ "${#POSITIONAL[@]}" -gt 0 ]; then
  CONFIG_FILE="${POSITIONAL[0]}"
fi

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  echo "error: config file not found. Pass as first arg or CONFIG_FILE env." >&2
  echo "usage: $0 <config-file.yaml> [--index N[,N|N-N]...]" >&2
  exit 2
fi

# Resolve CONFIG_FILE to an absolute path; the pytest invocation runs from
# $EST_ROOT and relative user input would otherwise be misinterpreted.
CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"

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

# --- Expand INDEX_SPEC into a list of integer indices ---------------------
expand_indices() {
  local spec="$1"
  if [ -z "$spec" ]; then
    local n
    n="$(yaml_entry_count)"
    seq 0 $((n - 1))
    return
  fi
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

# --- Query scenario type+name for each selected index via Python+yaml -----
read_scenario_field() {
  # $1 = index, $2 = yaml key (e.g. "scenario" / "name")
  CONFIG_FILE="$CONFIG_FILE" IDX="$1" KEY="$2" \
    "$EST_ROOT/.venv/bin/python" -c '
import os, sys, yaml
idx = int(os.environ["IDX"])
key = os.environ["KEY"]
with open(os.environ["CONFIG_FILE"]) as f:
    data = yaml.safe_load(f) or []
if idx < 0 or idx >= len(data):
    sys.exit(f"index {idx} out of range (len={len(data)})")
value = data[idx].get(key, "")
print(value if value is not None else "")
'
}

# --- Infra bring-up (same as run_all_bloat.sh) ----------------------------
cleanup() {
  if [ -f "$NM_PID_FILE" ]; then
    local pid
    pid="$(cat "$NM_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo ">>> stopping background Nethermind (pid=$pid)"
      kill "$pid" || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$NM_PID_FILE"
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

KURTOSIS_RPC="${KURTOSIS_RPC:-http://127.0.0.1:8648}"
LAB_RPC="${LAB_RPC:-http://127.0.0.1:8545}"
SIGNER_KEY="${SIGNER_KEY:-0xbcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31}"

if [ "${SKIP_KURTOSIS:-0}" != "1" ]; then
  echo ">>> ensuring kurtosis devnet is up"
  "$EST_ROOT/scripts/kurtosis/run_kurtosis_local.sh" start || {
    echo "error: failed to start kurtosis"; exit 1;
  }
fi
wait_for_rpc "$KURTOSIS_RPC" "kurtosis-EL"

if [ "$CLEAN" = "1" ]; then
  if [ "${SKIP_NETHERMIND:-0}" = "1" ]; then
    echo ">>> --clean ignored: SKIP_NETHERMIND=1 means an existing Nethermind is still using $LAB_DIR/nethermind-db" >&2
  else
    echo ">>> cleaning lab nethermind DB at $LAB_DIR/nethermind-db"
    rm -rf "$LAB_DIR/nethermind-db"
  fi
fi

if [ "$SKIP_COMMITTED" = "1" ]; then
  echo ">>> SKIP_COMMITTED=1: skipping lab Nethermind launch + RPC wait"
elif [ "${SKIP_NETHERMIND:-0}" != "1" ]; then
  echo ">>> launching lab Nethermind in background (log: $NM_LOG_FILE)"
  (
    exec "$EST_ROOT/scripts/testing-build-block/run-nethermind.sh" \
      >"$NM_LOG_FILE" 2>&1
  ) &
  echo $! >"$NM_PID_FILE"
  wait_for_rpc "$LAB_RPC" "lab-nethermind" 120
else
  wait_for_rpc "$LAB_RPC" "lab-nethermind" 120
fi

SPAMOOR_SIGNER_KEY="$SIGNER_KEY"
if [ -z "${SPAMOOR_SIGNER_ADDR:-${SIGNER_ADDR:-}}" ]; then
  SPAMOOR_SIGNER_ADDR="$(cd "$EST_ROOT" && .venv/bin/python -c '
import sys
from execution_testing.test_types import EOA
print(str(EOA(key=sys.argv[1])))
' "$SPAMOOR_SIGNER_KEY")"
else
  SPAMOOR_SIGNER_ADDR="${SPAMOOR_SIGNER_ADDR:-$SIGNER_ADDR}"
fi
echo ">>> spamoor signer: $SPAMOOR_SIGNER_ADDR"
unset SIGNER_KEY SIGNER_ADDR

# --- Summary verifier (mirrors run_all_bloat.sh:verify_triggered) ---------
verify_triggered() {
  local label="$1" log="$2"
  if [ ! -s "$log" ]; then
    echo "  [$label] MISSING log ($log)"
    return 1
  fi
  if grep -qE '(^| )no tests ran( |$)|collected 0 items|errors during collection' "$log"; then
    echo "  [$label] NOT TRIGGERED (pytest collected no tests)"
    return 1
  fi
  local summary
  summary="$(grep -E '=+ [0-9]+ (passed|failed|error|skipped|xfailed|xpassed)' "$log" | tail -1 || true)"
  if [ -z "$summary" ]; then
    echo "  [$label] UNKNOWN — no pytest summary line found"
    return 1
  fi
  echo "  [$label] $summary"
  if grep -qE '[0-9]+ (failed|error)' <<<"$summary"; then
    return 1
  fi
  if ! grep -qE '[0-9]+ (passed|skipped)' <<<"$summary"; then
    return 1
  fi
  return 0
}

SUMMARY_FILE="$LOG_DIR/SUMMARY.txt"
: >"$SUMMARY_FILE"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_ENTRIES=()

MAX_COUNT_PYTEST_ARG=""
if [ -n "$MAX_COUNT" ]; then
  if ! [[ "$MAX_COUNT" =~ ^[0-9]+$ ]]; then
    echo "error: --max-count must be a positive integer, got '$MAX_COUNT'" >&2
    exit 2
  fi
  MAX_COUNT_PYTEST_ARG=" --spamoor-max-count=$MAX_COUNT"
fi

SKIP_ASSERT_PYTEST_ARG=""
if [ "$SKIP_ASSERT" = "1" ]; then
  SKIP_ASSERT_PYTEST_ARG=" --spamoor-skip-assert"
fi

echo ">>> config:  $CONFIG_FILE"
echo ">>> indices: ${INDICES[*]}"
if [ -n "$MAX_COUNT" ]; then
  echo ">>> max-count cap: $MAX_COUNT"
fi
if [ "$SKIP_ASSERT" = "1" ]; then
  echo ">>> submit-only mode (--skip-assert)"
fi
echo ">>> logs:    $LOG_DIR"
echo

# YAML scenario-name aliases → the test module stem that EST actually
# ships. Keeps runner output readable when spamoor's canonical name and
# EST's test filename diverge (e.g. spamoor's "erctx" = EST's "erc20tx").
declare -A SCENARIO_ALIAS=(
  [erctx]=erc20tx
)

SKIP_COUNT=0
SKIPPED_ENTRIES=()

for idx in "${INDICES[@]}"; do
  scenario="$(read_scenario_field "$idx" scenario || true)"
  name="$(read_scenario_field "$idx" name || true)"
  scenario_py="${scenario//-/_}"
  if [ -n "${SCENARIO_ALIAS[$scenario_py]:-}" ]; then
    scenario_py="${SCENARIO_ALIAS[$scenario_py]}"
  fi

  echo "=============================================================="
  echo ">>> index=$idx scenario=$scenario  name=$name"
  echo "=============================================================="

  sp_log="$LOG_DIR/${idx}-${scenario_py}-spamoor.log"
  cb_log="$LOG_DIR/${idx}-${scenario_py}-committed.log"
  sp_test="tests/benchmark/spamoor/test_${scenario_py}.py"
  cb_test="tests/benchmark/testing_build_block/test_${scenario_py}_committed.py"

  sp_ok=1
  cb_ok=1

  # If neither test module exists, mark the entry as SKIP (unportable)
  # rather than counting it as a failure.
  if [ ! -f "$EST_ROOT/$sp_test" ] && [ ! -f "$EST_ROOT/$cb_test" ]; then
    echo "  no test files for scenario='$scenario_py' — SKIP"
    printf '%-4s %-24s  spamoor=-- committed=--  SKIP  %s\n' \
      "$idx" "$scenario_py" "$name" | tee -a "$SUMMARY_FILE"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_ENTRIES+=("$idx:$scenario_py")
    echo
    continue
  fi

  if [ -f "$EST_ROOT/$sp_test" ]; then
    echo ">>> [$idx] spamoor -> $sp_log"
    (
      cd "$EST_ROOT"
      RPC_URL="$KURTOSIS_RPC" TEST_FILE="$sp_test" \
        SIGNER_KEY="$SPAMOOR_SIGNER_KEY" SIGNER_ADDR="$SPAMOOR_SIGNER_ADDR" \
        EXTRA_PYTEST_ARGS="--spamoor-config-file=$CONFIG_FILE --spamoor-scenario-index=$idx$MAX_COUNT_PYTEST_ARG$SKIP_ASSERT_PYTEST_ARG" \
        "$EST_ROOT/scripts/testing-spamoor/run-bloat.sh"
    ) >"$sp_log" 2>&1
    verify_triggered "spamoor" "$sp_log" && sp_ok=0 || true
  else
    echo "  [spamoor] SKIPPED — $sp_test not found"
  fi

  if [ "$SKIP_COMMITTED" = "1" ]; then
    cb_ok=0
    echo "  [committed] SKIPPED — SKIP_COMMITTED=1"
  elif [ -f "$EST_ROOT/$cb_test" ]; then
    echo ">>> [$idx] testing_build_block -> $cb_log"
    (
      cd "$EST_ROOT"
      RPC_URL="$LAB_RPC" \
        EXTRA_PYTEST_ARGS="--spamoor-config-file=$CONFIG_FILE --spamoor-scenario-index=$idx --bloat-config-file=$CONFIG_FILE --bloat-scenario-index=$idx$MAX_COUNT_PYTEST_ARG$SKIP_ASSERT_PYTEST_ARG" \
        "$EST_ROOT/scripts/testing-build-block/run-bloat.sh" "$scenario_py"
    ) >"$cb_log" 2>&1
    verify_triggered "committed" "$cb_log" && cb_ok=0 || true
  else
    echo "  [committed] SKIPPED — $cb_test not found"
  fi

  if [ "$sp_ok" -eq 0 ] && [ "$cb_ok" -eq 0 ]; then
    status="PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    status="FAIL"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_ENTRIES+=("$idx:$scenario_py")
  fi
  printf '%-4s %-24s  spamoor=%s committed=%s  %s  %s\n' \
    "$idx" "$scenario_py" \
    "$([ $sp_ok -eq 0 ] && echo ok || echo FAIL)" \
    "$([ $cb_ok -eq 0 ] && echo ok || echo FAIL)" \
    "$status" "$name" | tee -a "$SUMMARY_FILE"
  echo

  if [ "${STOP_ON_FAIL:-0}" = "1" ] && [ "$status" = "FAIL" ]; then
    echo ">>> STOP_ON_FAIL=1, aborting after first failure"
    break
  fi
done

END_TS="$(date +%s)"
ELAPSED="$((END_TS - START_TS))"

echo "=============================================================="
echo ">>> summary ($PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped)"
echo ">>> elapsed: $(fmt_duration "$ELAPSED") (${ELAPSED}s)"
echo "=============================================================="
cat "$SUMMARY_FILE"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo
  echo "failed entries: ${FAILED_ENTRIES[*]}"
  echo "full logs: $LOG_DIR"
fi
if [ "$SKIP_COUNT" -gt 0 ]; then
  echo
  echo "skipped entries (no EST test module): ${SKIPPED_ENTRIES[*]}"
fi

if [ "${SKIP_KURTOSIS_STOP:-0}" != "1" ]; then
  echo ">>> stopping kurtosis enclave"
  "$EST_ROOT/scripts/kurtosis/run_kurtosis_local.sh" stop || \
    echo "warn: kurtosis stop returned non-zero"
fi

[ "$FAIL_COUNT" -eq 0 ]
