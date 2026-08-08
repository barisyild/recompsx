# PROGRESS — recompsx (single source of truth; see AGENTS.md session protocol)

## Status snapshot

Phase: **M0 complete.** Toolchain pinned, specs committed, walking skeleton running on two
targets, and cross-target determinism verified — `./scripts/test.sh` builds the JavaScript and
the reflaxe.CPP builds and asserts their headless digests match (currently `329de455` over 300
frames). The windowed SDL2 build presents a gradient at 60 Hz.

Three decisions came out of M0, all forced by measurement rather than preference:
- **ADR-0002**: memory accessors are static methods, and the function table stores integer
  handles — inlined instance methods and arrays of function values do not compile.
- **ADR-0003**: develop on JavaScript, design for reflaxe.CPP. reflaxe.CPP was caught silently
  deleting `if` statements, including guard clauses, in code that then takes the wrong path.
  Haxe's own targets are correct on identical source. JS is the reference; every reflaxe.CPP
  constraint still applies everywhere.
- `IntMath.div` and `IntMath.mul` are mandatory: `/` on Ints yields Float, and `*` loses low bits
  on JS above 2^53. The first cross-target comparison diverged for exactly that reason.

Scope reminders that shape every decision: **all PS1 games are the target** (Crash Bash is the
bring-up vehicle, Spyro 3 demo is the anti-overfitting check), and **consoles are the
destination** (PC/SDL2 first; PS2 and derivatives, plus JVM, behind the same backend ABI).

## Next up (ordered)

1. **M1** — the recompiler tool, developed against `haxe --interp` (no target constraints):
   PS-EXE loader first, verified against the Crash Bash and Spyro 3 headers already recorded in
   `games/*/notes.md`; then the R3000A decoder with golden disassembly fixtures.
2. **M1** cont. — BIN/CUE + ISO9660 + `filesDir` loaders, then function discovery and the
   coverage report. Acceptance needs a coverage percentage for both game executables.
3. Report the reflaxe.CPP defects upstream (issues, with the minimal repros already in
   `tests/spike/{ifdrop,guard}`). Cheap, and the fixes benefit us directly.

## Milestones

- [ ] **M0 (M): toolchain + walking skeleton + docs**
  - [x] 0.1 process docs committed — accept: files exist on main ✔ 2026-08-08
        Evidence: commit `de6e264` "M0.1: process docs, specs, license and repo skeleton",
        49 files tracked on `main`. `.gitignore` behavior verified by experiment:
        `tests/fixtures/hello.exe` tracked, `tests/fixtures/external/psxtest_cpu.exe` ignored,
        `games/crashbash/local.json` ignored.
  - [x] 0.2 pinned toolchain — accept: `haxe -version` == 4.3.7 from `.toolchain` ✔ 2026-08-08
        Evidence: `haxe -version` -> `4.3.7`; `which haxe` ->
        `<repo>/.toolchain/haxe/haxe`; `haxelib list` -> `reflaxe.cpp: [dev:<repo>/vendor/reflaxe.CPP]`,
        `reflaxe: [dev:<repo>/vendor/reflaxe]`. System Haxe still reports `5.0.0-preview.1`,
        untouched. Submodules pinned: reflaxe `73a9831`, reflaxe.CPP `e07ab05`.
        Bonus: the macOS tarball is a universal binary, so no Rosetta — that risk is closed.
  - [x] 0.3 [M0-VERIFY] executed — accept: every item answered + evidence ✔ 2026-08-08
        14 of 19 items answered by experiment; 5 deferred to the milestone that needs them
        (each marked in the table below). Six upstream defects found and recorded. Two answers
        changed the architecture -> ADR-0002.
  - [x] 0.4 reflaxe.CPP hello — accept: 2-module hello compiles, layout documented, runs
        ✔ 2026-08-08. Evidence: `./scripts/spike.sh` -> "spike.sh: clean". Layout is
        `include/<Module>.h` + `src/<Module>.cpp` per class + `src/_main_.cpp` +
        `_GeneratedFiles.json`, as predicted. CMake template deferred to 0.5, where it has a
        real backend to link.
  - [x] 0.5 SDL window test pattern — accept: runtime.Main draws gradient VRAM via bp_present
        ✔ 2026-08-08. Evidence: `./scripts/run-pc.sh _demo` presented 3547 frames of the gradient
        with the moving marker before the window was closed. The chain Haxe → reflaxe.CPP →
        backend_c_api.h → SDL2 carries pixels end to end.
  - [x] 0.6 headless hash mode — accept: digest stable across two runs ✔ 2026-08-08
        Evidence: `--headless-hash 300` printed `digest=329de455` on both runs; `--headless-hash
        30` printed `ca3afab5`, so the digest tracks content rather than being constant.
  - [x] 0.7 (added) cross-target parity — accept: JS and C++ digests agree ✔ 2026-08-08
        Evidence: `./scripts/test.sh` → "both targets agree — 329de455". The first attempt
        diverged (js=1370700c) and found a real bug in our FNV-1a; see ADR-0003.
