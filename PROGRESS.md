# PROGRESS — recompsx (single source of truth; see AGENTS.md session protocol)

## Status snapshot

**2026-09-08: scalar-register and structured code generation is verified (ADR-0007).**
GPRs become Haxe locals, with publication/reload at calls and due pumps. Linear chains and
conditional self-loops use native control flow while retaining every block's resume index and
a single copy of its body. Crash Bash's 1358 functions now contain 916 block dispatchers instead
of 1212, plus 231 native loops. `gen --no-opt` retains the context-field/dispatcher reference.
Both modes also correct JALR-zero tail transfers, conditional linked calls, cycle wrapping and
immediate halt/unwind propagation. The halt correction changes this checkout's 3000-frame game
digest from `d8ab3d52` to `6bd5e3fd`; optimized/reference JS and optimized C++ agree. This does
not add load-delay accuracy or overflow exceptions. Spyro 3's 633 functions / 47 switch tables
also generate and compile to JS (not a full-game execution check).

Acceptance output, 2026-09-08:

    ./scripts/check.sh
      check.sh: clean
    ./scripts/test.sh
      all 194 checks passed
      conformance: 11 test(s) x 2 targets
      Codegen    818e2901   values=13907
      conformance: all targets agree
      test.sh: both targets agree — 329de455
    node out/_gen/game.js web/boot.exe web/disc.bin --headless-hash 3000
    ./out/_gen/build/recompsx web/boot.exe web/disc.bin --headless-hash 3000
      [info] distinct unimplemented things reached: 0
      [info] frames=3000 digest=6bd5e3fd

Scalar locals exposed reflaxe's declaration mover producing duplicate declarations and moving
declarations past reads. Three synthetic MIPS reproductions now pass on both targets; patch
0005 is exported and applied idempotently by `scripts/setup.sh`, with existing pins preserved.

Measured on macOS 26.5.2 / ARM64, five-run medians after warm-up, alternating modes, no builds
running during timing. `./scripts/bench-codegen.sh` regenerates and checks both loop variants;
each reports `result=2120718581 cycles=450000010` on both targets.

| Workload | Target / baseline | Baseline | Optimized | Result |
|---|---|---:|---:|---|
| 50M MIPS xorshift iterations | JS / `--no-opt` | 0.6747 s | 0.1603 s | 4.21x |
| 50M MIPS xorshift iterations | C++ / `--no-opt` | 0.0896 s | 0.0871 s | 1.03x; small |
| Crash Bash, 3000 frames | JS / corrected `--no-opt` | 4.026 s | 4.036 s | no measurable gain |
| Crash Bash, 3000 frames | C++ / pre-change build | 3.009 s | 2.839 s | 1.06x in this run |

The original JS game took 4.095 s. The C++ whole-game comparison includes the halt/call fixes;
it is not an isolated optimization comparison. Do not extrapolate the loop speedup to a game.
Release/null binary size: 5,495,880 → 5,545,416 bytes (+0.9%). JS size:
14,594,319 → 15,228,737 bytes (+4.3%; corrected reference 15,045,100). Generated Haxe grows
6,623,130 → 8,436,743 bytes versus the reference because boundary synchronization is explicit.
Raw samples and structure counts are in ignored `out/_codegen/{game-benchmark,structure}.json`
and `out/_codegen_bench/results.json`.

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

**2026-08-09: the bring-up game boots to its first screen.** Crash Bash NTSC-U reaches "Sony
Computer Entertainment America Presents" — it initialises libcd, reads its own filesystem, loads
`CRASHBSH.DAT`, runs code out of it, uploads artwork to VRAM and composites it. The same build
runs headless under Node and live in a browser: one JavaScript shim, two hosts, chosen by whether
the page supplied `globalThis.recompsxHost`.

The last stretch was a chain of seven defects where each one hid the next, and the shape of it is
worth keeping: **every layer worked except the one below it**, so the symptom never named the
cause. A CD that answered every command but never streamed a sector; a driver that was never
installed because a `setjmp` return value was left to chance; ordering tables walked faithfully
after being built out of uninitialised memory; a game waiting not on sound but on being told that
sound had finished. Nothing here was a missing feature that announced itself.

**2026-08-09: overlays are done, and the boot screen is now reproducible from the disc alone.**
A game bigger than RAM is compiled as several *universes* — the executable, and the executable
with each overlay's bytes laid over its window — and which one answers at run time is decided by
fingerprinting what is actually in the window. Crash Bash's two overlays are 41 lines of committed
config pointing at disc offsets; no capture file exists anywhere in the build, which is what
golden rule 4 requires and what the reverted first attempt got wrong. The design is ADR-0006.

The work left the run bounded for the first time: `--headless-hash <frames>` stops a game whose
main loop never returns, by sending a halt down the same road a `longjmp` travels, and prints one
digest over VRAM plus twenty-two deterministic counters. That is what makes a *game* — not just a
demo — comparable between JavaScript and reflaxe.CPP.

**The CD dialogue is now correct end to end, and the boot has no dead time in it.** Four separate
causes had been hiding behind one symptom each. The controller's interrupt enable belongs to the
BIOS, not to the game — starting it at zero cost seven seconds of every boot while libcd timed
out and re-armed a controller nobody had armed. Halfword stores to the CD page reached no device
at all, because `slowWrite16` had a branch for every peripheral except that one. `CdlPlay` and
`CdlStop` answered with errors. And `Test 04h`/`05h` — two sub-commands in libcd's CD-audio
startup — answered with errors too, which made the game abandon and restart a ten-command
sequence three times a second for as long as it ran. None of these announced itself; each was
found by asking the machine what it actually did, one register write at a time.

## Next up (ordered)

Codegen follow-up: profile multi-block hot loops before extending CFG structuring; reduce
boundary synchronization only with proven liveness and callback/resume tests (ADR-0007).

1. **M2 kernel HLE — done.** Crash Bash makes **no unimplemented kernel call**: every A0, B0, C0
   and syscall it reaches is handled, and both targets produce identical output across 238 lines.

   The whole surface is implemented, not only what this game touches: the C library and heap,
   `printf`, file descriptors and the TTY, events and interrupt chains, critical sections, COP0,
   threads, `setjmp`/`longjmp`, kernel timers, the device table, the GPU helper calls (which
   forward to GP0/GP1 and start working the moment those registers exist), and the kernel's own
   RAM tables at 100h/200h/674h/874h so a game that reads `GetB0Table` and jumps through an entry
   lands on a stub the runtime recognises.

   What is genuinely still blocked, and on what:

   - `cdrom:` files need ISO9660 — M1's remaining work.
   - `bu00:` files need SIO and a card image.
   - `longjmp` is wired end to end: generated functions take an entry-block parameter, every call
     is followed by `if (ctx.unwindToken != 0) return;`, and `Runtime.callAndResume` dispatches
     afresh from the saved `pc`. What is *not* built is block-granular resume — a saved return
     address in the middle of a block cannot be entered there, because call sites are not block
     leaders. Landing on a function entry works; landing mid-block reports the address. Making it
     general means promoting call-return sites to leaders and emitting a block table, which is
     worth doing when a game is found that needs it.
   - `qsort`/`bsearch`/`lsearch` take a comparison callback, which means calling back into
     recompiled code from a sort — possible, but no game seen so far calls them.

   **The GPU register file is in**, and `GPU timeout` is gone — `ResetGraph` completes. GPUSTAT is
   assembled on every read from the state the commands set plus the beam position, rather than
   stored, so a game polling it sees something that moves without an event having to fire. Bits 26
   and 28 read ready always, which is the truthful answer for a model where drawing is instant.

