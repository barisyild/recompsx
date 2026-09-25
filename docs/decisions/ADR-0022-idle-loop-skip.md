# ADR-0022: An idle loop's turns are counted, not run
Status: accepted   Date: 2026-09-25

## Context
A PlayStation game that has finished a frame waits for the next vertical blank by spinning:
libetc's `VSync` reads a counter that the vblank callback raises, decrements a timeout in a
stack slot, and branches back — thirty-two cycles a turn, tens of thousands of turns a frame.
The recompiled program executed every turn faithfully, and in the browser's profile the wait
was the largest single item: 8 % of the main thread with the frame lock on, 30 % with it off
(PROGRESS 2026-09-25). The user's question was whether the machine's waiting could be made to
cost the host nothing without changing anything the machine can observe.

## Decision
Prove at build time that a loop is idle, and emit at its head the arithmetic that takes all but
the last of the turns before the next event at once. `recomp.codegen.IdleLoopPlan` accepts a
natural loop whose turn is one path of blocks with one pump (the header's), whose instructions
are plain arithmetic, loads, one `lw/addiu/sw` of a stack slot and branches, whose registers are
never read before the turn writes them unless the loop never writes them, and whose counter is
read, while a register holds it, only by its own `addiu`, its store, the compiler's reloads of
the slot and one `beq`/`bne` against an invariant. The prologue (`Emitter.emitIdlePrologue`)
evaluates one dry turn into shadow locals — every load guarded to plain memory and away from
the slot at run time, the store left out, every invariant branch checked to be going round
again — then computes the turns before the next event (`core.IdleLoop.untilEvent`) and before
the counter's exit (`untilEqual`), charges the cycles and advances the slot for all but the
last, and lets the last turn run as generated code. The pump that ends the wait fires at the
cycle it always did; every register leaves the loop with the value the loop computes.

## Alternatives
- Move the clock to the next event when a wait is recognised, as dynamic recompilers do:
  approximate — the slot, the registers and the exact cycle of the pump would differ, and the
  digests with them. Rejected; this design skips turns, not time.
- Replace libetc's `VSync` with a native implementation (HLE): game-specific, and the same
  loop appears in every Sony-SDK title in slightly different registers. Rejected (golden rule:
  nothing game-specific in the tool).
- Reconstruct the registers a skipped turn would leave instead of running the last turn for
  real: needs symbolic evaluation of every write; running the last turn costs one turn and is
  exact by construction. Rejected for now.
- Also skip loops that poll an I/O register (a timer count): its value changes without any
  code running, so the turn count is not a function of the slot and the clock alone. Excluded
  at run time by `Memory.isPlainMemory`, which is why the address is checked at all.

## Consequences
- Only an optimised build takes the prologue, so the reference build is the proof: the
  `Codegen` conformance test runs a hand-assembled `VSync` (and libetc's exact
  store-then-reload shape) through both builds, reached, timed out, satisfied on entry and
  polling ROM, and requires the same registers, slot, polled word and cycle count. The game's
  digests, with and without sound, are unchanged.
- Fifteen loops in the bring-up game match, the wait in `f_80032264` among them; loops that
  call, carry a counter in a register or read I/O are emitted as before. Measurements are in
  PROGRESS.md under the same date.
- The C++ twin is unverified while the C++ path is paused (ADR-0015): the prologue is ordinary
  Haxe with `else {}` on every `if`, and `IntMath.mul` for the products, so nothing new is asked
  of reflaxe.CPP, but the digest there has not been taken.
- `Runtime.insns`/`blocks` count the skipped turns too under `recompsx_insns`, so instruction
  profiles keep their meaning; `core.IdleLoop.skipped` and `entries` are printed in the
  heartbeat line as diagnostics and are not in any digest.
