# ADR-0048: Guest code as SH-4 assembly on the Dreamcast
Status: accepted (the owner, 2026-10-04: with guest RAM through the MMU and the scene straight to
the PVR, "in order or out of order"; frame skipping never)   Date: 2026-10-03

## Context

Crash Bandicoot: Warped's gameplay is the one bench window not at full speed: 25.01 ms a frame under
the cache model (docs/perf/dreamcast-ledger.md, E-128), against 16.7. What is left in place is 0.05-0.3
ms an item (E-113..E-127; E-125, the largest since, took 0.34 ms off the generated code by taking spans
only where they are used), and the ledger's "Where the time goes (2026-10-03)" says why. The generated
code is 10.7 ms of the frame's 22.1 conflict-free: ~1.37 M SH-4 instructions for ~290 K guest
instructions, and its cost is what GCC makes of the C++ form on a sixteen-register machine:

- **CpuState traffic, ~20 %:** every guest register written is a store; a read after any call, pump or
  cold slow path is a load again (ADR-0029 chose fields over locals for good reasons that still hold).
- **Literal-pool loads, 13.3 %:** the memory map's constants at every decode and span, offsets past 60
  bytes, far-branch offsets — 0.99 ms of operand fills a frame, each function's pool a cold line.
- **Guest memory, ~30 %:** 10.6 K span set-ups a frame (~146 K instructions; a scratchpad base pays the
  RAM test first), 16.6 K unspanned decodes, a test at every spanned access GCC could not merge.
- **Instruction fills, 4.1 ms:** 31 % of the fetched slots never run — cold paths, pools, trampolines.

No change to the C++ form reaches these together. GCC rematerialises a constant from the pool rather
than hold it in a register, cannot keep a guest register in a host register across a call that may
read it, and lays its pools and far-branch trampolines inside the hot lines (E-009, E-101, E-115,
E-120, E-121). PROGRESS.md, Blockers 2026-10-03, lists this as option 1 of three.

## Decision

Proposed, for the owner. On the Dreamcast the recompiler also emits each guest function it can as SH-4
assembly, from the same analysis the Haxe form comes from — blocks, regions, span facts, cycle charges,
pump points, resume entries — and the build links that form in place of the C++ one. The Haxe form stays
the definition, every other target's code, and the Dreamcast's fallback for any function the assembly
emitter declines:

- **Pinned registers** across all assembled code: the CpuState, the arena's base, the cycle count, the
  RAM decode's mask. One stub saves and sets them on every entry from C++, so the runtime and the
  backend, compiled by GCC as now, see the ordinary ABI.
- **Guest registers** per function: the most used in SH-4 registers, the rest in CpuState; the dirty
  ones written back before a call, pump, trap or exit and reloaded after — ADR-0029's boundaries, with
  the call summaries (E-032) saying which a callee may change.
- **Memory:** RAM inline (mask, compare, indexed load, no pool constant); the scratchpad and the ports
  in shared out-of-line stubs; spans where they still pay.
- **Calls** between assembled functions direct, the after-call token in r0; computed jumps and dynamic
  calls through FnTable as now (ADR-0026, ADR-0028).
- **Exact, by digests:** the game digest at Crash 3's 5000 and Crash Bash's 20300 equals JavaScript's
  (47853ef7, 95e17b07) on a Dreamcast build — `scripts/dc-digest.sh`: GenMain's `--headless-hash`
  through RECOMPSX.CFG, read from the serial log; today's C++ builds print exactly those — and the TA
  hash over the bench windows equals the C++ build's. A function that cannot be shown exact is left
  to the C++ form.

## Alternatives

- **More of the C++ form:** each item now 0.05-0.3 ms (the ledger since E-113); the window needs 8.5.
- **Guest RAM through the SH-4's MMU (fastmem):** ~2-3 ms of the decode, but every port access a TLB
  miss whose handler needs the cycle count in a known register, the store queues translated through the
  UTLB, and Flycast models no MMU for this disc (ledger 2026-09-26): it could not be measured.
- **GCC global register variables** (`register ... asm("r13")`) for the arena or the cycle count in the
  C++ form: they survive LTO (checked with sh-elf-gcc 15.2), but each register reserved is one fewer
  for every function's own values, and the pools of everything else stay.
- **The C++ form with each function's hottest registers in locals** (ADR-0029 refined, not
  reversed): the generated code's 253 K CpuState accesses a frame are 16-28 % of each hot function's
  instructions, and six registers carry 38-62 % of a function's share. Tried (ledger E-124): six a
  function, synchronised at calls, pumps, traps and exits, exact — and slower, the generated code
  +0.12 ms in gameplay and +0.23 in the title, because GCC spills the locals (stack references in
  f_8003fc50 350 → 1,202): CpuState traffic became stack traffic with the synchronisation on top.
  Keeping guest registers in the SH-4's takes an allocator that knows which they are.

