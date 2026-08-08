#!/usr/bin/env bash
# scripts/recompsx.sh — run the recompiler tool.
#
#   ./scripts/recompsx.sh info <file.exe>
#   ./scripts/recompsx.sh dis <file.exe> --at 0x8002e7b0 --count 24
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
exec haxe build/tool.hxml --run recomp.Main "$@"