- [ ] **M1 (L)**: tool — PS-EXE / CUE-BIN / filesDir loaders, ISO9660, overlay extraction, R3000A
      disasm, CFG/function discovery, jump tables, coverage report — accept: golden disasm tests
      green; coverage % printed for the Crash Bash main exe *and* the Spyro 3 demo exe
- [ ] **M1.5 (M)**: scale spike — synthetic ~20k functions through emitter + reflaxe.CPP + clang;
      accept: wall times, peak RSS and **binary size** recorded here, checked against the console
      memory budgets in `docs/specs/backend.md` §0; mitigations chosen
- [ ] **M2 (L)**: codegen v1 + runtime skeleton + kernel-HLE TTY — accept: PSn00bSDK hello.exe
      prints through HLE putchar; amidog psxtest_cpu passes with a committed exclusion list
- [ ] **M3 (M)**: GTE integer-exact — accept: amidog psxtest_gte pass recorded
- [ ] **M4 (L)**: GPU software raster + DMA + timers — accept: PSn00bSDK gpu demos
      framebuffer-hash match recorded; determinism double-run test green
- [ ] **M5 (L)**: SPU + CD streaming + MDEC + pads/multitap — accept: integration fixture with a
      stable audio ring over 60 s headless; pad-state fixture green
- [ ] **M6 (XL)**: Crash Bash — 6a title screen · 6b menus + overlay switch into one minigame ·
      6c 4-player ≥15 min stable + audio + memcard save + FMV — accept per sub-item: a logged
      session with hash/screenshot evidence
- [ ] **M7 (M)**: polish — input remap, integer scaling, pacing/fast-forward, PAL variant if needed
- [ ] **M8 (M)**: portability proofs — JVM headless parity hash on the M4 demos; a console
      build-investigation memo (PS2 first) in `docs/specs/`

Effort tags: S < 1 day, M = days, L = 1–2 weeks, XL = multi-week.
Rule: never start M(n+1) before M(n)'s acceptance output is pasted into this file.

## [M0-VERIFY] checklist

Each item is one small experiment under `tests/spike/`. Record **YES/NO + one-line evidence**.
Everything here is an assumption about reflaxe.CPP or the toolchain that code shape depends on.

Executed 2026-08-08 with the spikes under `tests/spike/`. Rebuild them with
`haxe build/spike-verify.hxml` (from the repo root) — they are kept as regression tests for the
upstream behavior this project's code shape depends on.

