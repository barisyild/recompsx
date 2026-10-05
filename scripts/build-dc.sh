#!/usr/bin/env bash
# scripts/build-dc.sh [<target>] [--run] [--build-type <t>] [--max] — compile a generated C++
# tree for the Sega Dreamcast.
#
#   <target>       a directory under out/ (default: _demo, the walking skeleton)
#   --run          upload and start it with $KOS_LOADER when the build succeeds
#   --build-type   CMake build type (default Release; MinSizeRel is the one to reach for when
#                  the binary will not fit in 16 MB alongside 3.5 MB of emulated machine)
#   --placement F  place the hot code as F says (scripts/dc-layout.py) instead of the game's own
#                  games/<SERIAL>/dc-placement.txt, which is used when there is one, and else
#                  the runtime's and backend's shared src/backend/dreamcast/dc-code-placement.txt
#   --no-placement leave the code where the linker puts it
#   --no-data-placement  leave .data and .bss as the linker lays them out, instead of placing the
#                  runtime's and backend's hot variables (src/backend/dreamcast/dc-data-placement.txt)
#   --data-placement F  place the hot variables as F says instead (a candidate from a placement
#                  round, before it replaces that file)
#   --max          the fastest build: Release (-O3) with link-time optimisation, and without
#                  exceptions or RTTI, which no generated or runtime code uses (checked: no
#                  throw, try, dynamic_cast or typeid in reflaxe.CPP's output), plus the
#                  SH-4 flags in DC_MAX_FLAGS below. Built in build-dc-max so its cache never
#                  mixes with the ordinary build's. Not -funroll-loops: it grows code, and the
#                  SH-4 has an 8 KB instruction cache.
#
# Needs a KallistiOS environment: `source /opt/toolchains/dc/kos/environ.sh` (or wherever yours
# lives) before running this. Everything the cross-compiler needs comes from there — this script
# passes CMake the toolchain file KOS ships and otherwise uses the same CMakeLists as the desktop
# build, because the whole point of the backend ABI is that nothing else differs.
#
# Produces out/<target>/build-dc/recompsx.elf, which is what dcload uploads, and — when KOS's
# scramble utility is present — a 1ST_READ.BIN next to it, which is what a bootable disc holds.
# Also SYMS.BIN, the function table the --dc-overlay profile names hot code with.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="_demo"
RUN=0
MAX=0
BUILD_TYPE="Release"
PLACEMENT=auto
DATA_PLACEMENT=src/backend/dreamcast/dc-data-placement.txt
SHARED_PLACEMENT=src/backend/dreamcast/dc-code-placement.txt
while [ $# -gt 0 ]; do
  case "$1" in
    --run)        RUN=1 ;;
    --build-type) shift; BUILD_TYPE="${1:?--build-type needs a value}" ;;
    --max)        MAX=1 ;;
    --placement)  shift; PLACEMENT="${1:?--placement needs a file}" ;;
    --no-placement) PLACEMENT=none ;;
    --no-data-placement) DATA_PLACEMENT="" ;;
    --data-placement) shift; DATA_PLACEMENT="${1:?--data-placement needs a file}" ;;
    *)            TARGET="$1" ;;
  esac
  shift
done

: "${KOS_BASE:?KallistiOS environment not loaded — source your environ.sh first}"
TOOLCHAIN="$KOS_BASE/utils/cmake/kallistios.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || TOOLCHAIN="$KOS_BASE/utils/cmake/dreamcast.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || { echo "no KOS CMake toolchain under $KOS_BASE/utils/cmake"; exit 1; }

DIR="out/$TARGET"
[ -d "$DIR/cpp/src" ] || { echo "no generated sources in $DIR/cpp/src — generate first"; exit 1; }

# Fastmem (ADR-0049): a tree transpiled for it (build/game-cpp-dc.hxml) reaches guest memory through
# the SH-4's MMU, and the backend and the arena's layout must agree with it (RECOMPSX_FASTMEM): on for
# a tree with the runtime's fastmem glue (mem_Fastmem.cpp), off for any other.
FASTMEM_FLAGS=""
if [ -f "$DIR/cpp/src/mem_Fastmem.cpp" ]; then FASTMEM_FLAGS="-DRECOMPSX_FASTMEM=1"; echo "fastmem (ADR-0049): on"; fi

