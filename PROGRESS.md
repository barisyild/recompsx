# PROGRESS — recompsx (single source of truth; see AGENTS.md session protocol)

## Status snapshot

Phase: **M0 in progress**. M0.1 done — process docs, license, ADR-0001, the three subsystem
specs under `docs/specs/`, the directory skeleton, and the first two game configurations are
committed. No toolchain fetched yet, no code written yet.

Scope reminders that shape every decision: **all PS1 games are the target** (Crash Bash is the
bring-up vehicle, Spyro 3 demo is the anti-overfitting check), and **consoles are the
destination** (PC/SDL2 first; PS2 and derivatives, plus JVM, behind the same backend ABI).

## Next up (ordered)

1. **M0.2** — `scripts/env.sh` + `scripts/setup.sh`; fetch pinned Haxe 4.3.7 + neko into
   `.toolchain/`; add `vendor/reflaxe` and `vendor/reflaxe.CPP` submodules; run setup; paste the
   `haxe -version` output below.
2. **M0.3** — execute the `[M0-VERIFY]` checklist below; record YES/NO + one-line evidence for
   every item; amend `docs/decisions/ADR-0001-reflaxe-cpp.md` if any assumption breaks.
3. **M0.4** — two-module reflaxe.CPP hello; document the emitted C++ layout; build it with our
   own CMake.
4. **M0.5** — `runtime.Main` + `RawBytes` VRAM gradient presented through `backend_sdl2.c`.
5. **M0.6** — `--headless-hash 600` prints the same digest on two consecutive runs.

## Milestones

- [ ] **M0 (M): toolchain + walking skeleton + docs**
  - [x] 0.1 process docs committed — accept: files exist on main ✔ 2026-08-08
  - [ ] 0.2 pinned toolchain — accept: `haxe -version` == 4.3.7 from `.toolchain`, output pasted
  - [ ] 0.3 [M0-VERIFY] executed — accept: every item answered YES/NO + evidence pasted below
  - [ ] 0.4 reflaxe.CPP hello — accept: 2-module hello compiles, C++ layout documented, runs
  - [ ] 0.5 SDL window test pattern — accept: runtime.Main draws gradient VRAM via bp_present
  - [ ] 0.6 headless hash mode — accept: `run-pc.sh demo --headless-hash 600` stable across two runs
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

| # | Item | Answer | Evidence |
|---|---|---|---|
| 1 | `haxelib dev` works from the submodule `main` branch, or is the pre-built `nightly` branch required? (their haxelib.json differ) | | |
| 2 | Which `reflaxe` base commit pairs with the pinned reflaxe.CPP commit (4.0.0-beta lineage)? Pin both. | | |
| 3 | Two-module hello → output layout is `include/*.h` + `src/*.cpp` + `_main_.cpp` + `_GeneratedFiles.json`, and our CMake glob builds it | | |
| 4 | Haxe 4.3.7 x64 tarball runs under Rosetta; haxelib works with project-local NEKOPATH; `.haxelib/` isolation confirmed | | |
| 5 | `-D cxx_exceptions_disabled` compiles hello + a runtime-shaped file (then add `-fno-exceptions` to CMake); if std breaks, fall back to policy-only | | |
| 6 | RawBytes: 2 MB `Stdlib.malloc` + `ccast` → `CArray<UInt8>`; inline get/set produce raw indexing in the emitted C++; 1M-op loop timed | | |
| 7 | Extern C binding of `bp_log`/`bp_present` against a stub .c; `String`→`ConstCharPtr` mechanics; `Ptr` into a RawBytes interior | | |
| 8 | `untyped __cpp__` expression **and** statement forms with `{0}` interpolation compile | | |
| 9 | `cxx.num.Int64` arithmetic (32×32→64 multiply, shifts, sign) emits plain `int64_t` ops; no accidental `haxe.Int64` pull-in | | |
| 10 | What backs Haxe `Array<Int>` and `String` in the emitted C++ (document for the init-only allowance); bounds behavior | | |
| 11 | `-dce full` + a dispatch-table reference keeps functions alive without `@:keep` (open upstream issue: not honored) | | |
| 12 | `inline` effectiveness of RawBytes accessors in the emitted C++ (or reliance on clang -O2 — inspect) | | |
| 13 | CLAUDE.md `@AGENTS.md` import actually loads (run Claude Code in-repo, check `/context`) | | |
| 14 | The installed Codex CLI auto-reads AGENTS.md from the repo root; note its version | | |
| 15 | reflaxe.CPP's `-D cmake` emission — 10-minute look; ours stays authoritative either way | | |
| 16 | `Sys.args()` works under reflaxe.CPP (its std overrides Sys; generated `_main_.cpp` is `int main(int, const char**)`). Fallback: launch config via storage, or a `bp_args` accessor | | |
| 17 | Integer overflow semantics: does the emitted C++ rely on signed `int` overflow (UB)? Decide `-fwrapv` in CMake and record in ADR-0001 | | |
| 18 | Function-reference values of type `(CpuState, Memory)->Void` lower to plain C function pointers, not `std::function` — else switch FnTable to the packed-Int-handle Plan B | | |
| 19 | `haxe --no-output` typechecks generated code against the runtime classpath on 4.3.7 (used by the tool's end-to-end test) | | |

## Blockers & open questions

- None blocking. Known unknowns are tracked as `[M0-VERIFY]` items above and as the open
  questions in `games/crashbash/notes.md`.

## Session log (append-only, newest-first)

2026-08-08 [claude] M0.1 done: AGENTS/CLAUDE/PROGRESS/LICENSE/.gitignore, ADR-0001 + template,
  docs/architecture.md, docs/specs/{tool,runtime,backend}.md, dir skeleton, games/crashbash +
  games/spyro3demo configs. Verified both EXE headers + SYSTEM.CNF from the user's dump (TCB=4,
  EVENT=16, STACK=801FFF00 are load-bearing for kernel HLE). Added filesDir input mode and the
  PS2/console target matrix. Next: M0.2 toolchain fetch.
2026-08-08 [claude] master plan written incl. verified reflaxe.CPP facts; next: commit M0.1 docs