| # | Item | Answer | Evidence |
|---|---|---|---|
| 1 | `haxelib dev` works from the submodule `main` branch, or is the pre-built `nightly` branch required? (their haxelib.json differ) | **YES, with a caveat** | `main` works, but `-lib reflaxe.cpp` alone fails with `Type not found : cxx.Compiler`. The `reflaxe.stdPaths` declaration in haxelib.json is only consumed by `haxelib run reflaxe` (which flattens a release build — that is what the `nightly` branch is). A source checkout needs `-p vendor/reflaxe.CPP/std -p vendor/reflaxe.CPP/std/cxx/_std` passed explicitly. Encoded once in `build/reflaxe-cpp.hxml`. |
| 2 | Which `reflaxe` base commit pairs with the pinned reflaxe.CPP commit (4.0.0-beta lineage)? Pin both. | **YES** | reflaxe `73a9831` (main, 2026-03-22, haxelib.json version 4.0.0-beta — there is no v4 git tag) pairs with reflaxe.CPP `e07ab05` (main, 2025-12-09). Both pinned as submodules; the 3-month gap did not break anything. Fallback pin if it ever does: reflaxe `5a91527` (2025-12-03, contemporaneous). |
| 3 | Two-module hello → output layout is `include/*.h` + `src/*.cpp` + `_main_.cpp` + `_GeneratedFiles.json`, and our CMake glob builds it | **YES** | `tests/spike/hello` (Main + Helper) produced exactly that layout; `clang++ -std=c++17 -O2` built and ran it. |
| 4 | macOS Haxe 4.3.7 tarball runs on Apple Silicon; haxelib works with project-local NEKOPATH; `.haxelib/` isolation confirmed | **YES (better than assumed)** | The `-osx` asset is a **universal binary** (x86_64 + arm64, confirmed with `file`), so it runs natively — **no Rosetta needed**, and the "Rosetta dependency" risk is closed. Neko universal likewise. `haxelib list` resolves both dev libs; system Haxe still reports 5.0.0-preview.1, untouched. |
| 5 | `-D cxx_exceptions_disabled` compiles hello + a runtime-shaped file (then add `-fno-exceptions` to CMake); if std breaks, fall back to policy-only | *deferred* | Not exercised yet; the spikes compiled without it. Revisit when the runtime skeleton exists (M2). Policy-only (no `throw`/`try` in our code, enforced by check.sh) already holds. |
| 6 | RawBytes: 2 MB `Stdlib.malloc` + `ccast` → `CArray<UInt8>`; inline get/set produce raw indexing in the emitted C++ | **YES — but the API shape is forced** | 2 MB alloc + unchecked indexing works and inlines perfectly: `Mem.set32(0x1000, …)` emits four `Mem::ram[4096] = 239;` stores, and `get32` expands to a single `((Mem::ram[4096] \| (Mem::ram[4097] << 8)) \| …)` expression — no calls. **However** memory accessors must be `static` methods on a class with `static` fields. Instance methods (and abstracts) are unusable: see #12. |
| 7 | Extern C binding of `bp_log`/`bp_present` against a stub .c; `String`→`ConstCharPtr` mechanics; `Ptr` into a buffer interior | **YES** | `@:include("cstub.h") @:topLevel extern function …` binds cleanly. `ConstCharPtr.fromString(s)` is the documented String conversion and works. `CArray.toPtr()` + `Stdlib.ccast` yields a `Ptr<UInt16>` into our buffer, verified by summing values written from Haxe inside the C function. |
| 8 | `untyped __cpp__` expression form with `{0}` interpolation compiles | **YES** | `untyped __cpp__("((int)({0}) * 3 + 1)", 14)` → 43. The escape hatch is real; statement form untested (not yet needed). |
| 9 | `cxx.num.Int64` arithmetic (32×32→64 multiply, shifts, sign) emits plain `int64_t` ops; no accidental `haxe.Int64` pull-in | **YES** | `0x12345678 * 0x10` gives high=0x1, low=0x23456780; a 64-bit value round-trips through a C extern taking `uint64_t`. `haxe.Int64` never appeared in the output. |
| 10 | What backs Haxe `Array<Int>` and `String` in the emitted C++ | **ANSWERED** | `Array<T>` → `std::shared_ptr<std::deque<T>>`; `String` → `std::string`. Confirms the rule: Haxe arrays are init-time only, never in hot paths or in fixed-size buffers — those use `CArray`. |
| 11 | `-dce full` + a dispatch-table reference keeps functions alive without `@:keep` | **YES (via Plan B)** | With `-dce full`, `fnDouble`/`fnNegate` are reachable only through a static `switch` in `Dispatch.dispatch` and both survive and execute correctly. Reachability through a generated switch is sufficient; `@:keep` is not needed. |
| 12 | `inline` effectiveness of accessors in the emitted C++ | **YES for static methods; instance inlining is BROKEN** | Haxe's inliner introduces a receiver temp (`_this` for classes, `this1` for abstracts) and reflaxe.CPP prints the name without uniquifying it, so **two inlined instance-method calls in one scope emit `redefinition of '_this'` and do not compile**. Generated MIPS functions perform many memory accesses per function, so this rules out both an abstract and an instance-method `RawBytes`. Static methods have no receiver and no temp — they inline flawlessly. This is why `Memory` is a static-accessor class. |
| 13 | CLAUDE.md `@AGENTS.md` import actually loads | *pending* | Needs a fresh Claude Code session in-repo to confirm via `/context`. |
| 14 | The installed Codex CLI auto-reads AGENTS.md from the repo root; note its version | *pending* | Needs a Codex CLI session. |
| 15 | reflaxe.CPP's `-D cmake` emission — 10-minute look | *deferred* | Ours stays authoritative regardless; look at it when the real CMake template is written (M0.4/M0.5). |
| 16 | `Sys.args()` works under reflaxe.CPP | **NO — and the fix is ours** | The generated `_main_.cpp` is literally `int main(int, const char**) { Verify::main(); return 0; }` — argc/argv are **discarded**, so `Sys.args()` returns empty (verified: passed two arguments, got count 0). Decision: our CMake **excludes the generated `_main_.cpp`** and links our own `main.c`, which stores argc/argv for the backend and then calls the generated entry point. Command-line access then goes through the backend ABI like everything else. |
| 17 | Integer overflow semantics: does the emitted C++ rely on signed `int` overflow (UB)? | **YES it does — so `-fwrapv` is mandatory** | Haxe `Int` maps to C++ `int`, and `0x7FFFFFFF + 1` produced −2147483648 at `-O2` — the MIPS-correct answer, but only because clang happened to wrap. Signed overflow is UB in C++, so this is not something to rely on: **all builds must pass `-fwrapv`** (added to the CMake template). Recorded in ADR-0001. |
| 18 | Function-reference values lower to plain C function pointers, not `std::function` | **NO — Plan A is dead, Plan B is now the design** | `Array<(Int)->Int>` lowers to `std::deque<std::shared_ptr<std::function<int(int)>>>`: an allocation and a type-erased indirect call per entry, and the array literal **does not even compile** (`arithmetic on a pointer to the function type`). The FnTable therefore stores packed Int handles in raw memory and dispatches through generated `switch` statements — no function values anywhere. `docs/specs/tool.md` §3 updated accordingly. |
| 19 | `haxe --no-output` typechecks generated code against the runtime classpath on 4.3.7 | *deferred* | Needs generated code to exist (M1/M2). |

