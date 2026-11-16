#!/usr/bin/env bash
# Runs the scenarios against the real OP Stack L1 contracts.
# Needs git and Foundry (forge 1.8 or newer).
# Usage: ./run.sh [path to an optimism checkout]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/.optimism}"
# Head of optimism PR #24033 (VisionPolicyV1), which includes PR #24025 (ComplianceModule).
COMMIT=403dce99d2ad2d95ca929f6e77472f8f5a3fb26b
if [ ! -d "$WORK" ]; then
  git clone --filter=blob:none --no-checkout https://github.com/ethereum-optimism/optimism.git "$WORK"
  git -C "$WORK" sparse-checkout set packages/contracts-bedrock
fi
git -C "$WORK" fetch -q origin "$COMMIT"
git -C "$WORK" checkout -q "$COMMIT"
cd "$WORK/packages/contracts-bedrock"
git submodule update --init --depth 1 lib/forge-std lib/solady lib/openzeppelin-contracts \
  lib/openzeppelin-contracts-upgradeable lib/openzeppelin-contracts-v5 lib/solmate \
  lib/safe-contracts lib/lib-keccak lib/kontrol-cheatcodes
mkdir -p test/vision
cp "$HERE"/test/vision/*.sol test/vision/
DEV_FEATURE__BRIDGE_HOOK=true forge test --match-path 'test/vision/*' -vv
