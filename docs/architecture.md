# recompsx — Architecture

Living overview of how the pieces fit. Subsystem detail lives in `docs/specs/`; decisions and
their rationale live in `docs/decisions/`. Golden rules and the session protocol are in
`AGENTS.md`; status and milestones are in `PROGRESS.md`.

## What this project is

recompsx statically recompiles PlayStation 1 games to Haxe. A build-time tool disassembles a
game's MIPS R3000A machine code and emits Haxe source; that generated source, plus a
hand-written integer-only runtime and a per-platform backend, compiles to a native executable
that *is* the game. No CPU interpreter exists at run time: code the game loads to a fixed address
is an overlay (ADR-0006), and code it loads anywhere is compiled from the disc too and recognised
by content (ADR-0025).

**The goal is every PS1 game**, driven by per-game configuration (`games/<SERIAL>/game.json`, by the disc's product code) and
nothing game-specific in the tool or runtime. Crash Bash NTSC-U (SCUS-94570) is the bring-up
vehicle — it exercises code overlays, 4-player multitap, MDEC video and streamed audio, so
making it work forces most of the general machinery into existence. The same disc also carries a
Spyro 3 demo, which is a convenient second, structurally different test subject.

**The goal is every plausible platform**, with PC as the development surface and consoles as the
real destination: PS2 and its relatives (PSP, Dreamcast, GameCube/Wii, Switch) plus JVM-family
targets. Adding one means implementing a single C header and one shim directory — see
`docs/specs/backend.md` §0 for the target matrix, per-target memory budgets and byte-order rules.

The restored Dreamcast backend is described in `docs/specs/backend.md` §2.1. Browser execution
uses optional main-thread continuations (ADR-0010); neither host owns guest timing.

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
- **Registers in CpuState, structured regions** (ADR-0029, ADR-0007): registers are `CpuState`
  fields at architectural boundaries; a looping leaf (no guest
  call or trap) keeps them in locals, published at its exits and due pumps.
  Linear chains use Haxe fallthrough and single-block loops use native `while`; remaining CFGs
  use `while (true) switch (bb)`. Every public block entry retains its stable resume index.
- **Recovered scalar signatures** (ADR-0044): bounded linear leaves and acyclic call trees can compute
  with ordinary Haxe arguments and immutable value SSA. One computed result uses the Int
  return; additional distinct results use allocation-free ABI words, consumed immediately
  under a no-callback/no-suspension contract. Constants, aliases and affine incoming values
  are reconstructed at the boundary. Entry adapters retain CpuState for events, public/interior
  dispatch and observable results. CFG joins use phi selections and return path-dependent
  counters through the same ABI contract. Build-time Boolean proofs simplify repeated/complementary
  conditions, phi choices and path charges using immutable SSA identities. A parameter disappears
  only when results, effects and accounting no longer need it. Helpers may take several checked plain-memory
  spans, preserving aliased load/store order; setters with no changed GPR return `Void`.
  Proved byte-range values can replace repeated loads; writes invalidate overlapping values
  and all values in other, possibly aliased spans. Every write remains observable in guest RAM.
  CFG loads/stores execute under block reach predicates. At joins, only exact byte/value facts
  shared by every predecessor survive. All possible spans are preflighted inside the ordinary-entry guard; interior entries
  and failed preflight retain the original CFG.
  All accesses are preflighted before any effect. Failed proofs use the original body for MMIO
  and irregular addresses. A direct caller can bypass the memory entry adapter only when its
  existing live spans cover every callee access, with runtime validity/alignment and entry-event
  guards. A shared `_withSpans` adapter owns these checks and result publication; callers pass
  spans anchored at callee inputs, and the computation retains its state-free `_value` signature.
  Block-local immutable value facts may prove an affine copy from another span's register;
  effects and public entries discard these facts. Shifts stay in the donor range and occur only
  after its validity check. The adapter introduces no guest checkpoint or dispatch entry.
  Donor registers participate in span liveness after the delay slot; all failed proofs
  retain the complete adapter. No calling-convention or non-aliasing assumption supplies this proof.
  A proved resident direct callee may be another ordinary `_value` call within a helper.
  Inputs, return-address restoration and child memory spans must be proved from SSA values;
  every secondary result/accounting word is captured before the next call. An entry guard
  requires the entire bounded call tree to finish before an event or cooperative deadline,
  with no pre-existing unwind. Otherwise the original checkpoints and guest frames execute.
  Child may-write ranges preserve disjoint saved values in the same checked view. For other
  views, a reused value requires an entry check that the physical byte ranges are disjoint;
  RAM mirrors are resolved through arena indices. Failed checks use the entire original body.
  Child alias conditions translate into the parent preflight too. Recursive, unknown and hooked
  calls remain on the general path; no callee body is expanded into its caller.
  Loaded addresses carry immutable read provenance. Entry preflight checks the source span
  before sampling its pointer, then checks dependent spans recursively. Earlier possible writes
  must be disjoint from that source; later writes cannot replace the saved value. Calls
  translate source ranges, prior writes and returned-pointer provenance into the caller.
  Failed proofs execute the entire original body; preflight never samples MMIO or writes RAM.
  Loaded views cannot use the borrowed-span adapter. General changed-pointer continuations
  and differing-pointer phis still require further recovery.
  Proved entry samples can become Int parameters, replacing repeated body reads. Helper
  signatures retain only spans used by live computations/effects/calls; preflight still
  checks every original access. Equal entry samples share a value without merging guest
  memory versions or dropping any alias exclusion. The six-parameter limit is unchanged,
  and entry preflight has its own six-span limit. Calls propagate these inputs directly.
  Outputs proved unconditionally equal to an entry sample plus a constant are reconstructed
  at the boundary, avoiding redundant helper arguments and result words. Entirely known
  memory-helper outputs permit Void returns while effects/accounting remain ordered. Child
  calls preserve read versions and reach predicates when reconstructing their own outputs;
  pointer provenance alone never authorizes dropping a computed result.
  An unconditional child invocation can export its independently proved numeric equality;
  the caller may establish the required read guard and eliminate an otherwise dead call.
  Effects and dynamic charges retain the call, while fixed packed charges propagate through
  nested summaries. Narrow forwarded conversions keep exact read-version/extension metadata.
  Every original access remains checked even when no host call survives.
  Analysis admits up to 256 guest instructions per function; a separate 96-unit live-body
  budget limits emitted definitions/effects/results/accounting. Dead guest instructions
  retain their charges. Parameter, preflight and transitive accounting bounds stay intact,
  and larger recovered helpers receive no forced inline annotation.
  Direct callers can omit memory-helper results proved overwritten on every path before an
  observation. All original access/alias guards, writes, path costs and full fallback entries
  remain. An adapter either reuses an identical proved borrowed-span preflight or constructs
  the complete preflight after its entry checks. All-dead read results permit Void helpers;
  device accesses still execute through the original callee. Public entries keep full state.
  This is bounded signature recovery, not a replacement for guest RAM, hardware state or general
  calling-convention recovery.
- **Values between observations** (ADR-0044): pure arithmetic intervals inside ordinary functions
  use immutable values and exact expression sharing, then reconstruct the changed GPRs before
  any effect. Experimental `--value-cfg` regions also carry values across Haxe branches in local
  merge variables; every public entry captures current state and every exit publishes changed
  GPRs. Values never survive a call, memory access, trap, back edge or pump. Span metadata updates
  keep their original order and operands. The next region starts from current CpuState, so nothing
  stale is restored over a callee's result. Looping-leaf locals keep their existing implementation.
  The CFG extension is off by default: current game measurements do not establish a speed gain.
  Neither pass adds a whole-function register cache or extra runtime helper calls.
- **Branch delay slots** are resolved at build time: latch the condition/target, write any link,
  execute the slot once, then transfer. The slot may overwrite the branch's input registers.
- **Cooperative scheduling.** Codegen adds `ctx.cycles = (ctx.cycles + N) | 0` per basic block; at loop
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
- Inputs are latched once per emulated VBlank (replay-friendly by construction). Online play is
  never netplay: it is built per game (ADR-0035) over the PS1's own i-mode adaptor, whose phone
  and centre the HLE kernel plays, HTTP out to the host's network (ADR-0040).
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
  2. **For kernel questions: OpenBIOS** (pcsx-redux `src/mips/openbios`). Those files carry their
     own MIT header, so unlike every emulator this is a source we may actually read, adapt and
     translate — see the licence note below first. It reimplements the retail BIOS in C and
     deliberately reproduces the original's bugs and quirks, which is exactly the behaviour our
     HLE has to match, so it settles what psx-spx describes only in prose. It is *not* the retail
     BIOS: where the two could differ, psx-spx and a test fixture decide.
  3. *Observe* DuckStation: reproduce the scenario in its debugger and watch
     registers/memory/VRAM. No source exposure, and usually faster than reading code. Its GDB
     stub makes this scriptable — breakpoints, read/write watchpoints, single steps, whole-RAM
     reads — with `scripts/duckstation-gdb.py` (enabling it edits DuckStation's settings.ini:
     back it up and restore it). Crash Bandicoot: Warped's culled objects (ADR-0027) were found
     this way, by comparing draw-list nodes and a single-stepped routine with ours.
  4. *Read* DuckStation source, last resort, under the **prose-intermediary discipline**: read
     to extract the behavioral rule → write that rule as prose in `docs/` with a citation →
     close the source → implement only from the prose note → write a PS1 test fixture proving
     the rule so our own test becomes the authority. Never implement with emulator source open
     side by side; never mirror its structure.

- **OpenBIOS licence note — read before using it.** The pcsx-redux repository as a whole is
  GPL-2.0, but the files under `src/mips/openbios/` each carry an MIT header
  (`Copyright (c) 2019 PCSX-Redux authors`), confirmed across `main/` and `kernel/`. A per-file
  notice is the grant that governs that file, and MIT is compatible with this project. Two
  obligations follow, neither optional:
  1. **Check the individual file.** The repository is mixed; a file without the header is
     GPL-2.0 and off limits.
  2. **Carry the attribution.** MIT requires the notice to travel with substantial portions, and
     a C-to-Haxe translation is a derivative work, not a clean rewrite. Anything adapted says so
     in a comment naming the file it came from.

  The prose-intermediary discipline exists for licence reasons that do not apply here, so it does
  not bind this source — but writing a fixture that proves the behaviour still does, because a
  reimplementation can be wrong and our own tests are what make a claim ours.

  **And it stays a source, never a BIOS we run.** The kernel is HLE by decision and that is not
  reopened: recompsx does not build OpenBIOS, ship it, load it, or grow a BIOS-image code path
  (golden rule 4 is unchanged). What it buys is an answer to "what does the retail kernel
  actually *do* here" where psx-spx names a function without pinning its behaviour.

## Repository layout

```text
tools/recomp/     build-time tool: loaders, R3000A disasm, analysis, Haxe emitter
shared/psxdisc/   disc model (CUE/ISO9660/sector math) — portable subset, shared with runtime
src/runtime/      portable integer-only core (see docs/specs/runtime.md)
src/backend/api/  backend_c_api.h — the platform ABI (see docs/specs/backend.md)
src/backend/pc/   backend_sdl2.c — the only file that touches SDL2
src/shims/cxx/    RawMem, I64, backend externs in reflaxe.CPP form
src/shims/jvm/    same API in pure Haxe/JVM (M8)
games/<SERIAL>/   game.json, syms.txt, notes.md, e.g. games/SCUS94570; local.json is gitignored
out/              all generated artifacts — gitignored
tests/            tool tests, runtime tests, fixtures
docs/             architecture.md, specs/, decisions/
vendor/           pinned reflaxe + reflaxe.CPP submodules
scripts/          setup, env, gen, build-pc, run-pc, test, check
build/            hxml files and the CMakeLists template
.toolchain/       pinned Haxe 4.3.7 + neko — gitignored
```
