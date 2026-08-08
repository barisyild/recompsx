#!/usr/bin/env bash
# scripts/build-pc.sh [<target>] [--null] — compile a generated C++ tree for the desktop.
#   <target>  a directory under out/ (default: _demo, the walking skeleton)
#   --null    build against the null backend: no window, no audio, no SDL2 dependency.
#             This is the reproducible build, not a lesser one — nothing from the host reaches
#             emulated state, so a headless digest means the same thing everywhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

TARGET="_demo"
BACKEND="pc"
for a in "$@"; do
  case "$a" in
    --null) BACKEND="null" ;;
    *)      TARGET="$a" ;;
  esac
done
DIR="out/$TARGET"
[ -d "$DIR/cpp/src" ] || { echo "no generated sources in $DIR/cpp/src — generate first"; exit 1; }

cp build/templates/CMakeLists.txt "$DIR/CMakeLists.txt"
cmake -S "$DIR" -B "$DIR/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DRECOMPSX_BACKEND="$BACKEND" >/dev/null
cmake --build "$DIR/build"
echo "built $DIR/build/recompsx"