# A separate build directory from the desktop one: same sources, different machine, and a shared
# CMake cache between two toolchains is a morning wasted.
BUILD="$DIR/build-dc"
EXTRA=()
if [ -n "$FASTMEM_FLAGS" ]; then EXTRA=("-DCMAKE_CXX_FLAGS=$FASTMEM_FLAGS" "-DCMAKE_C_FLAGS=$FASTMEM_FLAGS"); fi
# The --max build's code-generation flags, each measured on Flycast's cycle-counting profile
# (scripts/dc-flycast-prof.sh; Crash 3 vblanks 4700-5000, Crash Bash 18800-20300), which gives the
# same count for the same binary every run. Together: Crash 3 -2.6 %, Crash Bash -1.3 %.
#   -mbranch-cost=1       GCC's SH-4 default of 2 makes if-conversion turn short branches into
#                         longer branch-free sequences; at 1 the hottest recompiled functions are
#                         7 % fewer instructions and fewer compares (Crash 3 -1.8 %, Crash Bash 0).
#   -mdiv=call-fp         integer division through the FPU's double divide, not the div1 loop.
#                         Exact for every quotient C defines: a 32-bit int is exact in a double,
#                         and the rounded quotient never crosses an integer. The two it does not,
#                         x / 0 and INT_MIN / -1, never reach C (core.Ops answers MIPS's first, and
#                         a desktop build would trap on either). KOS resets FPSCR on interrupt
#                         entry, so no handler runs in the double mode the helper switches to.
#   -flto-partition=one   one LTO unit instead of parallel partitions, so every call sees its
#                         callee's register use; the link takes three times as long (~3 minutes).
#   -fschedule-insns -fsched-pressure   instructions scheduled before register allocation as well,
#                         with an eye on register pressure — for the runtime and the backend only
#                         (the game's own code turns it off again, below): there a load waiting on
#                         the load before it is the common stall (polygonHw, the scene build, the
#                         GTE), and moving loads apart saves more than the code it adds; over the
#                         megabytes of generated code the added code cost the instruction cache as
#                         much as the stalls saved (docs/perf/dreamcast-ledger.md, E-002, E-063).
# Tried and left out (same profile): -fsched2-use-superblocks,
# -fselective-scheduling2 and -fira-algorithm=priority (+0.3 to +0.7 %), -mpretend-cmove and
# -fipa-pta (no gain on top), -mlra (GCC 15.2 ICE in reload on dc_scene.c).
# DC_EXTRA_FLAGS in the environment adds flags to these for an experiment; a flag joins the list
# only once it has been measured. DC_GAME_FLAGS adds flags to the recompiled game's own code only
# (its shards, overlays and tables; RECOMPSX_GAME_FLAGS in the CMake template), after the rest: a
# CMake list, its flags separated by semicolons.
DC_MAX_FLAGS="-mbranch-cost=1 -mdiv=call-fp -flto-partition=one -fschedule-insns -fsched-pressure $FASTMEM_FLAGS ${DC_EXTRA_FLAGS:-}"
# The one partition's code is generated on one core, and it is most of the link. GCC 15's
# incremental LTO (-flto-incremental) keeps it: a link whose code has not changed takes it from the
# cache instead. That is the placement's second link, which only moves sections (Crash 3: 181 s ->
# 2 s, the loaded image byte-identical to one linked without the cache), and any relink after a
# change that leaves the code as it was. Two entries: the current code and the one before.
if [ "$MAX" = 1 ]; then
  BUILD="$DIR/build-dc-max"
  BUILD_TYPE="Release"
  mkdir -p "$ROOT/$BUILD/lto-cache"
  EXTRA=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
         "-DCMAKE_CXX_FLAGS=-fno-exceptions -fno-rtti $DC_MAX_FLAGS" "-DCMAKE_C_FLAGS=$DC_MAX_FLAGS"
         "-DCMAKE_EXE_LINKER_FLAGS=-flto-incremental=$ROOT/$BUILD/lto-cache -flto-incremental-cache-size=2")
fi

cp build/templates/CMakeLists.txt "$DIR/CMakeLists.txt"
configure() {
  cmake -S "$DIR" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DRECOMPSX_DC_ORDER="$1" \
    -DRECOMPSX_BACKEND=dreamcast \
    -DRECOMPSX_GAME_FLAGS="-fno-schedule-insns;-fno-sched-pressure${DC_GAME_FLAGS:+;$DC_GAME_FLAGS}" \
    ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null
}

# The hot code's placement for the 8 KB direct-mapped instruction cache (ADR-0043): the game's own
# unless one is named or none is wanted. It is worth more than most code changes — Crash 3's title
# screen went from 35.1 to 29.5 ms a frame under the cache model — and it costs a second link.
if [ "$PLACEMENT" = auto ]; then
  # No GameInfo.hx (the demo, a bare executable's tree) is no serial, not a failed build.
  SERIAL="$(sed -n 's/.*SERIAL = "\([A-Z0-9]*\)".*/\1/p' "$DIR/gen/GameInfo.hx" 2>/dev/null | head -1 || true)"
  PLACEMENT=""
  if [ -n "$SERIAL" ] && [ -f "games/$SERIAL/dc-placement.txt" ]; then PLACEMENT="games/$SERIAL/dc-placement.txt"
  # A game with no placement of its own still gets the runtime's and the backend's, which are the
  # same in every game: more than half of what a game's own placement wins (ledger E-134).
  elif [ -f "$SHARED_PLACEMENT" ]; then PLACEMENT="$SHARED_PLACEMENT"; fi
