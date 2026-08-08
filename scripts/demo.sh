#!/usr/bin/env bash
# scripts/demo.sh — generate + build the walking skeleton, then verify determinism.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

echo "==> generating C++"
rm -rf out/_demo
haxe build/pc-demo.hxml

echo "==> building"
./scripts/build-pc.sh _demo

echo "==> determinism: two headless runs must agree"
A="$(./scripts/run-pc.sh _demo --headless-hash 600 | tail -1)"
B="$(./scripts/run-pc.sh _demo --headless-hash 600 | tail -1)"
echo "  run 1: $A"
echo "  run 2: $B"
[ "$A" = "$B" ] || { echo "FAIL: digests differ"; exit 1; }
echo "  digests match"