2. **The game renders. Pixels of its own making are in VRAM.**

   Two things stood between Crash Bash and a picture, and neither was the CD.

   **DMA channel 2.** Psy-Q does not write GP0 a word at a time — `DrawOTag` hands the GPU an
   ordering table and DMA walks it. With no controller, every display list went into an
   unimplemented register. Twenty-nine GP0 words in eight minutes of play was not a game with
   nothing to draw; it was a game whose drawing went nowhere. Channel 2's linked-list and block
   modes turned that into 544 commands.

   **GP0(A0h), the CPU-to-VRAM upload.** An opcode census of a whole frame settled what the
   display list actually holds: 364 NOPs, 159 cache-clears, one rectangle for the screen clear,
   and **three uploads**. No polygons at all. That is how a game puts an image on screen without
   drawing anything — fonts, logos and loading screens are uploads, not primitives. A transfer
   arms itself once its header completes, since the size is only known then, and writes two
   pixels a word wrapping within VRAM's torus as the hardware does.

       gpu 552w/16c/1prim/261121px/1056up      618 non-zero pixels
       content at VRAM x896..927, y256..384

   Counting an upload's words and discarding them renders a game that draws nothing as a game
   that shows nothing, and from outside the two are identical. That is what made the CD look like
   the blocker for most of a day.

   **Still open, now secondary:** `CdInit` fails after fourteen candidates eliminated by
   measurement, so no level assets load and most of the screen stays empty. The escalation
   ladder's answer is unchanged — capture the same exchange in DuckStation with a CD-register
   breakpoint and diff it against our `cd#` trace. What changed is that the path behind it is
   proven all the way to visible pixels.

3. **M1 remaining** — BIN/CUE + ISO9660 + `filesDir` loaders, overlay extraction, syms.txt/.map
   import. The PS-EXE path works; the disc path is untouched, and overlays need it.

4. **Report the reflaxe defects upstream** — three now, with minimal repros already in
   `tests/spike/{ifdrop,guard,bbswitch}` and patches in `vendor/patches/000{1,2,4}`. Defect 9
   (`continue` deleting preceding statements) is the one that matters most to anyone else using
   reflaxe for generated code.

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
- [~] **M1 (L)**: tool — loaders, disasm, discovery, coverage report
  - [x] PS-EXE loader, R3000A decoder, disassembler — accept: golden tests green ✔ 2026-08-08
  - [x] function discovery + CFG + coverage report — accept: coverage printed for both games
        ✔ 2026-08-08. Crash Bash: 844 functions, 46,705 instructions, code ends at 0x8004c564,
        **25.0% of the code region unreached**. Spyro 3 demo: 597 functions, 70,351 instructions,
        **26.1% unreached**. The raw whole-image percentages (42.8% / 68.1%) differ only because
        the games have different data/code ratios; the code-region figure is the comparable one,
        and two unrelated engines agreeing at ~25% suggests it is the honest cost of static
        analysis rather than a defect in ours. 134 tool tests green.
  - [x] jump-table + BIOS-call recovery ✔ 2026-08-08 — and it was the lever it looked like:

        | | Crash Bash | Spyro 3 demo |
        |---|---|---|
        | unreached in code region | 25.0% -> **19.3%** | 26.1% -> **5.2%** |
        | switch tables recovered | 17 (381 arms) | 47 (1108 arms) |
        | BIOS calls identified | 41 | 16 |
        | computed jumps still unresolved | 55 -> **1** | -> 8 |

        Two findings drove it. Most "unresolved computed jumps" were not switches at all but
        **BIOS calls**: Psy-Q reaches the kernel with `addiu $t2,$zero,0xB0 / jr $t2 / addiu
        $t1,$zero,N`, so constant propagation plus reading the delay slot identifies both the
        vector and the function number. And the recovery pass has to run **after** the prologue
        sweep as well as before it, since swept functions contain computed jumps of their own —
        missing that was leaving two thirds of them unexplained.
  - [ ] BIN/CUE + ISO9660 + filesDir loaders, overlay extraction
  - [ ] syms.txt / .map import; optional Psy-Q signature naming (docs/specs/tool.md §2.1)
