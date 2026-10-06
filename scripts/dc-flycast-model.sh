#!/usr/bin/env bash
# scripts/dc-flycast-model.sh <image> <out.txt> [VAR=value ...]
#
# Runs a GDI or CDI under the profiling Flycast build's model of the SH-4's timing — its
# interpreter at the chip's own rate, with the instruction and operand caches, operand
# dependencies and uncached access costs modelled (branch recompsx-prof, core/profiler/rx_cache.h)
# — and writes the guest profile to <out.txt>, the cost attribution to <out.txt>.cache and the
# misses fully associative caches of the same sizes would have had to <out.txt>.cache.fa (what is
# left of each fill column once placement is perfect). Read them with
# scripts/dc-prof.py <out.txt> <recompsx.elf>. The image must carry --dc-bench=FROM:TO
# and --dc-rxprof in its recompsx.cfg, as for scripts/dc-flycast-prof.sh; the bench line on the
# overlay and in <out>.log is then in the model's time.
#
# Flycast's own timing (dc-flycast-prof.sh) models none of what makes the recompiled code slow on
# a console, and read Crash 3's title screen 1.6x fast; this model read it within a few percent
# of the console (src/backend/dreamcast/AGENTS.md, Measuring). It runs at a fraction of real time.
#
# The variables tune the model (RXCACHE_IFILL, RXCACHE_OFILL, RXCACHE_WB, RXCACHE_SQ,
# RXCACHE_EXT, RXCACHE_DEP=0); RXTRACE=<n> also records the first n instruction-line changes to
# <out.txt>.cache.itrace, for placing the code (scripts/dc-layout.py, dc-icache-sim.c, ADR-0043);
# RXOTRACE=<n> the first n operand accesses to <out.txt>.cache.otrace (dc-ocache-sim.c); RXCOUNT=1
# how many times each instruction ran, "address count" lines in <out.txt>.cache.count — what the
# code executes, where the profile only samples it (docs/perf/dreamcast-ledger.md, E-057).
# FLYCAST_MODEL points at the build (the clone's build-rxcache),
# FLYCAST_PROF_HOME is the HOME it runs with, never the user's own Flycast settings. VSync is off:
# with the window out of sight (the screen locked, another Space) the OpenGL swap waits for a vblank
# that never comes, on the thread that starts the game, and the run sits at the boot for good. The
# model's time is the SH-4's, not the host's, so presenting unpaced changes nothing. The build,
# in the clone:
#   cmake -S . -B build-rxcache -G Ninja -DCMAKE_BUILD_TYPE=Release -DUSE_VULKAN=OFF \
#     -DFLYCAST_PRESEED_DARWIN_XCODE_CHECKS=OFF -DUSE_BREAKPAD=OFF \
#     -DZLIB_LIBRARY="$(xcrun --show-sdk-path)/usr/lib/libz.tbd" && cmake --build build-rxcache
set -euo pipefail
FLYCAST_MODEL="${FLYCAST_MODEL:-$HOME/Desktop/Project/flycast/build-rxcache/Flycast.app/Contents/MacOS/Flycast}"
FLYCAST_PROF_HOME="${FLYCAST_PROF_HOME:-$HOME/Desktop/Project/flycast-home}"
image="${1:?image}"; out="${2:?output}"; shift 2
mkdir -p "$FLYCAST_PROF_HOME"
rm -f "$out" "$out.cache"
# FLYCAST_CONFIG: more Flycast settings for this run, space-separated `section:key=value` (e.g.
# config:rend.RenderToTextureBuffer=yes — a render to a texture written back to video memory at its
# address and pitch, as the PVR does, where by default Flycast keeps it apart by its start address).
extra=()
for c in ${FLYCAST_CONFIG:-}; do extra+=(-config "$c"); done
log="${out%.txt}.log"
env RXCACHE=1 "$@" HOME="$FLYCAST_PROF_HOME" RXPROF_OUT="$out" RXPROF_TIMEOUT="${RXPROF_TIMEOUT:-5400}" \
  "$FLYCAST_MODEL" -config config:Dynarec.Enabled=no -config config:rend.vsync=no ${extra[@]+"${extra[@]}"} "$image" \
  > "$log" 2>&1 &
fly=$!
# A run that never reaches the program — the HLE BIOS booting the disc again every few milliseconds —
# grows its log by megabytes a second and leaks memory into swap until the disk is full (2026-10-05:
# 76 GB of swap in half an hour, two such runs started beside five others). RXPROF_TIMEOUT never
# fires there, since no guest code runs. So this run is stopped here when the BIOS boots more than
# three times or its log passes 64 MB (a whole run's is a few KB), and says why in its log.
while kill -0 "$fly" 2>/dev/null; do
  sleep 5
  boots=$(head -c 2000000 "$log" 2>/dev/null | grep -a -c "REIOS: Booting up" || true)
  size=$(wc -c < "$log" 2>/dev/null || echo 0)
  if [ "${boots:-0}" -gt 3 ] || [ "${size:-0}" -gt 67108864 ]; then
    echo "rxwatch: stopped the run — ${boots:-0} BIOS boots, ${size:-0} bytes of log" >> "$log"
    kill "$fly" 2>/dev/null || true
    sleep 3
    kill -9 "$fly" 2>/dev/null || true
    break
  else :; fi
done
wait "$fly" 2>/dev/null || true
grep -a "^rxwatch" "$log" || true
grep -a -E '^rxcache|bench [0-9]+\.\.[0-9]+' "${out%.txt}.log" | tail -2 || true
[ -s "$out" ] || { echo "no profile written — see ${out%.txt}.log"; exit 1; }
