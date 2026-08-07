#!/usr/bin/env bash
# scripts/spike.sh — reflaxe.CPP behavior regression tests.
#
# These are not tests of our code. They pin down the upstream behavior that this project's code
# shape depends on (PROGRESS.md [M0-VERIFY], ADR-0002). Run them first whenever the vendor
# submodule pins or the Haxe version move — if they break, the architecture assumptions broke.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

CXXFLAGS=(-std=c++17 -O2 -fwrapv)   # -fwrapv: MIPS needs two's-complement wrapping (ADR-0001)

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

say "spike: hello (two-module layout)"
rm -rf out/_spike/hello
haxe build/spike-hello.hxml
for f in out/_spike/hello/src/_main_.cpp out/_spike/hello/include/Main.h out/_spike/hello/_GeneratedFiles.json; do
  [ -f "$f" ] || { echo "FAIL: expected $f"; exit 1; }
done
clang++ "${CXXFLAGS[@]}" -Iout/_spike/hello/include out/_spike/hello/src/*.cpp -o out/_spike/hello/hello
out/_spike/hello/hello > /dev/null
say "  layout + build + run OK"

say "spike: verify (memory, externs, int64, dispatch, semantics)"
rm -rf out/_spike/verify
haxe build/spike-verify.hxml
clang++ "${CXXFLAGS[@]}" -Iout/_spike/verify/include -Itests/spike/verify \
  -x c++ out/_spike/verify/src/*.cpp tests/spike/verify/cstub.c -o out/_spike/verify/verify
out/_spike/verify/verify
say "  all checks passed"

printf '\033[32mspike.sh: clean\033[0m\n'
