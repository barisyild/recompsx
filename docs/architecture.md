# recompsx — Architecture

Living overview of how the pieces fit. Subsystem detail lives in `docs/specs/`; decisions and
their rationale live in `docs/decisions/`. Golden rules and the session protocol are in
`AGENTS.md`; status and milestones are in `PROGRESS.md`.

## What this project is

recompsx statically recompiles PlayStation 1 games to Haxe. A build-time tool disassembles a
game's MIPS R3000A machine code and emits Haxe source; that generated source, plus a
hand-written integer-only runtime and a per-platform backend, compiles to a native executable
that *is* the game. No CPU interpreter exists at run time.

**The goal is every PS1 game**, driven by per-game configuration (`games/<id>/game.json`) and
nothing game-specific in the tool or runtime. Crash Bash NTSC-U (SCUS-94570) is the bring-up
vehicle — it exercises code overlays, 4-player multitap, MDEC video and streamed audio, so
making it work forces most of the general machinery into existence. The same disc also carries a
Spyro 3 demo, which is a convenient second, structurally different test subject.

**The goal is every plausible platform**, with PC as the development surface and consoles as the
real destination: PS2 and its relatives (PSP, Dreamcast, GameCube/Wii, Switch) plus JVM-family
targets. Adding one means implementing a single C header and one shim directory — see
`docs/specs/backend.md` §0 for the target matrix, per-target memory budgets and byte-order rules.

## Two-artifact split

The load-bearing structural decision: the tool and the runtime live under different rules.

```
BUILD TIME (dev machine only, any Haxe target — runs via `haxe --interp`, no console constraints)
  tools/recomp: game.json + BIN/CUE ──► loaders ──► R3000A disasm ──► analysis (functions,
      CFG, jump tables, overlays, coverage report) ──► Haxe emitter ──► out/<game>/hx/**

RUN TIME (portable subset: reflaxe.CPP C++17 now, JVM later)
  out/<game>/hx (generated)  ──calls──►  src/runtime (CpuState, memory, scheduler, kernel-HLE,
      GPU sw-raster, GTE, SPU, CD, MDEC, DMA, timers, SIO)
  src/runtime ──Backend interface──► src/shims/cxx externs ──► backend_c_api.h (flat C ABI)
      ──► backend_sdl2.c (PC)  |  backend_gc.c (GameCube, later)  |  JvmBackend (pure Haxe, later)
  byte-order & raw-memory seam = src/shims/{cxx,jvm}/RawMem — NEVER in backends
```

- The recompiler tool has zero console constraints and may use the full Haxe language.
- Only `src/runtime`, `src/shims`, `shared/` and generated code obey the portable-subset
  discipline (no Float, no Dynamic, no exceptions, no post-init allocation — see
  `docs/specs/backend.md` §5 and rule 1 in `AGENTS.md`).
- The only native boundary on C++ targets is a **flat C API**: pointers and ints, no structs
  crossing Haxe↔C. This sidesteps unverified reflaxe.CPP extern behavior and reduces a console
  port to "implement one header against the platform SDK".

## Execution model

- **No instruction fetch.** Each MIPS function becomes a static Haxe function
  `(ctx:CpuState)->Void`. `jal` to a known target is a direct static call;
  `jr $ra` is a return; indirect calls go through a generated address→function table.
- **No goto in Haxe**, so intra-function control flow is a basic-block state machine:
  `while (true) switch (bb) { ... bb = N; continue; }`. Simple linear functions emit a flat body.
- **Branch delay slots** are resolved at build time by duplicating the slot instruction into
  the taken and not-taken paths, with the branch condition latched into a temp beforehand.
- **Cooperative scheduling.** Codegen adds `ctx.cycles += N` per basic block; at loop
  back-edges and function entries it emits a pump check. Hardware events (VBlank, timers, CD
  sectors, SPU ticks, SIO bytes) and interrupt delivery happen only at those sync points.
- **Overlays** are recompiled as separate modules. The runtime activates/deactivates their
  address→function mappings when an overlay load is detected (CD-read destination tracking,
  with a content-hash fallback on dispatch miss).

## Hardware strategy

- **Kernel/BIOS = HLE.** Kernel services (events, pads, TTY, heap, file API, exception
  surface) are implemented natively in the runtime. No BIOS image is ever needed or shipped.
- **Hardware = LLE at register level.** Games and Psy-Q libraries poke GPU/SPU/CD/DMA/timer
  registers directly, so those are emulated at the register interface, with a reference-quality
  integer software rasterizer for the GPU.

