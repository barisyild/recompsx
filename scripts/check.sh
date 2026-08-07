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
  hits="$(grep -rnE '^[^/]*\b(throw|try)\b' src/runtime --include='*.hx' 2>/dev/null \
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

if [ $FAIL -eq 0 ]; then
  printf '\033[32mcheck.sh: clean\033[0m\n'
else
  printf '\033[31mcheck.sh: %s\033[0m\n' "violations found — fix before committing"
fi
exit $FAIL
