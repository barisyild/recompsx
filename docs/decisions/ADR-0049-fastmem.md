# ADR-0049: Guest RAM through the SH-4's MMU on the Dreamcast (fastmem)
Status: accepted (the owner, 2026-10-04: one of the three options for Crash 3's gameplay, "in order
or out of order")   Date: 2026-10-04

## Context

Every guest load and store the generated code makes is decoded in software: is the address RAM, the
scratchpad, or a port. On the Dreamcast that decode is a large share of the generated code, which is
itself the largest part of a gameplay frame (Crash 3's Toad Village demo, the cache model: 10.6 of
22.4 ms conflict-free, docs/perf/dreamcast-ledger.md E-130..E-133). Counted (2026-10-04, the
gameplay demo, JavaScript): 16,565 unspanned timed accesses a frame (each ~6-8 SH-4 instructions of
decode), 41,215 span tests (two each), and ~10,600 span set-ups (~146 K instructions); by the model's
samples the decode's constants alone — 0x1F9FFFFF, 0x1FFFFF, 0x1F800000, `recompsx_mem`, 0x1FFFFFFF,
0x3FF, 0x1FFFFC00 — are about half of the generated code's literal-pool loads, ~7 % of its time.
Altogether ~340 K of its ~1.41 M instructions a frame are the decode.

The SH-4 has an MMU. With it on, P0 (0x00000000-0x7FFFFFFF) is translated by a 64-entry UTLB, and an
access to an unmapped page raises a TLB miss with the address in TEA.

## Decision

On the Dreamcast, guest RAM and the scratchpad are mapped at their own bus addresses in P0, and the
generated code reaches them with one mask and one load or store; anything else traps and is emulated.

- **The mapping** (backend, at boot): MMUCR.AT on. Guest bus address = host P0 address (`a &
  0x1FFFFFFF`). RAM: 0x00000000-0x007FFFFF, the 2 MB arena and its three mirrors, as 1 MB pages (8
  wired UTLB entries); the arena's RAM 1 MB-aligned. The scratchpad: one 1 KB page at 0x1F800000,
  its arena copy 16 KB-aligned so that its P0 and P1 addresses index the same operand-cache lines
  (no synonyms; RAM's 1 MB pages have none). Everything else unmapped. KallistiOS's store-queue
  locking already maps the SQ area when the MMU is on (`sq_lock` → `mmu_set_sq_addr`).
- **The access** (runtime shims, `-D recompsx_fastmem`): one load or store in inline assembly that
  takes `ctx->cycles` as a memory input — so GCC has stored the block's clock before the access (the
  trap handler's ports read it) without a store at every access (GCC drops the redundant ones) and
  without a memory clobber. No span is ever taken (`Memory.span` answers none), so the span tests
  fold away. The generated code's accesses go by base register and offset (`Memory.read32bt` and
  the rest, the emitter's every timed access): for an offset that is not negative the base's bus
  address, `base & 0x1FFFFFFF`, which GCC computes once for every access through one base value — a
  span with no test — plus the offset, in the instruction's displacement where it fits (`mov.l
  @(0..60,Rn)`; `mov.w`/`mov.b` through R0) and in R0 where it does not (`@(R0,Rn)`); for a
  negative offset the bus address `(base + off) & 0x1FFFFFFF`. The first is that bus address too,
  but where the offset carries it past 0x1FFFFFFF: it then lands on no page and traps, and the trap
  wraps TEA as the bus does. A negative offset never takes that form, since it could carry the
  address below 0, into P4. Everywhere else the accessors are the bus address and one
  register-indirect access, as before. (A biased form, `(base & 0x1FFFFFFF) | 0x40000000` with RAM
  mapped there too, took negative offsets as well; its `or` and second constant cost what the
  displacements saved: a shard's instructions 33,724 → 33,729, against 32,129 unbiased.)
- **The trap** (backend): a TLB miss on P0 emulates the faulting access through the runtime's slow
  paths (`Memory.slowRead*`, `slowWrite*` with the bus address from TEA). The accessors are each one
  `mov.{b,w,l}` — register indirect, `@(R0,Rn)`, or `@(disp,Rn)` (`mov.l`, and `mov.w`/`mov.b`
  through R0) — never in a delay slot, so the instruction at the access's pc gives the size, the
  direction and the register; anything else is an error. The emulation runs back in normal context
  through a trampoline, not inside the exception, since a port write can run as much of the machine
  as a slow path does today; the trampoline reads the whole record and decodes before it calls out,
  so an access the slow path makes cannot change it. It keeps what a C call may change and the
  access's code may hold — r0..r7, PR, MACH, MACL, T — and not the FPU's: the generated code and the
  runtime have no floating point (`scripts/check.sh`), so no FP value is live at an access, and the
  division helper they call uses the FPU inside the call only. A load into r8..r14 goes straight to
  the register, which the slow path kept by the ABI.
- **The vector** (backend): while fastmem is on, VBR is a table of the backend's (`rx_fm_vbr`):
  KallistiOS's vectors for general exceptions and interrupts, and at 0x400 a TLB miss on a P0
  address by code in P1 — a guest access, the only P0 accesses there are — recorded (TEA and the pc)
  and resumed at the trampoline in fourteen instructions. KallistiOS's own path saves the whole
  context (both FPU banks) and dispatches in C, several hundred instructions a trap; it remains the
  path for any other miss (on P3, or by code in P0), which is an error. KallistiOS never reloads VBR (entry.s) and puts its own back at
  `irq_shutdown`.
- **What the compiler is not told** (runtime): that an access may write memory. A trap's slow path
  can schedule an event, which moves the CpuState's `nextEvent` (`Scheduler.scheduleAt`); the code
  after it must see that at its next pump test, as it does after the C++ form's call to the slow
  path. So the generated code reads the deadline through `Runtime.deadline(ctx)`: the field, read
  volatile where fastmem is on. Not a memory operand on the access: GCC takes any asm with a memory
  output for one that may write all memory, and stores and reloads every guest register cached
  around each access (a shard: `mov.l` 12,483 → 14,965; Crash 3's gameplay cf 20.29 → 21.09 under
  the model). Nothing else a slow path changes is read by the code around an access: it never
  pumps, never runs guest code, and leaves the clock alone (only an idle kernel wait moves it,
  through a call).
- **Exact:** the same addresses reach the same paths with the same clock as the C++ form's decode:
  RAM and its mirrors, the scratchpad in any segment, every other address through the slow paths.
  Held to the game digests on the Dreamcast (`scripts/dc-digest.sh`: Crash 3 47853ef7 at 5000, Crash
  Bash 95e17b07 at 20300) and the TA hash, as every Dreamcast change is.

## Measuring it

The cache model's Flycast translates P0 once KallistiOS maps a page (on-demand full MMU), but it
guessed WinCE page tables on a TLB miss (`USE_WINCE_HACK`) and so stopped trapping after the first
miss. The owner approved a separate copy, `~/Desktop/Project/flycast-fastmem`, built without that
guess; the original clone is not touched. Three more faults of its fast MMU, all patched in the
copy only (`recompsx-fastmem` comments), each a model artifact the hardware does not have:
- **1 KB pages** were neither cached nor looked up (WinCE has none; an empty entry reads as one), so
  every scratchpad access trapped: 65 ms a frame, three quarters of it in the trap path.
- **The cache model's hooks** were installed only with the MMU off; with it on, no fill was
  counted. Now translated accesses reach the model as their physical line through the P1 alias (the
  operand cache's index is the virtual address's bits 13..5, its tag the physical address, and our
  pages keep those bits alike).
- **The TLB cache** added every written entry and never took one out: KallistiOS rewrites the store
  queues' two entries at every `sq_lock`, and some 30 K locks in the table was full and the store
  queues wrote through stale translations (Crash Bash's Ballistix: 115 ms a frame, 50 of it waiting
  for the PVR). It now mirrors the UTLB, rebuilt at every change.

The copy reads a build without fastmem exactly as the original does (Crash 3's gameplay, the same
binary: 30.94 / cf 22.47 on both).

## Measured (2026-10-04, the cache model, builds without placement)

Exact: the Dreamcast digest at Crash 3's 5000 is JavaScript's (47853ef7) for every step below, with
the scratchpad mapped and with it trapping, and Crash Bash's at 20300 (95e17b07) with fastmem. Crash
3's gameplay demo (4700:5000) traps 292 times a frame, Crash Bash's Ballistix (18800:20300) 1,036:
by address (a diagnostic build, `-DRECOMPSX_FM_HIST=1`), Crash 3's are the interrupt controller's
I_STAT and I_MASK (124 and 60 a frame) read by the game's interrupt dispatcher through a pointer,
timer 2's mode (23) and the pad port (~26); Crash Bash's are the root counters — timer 2's mode and
count, timer 1's count, 606 a frame between them — I_STAT (152) and GPUSTAT (111).

| build | demo cf | Uka Uka cf |
|---|---|---|
| without fastmem | 22.47 | 18.18 |
| fastmem, KallistiOS's trap path | 20.72 | — |
| fastmem, the vector | 20.29 | — |
| the vector, the deadline read volatile | 20.34 | 16.77 |
| the lean trampoline, accesses by base and offset (kept) | 19.71 | — |

The generated code is most of it (−2.17 ms of the demo's: fewer instructions issued, and fewer
instruction fills that are not conflicts — the image is 0.9 MB smaller); the conflicts are a new
placement's to remove (docs/perf/dreamcast-ledger.md, E-135).

## Alternatives

- **Spans everywhere** (the C++ form's own answer, E-012, E-125): a span still costs its set-up, a
  test per access GCC rarely merges, and its constants.
- **GCC global register variables for the decode's constants:** each one a register taken from every
  function; the tests and branches stay.
- **ADR-0048's emitter** (accepted the same day): the same decode in assembly is cheaper but still a
  decode; fastmem removes it for both forms, and leaves GCC's register allocation the room spans and
  constants take today.

## Amended 2026-10-04: ports through the libraries' pointers do not trap

The traps were nearly all one shape: a port read or written through a pointer the program keeps in a
variable — the PlayStation libraries hold their ports that way (libetc's I_STAT is a word of the
executable whose value is 0x1F801070) — loaded, then dereferenced: Crash 3's interrupt dispatcher,
Crash Bash's root counters, GPUSTAT and its VSync poll. So the recompiler marks those accesses
(`PortBases`, a forward pass over each function: constants built by `lui`/`addiu`/`ori`; a pointer
loaded from a constant address whose word in the image is a port, kept through `addiu` and through an
`addu` with one pointer operand, forgotten at any other write and at whatever a call may write; facts
flow into a block where every predecessor agrees), and the emitter gives them `Memory.*pt`/`*pf`. On
fastmem those decode the address as every other target does (`Memory.portRead*`, `portWrite*`, out
of line: RAM and its mirrors through the arena — the same bytes the pages map — the scratchpad, else
the slow path with the clock stored first); on every other build they are `*bt`/`*bf` themselves.
Which accesses reach a port stays a run-time fact and this a guess: a wrong one is the same access,
decoded instead of mapped, only slower. Measured (docs/perf/dreamcast-ledger.md, E-146): Crash 3's
demo 268 traps a frame → 2, Crash Bash's Ballistix 1,036 → 4 and its disc load 6,173 → 6; the work
of a frame −0.29 (demo), −0.84 (Ballistix), −7.1 ms (the disc load, a VSync poll).

## Consequences

- A Dreamcast-only memory path: the arena's alignment (up to 1 MB of padding before RAM, 16 KB before
  the scratchpad), the MMU on for the whole run, a TLB-miss handler in the backend.
- Port accesses through a computed address the recompiler does not see trap (2-6 a frame left in
  the windows measured, from 292 in Crash 3's gameplay and ~1,000 in Crash Bash's before the
  amendment); each costs an exception, the vector and the trampoline. An access whose address the
  C++ compiler can prove is a port (`__builtin_constant_p`: `lui $at, 0x1F80` and an offset) calls
  the slow path directly, without the trap.
- The generated code reads the deadline through `Runtime.deadline` on every target; only fastmem's
  read is volatile, and the C++ of every other build is the same as before (checked: identical but
  for temporaries' numbers).
- Every other target is unchanged: `recompsx_fastmem` is the Dreamcast's. A Dreamcast tree is
  transpiled with `build/game-cpp-dc.hxml` (game-cpp.hxml and `-D recompsx_fastmem`);
  `scripts/build-dc.sh` sees such a tree (the runtime's glue, `mem_Fastmem.cpp`) and builds it with
  `RECOMPSX_FASTMEM`, and a desktop build of one stops at an `#error` in CpuState's header. A tree
  transpiled without it still builds for the Dreamcast as before.