## Determinism

Determinism is a feature, not a side effect: the same inputs must produce bit-identical VRAM
and audio on every platform and every target.

- Master clock is emulated CPU cycles (33,868,800 Hz). Every latency and tick is an integer
  function of cycles (SPU sample every 768 cycles = exactly 44100 Hz; scanline timing as exact
  integer fractions with accumulators).
- No `Float` anywhere in runtime or generated code.
- Host time (`bp_time_us`) paces presentation only and never reaches emulated state. Host audio
  consumption never back-pressures the emulated timeline.
- Inputs are latched once per emulated VBlank (replay/netplay-friendly by construction).
- All RAM/VRAM/SPU-RAM is explicitly zero-initialized; no host randomness; no dependence on
  map iteration order.
- Verified by `--headless-hash N`: FNV-1a over scanout and audio per frame folded into a
  digest. CI compares double runs, and later compares C++ against JVM builds.

## Verification ladder

1. Unit tests — disasm goldens, analysis on synthetic functions, codegen snapshots, GTE op
   vectors, ADPCM/MDEC vectors, ISO9660 parsing.
2. Homebrew fixtures — small PSn00bSDK executables authored and built by this project.
3. amidog conformance executables (psxtest_cpu, psxtest_gte) — fetched, not committed; passed
   with a committed exclusion list justified by the HLE/static-recompilation model.
4. Determinism hashes — double-run equality, later cross-target parity.
5. Crash Bash milestones — driven by the coverage report and the runtime's dispatch-miss and
   unimplemented-kernel-call registries.

Contingency, not scheduled: if a divergence resists diagnosis, add a minimal trace-capable MIPS
interpreter to bisect recompiled-vs-reference execution. `CpuState` and `Memory` are reusable
for it by design.

## Reference emulator policy (DuckStation)

DuckStation is this project's designated reference emulator: best-in-class accuracy plus a
capable debugger. It is used two ways, and the boundary between them is a hard rule.

- **Behavioral oracle** — run the same fixture or game and compare TTY output, VRAM dumps,
  memory at breakpoints, GPU packet behavior, audio character. A divergence is presumed to be
  our bug until psx-spx says otherwise.
- **RE tool** — its debugger is the standard workflow for mapping Crash Bash overlays and for
  capturing `memdump` overlay sources.
- **License hygiene (hard rule)** — this project is MIT; DuckStation is CC-BY-NC-ND (GPL-3
  before late 2024), Mednafen is GPL-2. Never copy, port, or line-by-line translate code from
  any emulator; a translation is still a derivative work. Hardware constant tables (GTE UNR
  table, SPU gaussian and ADSR tables, dither matrix) are hardware facts documented in psx-spx
  — always take them from psx-spx.
- **Escalation ladder when stuck**:
  1. psx-spx — the primary spec, resolves most questions.
  2. *Observe* DuckStation: reproduce the scenario in its debugger and watch
     registers/memory/VRAM. No source exposure, and usually faster than reading code.
  3. *Read* DuckStation source, last resort, under the **prose-intermediary discipline**: read
     to extract the behavioral rule → write that rule as prose in `docs/` with a citation →
     close the source → implement only from the prose note → write a PS1 test fixture proving
     the rule so our own test becomes the authority. Never implement with emulator source open
     side by side; never mirror its structure.

## Repository layout

```text
tools/recomp/     build-time tool: loaders, R3000A disasm, analysis, Haxe emitter
shared/psxdisc/   disc model (CUE/ISO9660/sector math) — portable subset, shared with runtime
src/runtime/      portable integer-only core (see docs/specs/runtime.md)
src/backend/api/  backend_c_api.h — the platform ABI (see docs/specs/backend.md)
src/backend/pc/   backend_sdl2.c — the only file that touches SDL2
src/shims/cxx/    RawMem, I64, backend externs in reflaxe.CPP form
src/shims/jvm/    same API in pure Haxe/JVM (M8)
games/<id>/       game.json, syms.txt, notes.md; local.json is gitignored
out/              all generated artifacts — gitignored
tests/            tool tests, runtime tests, fixtures
docs/             architecture.md, specs/, decisions/
vendor/           pinned reflaxe + reflaxe.CPP submodules
scripts/          setup, env, gen, build-pc, run-pc, test, check
build/            hxml files and the CMakeLists template
.toolchain/       pinned Haxe 4.3.7 + neko — gitignored
```