### Upstream defects found (fork-and-fix backlog, per ADR-0001)

Recorded so they are not rediscovered. None currently block us; workarounds are in place.

1. **Inlined instance methods collide** — every inline expansion emits `T& _this = …;` with a
   fixed name, so two calls in one scope fail to compile. *Impact: high* (it dictates the
   static-accessor design). *Workaround:* static methods only in hot code. *Real fix:* uniquify
   the temp by TVar id.
2. **`Array<FunctionType>` does not compile** — the `std::deque` of `std::function` initializer
   is malformed. *Impact: high* (killed FnTable Plan A). *Workaround:* Plan B integer handles.
3. **`Sys.println` emits `std::cout` without `#include <iostream>`.** *Workaround:*
   `@:cppInclude("iostream", true)` on the class, or route output through the backend (which is
   what the runtime does anyway).
4. **Interpolating `array.length`** emits `->size()` (`size_type`), which does not compile
   against `std::string operator+`. *Workaround:* bind to an `Int` first.
5. **`trace(cond ? a : b)`** default-constructs `haxe::DynamicToString`, which has no default
   constructor. *Workaround:* use plain `if`/`else` statements.
6. **`@:valueType` class as a static field** requires a default constructor that is not
   generated. *Workaround:* static fields of primitive/`CArray` type instead.
7. **Target-code templates splice arguments without parentheses — in BOTH mechanisms.**
   `"({0} / {1})"` via `untyped __cpp__`, and `"({arg0} / {arg1})"` via `@:nativeFunctionCode`,
   both emit `(y * 31 / h - 1)` for `div(y * 31, h - 1)` — returning 42 where 54 is correct.
   *Impact: high, silent.* *Rule:* parenthesise every placeholder by hand, always:
   `"(({arg0}) / ({arg1}))"`. Locked by checks in `tests/spike/{verify,intdiv}`.

   On mechanism choice: `@:nativeFunctionCode` is the reflaxe.CPP-native way and what its own std
   uses (`cxx.CArray`, `cxx.ConstCharPtr`, `cxx.Stdlib`); `untyped __cpp__` is reflaxe's generic
   injection hook, whose name is merely configured to hxcpp's spelling. Prefer the former and
   keep target code inside declarations; reserve `__cpp__` for statement-level injection.
