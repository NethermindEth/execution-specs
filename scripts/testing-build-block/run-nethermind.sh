#!/usr/bin/env bash
# Launch Nethermind from the lab worktree against lab-genesis.json.
#
# Sync, peer discovery, and networking are disabled — this node is solo and
# its only block source is testing_commitBlockV1 coming from EST.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EST_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
WORKTREE_DIR="${WORKTREE_DIR:-$EST_ROOT/.lab/nethermind-testing-commit}"
RUNNER_DIR="$WORKTREE_DIR/src/Nethermind/Nethermind.Runner"
CHAINSPEC="${CHAINSPEC:-$SCRIPT_DIR/lab-genesis.json}"
JWT_SECRET="${JWT_SECRET:-$SCRIPT_DIR/keystore/jwt-secret}"
DB_PATH="${DB_PATH:-$EST_ROOT/.lab/nethermind-db}"
LOG_PATH="${LOG_PATH:-$EST_ROOT/.lab/nethermind-logs}"

if [ ! -d "$RUNNER_DIR" ]; then
  echo "error: Nethermind worktree not found at $WORKTREE_DIR"
  echo "add one with: git -C <nethermind-repo> worktree add $WORKTREE_DIR <branch>"
  exit 1
fi

for required in "$CHAINSPEC" "$JWT_SECRET"; do
  if [ ! -f "$required" ]; then
    echo "error: missing $required"
    exit 1
  fi
done

mkdir -p "$DB_PATH" "$LOG_PATH"

CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_FLAG="${BUILD_FLAG:-}"

cd "$RUNNER_DIR"

echo "launching Nethermind"
echo "  worktree:  $WORKTREE_DIR"
echo "  head:      $(git -C "$WORKTREE_DIR" rev-parse --short HEAD)"
echo "  chainspec: $CHAINSPEC"
echo "  db:        $DB_PATH"
echo "  rpc:       http://127.0.0.1:8545  (Eth,Net,Web3,TxPool,Testing)"
echo "  engine:    http://127.0.0.1:8551  (Engine, JWT)"
echo

exec dotnet run -c "$CONFIGURATION" $BUILD_FLAG -- \
  --config none \
  --Init.ChainSpecPath "$CHAINSPEC" \
  --Init.BaseDbPath "$DB_PATH" \
  --Init.LogDirectory "$LOG_PATH" \
  --Init.DiscoveryEnabled false \
  --Init.PeerManagerEnabled false \
  --Network.OnlyStaticPeers true \
  --Sync.FastSync false \
  --Sync.SnapSync false \
  --Sync.NetworkingEnabled false \
  --Merge.Enabled true \
  --JsonRpc.Enabled true \
  --JsonRpc.Host 127.0.0.1 \
  --JsonRpc.Port 8545 \
  --JsonRpc.EnabledModules "Eth,Net,Web3,TxPool,Testing" \
  --JsonRpc.EngineHost 127.0.0.1 \
  --JsonRpc.EnginePort 8551 \
  --JsonRpc.EngineEnabledModules "engine,eth,net,web3" \
  --JsonRpc.JwtSecretFile "$JWT_SECRET"
