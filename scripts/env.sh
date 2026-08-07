#!/usr/bin/env bash
# scripts/env.sh — SOURCE this, do not execute it:  source scripts/env.sh
#
# Puts the pinned project-local toolchain in front of everything else. The system Haxe
# installation is never used by this project (see AGENTS.md golden rule 2): it is Haxe 5,
# which reflaxe.CPP does not support.
#
# Works in bash and zsh, and whether sourced from the repo root or a subdirectory.

# --- locate the repository root -------------------------------------------------------------
if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: %N is the path of the sourced file. Hidden behind eval so bash never parses it.
  _recompsx_src="$(eval 'echo ${(%):-%N}')"
else
  _recompsx_src="${BASH_SOURCE[0]:-$0}"
fi

if [ -n "$_recompsx_src" ] && [ -f "$_recompsx_src" ]; then
  RECOMPSX_ROOT="$(cd "$(dirname "$_recompsx_src")/.." && pwd)"
else
  # Fallback: walk up from $PWD looking for the repo marker.
  _recompsx_d="$PWD"
  while [ "$_recompsx_d" != "/" ] && [ ! -f "$_recompsx_d/AGENTS.md" ]; do
    _recompsx_d="$(dirname "$_recompsx_d")"
  done
  RECOMPSX_ROOT="$_recompsx_d"
fi
unset _recompsx_src _recompsx_d

if [ ! -f "$RECOMPSX_ROOT/AGENTS.md" ]; then
  echo "env.sh: cannot locate the recompsx repository root (looked for AGENTS.md)" >&2
  return 1 2>/dev/null || exit 1
fi

export RECOMPSX_ROOT

# --- pinned toolchain ------------------------------------------------------------------------
export PATH="$RECOMPSX_ROOT/.toolchain/haxe:$RECOMPSX_ROOT/.toolchain/neko:$PATH"
export HAXE_STD_PATH="$RECOMPSX_ROOT/.toolchain/haxe/std"
export NEKOPATH="$RECOMPSX_ROOT/.toolchain/neko"
export DYLD_FALLBACK_LIBRARY_PATH="$RECOMPSX_ROOT/.toolchain/neko:${DYLD_FALLBACK_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$RECOMPSX_ROOT/.toolchain/neko:${LD_LIBRARY_PATH:-}"

# Project-local haxelib repository. Set explicitly so it is found regardless of cwd,
# instead of relying on haxelib walking up the directory tree.
export HAXELIB_PATH="$RECOMPSX_ROOT/.haxelib"
