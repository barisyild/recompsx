#!/usr/bin/env bash
# scripts/dc-digest.sh <recompsx.elf> <data-dir> <frames> [<name>]
#
# The game digest a Dreamcast build prints at a frame — GenMain's `--headless-hash`, given through
# the disc's RECOMPSX.CFG and read from Flycast's serial log — which is the digest JavaScript and the
# desktop C++ build print for the same disc and frame. So a Dreamcast build is held to the reference
# (AGENTS.md: JavaScript is the reference when targets disagree), by everything GCC and the SH-4 cores
# do with the machine's state: Crash 3's r117 build printed 47853ef7 at 5000, JavaScript's.
#
# A headless run draws with the runtime's software rasteriser and mixes no sound (GenMain ignores
# --video-hw and --audio-hw there), so it checks the generated code, the runtime and the GTE's RTPS
# core; the polygon core and the scene build are the TA hash's (docs/perf/dreamcast-ledger.md, How
# to measure). <data-dir> gives BOOT.EXE and DISC.BIN (linked, not copied); the RECOMPSX.CFG is
# written here. The run is the model's Flycast build with its interpreter and without the cache
# model (RXCACHE=0) — Crash Bash's 20,300 frames take about half an hour, Crash 3's 5,000 about a
# quarter with the cache model on — and RXPROF_OUT must be set, or that build never gets past the
# boot. Prints the digest line; the run's log is out/_dg_<name>/run.log. DIGEST_ARGS adds launch
# lines to the RECOMPSX.CFG, one argument a line: `DIGEST_ARGS=$'--pad-script\n3400:START,3410:-'`
# runs a scripted pad (sio.PadScript), as `--pad-script` does for JavaScript.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
elf="${1:?recompsx.elf}"; data="${2:?data directory}"; frames="${3:?frames}"
name="${4:-$(basename "$(dirname "$(dirname "$elf")")")-$frames}"
FLYCAST_MODEL="${FLYCAST_MODEL:-$HOME/Desktop/Project/flycast/build-rxcache/Flycast.app/Contents/MacOS/Flycast}"
home="${FLYCAST_PROF_HOME:-$HOME/Desktop/Project/flycast-home}-dg-$name"
D="out/_dg_$name"
rm -rf "$D"; mkdir -p "$D/bd" "$D/gdi" "$home"
ln "$data/BOOT.EXE" "$D/bd/BOOT.EXE"; ln "$data/DISC.BIN" "$D/bd/DISC.BIN"
# The run-time layout's table (ADR-0063), when the build has one: DIGEST_ARGS=--dc-hotcode=FROM:TO moves
# the code during the run, which must leave the digest as it was.
if [ -f "$(dirname "$elf")/HOTCODE.BIN" ]; then cp "$(dirname "$elf")/HOTCODE.BIN" "$D/bd/"; fi
printf '/cd/BOOT.EXE\n/cd/DISC.BIN\n--headless-hash\n%s\n' "$frames" > "$D/bd/RECOMPSX.CFG"
if [ -n "${DIGEST_ARGS:-}" ]; then printf '%s\n' "$DIGEST_ARGS" >> "$D/bd/RECOMPSX.CFG"; fi
serial="$(strings -n 9 "$elf" | grep -m1 -E '^S[CL][EUP][SM][0-9]{5}$' || true)"
mkdcdisc -q --allow-overwrite -F gdi -e "$elf" -D "$D/bd" -n "$name" -a recompsx ${serial:+-s "$serial"} \
  -o "$D/gdi/disc.gdi"
HOME="$home" RXCACHE="${RXCACHE:-0}" RXPROF_OUT="$D/prof.txt" RXPROF_TIMEOUT="${RXPROF_TIMEOUT:-7200}" \
  "$FLYCAST_MODEL" -config config:Dynarec.Enabled=no -config config:rend.vsync=no "$D/gdi/disc.gdi" \
  > "$D/run.log" 2>&1 &
t0=$(date +%s)
# The build may run again under another process id; the log says when the digest is out.
until grep -a -q "digest=" "$D/run.log" 2>/dev/null; do
  pgrep -f "$D/gdi/disc.gdi" > /dev/null || break
  sleep 10
done
pkill -f "$D/gdi/disc.gdi" 2>/dev/null || true
rm -rf "$D/gdi" "$D/bd"
echo "$name: $(( $(date +%s) - t0 )) s"
grep -a "digest=" "$D/run.log" | tail -1 || { echo "no digest — see $D/run.log"; exit 1; }
