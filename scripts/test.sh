#!/usr/bin/env bash
# scripts/test.sh — the project's test gate.
#
# Three things, in order of how fast they fail:
#   1. reflaxe.CPP behaviour spikes  — is the C++ compiler still doing what we assume?
#   2. JS build + headless digest    — is the emulator itself correct? (seconds)
#   3. C++ build + digest comparison — do both targets agree, bit for bit?
#
# Step 3 is the one that matters most. A divergence means either a portability leak in our code
# or a miscompilation in reflaxe.CPP; JavaScript is the reference, because Haxe's JS backend is
# mature and reflaxe.CPP is v0.1.0 and has already been caught deleting branches.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

FRAMES="${FRAMES:-300}"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

say "1/3 reflaxe.CPP behaviour spikes"
./scripts/spike.sh >/dev/null || fail "spikes broke — upstream behaviour changed, read scripts/spike.sh output"
say "    ok"

say "2/3 JavaScript build + headless digest"
mkdir -p out/_demo/js
haxe build/js-demo.hxml
JS_OUT="$(node out/_demo/js/demo.js --headless-hash "$FRAMES")"
JS_DIGEST="$(echo "$JS_OUT" | sed -n 's/.*digest=\([0-9a-f]*\).*/\1/p')"
[ -n "$JS_DIGEST" ] || fail "no digest from the JS build: $JS_OUT"
say "    js digest = $JS_DIGEST"

# Determinism within a target: the same input must give the same answer twice.
JS_AGAIN="$(node out/_demo/js/demo.js --headless-hash "$FRAMES" | sed -n 's/.*digest=\([0-9a-f]*\).*/\1/p')"
[ "$JS_DIGEST" = "$JS_AGAIN" ] || fail "the JS build is not deterministic: $JS_DIGEST vs $JS_AGAIN"

say "3/3 C++ build + cross-target comparison"
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
