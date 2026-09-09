#!/usr/bin/env bash
# scripts/check.sh — the discipline gate. Run before EVERY commit (AGENTS.md).
#
# Mechanically enforces the parts of the portable subset that grep can see. It is a backstop
# for review, not a substitute: rules 2, 3, 7 and 9 in docs/specs/backend.md §5 still need eyes.
#
# Exit 0 = clean, nonzero = at least one violation.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0
fail() { printf '\033[31mVIOLATION\033[0m %s\n' "$*" >&2; FAIL=1; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }

# Directories holding code bound by the portable subset (runtime + shims + shared + generated).
PORTABLE_DIRS=()
for d in src/runtime src/shims shared tools/recomp/src; do
  [ -d "$d" ] && PORTABLE_DIRS+=("$d")
done

# --- 1. no floating point in Haxe sources -----------------------------------------------------
# Determinism depends on this: no Float means no platform-dependent rounding, ever.
# A line may opt out with a trailing `// portable-ok: <reason>` comment.
if [ ${#PORTABLE_DIRS[@]} -gt 0 ]; then
  hits="$(grep -rnE '\b(Float|Single)\b' "${PORTABLE_DIRS[@]}" --include='*.hx' 2>/dev/null \
          | grep -v 'portable-ok' || true)"
  if [ -n "$hits" ]; then
    fail "Float/Single in portable code:"; echo "$hits" >&2
  else
    ok "no Float/Single in ${PORTABLE_DIRS[*]}"
  fi
fi

# --- 2. no floating point in generated C++ ----------------------------------------------------
# Catches the case where the Haxe is clean but the compiler lowered something to a double.
# The backend is exempt: platform code may legitimately use float for window scaling.
if compgen -G "out/*/cpp/src" >/dev/null 2>&1; then
  hits="$(grep -rlE '\b(float|double)\b' out/*/cpp/src 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    fail "floating point in generated C++:"; echo "$hits" >&2
  else
    ok "no floating point in generated C++"
  fi
fi

# --- 3. no exceptions in the runtime ----------------------------------------------------------
# Unrecoverable conditions go to Fatal.raise -> bp_fatal. See docs/specs/backend.md §5 rule 6.
if [ -d src/runtime ]; then
  # Comments are stripped before matching. The original form skipped lines beginning with `/`,
  # which does not describe a doc comment's body — the word "try" in an ordinary English sentence
  # inside `/** */` tripped it, and a check that fires on prose is one people learn to ignore.
  #
  # awk strips, grep matches. Keeping the regex in grep is deliberate: awk's `\<` word boundaries
  # are a GNU extension and silently match nothing on the BSD awk macOS ships, which turned this
  # from a check that cried wolf into one that saw nothing at all.
  hits="$(find src/runtime -name '*.hx' -print0 2>/dev/null \
          | xargs -0 awk '
              { line = $0
                if (inblock) {
                  if (line !~ /\*\//) next
                  sub(/^.*\*\//, "", line); inblock = 0
                }
                sub(/\/\/.*/, "", line)
                # Whole /* ... */ pairs on one line go first. Without this a single-line doc
                # comment opened a block that its own closing never shut, and everything after
                # it in the file was skipped — the check went silent instead of noisy.
                while (line ~ /\/\*.*\*\//) sub(/\/\*.*\*\//, "", line)
                if (line ~ /\/\*/) { sub(/\/\*.*/, "", line); inblock = 1 }
                print FILENAME ":" FNR ":" line }
            ' \
          | grep -E '(^|[^A-Za-z0-9_])(throw|try)([^A-Za-z0-9_]|$)' \
          | grep -v 'portable-ok' || true)"
  if [ -n "$hits" ]; then
    fail "throw/try in src/runtime:"; echo "$hits" >&2
  else
    ok "no throw/try in src/runtime"
  fi
fi

# --- 4. no hand-edited generated code ---------------------------------------------------------
# out/ is gitignored; if anything under it is tracked, someone committed generated output.
tracked_out="$(git ls-files out/ 2>/dev/null || true)"
if [ -n "$tracked_out" ]; then
  fail "generated output is tracked by git:"; echo "$tracked_out" >&2
else
  ok "no generated output tracked"
fi

# --- 5. no game media in the repository -------------------------------------------------------
# Belt and braces over .gitignore: the content policy in LICENSE is absolute.
media="$(git ls-files | grep -iE '\.(bin|cue|iso|img|psexe|mcd)$' || true)"
# Homebrew fixtures we build ourselves are the one allowed executable class.
media_exe="$(git ls-files | grep -iE '\.exe$' | grep -v '^tests/fixtures/' || true)"
if [ -n "$media$media_exe" ]; then
  fail "game/BIOS media tracked by git:"; echo "$media$media_exe" >&2
else
  ok "no game media tracked"
fi

# --- 6. toolchain sanity ----------------------------------------------------------------------
if [ -x .toolchain/haxe/haxe ]; then
  # shellcheck source=scripts/env.sh
  source "$ROOT/scripts/env.sh"
  v="$(haxe -version 2>&1 | head -1)"
  if [ "$v" != "4.3.7" ]; then
    fail "haxe on PATH is '$v', expected 4.3.7 from .toolchain"
  else
    ok "haxe 4.3.7 from .toolchain"
  fi
else
  printf '\033[33m  skip\033[0m toolchain not installed yet (run scripts/setup.sh)\n'
fi

# --- 7. submodules at their pinned commits ----------------------------------------------------
if [ -f .gitmodules ]; then
  dirty="$(git submodule status --recursive 2>/dev/null | grep -E '^[+U-]' || true)"
  if [ -n "$dirty" ]; then
    fail "submodules not at pinned commits (+ = moved, - = uninitialized, U = conflict):"
    echo "$dirty" >&2
  else
    ok "submodules at pinned commits"
  fi
fi

# ---- root-package class names that collide with system headers -------------------------------
#
# A Haxe class in the root package compiles to a bare header — `Time.hx` gives `Time.h` — and the
# generated include directory sits on the compiler's -I path. On a case-insensitive filesystem
# (macOS by default), libc++'s own `#include <time.h>` then resolves to *our* file, and the
# translation unit fails with unresolved `time_t` and an incomplete `timespec` while never having
# mentioned time at all. Cost me a while to find; costs a grep to prevent.
#
# Classes inside a package are safe: reflaxe prefixes them (`mem/Memory.hx` -> `mem_Memory.h`).
#
# Scoped to what actually reaches a C++ compiler. tools/recomp runs under --interp and is never
# generated, so a class named `Assert` there is fine — the hazard needs a C++ include path to
# exist at all.
RESERVED_HEADERS="time math string memory stdio stdlib limits errno signal thread mutex complex
new list map set vector queue stack locale random regex tuple utility bit chrono format
filesystem atomic future optional variant span numeric iterator algorithm functional exception
typeinfo ctime cmath cstdio assert stdint stddef wchar ctype float"
collisions=""
while IFS= read -r hx; do
  # Root package only — a `package x;` line makes the emitted header prefixed and harmless.
  if grep -qE '^[[:space:]]*package[[:space:]]+[a-zA-Z_]' "$hx"; then continue; fi
  base="$(basename "$hx" .hx)"
  lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  for r in $RESERVED_HEADERS; do
    if [ "$lower" = "$r" ]; then collisions="$collisions $hx"; fi
  done
done <<EOF
$(find src shared tests/conformance tests/spike -name '*.hx' 2>/dev/null)
EOF
if [ -n "$collisions" ]; then
  fail "root-package class name collides with a system header (case-insensitively):$collisions"
  echo "  rename the class, or move it into a package so the emitted header gets a prefix" >&2
else
  ok "no generated header shadows a system one"
fi


# ---- static arrays built at their declaration -------------------------------------------------
#
# reflaxe.CPP emits a statement block at namespace scope for a static field initialised with an
# array comprehension, which is not valid C++ and fails only on the C++ build. Tables belong in an
# init function, which is also what "no allocation after boot" wants. Cost me three separate
# debugging rounds before it went in here.
# Scoped to what reflaxe.CPP actually compiles. src/shims/js is the JavaScript half of the seam
# and never reaches a C++ generator, so a table at its declaration there is fine.
bad_static="$(grep -rnE '^[[:space:]]*(public[[:space:]]+)?static[[:space:]]+(var|final)[^=]*=[[:space:]]*\[for[[:space:]]' src/runtime src/shims/cxx shared tests/conformance tests/spike 2>/dev/null || true)"
if [ -n "$bad_static" ]; then
  fail "static field initialised with an array comprehension — build it in init() instead:"
  echo "$bad_static" >&2
else
  ok "no static tables built at their declaration"
fi


# ---- identifiers that are C macros -------------------------------------------------------------
#
# A field named `errno` does not compile: <errno.h> defines it as a macro, so the generated C++
# expands it inside the declaration. Reserved words are not the hazard — macros are, and they are
# invisible from the Haxe side.
MACRO_NAMES="errno stdin stdout stderr assert NULL EOF BUFSIZ EXIT_SUCCESS EXIT_FAILURE
RAND_MAX offsetof major minor complex I"
macro_hits=""
for m in $MACRO_NAMES; do
  h="$(grep -rnE "(var|final|function)[[:space:]]+$m\b" src/runtime src/shims/cxx shared 2>/dev/null || true)"
  if [ -n "$h" ]; then macro_hits="$macro_hits
$h"; fi
done
if [ -n "$macro_hits" ]; then
  fail "identifier collides with a C macro, which the C++ build expands:$macro_hits"
else
  ok "no identifier collides with a C macro"
fi



# ---- every backend implements the whole ABI ---------------------------------------------------
#
# backend_c_api.h IS the platform boundary, and a port that quietly omits one of its functions
# does not fail to build — it fails to link, on a cross-toolchain, at the end of a twenty-minute
# compile, with an error naming a symbol and not a file. Cheaper to notice here.
#
# Definitions are recognised by starting at column 0, which is how every backend in this tree is
# written; calls are indented. A forward declaration would satisfy the check, which is acceptable:
# the linker catches that case immediately and this one it does not.
if [ -f src/backend/api/backend_c_api.h ]; then
  abi_names="$(grep -oE 'bp_[a-z_]+\(' src/backend/api/backend_c_api.h | tr -d '(' | sort -u)"
  abi_gaps=""
  for impl in src/backend/*/*.c; do
    [ -f "$impl" ] || continue
    gap=""
    for n in $abi_names; do
      grep -qE "^[A-Za-z_][A-Za-z0-9_ *]*${n}\(" "$impl" || gap="$gap $n"
    done
    if [ -n "$gap" ]; then abi_gaps="$abi_gaps
  $impl does not define:$gap"; fi
  done
  if [ -n "$abi_gaps" ]; then
    fail "a backend is missing part of backend_c_api.h:$abi_gaps"
  else
    ok "every backend implements all $(echo "$abi_names" | wc -l | tr -d ' ') ABI functions"
  fi
fi


if [ $FAIL -eq 0 ]; then
  printf '\033[32mcheck.sh: clean\033[0m\n'
else
  printf '\033[31mcheck.sh: %s\033[0m\n' "violations found — fix before committing"
fi
exit $FAIL
