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

say "spike: nat64 (does cxx.num.Int64 keep 64 bits?)"
rm -rf out/_spike/nat64
haxe build/spike-nat64.hxml
# The trap, and why this runs on every pin change: `cxx.num.Int64` is declared
# `extern abstract Int64 to Int from Int`, so Haxe's typer resolves operators through `to Int`
# and reflaxe emits a plain 32-bit multiply that is only widened AFTERWARDS. A product that
# leaves 32 bits is lost before it is ever stored. Any future move of shim.I64 onto a native
# int64 must therefore spell every operation with @:nativeFunctionCode, never with the
# abstract's own operators. If this grep ever fails, upstream fixed it and that constraint
# can be revisited.
if grep -qE "int64_t wide = \(\(int64_t\)|int64_t wide = \(int64_t\)" out/_spike/nat64/src/*.cpp; then
  say "  cxx.num.Int64 now widens BEFORE multiplying — upstream changed; revisit shim.I64"
else
  say "  confirmed: cxx.num.Int64 arithmetic truncates to 32 bits (use @:nativeFunctionCode)"
fi

say "spike: guard (does the compiler keep our branches?)"
rm -rf out/_spike/guard
haxe build/spike-guard.hxml
clang++ "${CXXFLAGS[@]}" -Iout/_spike/guard/include out/_spike/guard/src/*.cpp -o out/_spike/guard/guard
GUARD_OUT="$(out/_spike/guard/guard)"
echo "$GUARD_OUT"
if echo "$GUARD_OUT" | grep -q 'early-return guard: "guarded;"'; then
  say "  guard clauses are compiled correctly — upstream defect 8 appears FIXED; revisit the"
  say "  workarounds in src/runtime and docs/specs before relying on it"
else
  say "  guard clauses still miscompiled (upstream defect 8) — keep using if/else"
fi

say "spike: ifbody (does the compiler keep multi-statement branches?)"
rm -rf out/_spike/ifbody
haxe build/spike-ifbody.hxml
clang++ "${CXXFLAGS[@]}" -w -Iout/_spike/ifbody/include out/_spike/ifbody/src/*.cpp -o out/_spike/ifbody/run
IFBODY_OUT="$(out/_spike/ifbody/run)"
echo "$IFBODY_OUT"
if echo "$IFBODY_OUT" | grep -q '2 stmts       : "B1B2"'; then
  say '  multi-statement branches survive — upstream defect 8 appears FIXED; the "else {}"'
  say '  workarounds in src/ and tests/ can be revisited'
else
  say "  multi-statement branches still deleted without an else (upstream defect 8)"
fi

printf '\033[32mspike.sh: clean\033[0m\n'
