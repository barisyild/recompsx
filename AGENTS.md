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

**Platforms: PC first, consoles are the point.** macOS/SDL2 now; PS2 and derivatives (PSP,
Dreamcast, GameCube/Wii, Switch) and JVM targets follow by implementing one C header
(src/backend/api/backend_c_api.h) plus one shim directory. Target matrix, memory budgets and
byte-order rules: docs/specs/backend.md §0. Never let platform assumptions leak into
src/runtime — that is what the backend ABI and src/shims exist to prevent.

## Golden rules
1. Portable subset in src/runtime, src/shims, shared/, generated code: NO Float/Single, no
   Dynamic, no reflection, no anon structs, no closures in hot paths, no exceptions, no
   allocation after init, I64 abstract for 64-bit. `scripts/check.sh` enforces what grep can.
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
    ./scripts/gen.sh crashbash      # tool -> Haxe -> C++ (+ CMakeLists)
    ./scripts/build-pc.sh crashbash # cmake+ninja
    ./scripts/run-pc.sh crashbash [--headless-hash 600]
    ./scripts/test.sh               # tool tests (interp) + runtime tests (native)   [from M1]
    ./scripts/spike.sh              # reflaxe.CPP behavior regression — run after pin changes
    ./scripts/check.sh              # discipline gate — run before EVERY commit

Commands marked [from M1] arrive with the milestone that needs them; setup/env/spike/check work now.

## Directory map
tools/recomp (tool) · shared/psxdisc (disc model, portable) · src/runtime (core) ·
src/backend/{api,pc} (C ABI + SDL2) · src/shims/{cxx,jvm} (RawMem/I64/externs) ·
games/<id> (configs, RE notes) · out/ (generated, gitignored) · tests/ ·
docs/{architecture.md,specs,decisions} · vendor/{reflaxe,reflaxe.CPP} (pinned submodules) ·
build/ (hxml) · scripts/

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
