#!/usr/bin/env bash
# Run every spamoor + testing_build_block scenario test suite end-to-end.
#
# Brings up both verification backends (kurtosis enclave + lab Nethermind),
# discovers all scenarios with matching tests/benchmark/spamoor/test_*.py and
# tests/benchmark/testing_build_block/test_*_committed.py files, runs each
# pair, and prints a summary table at the end.
#
# Usage: ./scripts/run_all_bloat.sh [scenario [scenario ...]]
#   no args           -> every discovered scenario
#   ./... eoatx       -> just the eoatx pair (spamoor + committed)
#   ./... eoatx calltx -> multiple specific scenarios
#
# Env overrides:
#   SKIP_KURTOSIS=1       — assume kurtosis is already up
#   SKIP_NETHERMIND=1     — assume run-nethermind.sh is already up elsewhere
#   SKIP_KURTOSIS_STOP=1  — leave kurtosis enclave running after the run
#   KURTOSIS_RPC          — default http://127.0.0.1:8648
#   LAB_RPC               — default http://127.0.0.1:8545
#   SIGNER_KEY            — spamoor signer private key (default: Foundry
#                           dev key #0, prefunded by ethereum-package)
#   SIGNER_ADDR           — override derived signer address
#   STOP_ON_FAIL=1        — abort on first failing scenario
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EST_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LAB_DIR="$EST_ROOT/.lab"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$LAB_DIR/run-all-bloat/$RUN_STAMP"
mkdir -p "$LOG_DIR" "$LAB_DIR/nethermind-logs"

NM_PID_FILE="$LAB_DIR/.run-all-bloat.nm.pid"
NM_LOG_FILE="$LAB_DIR/nethermind-logs/run-all-bloat-$RUN_STAMP.log"

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
# ethereum-package prefunded account #0 (address
# 0x8943545177806ED17B9F23F0a21ee5948eCaa776). Source:
# ethereum-package/src/prelaunch_data_generator/genesis_constants/
# genesis_constants.star. Override SIGNER_KEY to use a different
# prefunded account from that list.
SIGNER_KEY="${SIGNER_KEY:-0xbcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31}"

if [ "${SKIP_KURTOSIS:-0}" != "1" ]; then
  echo ">>> ensuring kurtosis devnet is up"
  "$EST_ROOT/scripts/kurtosis/run_kurtosis_local.sh" start || {
    echo "error: failed to start kurtosis"; exit 1;
  }
fi
wait_for_rpc "$KURTOSIS_RPC" "kurtosis-EL"

if [ "${SKIP_NETHERMIND:-0}" != "1" ]; then
  echo ">>> launching lab Nethermind in background (log: $NM_LOG_FILE)"
  (
    exec "$EST_ROOT/scripts/testing-build-block/run-nethermind.sh" \
      >"$NM_LOG_FILE" 2>&1
  ) &
  echo $! >"$NM_PID_FILE"
fi
wait_for_rpc "$LAB_RPC" "lab-nethermind" 120

# Derive the spamoor signer address once (the spamoor tests need both
# --spamoor-private-key and --spamoor-from). EST's EOA class derives the
# address from the key. Stored under SPAMOOR_* so they don't collide with
# the committed path's SIGNER_KEY (which targets a different genesis).
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

discover_scenarios() {
  # Print scenarios (underscore form) that have BOTH a spamoor test and a
  # testing_build_block committed test. Output is sorted + unique.
  local sp_dir="$EST_ROOT/tests/benchmark/spamoor"
  local cb_dir="$EST_ROOT/tests/benchmark/testing_build_block"
  comm -12 \
    <(ls "$sp_dir"/test_*.py 2>/dev/null \
       | sed -E 's|.*/test_(.+)\.py$|\1|' | sort -u) \
    <(ls "$cb_dir"/test_*_committed.py 2>/dev/null \
       | sed -E 's|.*/test_(.+)_committed\.py$|\1|' | sort -u)
}

