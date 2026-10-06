#!/usr/bin/env bash
# scripts/dc-exp.sh <name> <base> <bench-data> [<cpp>] — one Dreamcast experiment, measured under
# the cache model.
#
#   <name>        the experiment; its build is out/_x_<name>, its profile out/_x_<name>/model
#   <base>        the out/ directory whose generated code is measured (out/<base>/gen, /cpp)
#   <bench-data>  a disc data directory whose RECOMPSX.CFG carries --dc-rxprof and
#                 --dc-bench=FROM:TO (BOOT.EXE and DISC.BIN are linked, not copied)
#   <cpp>         another transpiled tree to build instead of out/<base>/cpp (a runtime change)
#
# Builds with scripts/build-dc.sh --max (DC_EXTRA_FLAGS adds compiler flags; the game's placement
# applies as in any build), makes a bench GDI from <bench-data> with this build's SYMS.BIN, runs it
# under scripts/dc-flycast-model.sh (MODEL_VARS passes RXTRACE=.. RXOTRACE=..) with a Flycast HOME
# of its own, so experiments can run side by side, and prints the bench line and the frame's
# breakdown (scripts/dc-prof.py --frames). The GDI is deleted afterwards: 1.2 GB each.
# DC_EXP_REUSE=1 skips the build when out/_x_<name> already has one.
#
# Compare code changes on the conflict-free column, and record the result in
# docs/perf/dreamcast-ledger.md whether the change is kept or not.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${KOS_BASE:?KallistiOS environment not loaded — source your environ.sh first}"
name="${1:?name}"; base="${2:?base out directory}"; data="${3:?bench data directory}"; cpp="${4:-}"
X="_x_$name"; DIR="out/$X"
mkdir -p "$DIR"
[ -e "$DIR/gen" ] || ln -s "../$base/gen" "$DIR/gen"
rm -f "$DIR/cpp"
ln -s "../${cpp:-$base/cpp}" "$DIR/cpp"
serial="$(sed -n 's/.*SERIAL = "\([A-Z0-9]*\)".*/\1/p' "$DIR/gen/GameInfo.hx" | head -1)"
range="$(sed -n 's/^--dc-bench=\([0-9]*\):\([0-9]*\).*/\1 \2/p' "$data/RECOMPSX.CFG")"
[ -n "$range" ] || { echo "no --dc-bench=FROM:TO in $data/RECOMPSX.CFG"; exit 1; }
frames=$(( ${range#* } - ${range% *} ))

t0=$(date +%s)
# DC_EXP_REUSE=1 measures the build already there (another model run of the same binary: a new
# model, or a second look), and builds only when there is none.
if [ "${DC_EXP_REUSE:-0}" != 1 ] || [ ! -f "$DIR/build-dc-max/recompsx.elf" ]; then
  ./scripts/build-dc.sh "$X" --max > "$DIR/build.log" 2>&1 || { tail -20 "$DIR/build.log"; exit 1; }
fi
grep -E "placed|loaded image" "$DIR/build.log" | tail -3
BD="$DIR/benchdata"
rm -rf "$BD" "$DIR/gdi"; mkdir -p "$BD" "$DIR/gdi" "$DIR/model"
ln "$data/BOOT.EXE" "$BD/BOOT.EXE"; ln "$data/DISC.BIN" "$BD/DISC.BIN"
cp "$data/RECOMPSX.CFG" "$DIR/build-dc-max/SYMS.BIN" "$BD/"
[ -f "$DIR/build-dc-max/HOTCODE.BIN" ] && cp "$DIR/build-dc-max/HOTCODE.BIN" "$BD/"
cp "$DIR/build-dc-max/recompsx.elf" "$DIR/model/traced.elf"
cp "$DIR/build-dc-max/recompsx.map" "$DIR/model/traced.map"
mkdcdisc -q --allow-overwrite -F gdi -e "$DIR/model/traced.elf" -D "$BD" -n "$name" -a recompsx \
  -s "$serial" -o "$DIR/gdi/disc.gdi"
t1=$(date +%s)
# shellcheck disable=SC2086
FLYCAST_PROF_HOME="${FLYCAST_PROF_HOME:-$HOME/Desktop/Project/flycast-home}-x-$name" \
  scripts/dc-flycast-model.sh "$DIR/gdi/disc.gdi" "$DIR/model/prof.txt" ${MODEL_VARS:-} > /dev/null 2>&1 || true
t2=$(date +%s)
rm -rf "$DIR/gdi"
echo "$X: build $((t1 - t0)) s, model $((t2 - t1)) s"
grep -a "bench [0-9]" "$DIR/model/prof.log" | tail -1
python3 scripts/dc-prof.py "$DIR/model/prof.txt" "$DIR/model/traced.elf" --top 0 --frames "$frames" | grep "a frame"
