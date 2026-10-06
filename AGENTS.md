# AGENTS.md — recompsx agent memory (canonical; Claude Code imports this via CLAUDE.md)

recompsx statically recompiles PS1 games to Haxe. A build-time TOOL (tools/recomp, runs in
--interp) parses PS-EXE + CD image (incl. overlays), disassembles R3000A code, and emits Haxe.
Generated code + the hand-written integer-only RUNTIME (src/runtime) compile via reflaxe.CPP
(NOT hxcpp) to dependency-free GC-less C++17, linked against a tiny C backend ABI
(src/backend/api/backend_c_api.h). Kernel is HLE; hardware is LLE at register level.

**Scope: ALL PS1 games are the target.** Crash Bash NTSC-U is only the bring-up vehicle — the
game whose failures drive the work order. Nothing game-specific ever goes in tools/recomp or
src/runtime; per-game facts live in games/<SERIAL>/game.json (+ syms.txt, notes.md), keyed by
the product code on the disc, upper case, no punctuation: games/SCUS94570 is Crash Bash, and
games/SCUS94244 is Crash Bandicoot: Warped. If a fix would only work for one game, it belongs in
config, not in code. Code that *extends* a game — a mod — lives with it, in
games/<SERIAL>/mods/<id> (ADR-0033), and reaches the game only through `mod.ModHost`.

**Online is never netplay (ADR-0035).** No lockstep, rollback, input exchange or savestate sync —
ever. Online play is written per game: a lobby in the game's own UI and a game-level protocol in
the game's mod, over the PS1's own i-mode adaptor (ADR-0040) — its phone and i-mode centre are
the HLE kernel's ("PS1 Pro"), HTTP out through a transport per target — so consoles, web and
desktop play together. Never propose netplay as a design. A player types only an address; each
game's port is fixed in its mod. Mods read the mouse and keyboard the same way: the PS1's own
devices (Sony Mouse, PS/2 keyboard) on ports of their own, never a custom API.

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
   C++ does, and the hardware does; `| 0` costs nothing on C++. Never store -0 or an unsigned
   reading either: `%` and a negated zero give -0 on JS, `>>> 0` gives a number above 2^31, and
   one such value turns a field or array into boxed doubles for good — the page's GC (ADR-0023). Never `a / b` on Ints (yields
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
    ./scripts/recompsx.sh gen <disc.cue>   # disc -> Haxe in out/gen; SYSTEM.CNF's product code
                                           # picks games/<SERIAL>/game.json when there is one
    ./scripts/recompsx.sh gen SCUS94570    # the same, the disc named by games/SCUS94570/local.json
    ./scripts/recompsx.sh gen SCUS94570 --mods <ids|all>   # with the game's mods; compile the
                                           # result with -D recompsx_mods (ADR-0033)
    haxe build/game-js.hxml && node out/_gen/game.js <exe> <disc.bin>   # run it (JS = reference)
    haxe build/game-cpp.hxml && ./scripts/build-pc.sh _gen --null       # the same, reflaxe.CPP
    haxe build/game-cpp-dc.hxml && ./scripts/build-dc.sh _gen --max     # the Dreamcast's (fastmem, ADR-0049;
                                           # -D dreamcast, which only a mod may ask: ADR-0033)
    <run> --headless-hash 600    # stop at frame 600, print one digest; the cross-target compare
                                 # for a GAME (test.sh's 329de455 is the demo's, and stays put)
    ./scripts/test.sh               # THE gate: spikes + conformance + both target digests
    ./scripts/conformance.sh [name] # run cross-target conformance tests (add one = add a file)
    ./scripts/spike.sh              # reflaxe.CPP behaviour regression — run after pin changes
    ./scripts/check.sh              # discipline gate — run before EVERY commit
    haxe build/js-demo.hxml && node out/_demo/js/demo.js --headless-hash 300   # fast inner loop
    ./scripts/build-pc.sh _demo && ./scripts/run-pc.sh _demo                   # windowed

## Backend notes — read only the one you are working on
Each backend keeps its own agent notes beside its code. Before working on a backend, read ITS
note, and not the others: they are written to be loaded one at a time (Claude Code loads the
matching `CLAUDE.md` in that directory by itself).
- Dreamcast — `src/backend/dreamcast/AGENTS.md`: **sh4zam first — every std function with an
  sh4zam counterpart uses sh4zam**; measuring on Flycast vs hardware; CDIs; the PVR scene.
- PC (SDL2) — `src/backend/pc/AGENTS.md`
- Null — `src/backend/null/AGENTS.md`
- Browser (JavaScript) — `web/AGENTS.md`: the page, the WebGL2 renderer, `src/shims/js`.
A new backend gets a note of its own, listed here, in the same change that adds it.

## Directory map
tools/recomp (tool) · shared/psxdisc (disc model, portable) · src/runtime (core) ·
src/backend/{api,pc,null,dreamcast} (C ABI + backends) · src/shims/{cxx,js} (RawBuf/RawMem/
IntMath/Backend) · web/ (browser page + WebGL2 renderer) · games/<SERIAL> (configs, RE notes) ·
out/ (generated, gitignored) · tests/ · docs/{architecture.md,specs,decisions} ·
vendor/{reflaxe,reflaxe.CPP,sh4zam} (pinned submodules; sh4zam is the Dreamcast's) ·
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
- ONE TREE: work only in this working tree. Never in another worktree — no `git worktree`, no
  copy of the tree to build, test or measure in — unless the owner says otherwise. Several
  sessions share this tree at once.
- END: update snapshot, append ONE log entry (<=5 lines, newest-first):
  `YYYY-MM-DD [agent] did X; next Y`.
- A milestone is DONE only when its acceptance command's output is pasted into PROGRESS.md.
- Architectural decisions -> docs/decisions/ADR-NNNN (template in docs/decisions/TEMPLATE.md).
- Blockers -> "Blockers & open questions" in PROGRESS.md; never leave them only in chat.

## Key references
- PS1 hardware truth: https://psx-spx.consoledev.net/ (primary spec, always first)
- Kernel behaviour: **OpenBIOS** — https://github.com/grumpycoders/pcsx-redux/tree/main/src/mips/openbios
  A retail-BIOS reimplementation in C that deliberately keeps the original's bugs and quirks —
  which is what our HLE must match. Those files carry their own **MIT** header even though the
  surrounding repo is GPL-2.0, so this is the one non-spec source we may read, adapt and
  translate. Two rules: verify the MIT header in the specific file (the repo is mixed), and carry
  the attribution in a comment, since a C-to-Haxe translation is a derivative work. Still second
  to psx-spx, and still needs a fixture — a reimplementation can be wrong.
  **It is a source to read, never a BIOS to run.** The kernel stays HLE (golden rule 4 is
  unchanged): we do not build it, ship it, load it, or add a BIOS-image path. Its value is that
  it answers "what does the retail kernel actually do here" when psx-spx only describes it.
- Reference emulator: DuckStation — behavioral oracle (compare TTY/VRAM/memory dumps) and
  RE debugger for overlay mapping. NEVER copy/port emulator code (license-incompatible with
  MIT); record learned behavioral facts in docs/ with citation, prefer proving them with our
  own test fixtures. Escalation ladder in docs/architecture.md.
- reflaxe.CPP: https://github.com/SomeRanDev/reflaxe.CPP (CI pins Haxe 4.3.7; verified facts
  live in docs/decisions/ADR-0001 — do not re-derive them from memory)
- docs/architecture.md — layering. docs/specs/ — subsystem specs (tool, runtime, backend).
