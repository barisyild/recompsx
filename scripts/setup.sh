#!/usr/bin/env bash
# scripts/setup.sh — one-shot, idempotent environment bootstrap.
#
# Fetches the pinned Haxe + Neko into .toolchain/ (both gitignored), initializes the vendored
# reflaxe submodules, and registers them in a project-local haxelib repository. Touches nothing
# outside this repository — in particular it never modifies the system Haxe installation.
#
# Safe to re-run: every step is skipped if already satisfied.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HAXE_VERSION="4.3.7"          # pinned: the only version reflaxe.CPP's CI tests
NEKO_VERSION="2.4.1"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# --- platform -------------------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin)
    # The "osx" asset is a universal binary (x86_64 + arm64) despite its undifferentiated
    # name — verified 2026-08-08 with `file`. It runs natively on Apple Silicon; no Rosetta.
    HAXE_ASSET="haxe-${HAXE_VERSION}-osx.tar.gz"
    # Neko must match the *Haxe* binary's architecture, not the host's. The universal build
    # covers both and is what pairs safely with a universal Haxe — do not "optimize" this to
    # neko-...-osx-arm64.tar.gz, which would break if Haxe ever ships x64-only again.
    NEKO_ASSET="neko-${NEKO_VERSION}-osx-universal.tar.gz"
    ;;
  Linux)
    case "$ARCH" in
      x86_64)         HAXE_ASSET="haxe-${HAXE_VERSION}-linux64.tar.gz"
                      NEKO_ASSET="neko-${NEKO_VERSION}-linux64.tar.gz" ;;
      aarch64|arm64)  HAXE_ASSET="haxe-${HAXE_VERSION}-linux-arm64.tar.gz"
                      NEKO_ASSET="neko-${NEKO_VERSION}-linux-arm64.tar.gz" ;;
      *) die "unsupported Linux architecture: $ARCH" ;;
    esac
    ;;
  *)
    die "unsupported platform: $OS (Windows: use WSL, or add the win64 assets here)"
    ;;
esac

HAXE_URL="https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/${HAXE_ASSET}"
NEKO_TAG="v$(echo "$NEKO_VERSION" | tr '.' '-')"
NEKO_URL="https://github.com/HaxeFoundation/neko/releases/download/${NEKO_TAG}/${NEKO_ASSET}"

mkdir -p .toolchain/dl

# fetch_and_unpack <url> <archive-name> <dest-dir> <probe-file>
# Unpacks into dest-dir, flattening the single top-level directory the tarballs contain.
fetch_and_unpack() {
  local url="$1" archive="$2" dest="$3" probe="$4"
  if [ -e "$dest/$probe" ]; then
    say "$dest already present, skipping"
    return 0
  fi
  if [ ! -f ".toolchain/dl/$archive" ]; then
    say "downloading $archive"
    curl -fL --retry 3 -o ".toolchain/dl/$archive.part" "$url" \
      || die "download failed: $url"
    mv ".toolchain/dl/$archive.part" ".toolchain/dl/$archive"
  fi
  say "unpacking $archive -> $dest"
  rm -rf "$dest" "$dest.tmp"
  mkdir -p "$dest.tmp"
  tar xzf ".toolchain/dl/$archive" -C "$dest.tmp"
  # tarballs contain exactly one top-level directory; hoist its contents
  local inner
  inner="$(find "$dest.tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [ -n "$inner" ] && [ "$(find "$dest.tmp" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; then
    mv "$inner" "$dest"
    rmdir "$dest.tmp"
  else
    mv "$dest.tmp" "$dest"
  fi
  [ -e "$dest/$probe" ] || die "unpack of $archive did not produce $dest/$probe"
}

say "toolchain: Haxe $HAXE_VERSION + Neko $NEKO_VERSION ($OS/$ARCH)"
fetch_and_unpack "$HAXE_URL" "$HAXE_ASSET" ".toolchain/haxe" "haxe"
fetch_and_unpack "$NEKO_URL" "$NEKO_ASSET" ".toolchain/neko" "neko"

# Record the archive checksums so a future run (or another machine) can detect a changed
# upstream asset. Written on first successful setup; compared on every later run.
LOCKFILE=".toolchain/checksums.txt"
CURRENT="$( (cd .toolchain/dl && shasum -a 256 "$HAXE_ASSET" "$NEKO_ASSET") )"
if [ -f "$LOCKFILE" ]; then
  if ! diff -q <(echo "$CURRENT") "$LOCKFILE" >/dev/null; then
    warn "toolchain archive checksums differ from $LOCKFILE:"
    diff <(echo "$CURRENT") "$LOCKFILE" >&2 || true
    warn "upstream assets changed, or the download is corrupt. Investigate before trusting builds."
  fi
else
  echo "$CURRENT" > "$LOCKFILE"
  say "recorded toolchain checksums in $LOCKFILE"
fi

# --- environment ----------------------------------------------------------------------------
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

ACTUAL_VERSION="$(haxe -version 2>&1 | head -1)"
[ "$ACTUAL_VERSION" = "$HAXE_VERSION" ] \
  || die "expected Haxe $HAXE_VERSION from .toolchain, got '$ACTUAL_VERSION' (is $ROOT/.toolchain/haxe first on PATH?)"
say "haxe -version -> $ACTUAL_VERSION"
say "which haxe     -> $(command -v haxe)"

# --- vendored compiler submodules -------------------------------------------------------------
say "initializing vendored submodules"
git submodule update --init --recursive

[ -f vendor/reflaxe/haxelib.json ]     || die "vendor/reflaxe is empty — submodule init failed"
[ -f vendor/reflaxe.CPP/haxelib.json ] || die "vendor/reflaxe.CPP is empty — submodule init failed"

# --- project-local haxelib repository ---------------------------------------------------------
if [ ! -d "$ROOT/.haxelib" ]; then
  say "creating project-local haxelib repository"
  haxelib newrepo
fi

say "registering vendored libraries as dev checkouts"
haxelib dev reflaxe     "$ROOT/vendor/reflaxe"     >/dev/null
haxelib dev reflaxe.cpp "$ROOT/vendor/reflaxe.CPP" >/dev/null
haxelib list

# --- host build tools (not fetched; only reported) ---------------------------------------------
for tool in cmake ninja; do
  command -v "$tool" >/dev/null || warn "$tool not found — needed from M0.4 on (brew install $tool)"
done
command -v ccache >/dev/null || warn "ccache not found — optional, speeds up rebuilds (brew install ccache)"
if [ "$OS" = "Darwin" ]; then
  pkg-config --exists sdl2 2>/dev/null || [ -d /opt/homebrew/include/SDL2 ] || [ -d /usr/local/include/SDL2 ] \
    || warn "SDL2 not found — needed from M0.5 on (brew install sdl2)"
fi

say "setup OK — run 'source scripts/env.sh' in each new shell"
