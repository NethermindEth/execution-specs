#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EST_ROOT="${EST_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"

# Kurtosis EL (nethermind) RPC. ethereum-package's port_publisher allocates
# host ports sequentially from public_port_start (8645 in network.yaml) in
# the container port declaration order:
#   8645 -> tcp-discovery, 8646 -> engine-rpc, 8647 -> metrics,
#   8648 -> rpc (JSON-RPC), 8649 -> ws
# So the JSON-RPC we want is on 8648. Confirm with:
#   kurtosis enclave inspect local-eth-dev
# Assumes `scripts/kurtosis/run_kurtosis_local.sh start` is already running.
RPC_URL="${RPC_URL:-http://127.0.0.1:8648}"

# Signer defaults to ethereum-package prefunded account #0 (address
# 0x8943545177806ED17B9F23F0a21ee5948eCaa776). Override SIGNER_KEY to use
# another prefunded account from genesis_constants.star.
SIGNER_KEY="${SIGNER_KEY:-0xbcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31}"
COUNT="${COUNT:-5}"
THROUGHPUT="${THROUGHPUT:-1.0}"
AMOUNT="${AMOUNT:-1000000000000000000}"
TIP_FEE="${TIP_FEE:-1000000000}"

TEST_FILE="${TEST_FILE:-tests/benchmark/spamoor/test_eoatx.py}"

cd "$EST_ROOT"

# Derive the signer address from the private key unless caller pinned it.
if [ -z "${SIGNER_ADDR:-}" ]; then
  SIGNER_ADDR="$(.venv/bin/python -c '
import sys
from execution_testing.test_types import EOA
print(str(EOA(key=sys.argv[1])))
' "$SIGNER_KEY")"
fi

if ! curl -fsS -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$RPC_URL" >/dev/null; then
  echo "RPC endpoint $RPC_URL unreachable." >&2
  echo "Start the kurtosis network first:" >&2
  echo "  scripts/kurtosis/run_kurtosis_local.sh start" >&2
  exit 1
fi

# shellcheck disable=SC2086  # EXTRA_PYTEST_ARGS must split on spaces.
exec .venv/bin/python -m pytest "$TEST_FILE" -v -s \
  -p execution_testing.cli.pytest_commands.plugins.spamoor.spamoor \
  --spamoor-endpoint="$RPC_URL" \
  --spamoor-private-key="$SIGNER_KEY" \
  --spamoor-from="$SIGNER_ADDR" \
  --spamoor-count="$COUNT" \
  --spamoor-throughput="$THROUGHPUT" \
  --spamoor-amount="$AMOUNT" \
  --spamoor-tip-fee="$TIP_FEE" \
  ${EXTRA_PYTEST_ARGS:-}