8. **`if` statements are silently DELETED in several common shapes — the most serious defect
   found.** No error, no warning; the branch simply vanishes and the program takes a different
   path. Confirmed shapes (`tests/spike/ifdrop`, `tests/spike/guard`):
   - **`if (cond) { ...; return; }` in a `Void` function** — the guard clause. The body is
     dropped *and the fall-through code runs instead*, so the function does the opposite of
     what it says. This is the most common control-flow idiom in systems code.
   - Inside a `while` loop, when the branch body assigns to the loop-condition variable.
   - Inside a `while` loop, when the branch body contains a ternary.
   - Inside a `while` loop, when branches are nested.
   Haxe's own targets are correct on identical source: `--interp` and `-js` both produce the
   right answer, and the emitted JavaScript is a faithful translation. **The defect is entirely
   reflaxe.CPP's.** *Workarounds:* `if/else` instead of guard clauses; no ternaries or nested
   branches inside loop bodies. But these are workarounds for the shapes we have found, not a
   guarantee about the ones we have not — which is the real problem for a project whose output
   is millions of lines of machine-written branches.

## Blockers & open questions

- None blocking. Known unknowns are tracked as `[M0-VERIFY]` items above and as the open
  questions in `games/crashbash/notes.md`.

## Session log (append-only, newest-first)

2026-08-08 [claude] Integer semantics settled (ADR-0004) after a suggestion to use haxe.Int64
  led to measuring it. Two findings: haxe.Int64 allocates per value on BOTH our targets (no
  native override for js or reflaxe.CPP) — 41ms vs 7ms hand-rolled hi/lo on the GTE workload;
  and far worse, JS does NOT wrap Int + / -, so every addu/subu would have diverged. Fix is
  `| 0` on overflowing results (free on C++). tests/conformance/Arith.hx now guards all of it
  on both targets (f975e3f9) as step 2 of test.sh.

2026-08-08 [claude] JS memory fast path: RawBuf now carries u8/u16/i32 views over one
  ArrayBuffer; aligned wide accesses use them (endianness measured at startup, not assumed).
  Motivated by a performance question; measured first: byte-composed get32 = 596 Mops/s,
  view = 1204 Mops/s, PS1 realtime needs ~10 M/s. Digests unchanged (329de455).

2026-08-08 [claude] M1 started: Vaddr, PsxExe loader (full header validation + warnings), mips.Op
  (exhaustive enum abstract) and mips.Instr written; decoder + golden tests are the next step.
  Added docs/specs/tool.md §3.1: why memory stays a flat array and what may be promoted later
  (registers already are variables; stack-slot promotion is the future win). Paused at user
  request.

2026-08-08 [claude] M0 COMPLETE. Backend ABI + SDL2 + our own main; shim/{RawBuf,RawMem,IntMath,
  Backend}; runtime/{Main,core.Hash,gpu.Vram}; CMake template; scripts/{build-pc,run-pc,test}.sh.
  Found reflaxe.CPP silently deleting `if` statements (guard clauses run the WRONG path) -> added
  the JS target and made it the reference (ADR-0003). Cross-target digests now agree: 329de455.
  Next: M1, the recompiler tool, starting with the PS-EXE loader.
2026-08-08 [claude] M0.2-0.4 done: pinned toolchain installed (Haxe 4.3.7 universal, no Rosetta),
  reflaxe pair pinned as submodules, [M0-VERIFY] executed via tests/spike/*. Two findings forced
  design changes (ADR-0002): static memory accessors, integer-handle dispatch. Haxe 5 confirmed
  incompatible. scripts/{env,setup,check,spike}.sh written. Next: M0.5 SDL2 backend shim.
2026-08-08 [claude] M0.1 done: AGENTS/CLAUDE/PROGRESS/LICENSE/.gitignore, ADR-0001 + template,
  docs/architecture.md, docs/specs/{tool,runtime,backend}.md, dir skeleton, games/crashbash +
  games/spyro3demo configs. Verified both EXE headers + SYSTEM.CNF from the user's dump (TCB=4,
  EVENT=16, STACK=801FFF00 are load-bearing for kernel HLE). Added filesDir input mode and the
  PS2/console target matrix. Next: M0.2 toolchain fetch.
2026-08-08 [claude] master plan written incl. verified reflaxe.CPP facts; next: commit M0.1 docs
