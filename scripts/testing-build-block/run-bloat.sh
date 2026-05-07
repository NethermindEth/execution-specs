#!/usr/bin/env bash
# Drive a spamoor scenario through testing_commitBlockV1 against the lab node.
#
# Usage: ./scripts/lab/run-bloat.sh [scenario]
#   scenario: any scenario with a matching
#     tests/benchmark/testing_build_block/test_<scenario>_committed.py
#   built-in scenarios: eoatx (default) | calltx | factorydeploytx
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EST_ROOT="${EST_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
JWT_SECRET="${JWT_SECRET:-$SCRIPT_DIR/keystore/jwt-secret}"

SCENARIO="${1:-eoatx}"
if [[ ! "$SCENARIO" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "error: scenario name must match [A-Za-z0-9_-]+, got '$SCENARIO'"
  exit 1
fi

# Anvil/Hardhat account #0 — matches the 0xf39F... pre-funded alloc in lab-genesis.json.
SIGNER_KEY="${SIGNER_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
CHAIN_ID="${CHAIN_ID:-13337}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ENGINE_URL="${ENGINE_URL:-http://127.0.0.1:8551}"
COMMIT_MODE="${COMMIT_MODE:-commit}"
COUNT="${COUNT:-5}"

if [ ! -d "$EST_ROOT/.venv" ]; then
  echo "error: EST venv not found at $EST_ROOT/.venv"
  echo "set EST_ROOT or run: cd $EST_ROOT && uv sync"
  exit 1
fi

echo "sanity check: RPC reachable?"
if ! curl -sf -X POST "$RPC_URL" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null; then
  echo "error: RPC $RPC_URL is not responding. Is run-nethermind.sh running?"
  exit 1
fi

# Python module filenames use underscores. Accept kebab-case scenario names.
SCENARIO_PY="${SCENARIO//-/_}"
TEST_FILE="tests/benchmark/testing_build_block/test_${SCENARIO_PY}_committed.py"

cd "$EST_ROOT"

echo
echo "driving scenario: $SCENARIO (count=$COUNT, mode=$COMMIT_MODE)"
echo "  rpc:    $RPC_URL"
echo "  engine: $ENGINE_URL"
echo "  chain:  $CHAIN_ID"
echo

# shellcheck disable=SC2086  # EXTRA_PYTEST_ARGS must split on spaces.
exec .venv/bin/python -m pytest "$TEST_FILE" -v -s \
  -p execution_testing.cli.pytest_commands.plugins.testing_build_block.testing_build_block \
  -p execution_testing.cli.pytest_commands.plugins.spamoor.spamoor \
  --bloat-rpc-url="$RPC_URL" \
  --bloat-engine-url="$ENGINE_URL" \
  --bloat-jwt-secret-file="$JWT_SECRET" \
  --bloat-signer-key="$SIGNER_KEY" \
  --bloat-chain-id="$CHAIN_ID" \
  --bloat-commit-mode="$COMMIT_MODE" \
  --spamoor-count="$COUNT" \
  ${EXTRA_PYTEST_ARGS:-}
