# Building and running recompsx (JavaScript / desktop)

**Browser update, 2026-09-09:** the reproducible main-thread build and local-server commands
are in [WEB.md](WEB.md). Use `./scripts/build-web.sh <game-id>`; copying a Node bundle into the
page does not enable cooperative execution. Current acceptance digests and compatibility
limits are recorded in [PROGRESS.md](../PROGRESS.md); the older digest samples below are historical.

Everything here is the JavaScript path, which is the development target and the reference when
targets disagree (ADR-0003). It builds in seconds and runs a three-thousand-frame verification in
about twenty-five, which is why work happens here first and the C++ side is a commit-point check
rather than an inner loop.

## 0. Once per machine

    ./scripts/setup.sh

Downloads the pinned Haxe 4.3.7 and Neko into the repository, initialises the submodules, and
registers the vendored compilers with haxelib. It does not touch the system Haxe; nothing in this
project ever uses one.

`setup.sh` applies the compiler patches idempotently, including the scalar-local declaration
fix and the contiguous Array patch. Do not blindly reapply them to an already patched checkout.
See `vendor/patches/README.md`; the Array rationale is in ADR-0009.

## Every shell

    source scripts/env.sh

Puts the pinned toolchain on PATH and exports `RECOMPSX_ROOT`. Skipping it silently uses whatever
Haxe the system has, which is the wrong compiler.

## 1. The game media, which is never in git

Create `games/crashbash/local.json` — gitignored, and the only place an absolute path to a disc
image may appear:

    { "cue": "/absolute/path/to/Crash Bash.cue" }

The generator reads the executable and the overlays straight out of the disc image; there is no
step that copies game data into the repository, and there must never be one. `game.json` carries
only facts *about* the disc (the executable's path inside it, its SHA-256, where the overlays
live), which is why it is checked in and `local.json` is not.

For running, the runtime wants the executable and the disc image as two arguments. The convenient
arrangement is two gitignored symlinks:

    mkdir -p web
    ln -sf "/path/to/SCUS_945.70"   web/boot.exe
    ln -sf "/path/to/Crash Bash.bin" web/disc.bin

## 2. Generate, build, run

    ./scripts/recompsx.sh gen games/crashbash/game.json    # disc -> Haxe, into out/gen
    haxe build/game-js.hxml                                # out/gen -> out/_gen/game.js
    node out/_gen/game.js web/boot.exe web/disc.bin

Generation runs the tool under Haxe's interpreter and takes a couple of minutes; it only needs
repeating when `tools/recomp` or `games/<id>/*.json` changes. Editing anything in `src/runtime` or
`src/shims` needs only the `haxe` step.

Headless, for verification rather than watching:

    node out/_gen/game.js web/boot.exe web/disc.bin --headless-hash 3000

It runs three thousand emulated frames, hashes the machine's observable state and prints one line.
**The expected digest is `5853aa57`.** If it differs, something changed emulated behaviour —
which is the entire point of the number.

### A trap that has already cost an hour

`node` will happily run a *stale* `out/_gen/game.js` when the Haxe build failed, and print the
right digest from the previous build. Delete the output before trusting it:

    rm -f out/_gen/game.js && haxe build/game-js.hxml && test -f out/_gen/game.js

## 3. The gates

    ./scripts/check.sh        # discipline: portable-subset rules, ABI completeness. Before every commit.
    ./scripts/conformance.sh  # 14 tests x 2 targets; the digests must match across targets
    ./scripts/spike.sh        # compiler behaviour regressions; run after any submodule change
    ./scripts/test.sh         # all of the above plus both target digests — the full gate

`conformance.sh` compiles C++ with clang directly, **not** through CMake. That is a second build
path, and a new C++ source file must be added to both or seven tests fail to build while the game
digest keeps reporting success. `src/shims/cxx/native/recompsx_arena.c` is the current example.

Known-good digests: game `5853aa57` (3000 frames), demo `329de455` (300 frames), and among the
conformance tests `Mem 27f9aa59`, `GteOps 1cf89aa2`, `Acc64 0deeafe0`, `Raster b66077e7`.

## 4. Running natively on the desktop, with a window

    haxe build/game-cpp.hxml          # Haxe -> C++, roughly fifteen minutes
    ./scripts/build-pc.sh _gen        # SDL2 backend
    ./scripts/run-pc.sh _gen

`--null` on `build-pc.sh` builds the headless backend instead, which is what the C++ digest check
uses. The C++ transpile is slow because it runs inside Haxe's macro interpreter — no hotspot, just
the interpreter's cost — so it belongs at commit points, not in a loop.

## 5. Measuring

    haxe build/game-js.hxml -D recompsx_insns

Adds a per-block counter of emulated instructions, reported in the summary line as `insns`. It is
behind a flag because a store per block on the hot path is a real cost and has been deliberately
removed from it once already. The count is deterministic and identical on every target, so
measuring it on JavaScript in twenty-five seconds answers the question for all of them.

## Where things are

    tools/recomp        the build-time tool: disc + PS-EXE in, Haxe out
    src/runtime         the emulator, portable subset only (see AGENTS.md golden rule 1)
    src/shims/{js,cxx}  the same names, spelled per target
    out/gen             generated Haxe        (gitignored)
    out/_gen            build output          (gitignored)
    games/<id>          per-game configuration and RE notes
    docs/decisions      ADRs — read before changing anything they cover

`AGENTS.md` is the standing brief: the rules, the commands, and the session protocol. `PROGRESS.md`
holds the status snapshot, what is next, and an append-only log of what was tried and what it
measured — including the things that did not work, which are usually the more useful half.
