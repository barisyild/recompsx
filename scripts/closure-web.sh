#!/usr/bin/env bash
# Compile the Haxe ES6 bundle without lowering it to ES5 or changing the generated host ABI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INPUT="${1:-out/_web/game.raw.js}"
OUTPUT="${2:-out/_web/game.js}"
COMPILER="${RECOMPSX_CLOSURE_COMPILER:-google-closure-compiler}"

command -v npx >/dev/null 2>&1 || {
	printf '%s\n' 'Closure Compiler requires npm/npx. Install Node.js first.' >&2
	exit 2
}

# --no-install makes the build reproducible and prevents a typo or missing local install from
# silently downloading a different compiler during a normal game build.
npx --no-install "$COMPILER" \
	--compilation_level SIMPLE_OPTIMIZATIONS \
	--language_in ECMASCRIPT_2020 \
	--language_out ECMASCRIPT_2015 \
	--warning_level QUIET \
	--js "$INPUT" \
	--js_output_file "$OUTPUT"

node --check "$OUTPUT"
printf 'Closure Compiler ES6 bundle: %s (%s bytes)\n' "$OUTPUT" "$(wc -c < "$OUTPUT" | tr -d ' ')"