elif [ "$PLACEMENT" = none ]; then
  PLACEMENT=""
fi
ORDER="$BUILD/placement"
[ -n "$DATA_PLACEMENT" ] && [ ! -f "$DATA_PLACEMENT" ] && DATA_PLACEMENT=""
if [ -n "$PLACEMENT" ] || [ -n "$DATA_PLACEMENT" ]; then
  # The first link keeps the last build's order: where a section goes does not change its size,
  # and sizes are all a plan is made from. When the plan it gives is that same order, it is done.
  # A data placement lists .data and .bss whole, and a section's start can move by a few bytes of
  # alignment between links; then the plan is made again from the new link, once. A relink of
  # unchanged code takes its code from the LTO cache, in seconds.
  if [ -f "$ORDER/order.ld" ]; then configure "$(pwd)/$ORDER"; else configure ""; fi
  cmake --build "$BUILD"
  for round in 1 2; do
    rm -rf "$ORDER.new"
    python3 scripts/dc-layout.py place "$BUILD/recompsx.map" "${PLACEMENT:--}" "$ORDER.new" ${DATA_PLACEMENT:+"$DATA_PLACEMENT"}
    if cmp -s "$ORDER.new/order.ld" "$ORDER/order.ld" 2>/dev/null && cmp -s "$ORDER.new/pad.s" "$ORDER/pad.s"; then
      rm -rf "$ORDER.new"
    else
      rm -rf "$ORDER"
      mv "$ORDER.new" "$ORDER"
      configure "$(pwd)/$ORDER"
      cmake --build "$BUILD"
    fi
    if python3 scripts/dc-layout.py check "$BUILD/recompsx.map" "$ORDER/plan.txt"; then break; fi
    [ "$round" = 2 ] && echo "warning: the hot code or data is not where its placement puts it — see ADR-0043"
  done
else
  configure ""
  cmake --build "$BUILD"
fi

ELF="$BUILD/recompsx.elf"
echo "built $ELF ($(du -h "$ELF" | cut -f1) on disk)"

# 16 MB is the whole machine, and 3.5 MB of it is already spoken for by emulated RAM, VRAM, SPU
# RAM and the scratchpad. Say so at the moment it stops being true rather than when a console
# refuses to boot.
#
# What counts is text+data+bss — what the loader puts in RAM — and NOT the size of the file, which
# also carries the symbol table and drops out entirely once the ELF becomes a 1ST_READ.BIN. On the
# desktop binary the difference is half a megabyte, which is exactly the margin this warning is
# meant to be judging.
SIZE_TOOL=""
for cand in "${KOS_CC_BASE:-}/bin/sh-elf-size" sh-elf-size; do
  command -v "$cand" >/dev/null 2>&1 && { SIZE_TOOL="$cand"; break; }
done
if [ -n "$SIZE_TOOL" ]; then
  LOADED="$("$SIZE_TOOL" "$ELF" | awk 'NR==2 {print $4}')"
  echo "loaded image: ${LOADED} bytes (text+data+bss)"
  if [ "$LOADED" -gt 12000000 ]; then
    echo "warning: leaves under 4 MB for the emulated machine — see docs/specs/backend.md §2.1"
  fi
else
  echo "note: no sh-elf-size on PATH, cannot report the loaded image size"
fi

# The overlay's function names (scripts/dc-syms.py). Copy SYMS.BIN to the disc's root beside the
# data; the backend refuses one from another build, so a stale copy costs names, not correctness.
NM_TOOL=""
for cand in "${KOS_CC_BASE:-}/bin/sh-elf-nm" sh-elf-nm; do
  command -v "$cand" >/dev/null 2>&1 && { NM_TOOL="$cand"; break; }
done
if [ -n "$NM_TOOL" ] && command -v python3 >/dev/null 2>&1; then
  python3 scripts/dc-syms.py "$NM_TOOL" "$ELF" "$BUILD/SYMS.BIN"
else
  echo "skipped SYMS.BIN (no sh-elf-nm or python3) — the overlay profile will be off"
fi

SCRAMBLE="$KOS_BASE/utils/scramble/scramble"
if [ -x "$SCRAMBLE" ] && command -v kos-objcopy >/dev/null 2>&1; then
  kos-objcopy -R .stack -O binary "$ELF" "$BUILD/recompsx.bin"
  "$SCRAMBLE" "$BUILD/recompsx.bin" "$BUILD/1ST_READ.BIN"
  echo "built $BUILD/1ST_READ.BIN"
else
  echo "skipped 1ST_READ.BIN (scramble or kos-objcopy not on PATH) — the .elf is enough for dcload"
fi

if [ "$RUN" -eq 1 ]; then
  : "${KOS_LOADER:?KOS_LOADER is not set — e.g. export KOS_LOADER=\"dc-tool-ip -t 192.168.1.100 -x\"}"
  # shellcheck disable=SC2086
  exec $KOS_LOADER "$ELF"
fi
