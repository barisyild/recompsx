#!/usr/bin/env bash
# scripts/dc-flycast-prof.sh <image.cdi> <recompsx.elf> <out.txt> [--callers NAME,NAME,...]
#
# Runs a CDI under the profiling Flycast build and writes its guest profile to <out.txt>; read it
# with scripts/dc-prof.py <out.txt> <recompsx.elf>. The image must carry --dc-bench=FROM:TO and
# --dc-rxprof in its recompsx.cfg: the run records between the markers the backend prints and
# quits at the end of the range.
#
# The build is a local Flycast clone on branch recompsx-prof (GPL-2.0; it stays outside this
# repository). VSync is off, as in dc-flycast-model.sh: an unseen window's swap can wait forever.
# FLYCAST_PROF points at its binary; FLYCAST_PROF_HOME is the HOME it runs with, so
# it never reads or writes the user's own Flycast settings. --callers names functions (substrings
# of their demangled names, comma-separated) whose callers are to be counted too.
set -euo pipefail
FLYCAST_PROF="${FLYCAST_PROF:-$HOME/Desktop/Project/flycast/build/Flycast.app/Contents/MacOS/Flycast}"
FLYCAST_PROF_HOME="${FLYCAST_PROF_HOME:-$HOME/Desktop/Project/flycast-home}"
NM="${NM:-$HOME/toolchains/dc/sh-elf/bin/sh-elf-nm}"
cdi="${1:?image}"; elf="${2:?elf}"; out="${3:?output}"; shift 3
callers=""
if [ "${1:-}" = "--callers" ]; then
  callers="$(python3 - "$NM" "$elf" "$2" <<'PY'
import subprocess, sys
nm, elf, want = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
out = subprocess.run([nm, "-n", "-S", "-C", elf], check=True, capture_output=True, text=True).stdout
ranges = []
for line in out.splitlines():
    p = line.split(maxsplit=3)
    if len(p) == 4 and p[2] in "tTwW" and int(p[1], 16) > 0 and any(w == p[3].split("(")[0].split("::")[-1] or w in p[3] for w in want):
        lo = int(p[0], 16); ranges.append(f"{lo:x}-{lo + int(p[1], 16):x}")
print(",".join(ranges[:16]))
PY
)"
  echo "watching callers of ${callers}"
fi
mkdir -p "$FLYCAST_PROF_HOME"
rm -f "$out"
HOME="$FLYCAST_PROF_HOME" RXPROF_OUT="$out" RXPROF_TIMEOUT="${RXPROF_TIMEOUT:-1500}" RXPROF_CALLERS="$callers" \
  "$FLYCAST_PROF" -config config:rend.vsync=no "$cdi" > "${out%.txt}.log" 2>&1 || true
grep -a '^rxprof' "${out%.txt}.log" || true
[ -s "$out" ] || { echo "no profile written — see ${out%.txt}.log"; exit 1; }
