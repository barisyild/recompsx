#!/usr/bin/env bash
# scripts/conformance.sh — run every conformance test on every target and require agreement.
#
# A conformance test is one file in tests/conformance/: a class with a `main` that feeds values
# into `Conf` and calls `Conf.report`. This script finds them all, builds each for each target,
# runs it, and compares digests. Adding a test is dropping in a file — no build wiring, no
# registration list. That is the point: a testing discipline with per-test overhead does not last.
#
# src/runtime is on the classpath, so a conformance test can exercise the emulator itself and not
# only the shims — which is where most of the arithmetic worth checking lives.
#
# What a mismatch means, in order of likelihood:
#   1. arithmetic that needs `| 0` or IntMath (ADR-0004)
#   2. a target-specific path in a shim behaving differently from its counterpart
#   3. reflaxe.CPP miscompiling something (PROGRESS.md upstream defects)
# JavaScript is the reference when they disagree — Haxe's JS backend is mature, reflaxe.CPP is
# v0.1.0 and has already been caught deleting branches.
#
# Usage:  ./scripts/conformance.sh [test-name ...]     (default: all)

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

CXXFLAGS=(-std=c++17 -O2 -fwrapv)   # -fwrapv per ADR-0004
OUT="out/_conf"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %-10s %s\n' "$1" "$2"; }
bad()  { printf '  \033[31mFAIL\033[0m %-10s %s\n' "$1" "$2"; }

# Which tests to run: named on the command line, or every file that is not the shared harness.
if [ $# -gt 0 ]; then
  TESTS=("$@")
else
  TESTS=()
  for f in tests/conformance/*.hx; do
    name="$(basename "$f" .hx)"
    [ "$name" = "Conf" ] && continue
    TESTS+=("$name")
  done
fi

[ ${#TESTS[@]} -gt 0 ] || { echo "no conformance tests found"; exit 1; }

mkdir -p "$OUT"
FAILED=0

digest_of() { sed -n 's/.*digest=\([0-9a-f]*\).*/\1/p' <<<"$1"; }

say "conformance: ${#TESTS[@]} test(s) x 2 targets"

for name in "${TESTS[@]}"; do
  src="tests/conformance/$name.hx"
  [ -f "$src" ] || { bad "$name" "no such test ($src)"; FAILED=1; continue; }

  # ---- JavaScript ----
  js_log="$OUT/$name.js.log"
  if ! haxe -cp tests/conformance -cp src/runtime -cp src/shims/js -main "$name" \
            -js "$OUT/$name.js" -D js-es=6 -D analyzer-optimize >"$js_log" 2>&1; then
    bad "$name" "JS build failed — see $js_log"; FAILED=1; continue
  fi
  js_out="$(node "$OUT/$name.js" 2>&1)"
  js_digest="$(digest_of "$js_out")"

  # ---- reflaxe.CPP ----
  cpp_dir="$OUT/$name.cpp"
  cpp_log="$OUT/$name.cpp.log"
  rm -rf "$cpp_dir"
  if ! haxe build/reflaxe-cpp.hxml -cp tests/conformance -cp src/runtime -cp src/shims/cxx \
            -D "mainClass=$name" -main "$name" \
            -D "cpp-output=$cpp_dir" -D analyzer-optimize >"$cpp_log" 2>&1; then
    bad "$name" "C++ generation failed — see $cpp_log"; FAILED=1; continue
  fi
  # The null backend, not SDL: a conformance test needs logging and nothing else, and building
  # against it also keeps proving the ABI is substitutable.
  if ! clang++ "${CXXFLAGS[@]}" -w \
        -I"$cpp_dir/include" -I"$ROOT/src/backend/api" \
        "$cpp_dir"/src/*.cpp "$ROOT/src/backend/null/backend_null.c" \
        -o "$cpp_dir/run" >>"$cpp_log" 2>&1; then
    bad "$name" "C++ build failed — see $cpp_log"; FAILED=1; continue
  fi
  cpp_out="$("$cpp_dir/run" 2>&1)"
  cpp_digest="$(digest_of "$cpp_out")"

  # ---- compare ----
  if [ -z "$js_digest" ] || [ -z "$cpp_digest" ]; then
    bad "$name" "a target printed no digest"
    printf '    js : %s\n    cpp: %s\n' "$js_out" "$cpp_out"
    FAILED=1
  elif [ "$js_digest" != "$cpp_digest" ]; then
    bad "$name" "targets disagree: js=$js_digest cpp=$cpp_digest"
    printf '    js : %s\n    cpp: %s\n' "$js_out" "$cpp_out"
    FAILED=1
  elif grep -q "failed" <<<"$js_out$cpp_out"; then
    bad "$name" "digests agree ($js_digest) but assertions failed"
    printf '    %s\n' "$js_out"
    FAILED=1
  else
    ok "$name" "$js_digest   $(sed -n 's/.*\(values=[0-9]*\).*/\1/p' <<<"$js_out")"
  fi
done

if [ $FAILED -eq 0 ]; then
  printf '\033[32mconformance: all targets agree\033[0m\n'
else
  printf '\033[31mconformance: failures above\033[0m\n'
fi
exit $FAILED
