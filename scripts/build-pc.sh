#!/usr/bin/env bash
# scripts/build-pc.sh [<target>] — compile a generated C++ tree for the desktop.
# <target> is a directory under out/ (default: _demo, the walking skeleton).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

TARGET="${1:-_demo}"
DIR="out/$TARGET"
[ -d "$DIR/cpp/src" ] || { echo "no generated sources in $DIR/cpp/src — generate first"; exit 1; }

cp build/templates/CMakeLists.txt "$DIR/CMakeLists.txt"
cmake -S "$DIR" -B "$DIR/build" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$DIR/build"
echo "built $DIR/build/recompsx"