if [ $# -gt 0 ]; then
  SCENARIOS=()
  for s in "$@"; do
    SCENARIOS+=("${s//-/_}")
  done
else
  mapfile -t SCENARIOS < <(discover_scenarios)
fi

if [ "${#SCENARIOS[@]}" -eq 0 ]; then
  echo "error: no scenarios discovered"
  exit 1
fi

echo ">>> scenarios to run (${#SCENARIOS[@]}): ${SCENARIOS[*]}"
echo ">>> logs: $LOG_DIR"
echo

verify_triggered() {
  # Args: <label> <log-path>
  # Returns 0 iff the log has a pytest summary with >=1 passed and no
  # "no tests ran" / collection-0 / collection-error markers.
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
  # Pass iff the summary has no "failed"/"error" counts and shows at
  # least one non-zero passed/skipped count (skipped is allowed for the
  # blob scenario which can't broadcast type-3 via eth_sendRawTransaction).
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
FAILED_SCENARIOS=()

for scenario in "${SCENARIOS[@]}"; do
  echo "=============================================================="
  echo ">>> scenario: $scenario"
  echo "=============================================================="

  sp_log="$LOG_DIR/${scenario}-spamoor.log"
  cb_log="$LOG_DIR/${scenario}-committed.log"
  sp_test="tests/benchmark/spamoor/test_${scenario}.py"
  cb_test="tests/benchmark/testing_build_block/test_${scenario}_committed.py"

  sp_ok=1
  cb_ok=1

  if [ -f "$EST_ROOT/$sp_test" ]; then
    echo ">>> [$scenario] spamoor -> $sp_log"
    (
      cd "$EST_ROOT"
      RPC_URL="$KURTOSIS_RPC" TEST_FILE="$sp_test" \
        SIGNER_KEY="$SPAMOOR_SIGNER_KEY" SIGNER_ADDR="$SPAMOOR_SIGNER_ADDR" \
        "$EST_ROOT/scripts/testing-spamoor/run-bloat.sh"
    ) >"$sp_log" 2>&1
    verify_triggered "spamoor" "$sp_log" && sp_ok=0 || true
  else
    echo "  [spamoor] SKIPPED — $sp_test not found"
  fi

  if [ -f "$EST_ROOT/$cb_test" ]; then
    echo ">>> [$scenario] testing_build_block -> $cb_log"
    (
      cd "$EST_ROOT"
      RPC_URL="$LAB_RPC" \
        "$EST_ROOT/scripts/testing-build-block/run-bloat.sh" "$scenario"
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
    FAILED_SCENARIOS+=("$scenario")
  fi
  printf '%-30s  spamoor=%s committed=%s  %s\n' \
    "$scenario" \
    "$([ $sp_ok -eq 0 ] && echo ok || echo FAIL)" \
    "$([ $cb_ok -eq 0 ] && echo ok || echo FAIL)" \
    "$status" | tee -a "$SUMMARY_FILE"
  echo

  if [ "${STOP_ON_FAIL:-0}" = "1" ] && [ "$status" = "FAIL" ]; then
    echo ">>> STOP_ON_FAIL=1, aborting after first failure"
    break
  fi
done

echo "=============================================================="
echo ">>> summary ($PASS_COUNT passed, $FAIL_COUNT failed)"
echo "=============================================================="
cat "$SUMMARY_FILE"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo
  echo "failed scenarios: ${FAILED_SCENARIOS[*]}"
  echo "full logs: $LOG_DIR"
fi

if [ "${SKIP_KURTOSIS_STOP:-0}" != "1" ]; then
  echo ">>> stopping kurtosis enclave"
  "$EST_ROOT/scripts/kurtosis/run_kurtosis_local.sh" stop || \
    echo "warn: kurtosis stop returned non-zero"
fi

[ "$FAIL_COUNT" -eq 0 ]
