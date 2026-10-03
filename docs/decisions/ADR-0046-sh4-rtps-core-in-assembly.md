# ADR-0046: RTPS's common vertex in scheduled SH-4 assembly
Status: accepted   Date: 2026-10-02

## Context

RTPS and RTPT are the transform every 3D PlayStation game runs on every vertex, and on the
Dreamcast they had reached the floor of what GCC makes of the C form: ~204 cycles a vertex inline in
generated code (Crash Bandicoot: Warped's title, ~1,300 a present), 233 out of line (`cmdRtps`,
Crash Bash's ~1,655 a present), ~256 a vertex in RTPT's loop (gameplay). An assembly version written
in source order was no better (213 cycles, ledger E-080), and timing showed why: the SH-4 issues two
instructions together only when their units differ (two EX never pair, two LS never pair, the
multiplier's CO instructions never pair), and the vertex's 15 multiplies, ~60 loads and stores and
~55 integer operations were laid out so that most of them issued alone.

## Decision

**On the SH-4, `Gte.project` at sf = 1 first runs a core in assembly; the core either writes every
output and returns 0, or returns 1 having changed nothing the C form reads, and the C form runs as
before.** The core is generated, never written by hand:

- **Source:** scripts/sh4/rtp1.blk (the last vertex, with the depth cue) and rtp1n.blk (RTPT's first
  two), assembly in dependency order with tags for what may move: exits (declines), stores the C form
  writes again (MAC1-3, IR1-3), the SZ FIFO's push (undone by a stub if a later test declines), the
  register file's words. The instruction mix is chosen for pairing: range tests as compares and
  branches (MT, BR) rather than masks (EX), signed overflow by `addv`'s T, the divisor's leading zeros
  from the register file's CLZ table (no floating point anywhere: golden rule 1, `scripts/check.sh`;
  the FPU's exact int-to-float exponent was 6 cycles a vertex cheaper), the 64-bit quotient joined by `xtrct`,
  constants from the literal pool (LS). lm = 1, a vertex outside +-2^14, a wide translation, an IR or
  depth out of range, a divide overflow or a quotient over 16 bits are declined to the C form.
- **Schedule:** scripts/dc-sched.py list-schedules each block under the cache model's own rules
  (scripts/dc-issue-sim.py: pairing by unit, latencies from Flycast's opcode table), pairing each
  leader with a partner, and writes the result into Gte.hx's `@:cppFileCode` between markers, as one
  top-level `__asm__` compiled only for the SH-4 (`RECOMPSX_GTE_NO_ASM` turns it off).
- **Call:** `GteFile.rtp` → `recompsx_gte_rtp` (Gte's header): a `jsr` from inline asm with the
  register file as a `+m` operand and r0-r7, PR, MACH/MACL and T clobbered (the core saves
  r8-r11), so generated code around it keeps its CpuState fields in registers. Every other target
  answers 1 and compiles to the C form alone.

Verified twice, since only an SH-4 runs it: scripts/dc-shrun.py runs the assembled core in an SH-4
interpreter over vertices recorded from the JavaScript build (`-D recompsx_rtp_capture`,
tests/spike/RtpCapture.hx; 76,000 from Crash 3's title and gameplay and Crash Bash) and compares every
word of the register file with the reference — 0 differ; and a Dreamcast build with
`-DRECOMPSX_GTE_RTP_CHECK=1` runs the core on a copy of the file before every C-form vertex and
compares the two, word by word, logging the count.

## Alternatives

- **The C form restructured** (E-062, and a leaf C function of the same algorithm compiled with
  `-fschedule-insns`): 238 cycles — GCC spends what the source saves on the SH-4's registers.
- **The assembly in source order** (E-080): 211-213 cycles; the instruction count and mix decide,
  not the hand-picked order.
- **A dead-output analysis in the recompiler** (skip the depth cue or MAC/IR stores no instruction
  reads): ~10 % of RTPS, and a GTE dataflow pass over every game's code.

## Consequences

- RTPS's common vertex: 155 cycles (the depth cue's entry), 144 (RTPT's first two), against ~204
  inline and 233 out of line; measured under the model in ledger E-083.
- The runtime carries machine code for one target. It stays exact by construction (the C form is the
  definition; the core declines whatever it does not do) and by the two checks above; a change to the
  GTE's semantics or register-file layout must regenerate and re-check the core
  (`scripts/dc-sched.py --into src/runtime/gte/Gte.hx scripts/sh4/*.blk`, then dc-shrun.py over fresh
  samples).
- Declines still cost the core's tests (~80-110 cycles) before the C form: Crash 3's title sends ~15 %
  of its last vertices behind the camera (a negative depth, then a divide overflow), which the core
  declines.
