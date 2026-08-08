#!/usr/bin/env bash
# scripts/run-pc.sh [<target>] [args...] — run a built target.
#   ./scripts/run-pc.sh                        windowed
#   ./scripts/run-pc.sh _demo --headless-hash 600
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TARGET="${1:-_demo}"; shift || true
BIN="out/$TARGET/build/recompsx"
[ -x "$BIN" ] || { echo "$BIN not built — run scripts/build-pc.sh $TARGET"; exit 1; }
exec "$BIN" "$@"
