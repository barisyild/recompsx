#!/usr/bin/env bash
# scripts/build-dc.sh [<target>] [--run] [--build-type <t>] [--max] — compile a generated C++
# tree for the Sega Dreamcast.
#
#   <target>       a directory under out/ (default: _demo, the walking skeleton)
#   --run          upload and start it with $KOS_LOADER when the build succeeds
#   --build-type   CMake build type (default Release; MinSizeRel is the one to reach for when
#                  the binary will not fit in 16 MB alongside 3.5 MB of emulated machine)
#   --max          the fastest build: Release (-O3) with link-time optimisation, and without
#                  exceptions or RTTI, which no generated or runtime code uses (checked: no
#                  throw, try, dynamic_cast or typeid in either transpiler's output), plus the
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
while [ $# -gt 0 ]; do
  case "$1" in
    --run)        RUN=1 ;;
    --build-type) shift; BUILD_TYPE="${1:?--build-type needs a value}" ;;
    --max)        MAX=1 ;;
    *)            TARGET="$1" ;;
  esac
  shift
done

: "${KOS_BASE:?KallistiOS environment not loaded — source your environ.sh first}"
TOOLCHAIN="$KOS_BASE/utils/cmake/kallistios.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || TOOLCHAIN="$KOS_BASE/utils/cmake/dreamcast.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || { echo "no KOS CMake toolchain under $KOS_BASE/utils/cmake"; exit 1; }

DIR="out/$TARGET"
# reflaxe.CPP writes cpp/src; Hatchet (scripts/build-hatchet.sh --transpile-only) one tree
# under cpp/ with GenMain at its root. The template builds either.
TRANSPILER=reflaxe
if [ ! -d "$DIR/cpp/src" ] && [ -f "$DIR/cpp/GenMain.h" ]; then TRANSPILER=hatchet; fi
[ -d "$DIR/cpp/src" ] || [ "$TRANSPILER" = hatchet ] || { echo "no generated sources in $DIR/cpp/src — generate first"; exit 1; }

# A separate build directory from the desktop one: same sources, different machine, and a shared
# CMake cache between two toolchains is a morning wasted.
BUILD="$DIR/build-dc"
EXTRA=()
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
# Tried and left out (same profile): -fschedule-insns -fsched-pressure, -fsched2-use-superblocks,
# -fselective-scheduling2 and -fira-algorithm=priority (+0.3 to +0.7 %), -mpretend-cmove and
# -fipa-pta (no gain on top), -mlra (GCC 15.2 ICE in reload on dc_scene.c).
DC_MAX_FLAGS="-mbranch-cost=1 -mdiv=call-fp -flto-partition=one"
if [ "$MAX" = 1 ]; then
  BUILD="$DIR/build-dc-max"
  BUILD_TYPE="Release"
  EXTRA=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
         "-DCMAKE_CXX_FLAGS=-fno-exceptions -fno-rtti $DC_MAX_FLAGS" "-DCMAKE_C_FLAGS=$DC_MAX_FLAGS")
fi

cp build/templates/CMakeLists.txt "$DIR/CMakeLists.txt"
cmake -S "$DIR" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DRECOMPSX_BACKEND=dreamcast -DRECOMPSX_TRANSPILER="$TRANSPILER" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null
cmake --build "$BUILD"

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