- [~] **M1.5 (M)**: scale spike — run early against the real game rather than a synthetic one,
      because the real one was available. Findings 2026-08-08:

      | Stage | Result |
      |---|---|
      | `recompsx gen` on Crash Bash | 861 functions, 11 files, **87,547 lines**, 0.9 s |
      | Haxe typecheck | 0.95 s |
      | Haxe → JavaScript | 3.7 s, 6.9 MB, **and it runs** |
      | Haxe → C++ (reflaxe.CPP) | **fails: "Uncaught exception Stack overflow" after ~19 s** |

      **The C++ target does not currently scale to a whole PS1 game.** Not fixed by raising the
      OS stack to 64 MB (so it is Haxe's eval stack, not the process stack), nor by
      `-D analyzer-optimize`, nor by cutting shards from 120 functions to 25 — which rules out
      per-file size and points at either one large function's expression tree or something
      global. 88 K lines is not a lot; this is a limit in a v0.1.0 compiler, not in the approach.

      **Bisected 2026-08-08.** `gen --limit N` emits the first N functions by address; binary
      search over N puts the boundary at exactly 860 functions passing and 861 failing — roughly
      87,500 lines. Everything that would explain a *structural* cause has been ruled out:

      - Not one large function. Function 861 is `f_8004c55c`: one block, three instructions.
      - Not per-file size. 25 functions per shard fails identically to 120.
      - Not the dispatch table's 861-element array literals. Replacing them with `[0]` still
        overflows.
      - Not the process stack. 64 MB changes nothing, so it is Haxe's eval stack.
      - Not the analyzer, in either direction.

      So it is cumulative: some recursion inside reflaxe.CPP grows with total program size and
      runs out of eval stack a hair past where Crash Bash lands. A slightly smaller game would
      compile and a slightly larger one would not, which makes this a hard blocker rather than a
      tuning problem.

      **Fixed 2026-08-08, in the vendored fork.** The stack trace named
      `reflaxe/preprocessors/implementations/RemovePureExpressionsImpl.blockElement`, which walked
      a block's statement list by recursing once per element. Every call was in tail position, so
      it is now a loop. The whole game generates C++ in **63 s, 19 files, 2.1 MB**.

      Reading that file to fix the recursion also turned up the cause of upstream defect 8 —
      see below. Both patches are exported to `vendor/patches/`.

      **Full M1.5 numbers, Crash Bash, 861 functions:**

      | Stage | Result |
      |---|---|
      | `recompsx gen` | 11 files, 87,547 lines, 0.9 s |
      | Haxe typecheck | 0.95 s |
      | Haxe → JavaScript | 3.7 s, 6.9 MB — **runs** |
      | Haxe → C++ | 63 s, 19 files, 2.1 MB |
      | clang -O2 | 9 s, **2.1 MB binary** |

      Every threshold in the original plan is met with room to spare. The binary size is the
      number that matters for the console targets: 2.1 MB of code against a 32 MB machine, with
      3.5 MB of emulated hardware state and ~7 KB of dispatch table. The memory budget in
      `docs/specs/backend.md` §0 holds.

      **Correction:** this table first recorded a 340 KB binary. That figure was measuring a
      program with 86% of its basic-block bodies deleted by upstream defect 9 (below) — a
      compiler bug flattering a benchmark. 2.1 MB is the honest number.

  - [x] **The recompiled game runs on JavaScript.** `build/game-js.hxml` compiles out/gen in
        **4.5 s** with `-D analyzer-optimize` and `node` executes it. It gets through Crash Bash's
        real startup, in this order:

            A0(39h) InitHeap        the kernel heap the game asks for at boot
            A0(49h) GPU_cw          a GP0 command word — the GPU being set up
            SYS(01h) Enter…         a critical section opening
            A0(44h) FlushCache      immediately after a code copy — an overlay landing
            SYS(02h) Exit…          and closing again
            mfc0/mtc0 COP0 r12      the status register: interrupts being set up
            GTE control 24..30      the projection constants

        **The image is loaded now, and it changed the picture.** `ExeLoader` copies the payload
        from offset 0x800 to the load address `GameInfo` recorded at build time. With real bytes
        in RAM, `InitHeap` reports **1,569,644 bytes at 0x80078c98** instead of zero — a sane
        1.5 MB heap for a 2 MB machine — and the game reaches calls it never got to before:
        `B0(19h)`, `A0(72h)`, `B0(35h)`. That is the difference between running on the game's own
        data and running on a memory full of nothing.

        **Both targets, and byte-identical.** An earlier note here claimed arguments do not reach
        Haxe under reflaxe.CPP and marked [M0-VERIFY] 16 answered NO. That was wrong, and the
        mistake is worth keeping: the C++ build had been compiled with an ad-hoc `clang++` line
        over `cpp/src/*.cpp`, which pulls in reflaxe's `_main_.cpp` — the one whose `main`
        discards argv — and never links `main_pc.cpp`, which is the file that exists precisely to
        capture it. The architecture was right and the build command was not. Diagnosing a
        bypassed build path as a platform limitation is an easy way to design around a problem
        that is not there.

        Fixed properly instead: `main_pc.cpp` now takes its entry class as a compile definition,
        CMake reads that class out of the `_main_.cpp` it excludes (so nothing is told twice), and
        `build-pc.sh --null` builds against the null backend with no SDL2 dependency. Running both
        targets on the real executable gives the same 35 lines, in the same order.

        Names verified against psx-spx "BIOS Function Summary", not written from memory. The
        first three are now implemented: `FlushCache` is a genuine no-op under static
        recompilation — there is no instruction fetch to invalidate — and the critical-section
        pair became a depth counter, which makes nesting work the way the hardware's single flag
        never had to. `InitHeap` and `GPU_cw` are next, and both need real subsystems behind
        them rather than a stub.

        and then spins. The spin is *correct behaviour for what exists*: having enabled
        interrupts and configured the GTE, the game waits for VBlank, and there is no scheduler
        to deliver one yet. Seven hundred instructions of real game code executed to reach that
        point, through the dispatch table, the memory map, and the emitted arithmetic.

        That list is also the M2 work order, written by the game itself in the order it needs
        things — worth more than any checklist drawn up in advance.

        Two entries were wrong when first recorded here, both because the diagnostic was.
        `Kernel.syscall` reported the instruction's 20-bit code field, which compilers emit as 0
        essentially always; the function is selected by **$a0**. So every syscall printed
        `syscall 0`, and because `reportOnce` keys on what it prints, the *second* distinct call
        was suppressed entirely — a diagnostic that could not distinguish anything was also
        hiding something. It now reports `$a0`, and the game turns out to open and close a
        critical section around its early setup (`a0=1` then `a0=2`).

        The A0 function numbers above are deliberately not named yet: naming them from memory is
        exactly what golden rule 6 forbids. They get names when each is implemented against
        psx-spx.

  - [x] **The C++ build now matches JavaScript, and the cause was upstream defect 9.**
        `Fns_04_8002c97c::dispatch` missed `case 14` on the first dispatch. Chasing it down
        found something far larger: **86% of the switch-case bodies in the generated C++ were
        empty** — 1119 of shard 4's 1296 `case` blocks compiled to a bare `break;` while
        JavaScript kept the statements.

        One line in `RemovePureExpressionsImpl.blockElement`:

            case TContinue: { acc = []; el = tail; continue; }

        `continue` ends a block: everything *before* it must be kept and everything *after* it is
        unreachable. This cleared `acc` — the statements already collected, which are the ones
        before — and then walked the tail anyway. Exactly backwards, and the same shape as
        defect 8's inverted return, sixty lines away in the same file.

        Invisible in ordinary code, total in ours: every recompiled function is a
        `while(true) switch(bb)` state machine whose cases end in `bb = N; continue;`, so this
        deleted the body of nearly every basic block. The dispatch symptom followed from it — with
        the arms gutted, clang folded a 91-case switch into a 13-comparison tree with no jump
        table, and `case 14` was not in the compiled code at all.

        Fixed in `vendor/patches/0004-reflaxe-continue-deletes-preceding.patch`. Empty case blocks
        in shard 4: 1119 → **0**. The C++ build now produces the same startup sequence as
        JavaScript, call for call, and waits for the same VBlank.

        Reduced to `tests/spike/bbswitch/` — a four-block state machine assigning to fields — so
        `scripts/spike.sh` reports if upstream fixes it.

- [~] **MO (L): overlays** — the design is in the approved plan; four stages, each gated on its
      own acceptance output being pasted here before the next begins.

  - [x] **S1 config + disc access** — accept: config-driven `gen` is byte-identical to the
        flag-driven invocation it replaces, and idempotent ✔ 2026-08-09

        `games/<id>/game.json` now carries the seeds that were living in a command line in
        notes.md, and `gen` reads the executable out of the disc that the gitignored `local.json`
        names — so a build depends on the repository plus somebody's own dump, and on nothing
        that was extracted by hand. New: `config/GameConfig.hx`, `loader/DiscImage.hx`,
        `loader/IsoWalk.hx`; `gen` takes either a config or a bare executable.

        Evidence:

            $ recompsx gen <SCUS_945.70> --out out/gen_baseline --seed 0x80031d28 ... (6 seeds)
            wrote 12 files, 106129 lines to out/gen_baseline
            957 functions, 17 switch tables

            $ recompsx gen games/crashbash/game.json
            wrote 12 files, 106129 lines to out/gen
            957 functions, 17 switch tables

            $ diff -r out/gen_baseline out/gen
            IDENTICAL: config mode == flag-driven, byte for byte

            $ recompsx gen games/crashbash/game.json --out out/gen_twice && diff -r out/gen ...
            IDEMPOTENT: two runs, identical trees

            check.sh: clean
            conformance: 6 tests x 2 targets, all agree
            js digest = c++ digest = 329de455

        Two notes for later stages. The tool's disc reader deliberately duplicates the layout
        detection in `src/runtime/cd/Iso9660.hx` rather than sharing it: one reads through the
        backend ABI into a `RawBuf` under the portable subset, the other through `sys.io` into
        `haxe.io.Bytes`, and unifying them means building the byte-buffer abstraction
        `shared/psxdisc` was meant to be — worth doing as its own change, not inside this one.
        And overlay stanzas parse and validate now but nothing reads them until S2.

  - [x] **S2 universes + emission** — accept: synthetic tool tests cover the call policy, two
        universes' tables, sharing and determinism ✔ 2026-08-09

        The executable is one *universe*; each overlay is another — the executable with that
        overlay's bytes laid over its window, analysed on its own, because while it is resident
        that is what the memory holds. Overlay passes are scoped to their window (the base is
        analysed once) and lenient inside it (code and artwork are adjacent with no linker map, so
        a wrong boundary costs one dropped function rather than the build). Shard indices are
        program-wide, classes are prefixed `Ovl_<id>_`, and a generated `Overlays.hx` carries each
        window, its FNV-1a fingerprint and its own dispatch rows as flat integer arrays.

        The call policy is the whole cost model, and it is three cases: a call inside the
        executable stays a direct call; a call *into* a window becomes a dispatch, because nothing
        at build time knows which overlay is loaded; a call from an overlay into its **own** window
        stays direct, because the caller running proves the callee is resident. Identical function
        bodies in two universes are emitted once and forwarded to, which is where a console gets
        its size back.

        Evidence:

            $ haxe build/tests-tool.hxml
              overlay: a call into a window is dispatched, one inside the base is not
              overlay: an overlay calls the base directly and itself directly
              overlay: two overlays in one window keep their own classes
              overlay: identical code is emitted once and shared
              overlay: the generated table describes both windows
              overlay: the executable's own table excludes overlay code
              overlay: generation is deterministic
              overlay: two overlays the runtime could not tell apart are refused
            all 175 checks passed          (150 before; 25 new)

            $ recompsx gen games/crashbash/game.json --out out/gen_s2 && diff -r out/gen out/gen_s2
            wrote 13 files, 106232 lines
            957 functions, 17 switch tables
            (only difference: the new Overlays.hx, and two doc lines in FnTable)

            check.sh: clean
            conformance: 6 tests x 2 targets, all agree
            js digest = c++ digest = 329de455

        A game with no overlays configured therefore generates what it generated before, which is
        the property that made this safe to land ahead of any real overlay. Nothing dispatches
        into `Overlays` yet — that is S3, and until then the file is written and unread.

  - [x] **S3 runtime activation** — accept: a conformance test drives the whole state machine and
        both targets agree ✔ 2026-08-09

        `kernel.OverlayMgr` decides which code is in a window. The runtime installs nothing: the
        game loads its own overlays through hardware that is already emulated, so RAM already
        holds the right bytes and only the address-to-code mapping has to follow. Three signals:
        a load into a window **evicts** (what was compiled for those addresses is gone, even if
        what replaced it is artwork — the half a fingerprint cannot see); `FlushCache` **rescans**
        (a real machine cannot see newly written code until then, so every loader ends there,
        which makes it the one complete checkpoint); and a dispatch that misses inside a window
        rescans **once** before reporting.

        Recognition is FNV-1a over the window's first words against the value the tool computed.
        The same seven lines exist in three places — `recomp.codegen.Universe`,
        `kernel.OverlayMgr` and the test — deliberately, because a fingerprint that differs by one
        bit between targets activates an overlay on one and not the other.

        Evidence:

            $ ./scripts/conformance.sh Overlay
              ok   Overlay    7564ec5d   values=43
            conformance: all targets agree

        *Revised during S4 bring-up and the audit that followed.* The real game replaced the
        exclusive-windows model with nesting (a 32 KB overlay loads into the middle of a 378 KB
        one and both are genuinely present; the smaller window answers where they share), and the
        audit added KSEG canonicalisation and the resident-but-no-row diagnostic. The test grew
        with each: digest `9fdcde0f`, 54 values, both targets agreeing throughout.

            $ ./scripts/test.sh
            conformance: 7 test(s) x 2 targets — all agree
            js digest = c++ digest = 329de455
            check.sh: clean

        The test found one thing worth recording: when two windows overlap and the bytes of the
        second are overwritten, the *first* is recognised again and takes back the shared
        addresses. That is correct — at any moment exactly one thing is in memory, and "whichever
        one's bytes are actually there" is the only answer that can be right — and it was the
        assertion that was wrong, not the code.

        **Two deviations from the plan, both deliberate.** There is no `--record-overlays` flag
        and no `overlays.suggested.json`: instead a miss reports the span the disc was read into
        that covers it, with the numbers to paste. Same information, no new flag, no new file, and
        it is the form that actually got used when this problem was first met. And load *matching*
        by disc key is not implemented — a load only evicts, and the fingerprint at `FlushCache`
        is the sole authority on identity. It is complete on its own, and the LBA plumbing would
        have bought a second, weaker answer to a question already settled.

        On the real game, with no overlays configured yet, the diagnostic now reads:

            no function at 0x80092bdc (ra=0x80010478) — but the disc was read into
            0x80078c90..0x800d7490, which covers it. That is an overlay: code the executable
            never held, so the tool never saw it. Add it to games/<id>/game.json with
            loadAddr 2147978384 length 387072 and entryHint 2148084700.

  - [x] **S4 Crash Bash end-to-end + ADR-0006** — accept: the game generated from disc and config
        alone, running on both targets to the same digest ✔ 2026-08-09

        Two overlays, found by running the game and reading what the misses said, written into
        `games/crashbash/game.json` as disc offsets: `boot` (387072 bytes at 0x80078c90) and
        `stage` (32768 bytes at 0x800b32b4, inside boot's window). **No capture file exists
        anywhere in the build** — the tool opens the disc the gitignored `local.json` names and
        reads the extents itself.

            $ ./scripts/recompsx.sh gen games/crashbash/game.json
            wrote 21 files, 180722 lines to out/gen
            963 functions, 17 switch tables
            overlay boot: 0x80078c90..0x800d748f (387072 bytes): 319 functions, 26 rejected as data
            overlay stage: 0x800b32b4..0x800bb2b3 (32768 bytes): 66 functions

        The audit that closed the stage found eight things; the four that were defects are fixed
        and now have tests. A resident overlay **shadows** the executable even where it has no row
        (falling back to the base table would run code the game overwrote); the executable's own
        functions *inside* a window are dispatched, never direct-called (same reason, and the
        window test now runs before the own-universe test); a window shorter than its own
        fingerprint is a build error (the tool clamped where the runtime would not, so the overlay
        could never activate); and the resident-but-no-row miss now names the overlay and the hint
        to add instead of implying nothing is loaded. The rest were documentation — the
        fingerprint-region-only eviction rule and its accepted cost are in ADR-0006 and in the
        `OverlayMgr` header — plus KSEG canonicalisation on every address entering the manager and
        an unsigned-decimal printer, because `x >>> 0` still prints negative through C++.

        **The overlay program compiles and runs through reflaxe.CPP**, which nothing had yet
        proved: eight `Ovl_*` translation units, and the two builds agree to the bit.

            $ ./out/_gen/build/recompsx SCUS_945.70 disc.bin --headless-hash 600
            frame 600 | events 5057 | irqs 992 | handlers 1479 | delivered 215/0cb
              | dma 523w/1list/98880cdw | gpu 552w/16c/1prim/261121px/1056up
              | cd 19cmd/192sec/215irq/1drop | spu 109656hw/72kon/442318smp
            frames=600 digest=7e32dc6d          # C++
            frames=600 digest=7e32dc6d          # JavaScript, every counter line identical

        Comparing a *game* at all is new. Its main loop never returns, so `--headless-hash
        <frames>` stops one from inside: `Kernel.UNWIND_HALT` travels the road a `longjmp` already
        travels — every generated call site returns when a token is set — and nothing catches it,
        so `Runtime.callAndResume` stops instead of resuming. The digest is VRAM plus twenty-two
        deterministic counters, because either half can agree while the machine differs: the
        picture alone would miss a dropped interrupt, and the counters alone would miss a wrong
        pixel. C++ runs the 600 frames in 0.31 s against JavaScript's 1.91 s.

        Two things found on the way, both instruments rather than features. `core.Hash` — what
        every digest in this project is measured with — had **no test at all**, and `Hash.word`
        was the exact shape upstream defect 1 mishandles: a multi-statement `inline` whose
        parameter is used four times. It is correct on both targets, but that was luck until
        `tests/conformance/HashFold.hx` (`a5b38872`, 69 values) made it a fact. And `check.sh`
        caught four bare integer divisions that lowered to `double` in generated C++
        (`Gpu.putTexel`, `Iso9660.totalSectors`, and two constant-folded ones in `Cdrom`/
        `KTables`) — ADR-0004 forbids `a / b` on Ints and these predate the rule's enforcement
        reaching generated output. Conformance digests are unchanged by the fix, as expected.

        Also measured, not acted on: **upstream defect 8 is fixed in the pinned fork.** All nine
        `spike-ifbody` cases pass, including a two-statement `if` with no `else` and an inverted
        guard clause. The `else {}` workaround stays everywhere for now — removing hundreds of
        them is its own decision, and `scripts/spike.sh` is the regression test that says when it
        is safe. (That script was also printing its own finding as a shell syntax error; fixed.)

  - [ ] **Deferred from S4, deliberately.** `shared/psxdisc` stays an aspiration: the tool and the
        runtime each keep a small disc reader (~150 lines apiece, three-layout autodetect proven
        twice) rather than being unified mid-feature. §6.2 multi-entry extent duplication is still
        the known gap it was; overlay tracing did not hit it.

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

1. **Inlined locals collide — FIXED IN OUR FORK.** Haxe's inliner materialises a callee's
   parameters and temporaries as locals in the caller's scope, always with the callee's own
   names, so two calls to the same inline function in one scope emitted two declarations of the
   same name: `redefinition of 'a'`. The `_this` / `this1` receiver temporaries were the same
   bug wearing a different name, and it also blocked `RawMem.get16`/`get32` (whose parameter is
   used more than once, so Haxe binds it) from being called twice in a scope — which generated
   game code would do constantly.

   Fixed on branch `recompsx-fixes` in `vendor/reflaxe.CPP`: every declaration and reference
   already funnels through `Compiler.compileVarName`, and Haxe gives each variable a unique id,
   so names are now made unique per function body — first claimant keeps the name, later ones
   get their id appended (`a`, `a_24018`). Three small edits: `Compiler.hx` (the map and scope
   push/pop), `Expressions.hx` (declaration and reference sites), `Classes.hx` (reset per
   function). Worth offering upstream.
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
8. **FIXED in our fork.** *An `if` with no `else` and more than one statement in its body was
   silently deleted.* The cause was one missing `!`:
   `RemovePureExpressionsImpl.hasSideEffects` returns true to mean "has side effects" in every
   branch except the composite one covering TBlock/TIf/TVar/TSwitch, which computed a local named
   `isPure` and returned it unnegated. `blockElement` then used that to rewrite
   `if (cond) { body }` into just `cond`, believing a body full of assignments and calls was
   side-effect free.

   That single inversion explains everything filed here: guard clauses compiling to their
   fall-through, loop bodies losing branches, ternaries vanishing. It also explains why it looked
   like a size limit — a one-statement body is not a `TBlock` and never reached the inverted
   branch.

   The `else {}` workarounds in `src/runtime` and `tests/conformance` stay for now, so the code
   still builds against an unpatched reflaxe until this is upstreamed. `scripts/spike.sh` reports
   the change of state. Original characterisation, kept because it is what a future occurrence
   would look like:

   | Shape | Result |
   |---|---|
   | `if (c) { one; }` | kept |
   | `if (c) { two; statements; }` | **entire `if` deleted** |
   | `if (c) { two; statements; } else { ... }` | kept |
   | `if (c) { one; }  if (c) { one; }` | kept |

   Not the body — the whole statement disappears, so execution continues as if the condition
   were never tested. Everything previously filed as separate shapes was this one rule: guard
   clauses (`{ ...; return; }` is two statements), loop bodies that also advance the index, and
   ternaries (which lower to several statements). It bit the conformance harness itself:
   `Conf.expect` compiled to `feed(actual);` alone, so every assertion silently passed on C++
   while failing on JS.

   Haxe's own `--interp` and `-js` compile identical source correctly, so this is reflaxe.CPP's
   alone. Root cause not yet located — `compileIf` and `isMutator` both look correct, so it is
   further up the preprocessor pipeline. Reported shape is minimal and ready to file upstream.

   *Workarounds, all verified:* add `else {}`; extract the body into a function call; or invert
   a guard into `if (!c) {} else { ... }`. `scripts/spike.sh` reports when upstream fixes it.

   **Related, and the one that cost the most time so far: `inline` on a multi-statement function
   is unsafe.** Writing `core.Ops.div`/`divu` took four attempts, each correct on JavaScript and
   wrong on C++ — a ternary inside a branch, guard clauses ending in `return`, an
   `if / else if / else` chain with two-statement bodies, and finally a one-statement-per-branch
   version whose helper was `inline`. Only removing the `inline` made both targets agree.

   Practical rule for `src/runtime`: reserve `inline` for single-expression accessors with each
   parameter used once (`RawMem.get8` is the shape that is safe). Anything with a body gets a
   plain call — the C++ compiler inlines it anyway, and none of this is a hot path in the sense
   that would justify the risk.

9. **FIXED in our fork: statements before `continue` were deleted.** The block walker cleared
   its accumulated statements instead of returning them. Patch 0004 and the `bbswitch` spike
   retain the reduction; the M1.5 section above records the game-sized failure and acceptance.
10. **FIXED by patch 0005: declaration motion loses reads or duplicates variable ids.**
    `RemoveReassignedVariableDeclarationsImpl` reused a candidate after moving it and missed
    reads in initializers/nested blocks. Scalar GPR locals exposed both `Logic error` during
    Haxe-to-C++ generation and undeclared C++ identifiers. `constantStores`, `loadThenRedefine`
    and `storeThenRedefine` in `TestCodegen` reproduce the failures; the Codegen conformance
    test passes on JS and C++ after the fix. Setup applies the exported patch (ADR-0007).

## Blockers & open questions

- **Why Crash Bash reaches an anti-piracy screen at all is untraced**, and it is the one thing
  standing between the boot sequence and the game. It is a fidelity question about our machine,
  not about the disc: the same run answers `GetID` as a licensed disc, handles the drive's
  `Test 04h`/`05h` sub-commands, and now reports a console region. One wrong answer has already
  been found and fixed this way — the console had no region at all, so the game drew the Japanese
  message — and the method that found it (measure what the game reads before it decides, one
  register at a time) is what to run again.
- **The kernel has no font**, and will need one the moment a game draws text through the ROM.
  `B0(51h) Krom2RawAdd` and `B0(53h) Krom2Offset` hand out addresses of glyphs in the BIOS font
  ROM. Measured from a real ROM's structure (a format, not its data): 16×16 glyphs, 32 bytes
  each, two bytes a row, most significant bit leftmost. A real BIOS cannot be in the repository
  (golden rule 4) and neither can anything derived from its bitmaps, so the answer is either
  glyphs of our own or a freely-licensed bitmap font — and if the text needed is Japanese, only
  the second is realistic. Crash Bash stopped asking once it knew what console it was on, so this
  is no longer blocking anything.
- Otherwise none blocking. Known unknowns are tracked as `[M0-VERIFY]` items above and as the open
  questions in `games/crashbash/notes.md`.

## Session log (append-only, newest-first)

2026-09-08 [codex] Added scalar GPR lowering and structured chains/self-loops (ADR-0007),
  corrected call/unwind semantics, and exported reproducible reflaxe declaration patch 0005.
  Gate: 194 tool checks, 11 conformance groups x2; game JS/C++ 3000-frame digest 6bd5e3fd.
  Loop JS 4.21x; whole-game JS unchanged, native 1.06x measured; next profile multi-block CFGs.

2026-08-09 [opus] The console now says what it is, and has a font. The ROM window at 0x1FC00000
  was not in the memory map at all — every read returned zero — so the region letter games test
  at `0x1FC7FF52` said nothing and Crash Bash NTSC-U drew its anti-piracy message in *Japanese*
  (the glyph codes decode to 強制終了しました。本体が…). Serving that one byte as 'A' ended fifty-six
  `Krom2RawAdd` calls. The English branch then reads glyphs straight out of the ROM —
  `0xBFC7F8DE + (char-33)*15`, measured from the game's own disassembly — so `mem.RomFont` serves
  ninety-four 8×15 glyphs drawn for this project. Uploads went 13 → 3733 and three lines of text
  appear. They rendered as strokes at first, and the font was ruled out — payload correct per
  pixel, and the real ROM's glyphs render identically — so it was the rasteriser. The warning
  screen writes text in two passes (white letters with bit 15 set, then a black pass over the
  cell), and on hardware a CPU-to-VRAM upload obeys the mask bits exactly as a drawn primitive
  does, so the black pass skips the letters. `putTexel` ignored the check and erased them.
  Implementing mask-check/mask-set in the upload path restored the text — and then a photograph
  of the real screen showed the circle should pass *behind* the words, which is the same rule a
  layer up: `plot()`, the primitive path, ignored the mask too, so the circle painted over the
  text. Three writers into VRAM (`plot`, `putTexel`, `blend`) and only one of them obeyed
  GP0(E6). The text then sat left of the original, which turned out not to be a placement bug at
  all: the game's message table is data in the executable — `{x, y, text}` per region at
  0x800678A0, x=36 for America, short lines centred by literal spaces in the string — so we were
  drawing exactly where it asked. The font was too narrow, five ink columns against fourteen
  rows, so every line ended early and read as shifted. Stretched to seven columns, the longest
  line lands at 36..296 against a screen centre of 160. **The screen now reads "SOFTWARE
  TERMINATED / CONSOLE MAY HAVE BEEN MODIFIED / CALL 1-888-780-7690" with the circle behind it,
  laid out as the original.**

2026-08-09 [opus] The `unimplemented:` list is down to one line. Memory-control registers
  (1F801000-1020, RAM_SIZE, cache control) stored with the BIOS's reset values — bus timing is
  not modelled, but a register a game writes and reads back must answer. Every SPU register that
  was reporting itself as "reverb, not yet" now stores and returns: reverb output volume, the CD
  and external *input* volumes (which were never reverb at all), the 32-word reverb block, and
  the current-volume registers, which without sweeps are the set volume. Timers 0 and 1 count
  real dot clocks and scanlines: whole periods fold out exactly — `VIDEO_DEN * divider` cycles is
  exactly `numerator` dots — and the residue converts with the numerator split so nothing passes
  2^31. `A0(ABh) _card_info` answers for an empty slot by posting the timeout event, which
  **fired the kernel's callback path for the first time since it was written** (`delivered
  590/6cb`) and exposed eight more functions nothing calls statically. Left: `B0(51h)
  Krom2RawAdd`, which needs a font of our own — it is why the anti-piracy screen draws its circle
  and none of its words.

2026-08-09 [opus] GTE, first half: `shim.I64` (the 44-bit accumulator ADR-0004 specified and
  nobody had written), the whole register file with its side effects — SXY FIFO push on the mirror
  write, IRGB/ORGB, LZCS/LZCR, H's sign-extend-on-read bug, FLAG's computed bit 31 — the UNR
  division, and the projection ops RTPS/RTPT/NCLIP/AVSZ3/AVSZ4. Tool side needed nothing: all
  seven COP2 forms already compiled to these calls. Two new conformance tests, both agreeing
  across targets: `Acc64` 0deeafe0 (carry chains and the exact ±2^43 / ±2^31 fenceposts) and
  `GteOps` 6a9d8047 (1304 values; hand-computed identity transforms, permutation matrices, NCLIP
  areas, one vector per FLAG bit, the divider's edges). The GTE register warnings are gone from
  the game's log. **A null check on `Array<Int>` cost a segfault C++-only**: the type is not
  nullable, so the guard folded away on one target and not the other — the table was never built.
  With two more `functionHints` (three one-line functions sit in a row at 0x800309ec/0a00/0a08 and
  the sweep found only the first), **the game draws geometry for the first time: 132 primitives
  where there was 1.** Next: MVMVA and the lighting family.

2026-08-09 [opus] CD protocol + interrupt correctness — **the boot stall and the command storm are
  both gone**. Four causes, none of them the one the log named. The controller's interrupt enable
  starts at 0x1F because the BIOS leaves it there and a game's library never re-arms it (seven
  seconds of every boot were libcd timing out and resetting a controller we had never armed);
  `slowWrite16` had no CD branch at all, so every halfword store to the CD page was read-modify-
  written into a register that does not exist; `Test 04h`/`05h` are part of libcd's CD-audio
  startup and answering them with INT5 made Crash Bash restart that whole ten-command sequence
  three times a second forever; and `CdlPlay`/`CdlStop` existed only as errors. Also: an interrupt
  raised inside a handler is now delivered before `Irq.dispatch` returns instead of waiting an
  unbounded time for the next pump. Frame 900 went from 1289 CD commands and 1705 dropped answers
  to 52 and 17. Next: S2, the GTE.

2026-08-09 [fable] Overlay S4 closes the milestone: two overlays from disc offsets in committed
  config, no capture anywhere; the audit's four defects fixed and tested (resident overlays
  shadow the base with no fallthrough, in-window base functions dispatch, a fingerprint longer
  than its overlay is a build error, misses name the overlay). `--headless-hash` bounds a game
  whose loop never returns — JS and C++ agree at `7e32dc6d` over 600 frames. New `HashFold` test
  covers the digest instrument itself; four Int divisions that lowered to `double` fixed.
  Next: the logged `unimplemented:` work, S1 (CD Play + IRQ latch) first.

2026-08-09 [opus] Overlay S3: `kernel.OverlayMgr` decides which code is in a window. The runtime
  installs nothing — the game loads its own overlays through hardware already emulated, so only
  the mapping has to follow. A load evicts; `FlushCache` rescans and identifies by FNV-1a over the
  window's first words; a miss inside a window rescans once. A miss *outside* every window now
  quotes the span the disc was read into, with the numbers to paste into game.json, which is how a
  new game's config gets written. New conformance test `Overlay` — both targets agree at
  `7564ec5d`; 7 tests x 2 targets. Next: S4, Crash Bash end-to-end and ADR-0006.

2026-08-09 [opus] Overlay S2: universes. Each overlay is the executable with its bytes over its
  window, analysed on its own — scoped so the base is analysed once, lenient inside the window
  because code and artwork are adjacent there. Program-wide shard indices, `Ovl_<id>_` classes, a
  generated `Overlays.hx` of windows, fingerprints and per-overlay dispatch rows. Call policy:
  direct inside the executable, dispatched into a window, direct from an overlay into its own
  window. Identical bodies emitted once. 175 tool checks (25 new); a game with no overlays
  generates what it did before. Next: S3, `OverlayMgr` and activation.

2026-08-09 [opus] Overlay S1: `gen` reads a game config and pulls the executable off the disc
  itself. `config/GameConfig.hx` (game.json + gitignored local.json, overlay stanzas, hints —
  decimal addresses folded into the tool's signed representation), `loader/DiscImage.hx`
  (CD001 probe picks 2048 / 2352+16 / 2352+24), `loader/IsoWalk.hx`. Crash Bash's six seeds moved
  out of a notes.md command line into `functionHints`. Byte-identical to the flag-driven output
  it replaces and idempotent across two runs; gate green. Next: S2, patched-image universes.

2026-08-09 [opus] **SOUND.** Twenty-four ADPCM voices, ADSR, one stereo pair every 768 cycles.
  The bug that would have hidden all of it: the SPU was reachable by halfword only, and libspu
  sets volume pairs — including the main volume — with one word store, so every voice was
  multiplied by zero. `tests/conformance/SpuVoice` writes a waveform by hand, keys a voice on and
  listens, then keys it off and listens for nothing; both targets agree at `d7680e93`. The game
  reaches real audio at 15.4s emulated: 92% of samples non-silent, peak 79% of full scale, and
  114–535 zero-crossings per half second, which is notes rather than noise. Browser plays it live
  through a SharedArrayBuffer ring that also paces the machine — a full ring means the game is
  ahead of what anyone can hear. Missing and written down: gaussian interpolation, noise, pitch
  modulation, reverb, gliding volume sweeps. **Overlay support was written this session and then
  reverted at the user's instruction** — it is a sensitive area and its design is theirs to plan,
  not something to arrive at sideways while chasing a symptom. Nothing overlay-shaped is to be
  written until they say so. One consequence, recorded rather than hidden: the boot screen and the
  audio above both depended on code the disc loaded, so the tool can no longer produce the program
  that showed them. Open on the runtime side: timers still run dotclock and hblank at system clock.

2026-08-09 [opus] **BOOT SCREEN.** Crash Bash NTSC-U shows "Sony Computer Entertainment America
  Presents", on Node and in a browser. Seven fixes in a chain, each hidden by the one after it:
  `enterJmpBuf` left `v0` alone, so the game's exception hook — installed via `setjmp` — could
  not tell "just installed" from "an interrupt brought me here" and never dispatched its CD
  driver; FnTable now maps every basic block, since a longjmp lands after a `jal` and never on a
  prologue; the sweep takes code following a return as a function (GCC hoists loads above the
  stack adjust); the CD re-arms after answering, honours Setmode bit 5, and clearing the request
  bit resets the FIFO rather than discarding the drive's sector; DMA 3/4/6 and GP0(80h) exist.
  Next: overlays are transient — a RAM capture describes one, and the game loads several into the
  same memory, so `--ram` wants the per-overlay identification of plan section 6.4.

2026-08-08 [opus] THE GAME RENDERS. Two blockers, neither the CD: DMA channel 2 (Psy-Q draws via
  ordering tables, so every display list went nowhere) and GP0(A0h) CPU-to-VRAM uploads (an
  opcode census showed a frame is 3 uploads and a clear, no polygons — fonts and logos are
  uploads, not primitives). 618 non-zero pixels at VRAM x896..927/y256..384. CdInit still fails
  and is now secondary; next is the DuckStation register diff.

2026-08-08 [opus] DMA channel 2 was the render blocker, not the CD: Psy-Q draws through ordering
  tables, so every display list went into an unimplemented register. With DMA + a minimal
  rasteriser the path is proven end to end — 23 draw commands became 544, 261,121 pixels reached
  VRAM. The frame dumps uniformly black: the only primitive Crash Bash sends is a screen clear,
  because CdInit still fails. 14 CD candidates now eliminated by measurement. Final trace fact:
  every CD register access is [poll], never [handler] — libcd drives the drive entirely from
  ordinary code. NEXT: DuckStation register-breakpoint capture, diffed against our cd# trace.

2026-08-08 [opus] CD dialogue fully traced: Getstat and Init both complete correctly, libcd acks
  both, then loops the whole init forever. Delivery/ordering/ack all proven working. Tell: libcd
  never reads the response FIFO — so the suspect is 1F801800's status bits, which it does read.
  Next: trace 1800 reads against psx-spx's bit table.

2026-08-08 [opus] Timer wrap clamp (froze all counters at 2^31), SIO0 empty port, HookEntryInt
  now invoked as the exception epilogue OpenBIOS documents. Game passes frame 120k. Measured:
  libcd installs NO chain element and opens NO event — only libpad does. CD route still
  unidentified; next probe is tracing 1F80180x reads outside dispatch to find CdSync.

2026-08-08 [fable] Frame-29100 stall solved by profiler, twice: report-once built its string
  before the dedup check (25% of ticks in StringAdd), and libpad's ACK timeout counts on timer 2
  which read zero forever. Landed: Timers 0-2 closed-form (§7.10), SIO0 as honest empty port,
  alreadyReported guard, cycleHint at every pump point. Game now passes frame 120k with its own
  handlers live. Next: where do 120k frames go — CD_init not reached yet.

2026-08-08 [fable] The CD handler black hole was the sweep seeding a prologue 8 bytes past the
  true entry (GCC schedules loads before addiu sp) — sweep now seeds gap starts. Retracted the
  phantom "6th-seed regression": host load made 40s runs reach frame 29k instead of 65k, same
  trajectory. Detour cost: stale out/gen shard files (writeTo now cleans? no — TODO), zsh not
  splitting $VAR seed lists, and a diff script that lied. Long run in flight; next reads cd#.

2026-08-08 [fable] Named the dispatch misses (address+ra), found libcd's function-pointer black
  holes, added `gen --seed`. Five seeds: libcd now unmasks CD+DMA itself, its handler installs and
  runs, CD interrupts deliver (irqs>frames, handlers~1.12x frames). CdInit still fails — next is
  the chain/RFE/HookEntryInt contract, readable in OpenBIOS kernel/handlers.c (MIT). Sixth seed
  regresses (entry-inside-extent truncation): tool needs §6.2 multi-entry duplication.

2026-08-08 [claude] GPU register file, cdrom: in both shapes (directory and image — ISO9660
  detects Mode 2 Form 1 on a real Crash Bash BIN), and the CD-ROM controller. Game now initialises
  libcd and issues 17 commands. Four candidates for its NoIntr eliminated by measurement; three
  were real bugs fixed on their own merits. Next: disassemble CD_init at 8006de94 to find what
  libcd's wait loops actually poll — the answer is a memory address, not a register.

2026-08-08 [claude] Kernel HLE complete: threads, setjmp/longjmp, timers, device table, GPU helper
  calls, kernel RAM tables, the rest of the C library. Crash Bash now makes zero unimplemented
  kernel calls and both targets match over 238 lines. Three reflaxe.CPP traps found and each one
  turned into a check.sh guard: a root-package class shadowing a system header, a static table
  built at its declaration, and an identifier that is a C macro (`errno`). Next: the GPU register
  file — libgpu is timing out on GPUSTAT.

2026-08-08 [claude] M2 kernel HLE: scheduler, interrupt controller, event system, priority chains,
  C library, heap, printf, file descriptors, TTY. Crash Bash reaches its main loop and prints its
  own libgpu output; both targets identical over 239 lines. Two of my own bugs found by my own
  guards (frame-length overflow, a non-wrapping cycle compare that diverged JS from C++) and one
  fidelity error corrected (critical sections are a flag, not a counter). OpenBIOS supplied the
  event status values psx-spx omits. Next: the GPU register file — the game is timing out on it.

2026-08-08 [claude] Designed time/scheduling/interrupts as one piece (ADR-0005) after the startup
  trace showed the game waiting on the event system, not on five separate stubs. TimeBase landed
  and pinned on both targets (VideoTime, 052bdaac). User found OpenBIOS: its files are MIT even
  though pcsx-redux is GPL-2, so it is the one non-spec source we may read and translate — added
  to the escalation ladder with the attribution rules; kernel stays HLE, we never run it.
  Next: Scheduler, then I/O dispatch so I_STAT/I_MASK have somewhere to live.

2026-08-08 [claude] Fixed reflaxe defect 9: `case TContinue: acc = []` deleted every statement
  BEFORE a continue, gutting 86% of the basic-block bodies in the C++ build (1119/1296 cases in
  one shard). C++ now matches JS call-for-call on the real game. Corrected the M1.5 binary size
  (340 KB was measuring deleted code; 2.1 MB is honest). First 3 kernel calls implemented from
  psx-spx. Next: load the program image into RAM — nothing does, so every load returns 0.

2026-08-08 [claude] Found and fixed BOTH of reflaxe's worst defects, sixty lines apart in
  RemovePureExpressionsImpl: an inverted return in `hasSideEffects` was deleting if-bodies
  (defect 8), and a per-statement recursion in `blockElement` was overflowing the eval stack on
  large programs (M1.5). Whole game now: gen 0.9 s -> C++ 63 s -> clang 7.7 s -> 340 KB binary.
  The JS build RUNS the recompiled game into Crash Bash's real init sequence; the C++ build
  mis-dispatches on the first call, which is now the top open item.

2026-08-08 [claude] Whole-program generation works: 861 Crash Bash functions -> 87.5 K lines of
  Haxe in 0.9 s. The JS build links in 3.7 s and RUNS — recompiled startup code clears its BSS,
  calls through several functions, and reaches A0(44h) FlushCache, COP0 SR access and GTE control
  writes, all reported as unimplemented. The C++ build hits a stack overflow inside reflaxe.CPP
  (M1.5 above); not caused by shard size, OS stack or the analyzer. Adopted `-D js-es=6` project
  wide; measured `-D analyzer-optimize` as behaviour-preserving but currently worthless.

2026-08-08 [claude] core.Ops (mult/div, hardware edge cases) + tests/conformance/Mul.hx. The test
  earned itself immediately: four successive formulations of div/divu were correct on JS and
  wrong on C++, and the last culprit was `inline` on a two-statement helper. Both targets now
  agree (b5a873d9). Added the resulting rule to upstream defect 8: in runtime code, `inline` is
  only for single-expression accessors. Conformance now covers Arith, Mem and Mul.

2026-08-08 [claude] First generated code. runtime/{core.CpuState, core.Ops, mem.Memory} written,
  then codegen.Emitter + `recompsx emit`. Emitting Crash Bash's real entry point reads correctly:
  BSS-clear loop closes on itself, branch conditions latch before their delay slots, jal writes
  the link before the slot, and the closing `jr $t2` comes out as `Kernel.call(ctx, 0xa0, ...)`
  — A0(51h), Load and Exec, exactly what an entry point should end with.

2026-08-08 [claude] Jump-table + BIOS-call recovery. Unreached code fell 25.0%->19.3% (Crash Bash)
  and 26.1%->5.2% (Spyro); unresolved computed jumps 55->1 and ->8. The big surprise was that most
  of them were kernel calls through a vector register, not switches. 150 tool tests green.

2026-08-08 [claude] M1 analysis: Image/Func/Discovery/Coverage + the analyze command. Runs on both
  real games. Building the tests found a real CFG bug — blocks overlapped because a later backward
  branch can make an address inside an already-traced run a leader, so tracing is now two passes
  (reachability + leaders, then cut). Instruction counts dropped 57k->47k accordingly while
  coverage held, which is exactly the signature of removing double-counting. Also answered the
  Psy-Q version question in docs/specs/tool.md §2.1: no per-version abstraction needed, because we
  recompile library code rather than reimplementing it; signatures are a naming convenience.

2026-08-08 [claude] M1: decoder + disassembler + tool CLI, 99 tool tests green. Validated against
  the real Crash Bash executable — `info` reproduces every header field recorded in notes.md, and
  `dis` renders the Psy-Q startup correctly (BSS clear loop, backward branch target, lui/addiu
  address pairs). Findings added to games/crashbash/notes.md. Tool tests are now step 1 of
  test.sh. Next: function discovery and the CFG.

2026-08-08 [claude] Conformance testing made first-class: tests/conformance/ + Conf harness +
  scripts/conformance.sh runs every test on every target and compares digests; adding a test is
  dropping in a file. Two tests so far (Arith 14b7201f, Mem 27f9aa59). Building them found two
  things: upstream defect 1 (inline local collisions) is now FIXED in our vendored fork, and
  defect 8 is characterised exactly — an `if` with no `else` and >1 statement is deleted whole.
  It had silently disabled Conf.expect on C++, which is precisely the failure this harness
  exists to catch.

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
