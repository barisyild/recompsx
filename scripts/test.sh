#!/usr/bin/env bash
# scripts/test.sh — the project's test gate.
#
# The default loop is JavaScript-only because the JS backend is the active development target.
# Set RECOMPSX_JS_ONLY=0 at a commit point to restore the reflaxe.CPP spikes and C++ digest.
# The numbered stages below keep the old layout so logs remain easy to compare across runs.
#
# JavaScript remains the reference when the optional C++ gate is enabled.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

FRAMES="${FRAMES:-300}"
CXXFLAGS=(-std=c++17 -O2 -fwrapv)   # see ADR-0004
JS_ONLY="${RECOMPSX_JS_ONLY:-1}"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

say "1/5 recompiler tool tests (interp)"
haxe build/tests-tool.hxml || fail "tool tests failed"
say "    ok"

if [ "$JS_ONLY" = 1 ]; then
  say "2/5 reflaxe.CPP behaviour spikes (skipped: JS-only default; use RECOMPSX_JS_ONLY=0 to enable)"
else
  say "2/5 reflaxe.CPP behaviour spikes"
  ./scripts/spike.sh >/dev/null || fail "spikes broke — upstream behaviour changed, read scripts/spike.sh output"
  say "    ok"
fi

if [ "$JS_ONLY" = 1 ]; then
  say "3/5 conformance: every test on JavaScript"
else
  say "3/5 conformance: every test on every target"
fi
RECOMPSX_JS_ONLY="$JS_ONLY" ./scripts/conformance.sh || fail "conformance failed — see above"

say "4/5 JavaScript build + headless digest"
mkdir -p out/_demo/js
haxe build/js-demo.hxml
JS_OUT="$(node out/_demo/js/demo.js --headless-hash "$FRAMES")"
JS_DIGEST="$(echo "$JS_OUT" | sed -n 's/.*digest=\([0-9a-f]*\).*/\1/p')"
[ -n "$JS_DIGEST" ] || fail "no digest from the JS build: $JS_OUT"
say "    js digest = $JS_DIGEST"

# Determinism within a target: the same input must give the same answer twice.
JS_AGAIN="$(node out/_demo/js/demo.js --headless-hash "$FRAMES" | sed -n 's/.*digest=\([0-9a-f]*\).*/\1/p')"
[ "$JS_DIGEST" = "$JS_AGAIN" ] || fail "the JS build is not deterministic: $JS_DIGEST vs $JS_AGAIN"

if [ "$JS_ONLY" = 1 ]; then
  printf '\033[32mtest.sh: JS-only gate passed — %s\033[0m\n' "$JS_DIGEST"
  exit 0
fi

say "5/5 C++ build + cross-target comparison"
rm -rf out/_demo/cpp
haxe build/pc-demo.hxml
./scripts/build-pc.sh _demo >/dev/null
CPP_DIGEST="$(./out/_demo/build/recompsx --headless-hash "$FRAMES" | sed -n 's/.*digest=\([0-9a-f]*\).*/\1/p')"
[ -n "$CPP_DIGEST" ] || fail "no digest from the C++ build"
say "    c++ digest = $CPP_DIGEST"

if [ "$JS_DIGEST" != "$CPP_DIGEST" ]; then
  fail "targets disagree over $FRAMES frames: js=$JS_DIGEST cpp=$CPP_DIGEST
  JavaScript is the reference. Look for, in this order:
    - a 32-bit multiply written as \`*\` instead of IntMath.mul (loses low bits on JS)
    - \`/\` on two Ints anywhere, or any other Float leak
    - a branch reflaxe.CPP deleted (PROGRESS.md upstream defect 8)"
fi

printf '\033[32mtest.sh: both targets agree — %s\033[0m\n' "$CPP_DIGEST"
