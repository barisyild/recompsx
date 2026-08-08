# AGENTS.md — recompsx agent memory (canonical; Claude Code imports this via CLAUDE.md)

recompsx statically recompiles PS1 games to Haxe. A build-time TOOL (tools/recomp, runs in
--interp) parses PS-EXE + CD image (incl. overlays), disassembles R3000A code, and emits Haxe.
Generated code + the hand-written integer-only RUNTIME (src/runtime) compile via reflaxe.CPP
(NOT hxcpp) to dependency-free GC-less C++17, linked against a tiny C backend ABI
(src/backend/api/backend_c_api.h). Kernel is HLE; hardware is LLE at register level.

**Scope: ALL PS1 games are the target.** Crash Bash NTSC-U is only the bring-up vehicle — the
game whose failures drive the work order. Nothing game-specific ever goes in tools/recomp or
src/runtime; per-game facts live in games/<id>/game.json (+ syms.txt, notes.md). If a fix would
only work for one game, it belongs in config, not in code.

**Platforms: consoles are the point.** PS2 and derivatives (PSP, Dreamcast, GameCube/Wii,
Switch) plus JVM follow by implementing one C header (src/backend/api/backend_c_api.h) and one
shim directory. Target matrix, memory budgets and byte-order rules: docs/specs/backend.md §0.
Never let platform assumptions leak into src/runtime — that is what the backend ABI and
src/shims exist to prevent.

**Develop on JS, design for reflaxe.CPP (ADR-0003).** Write and verify emulator logic against
the JavaScript build: its compiler is mature, its loop is seconds long, and it is the reference
when targets disagree. But shape everything as if reflaxe.CPP is the only target, because for
consoles it is — take none of JavaScript's freedoms. `scripts/test.sh` builds both and compares
digests; a mismatch is either a portability leak of ours or an upstream miscompilation.

