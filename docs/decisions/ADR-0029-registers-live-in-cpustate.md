# ADR-0029: Guest registers live in CpuState
Status: accepted   Date: 2026-09-27

Supersedes the register lowering of ADR-0007, and ADR-0012 and ADR-0017 with it.

## Context

ADR-0007 lowered each function's GPRs to Haxe locals, synchronised with `CpuState` at calls,
returns, pumps and traps; ADR-0012 narrowed the reloads after a boundary to the registers the
continuation reads, and ADR-0017 dropped writes nothing was to read. One bug and two measurements
undid that.

- **The bug.** Publication was "every register this function writes", reload "what the
  continuation reads". A register the function wrote, a callee then changed, and the function never
  read again was not reloaded — and the next publication put the stale copy back over the callee's
  value, where the next callee read it. In Crash Bandicoot: Warped, `f_80049774` returns a pointer
  in `$v1`; its caller at 0x800495c8 reloads only `$sp`, then publishes its old `$v1` before the
  `jalr` to `f_8004aa94`. From vblank 9898 the game ran differently (the RAM hash differs there;
  the 20,000-frame digest was `f05fb3ea`). JavaScript and C++ agreed, running the same generated
  code, so the two-target gate could not see it. The `Codegen` fixture `staleAcrossCalls`
  reproduces it: `$v0` = 5 where the machine gives 7.
- **The SH-4.** About thirty locals for fourteen allocatable registers spill, and each boundary
  copied them between the spill slots and `CpuState`: 1.5 M guest calls in Crash 3's vblanks
  4700-5000 moved 31 M register values (16.1 M publications, 15.1 M reloads), besides the loads
  at every entry and the stores at every exit. The hottest generated functions ran 13-20 SH-4
  instructions per MIPS instruction, about 40 % of them spills and `CpuState` traffic.
- **JavaScript.** ADR-0007's premise, that locals are what the JIT needs, did not hold when only
  the register form was changed on the same generated code: Crash 3, 9,000 frames, 12.7-13.0 s
  with fields against 12.8 s with locals; Crash Bash 9.4-9.5 s against 9.6-9.7 s.

## Decision

Generated code reads and writes guest registers as `CpuState` fields (`ctx.v0`), in place, so
nothing is published or reloaded at calls, returns, traps, cooperative suspension or unwinds and
the state every boundary sees is the machine's own — except in a **looping leaf**: a function
with no guest call, trap or unknown instruction, with a loop, using at most 20 registers. It keeps
its registers in locals: while they are
live only the runtime's helpers run, which touch no general register, and due pumps, whose
callbacks give the interrupted registers back as they found them, so no copy can go stale. It
declares them at every entry, publishes the ones it writes at every way out (return, tail
transfer, due pump, suspension) and reads them again after a due pump. Every register write is
made, in both forms; there is no liveness narrowing and no dead-write elimination, and
`RegisterPlan` is gone. The rest of the optimised build — structured regions, native loops,
pattern fusion, stack forwarding, idle-loop skipping — is unchanged.

**2026-10-01 refinement (ADR-0044):** scalar helpers and pure `ValueRegion` intervals can replace
unobservable intermediate field writes with value SSA. An interval is at most 32 pure body
instructions; memory, traps, coprocessors, HI/LO, control, return-address writes and span refreshes
end it. All changed outputs are published before the next observation, and the next interval
reads current state anew. Nothing is cached across a call or pump. Only intervals reducing GPR
field references against their existing emission are selected; looping-leaf locals are unchanged.
This does not restore the per-function register cache or its liveness/publication bug above.

## Alternatives

- Keep the locals and fix the liveness, making every publication point a use of every written
  register: correct, but reloads grow at every call, and every copy this removes would remain.
- Locals on JavaScript, fields on C++: two generated trees and two code shapes for the digest to
  compare, for no measured JavaScript gain.
- Fields everywhere, leaves included: Crash Bash's hottest function, a leaf running a GTE loop
  (14 % of its window), was 11 % slower as fields — each helper call and guest store makes a
  field a load again for the C compiler, where a local stays in a machine register.
- Locals per basic block in the other functions — read at the block's start, written back before
  its transfer, where no call or pump can intervene: measured neutral (Crash 3 +0.15 %, Crash Bash
  -0.2 %) for a JavaScript bundle 21 % larger. Not kept.
- Locals in every leaf: Crash 3 lost 1.9 % (1535.3 -> 1564.8 M cycles). Its loopless leaves
  copy their registers in and out on every call for nothing, and its 29-register leaf spills
  them to the stack anyway; measured leaf by leaf, locals won only in loops of up to 17
  registers and were even at 22.
- The registers in a link-time array beside guest RAM, which the C compiler could tell apart from
  guest memory: measured on one hot function, no smaller than fields through `ctx` (10,280
  against 9,976 bytes of SH-4 code; 13,444 with locals). Not pursued.

## Consequences

Flycast, M cycles, with locals everywhere (before) / fields everywhere / locals in every leaf /
this decision: Crash 3 vblanks 4700-5000 1645.0 / 1535.3 / 1564.8 / **1537.7** (~61 % -> ~65 % of
real time); Crash Bash 18800-20300 6227.7 / 6282.8 / 6193.0 / **6174.2**. Images: Crash 3 11.60 ->
10.60 MB, Crash Bash 9.46 -> 9.53 MB. JavaScript bundles: Crash 3 15.5 -> 11.8 MB, Crash Bash
11.4 -> 9.6 MB, at the same speed.
Crash 3's reference digest at 20,000 frames becomes `a3419ae4` (9,000 frames unchanged,
`2c8bc61d`), JavaScript and desktop C++ alike; Crash Bash's are unchanged (`2ff36a18` /
`288ed8d6`), since nothing there reads a register across two calls. `Codegen` gains
`staleAcrossCalls` (`c6ccf6ad`); every other conformance digest is unchanged.

On the SH-4 `mov.l @(disp,Rn)` reaches 60 bytes, and reflaxe.CPP lays `CpuState` out by field
name, descending, not in declaration order (`cycles` at 136, `$a0`-`$a3`, `$s0`-`$s7` and `$ra`
past 60). A hand-edited hot-first layout compiled no smaller (one shard, +1.2 %), so the layout
stays and needs no compiler patch. A guest store may alias `*ctx` for the C compiler
(`-fno-strict-aliasing`), so a field read after one is a load again — which, spilled, a local
was too.
