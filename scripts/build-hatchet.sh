#!/usr/bin/env bash
# scripts/build-hatchet.sh — the generated game through Hatchet (Haxe -> C++98), null backend.
#
#   HATCHET=/path/to/hatchet ./scripts/build-hatchet.sh [--transpile-only]
#
# Hatchet is the Rust transpiler at github.com/barisyild/hatchet (branch `recompsx`), a
# candidate replacement for reflaxe.CPP under evaluation; see PROGRESS.md. It reads `.hx` files
# itself and requires one project root, so the four source trees a game build uses are staged
# into one: the runtime, the Hatchet shim (`src/shims/hatchet`), the generated program
# (`out/gen`, from `./scripts/recompsx.sh gen games/<id>/game.json`) and the launcher.
#
# The C++ is compiled with the flags the reflaxe.CPP build uses (`-fwrapv`,
# `-fno-strict-aliasing`), against the null backend, into out/_hatchet/recompsx. Run it like
# the other builds: out/_hatchet/recompsx <exe> <disc> --headless-hash N.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HATCHET="${HATCHET:-hatchet}"
OUT="out/_hatchet"
STAGE="$OUT/src"
CPP="$OUT/cpp"
OBJ="$OUT/obj"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"

[ -f out/gen/FnTable.hx ] || { echo "no generated program in out/gen — run recompsx.sh gen first"; exit 1; }

rm -rf "$STAGE" "$CPP" "$OBJ"
mkdir -p "$STAGE" "$CPP" "$OBJ"
cp -R src/runtime/. "$STAGE/"
rm -f "$STAGE/Main.hx"                       # the demo skeleton's entry point, not the game's
# Haxe's dead-code elimination drops the cooperative scheduler from a synchronous build; Hatchet
# transpiles whatever it is given, and `Cooperative` calls `Runtime.settle`, which only a
# `recompsx_cooperative` build defines. Every other reference to it is inside that `#if`.
rm -f "$STAGE/core/Cooperative.hx"
mkdir -p "$STAGE/shim"
cp src/shims/hatchet/shim/*.hx "$STAGE/shim/"
cp out/gen/*.hx "$STAGE/"
cp tests/spike/GenMain.hx "$STAGE/"

echo "== hatchet"
time "$HATCHET" --src "$STAGE" --out "$CPP" --force
[ "${1:-}" = "--transpile-only" ] && exit 0

echo "== c++ ($JOBS jobs)"
# OPT: -O3 matches the reflaxe.CPP build's CMake Release. LTO=1 adds link-time optimisation,
# which is what inlines one module's small functions into another's callers: reflaxe.CPP gets
# that from the Haxe compiler's own `inline`, which Hatchet leaves to the C++ compiler.
OPT="${OPT:--O3}"
[ "${LTO:-0}" = "1" ] && OPT="$OPT -flto"
CXXFLAGS="-std=gnu++98 $OPT -fwrapv -fno-strict-aliasing -w -I$CPP -Isrc/shims/hatchet/native -Isrc/shims/cxx/native -Isrc/backend/api"
# A generated Makefile: one object per source, in parallel, and only what changed recompiles.
{
  echo "CXXFLAGS := $CXXFLAGS"
  echo "OBJS :="
  find "$CPP" -name '*.cpp' | sort | while read -r src; do
    obj="$OBJ/$(echo "${src#$CPP/}" | tr / _ | sed 's/\.cpp$/.o/')"
    echo "OBJS += $obj"
    printf '%s: %s\n\t@c++ $(CXXFLAGS) -c %s -o %s\n' "$obj" "$src" "$src" "$obj"
  done
  echo "$OBJ/backend_null.o: src/backend/null/backend_null.c"
  printf '\t@cc -O2 -Isrc/backend/api -c $< -o $@\n'
  echo "$OBJ/recompsx_arena.o: src/shims/cxx/native/recompsx_arena.c"
  printf '\t@cc -O2 -Isrc/shims/cxx/native -c $< -o $@\n'
  # The same entry point as the reflaxe.CPP build: argv to the backend, then the launcher.
  echo "$OBJ/main.o: src/backend/pc/main_pc.cpp"
  printf "\t@c++ \$(CXXFLAGS) -DRECOMPSX_MAIN_HEADER='\"GenMain.h\"' -DRECOMPSX_MAIN_CLASS=GenMain -c \$< -o \$@\n"
  echo "$OUT/recompsx: \$(OBJS) $OBJ/backend_null.o $OBJ/recompsx_arena.o $OBJ/main.o"
  printf '\t@c++ %s -o $@ $^\n' "$OPT"
} > "$OUT/Makefile"
make -f "$OUT/Makefile" -j "$JOBS" -k "$OUT/recompsx"
echo "built $OUT/recompsx"