## Golden rules
1. Portable subset in src/runtime, src/shims, shared/, generated code: NO Float/Single, no
   Dynamic, no reflection, no anon structs, no closures in hot paths, no exceptions, no
   allocation after init, I64 abstract for 64-bit. `scripts/check.sh` enforces what grep can.
   Arithmetic (ADR-0004): wrap every overflowing result with `| 0` — JS does NOT wrap `+`/`-`,
   C++ does, and the hardware does; `| 0` costs nothing on C++. Never `a / b` on Ints (yields
   Float) and never bare `a * b` past 31 bits — use `IntMath.div` / `IntMath.mul`. 64-bit values
   are hi/lo Int pairs via `shim.I64`, never `haxe.Int64` (it allocates per value on both our
   targets — measured 6x slower on the GTE workload).
   Control flow: **an `if` with no `else` and more than one statement in its body is silently
   DELETED by reflaxe.CPP** — the whole statement, so the wrong path runs. Give it an `else {}`,
   or extract the body into a call. Guard clauses and ternaries are instances of this. See
   PROGRESS.md upstream defect 8; `scripts/spike.sh` reports if upstream fixes it.
   Every build includes `build/common.hxml`, which carries `-D analyzer-optimize`. It is
   verified behaviour-preserving (identical conformance digests on both targets) and must be on
   every path that produces code, or what is measured stops being what is shipped.
   JavaScript builds always pass `-D js-es=6`. Haxe's default emits prototype-based code; ES6
   classes let V8 optimise static access far better, and this runtime is nearly all static
   accessors. Never benchmark or ship a JS build without it.
   Target code: use `@:nativeFunctionCode` on an extern (what reflaxe.CPP's own std uses), not
   `untyped __cpp__`, which is reflaxe's generic hook borrowing hxcpp's spelling — reserve it for
   statement-level injection. BOTH splice arguments as raw text, so parenthesise every
   placeholder by hand: `"(({arg0}) / ({arg1}))"`. See PROGRESS.md upstream defect 7.
2. reflaxe.CPP only — never hxcpp, never system Haxe. Pinned toolchain: `source scripts/env.sh`.
3. Determinism is sacred: bp_time_us is pacing-only; all state zero-initialized; no host
   float/rand/iteration-order may reach emulated state.
4. No BIOS, no game assets, no out/ artifacts in git — ever. Dumps come from gitignored
   games/*/local.json.
5. Generated code is never hand-edited. Bug in output = fix tools/recomp, regenerate.
6. Verify before you rely: anything reflaxe.CPP-related not recorded in docs/ or an ADR gets a
   minimal experiment first (see [M0-VERIFY] in PROGRESS.md).

## Commands
    ./scripts/setup.sh              # once: toolchain + submodules + haxelib dev
    source scripts/env.sh           # every shell
    ./scripts/gen.sh crashbash      # tool -> Haxe -> C++ (+ CMakeLists)            [from M1]
    ./scripts/build-pc.sh crashbash # cmake+ninja
    ./scripts/run-pc.sh crashbash [--headless-hash 600]
    haxe build/game-js.hxml && node out/_gen/game.js   # run a generated game (JS = reference)
    haxe build/game-cpp.hxml                            # the same game through reflaxe.CPP
    ./scripts/test.sh               # THE gate: spikes + conformance + both target digests
    ./scripts/conformance.sh [name] # run cross-target conformance tests (add one = add a file)
    ./scripts/spike.sh              # reflaxe.CPP behaviour regression — run after pin changes
    ./scripts/check.sh              # discipline gate — run before EVERY commit
    haxe build/js-demo.hxml && node out/_demo/js/demo.js --headless-hash 300   # fast inner loop
    ./scripts/build-pc.sh _demo && ./scripts/run-pc.sh _demo                   # windowed

## Directory map
tools/recomp (tool) · shared/psxdisc (disc model, portable) · src/runtime (core) ·
src/backend/{api,pc} (C ABI + SDL2) · src/shims/{cxx,js} (RawBuf/RawMem/IntMath/Backend) ·
games/<id> (configs, RE notes) · out/ (generated, gitignored) · tests/ ·
docs/{architecture.md,specs,decisions} · vendor/{reflaxe,reflaxe.CPP} (pinned submodules) ·
build/ (hxml) · scripts/

## Testing discipline
Write many small tests and run each on EVERY target. A test that passes on one target proves
little; two targets disagreeing is how this project finds both its own bugs and its compiler's.
Adding one is dropping a file in `tests/conformance/` — a class with a `main` that feeds values
into `Conf` and calls `Conf.report`. `scripts/conformance.sh` finds it, builds it everywhere and
requires identical digests. When targets disagree, JavaScript is the reference.
Prefer this over single-target unit tests for anything numeric, bit-level or memory-shaped.

## Session protocol (both Codex CLI and Claude Code)
- START: read PROGRESS.md "Status snapshot" + "Next up". Do the top item unless told otherwise.
- END: update snapshot, append ONE log entry (<=5 lines, newest-first):
  `YYYY-MM-DD [agent] did X; next Y`.
- A milestone is DONE only when its acceptance command's output is pasted into PROGRESS.md.
- Architectural decisions -> docs/decisions/ADR-NNNN (template in docs/decisions/TEMPLATE.md).
- Blockers -> "Blockers & open questions" in PROGRESS.md; never leave them only in chat.

## Key references
- PS1 hardware truth: https://psx-spx.consoledev.net/ (primary spec, always first)
- Reference emulator: DuckStation — behavioral oracle (compare TTY/VRAM/memory dumps) and
  RE debugger for overlay mapping. NEVER copy/port emulator code (license-incompatible with
  MIT); record learned behavioral facts in docs/ with citation, prefer proving them with our
  own test fixtures. Escalation ladder in docs/architecture.md.
- reflaxe.CPP: https://github.com/SomeRanDev/reflaxe.CPP (CI pins Haxe 4.3.7; verified facts
  live in docs/decisions/ADR-0001 — do not re-derive them from memory)
- docs/architecture.md — layering. docs/specs/ — subsystem specs (tool, runtime, backend).