## If accepted: the order of the work

Each step is measured on the model against the C++ form of the same functions, and held to the
digests above before the next:

1. **The link and the check.** The assembly form of a function replaces its C++ form by symbol
   (the C++ one kept, renamed, as the fallback an entry it does not handle tail-calls), and a
   checking build runs both on copies of the machine and compares them, as
   `RECOMPSX_GTE_RTP_CHECK` does for the RTPS core. First for loopless leaves: Crash 3's
   `f_8003d0fc` (0.54 ms of gameplay, 0.94 of the title, 671 and 1,444 calls a frame) is one.
2. **Calls, pumps and resumes**: the boundaries of ADR-0029 with the guest registers in SH-4
   registers, publication and reloads narrowed by the call summaries; FnTable calls and the
   unwind check as today.
3. **Memory and the GTE**: spans and the RAM decode with their constants in registers; the
   scratchpad, the ports and the GTE commands through stubs that keep the pinned registers.
4. **Coverage**: every function the emitter can prove, the rest in C++; the placement rounds as
   now.

## Measured: the first step (2026-10-03, ledger E-131)

A first emitter (`tools/recomp/src/recomp/codegen/Sh4Emitter.hx`, `gen --sh4`, linked by a
Dreamcast build with `-D recompsx_sh4`) takes loopless leaves that call nothing and touch no
coprocessor — 198 of Crash 3's functions, `f_8003d0fc` and `f_8003e0fc` the hot ones — with the
CpuState, the clock and the RAM decode in registers, the six most used guest registers in SH-4
registers, the scratchpad and the ports through shared routines, the C++ form kept for resumes and
due pumps. It is **exact** (the Dreamcast digest at Crash 3's 5000 is JavaScript's, 47853ef7) and
**slower**: `f_8003d0fc` runs 178,480 SH-4 instructions a frame against GCC's 139,108 (+ 7,747 in
the lwl/lwr glue), its time 162 → 273 ms over the gameplay window; the frame's conflict-free time
22.59 → 23.80 (both unplaced). What the hand count assumed and this emitter lacks: guest registers
loaded where first used rather than all at the entry, only the callee-saved registers a path uses
saved, more than six of them held, and the C++ form's spans (one decode for a run of accesses
through a base) where it places a RAM test at every access. So the quarter fewer instructions is an
allocator's result, not a translator's; and the ten hottest functions of real play (E-130) also need
loops with their pumps, GTE transfers inline and switch tables before any of it reaches them.

## Measured: an allocator and a scheduler (2026-10-05, ledger E-177)

The emitter rewritten for fastmem with what the first step lacked: guest values as webs with a
graph-colouring allocator (`Sh4Webs`), a list scheduler by the cache model's issue rules
(`Sh4Sched`), loops with their pumps, checked returns, switch tables, and the ports PortBases
expects through the runtime's decode. Exact (the digest at Crash 3's 5000 is JavaScript's). On the
two hot leaves it is ~15 % faster than GCC's code conflict-free — fewer instructions (−5 %) but
mostly far fewer dependency stalls — and slower on the short ones that make up most of what it
takes: a function GOOL calls 216 times a frame for twenty guest instructions pays its webs' loads
at the entry and six callee-saved registers on every call. The renderer functions, where most of
the generated code's time is, all call, touch the GTE and switch through tables; the remaining
steps (lazy entry loads, saves only on the paths that need them, GTE transfers and the quick
commands inline, calls with summaries) were estimated at 0.3-0.5 ms of Crash 3's demo at best.
Not pursued further for now: the emitter stays opt-in, off.

## Consequences

- Weeks: an instruction selector for the R3000A's integer, memory, branch, COP0/COP2-transfer and GTE
  command instructions; a register allocator; the boundaries (pump, trap, unwind, resume, tail); the
  build linking both forms. A second code path for one target, which every change to the Haxe form's
  semantics (cycle charges, spans, pumps) must follow, held together by the digests above.
- Expected: the generated code's ~10.7 ms toward ~6-7 (no pool loads or CpuState traffic on hot paths,
  memory accesses of two to four instructions, less code and so fewer fills). Counted by hand for one
  function, Crash 3's `f_8003d0fc` (a bit-stream decoder, a leaf): ~141 K SH-4 instructions a frame from
  GCC against ~106 K for a direct translation, a quarter fewer — its shifts by register cost the SH-4
  three or four instructions in any form, and a leaf reloads little after calls; functions that call
  and are called more gain more. Crash 3's gameplay ~25 → ~20-21 ms: not full speed alone. The scene
  build and the GPU path (~6.5 ms a frame, Blockers option 2) must lose a third as well.
