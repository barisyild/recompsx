# ADR-0017: Eliminate dead pure register writes with CFG liveness
Status: accepted  Date: 2026-09-22

## Context

The scalar register lowering keeps guest GPRs in Haxe locals, but it still emitted every pure
arithmetic assignment even when a later instruction overwrote the same register before any guest
observable use. A full cross-block constant or copy replacement is unsafe at the current boundary:
every discovered block remains a valid interior entry and must begin from the caller's `CpuState`.

## Decision

Reuse `RegisterPlan`'s backwards CFG liveness to drop only pure GPR writes whose destination is not
live after the original instruction. The analysis includes successor uses, transfer and delay-slot
reads, function exits and the existing conservative publication rule. The emitter applies this to
non-trapping arithmetic, logical operations, comparisons, shifts, `lui`, and `mfhi`/`mflo`.

The pass protects every reverse CFG path that reaches a pump, call, trap, return or other external
transfer. Those paths can publish a local even when the boundary block has no explicit read of the
register. Only blocks outside that protected slice may drop a write.

Memory reads and writes, coprocessor reads, traps, control transfers and potentially overflowing
`add`/`addi`/`sub` remain emitted. The original instruction count and cycle charge remain unchanged.

## Consequences

The optimization is valid for normal entry and every interior entry because it removes a write only
when no later guest observation can depend on it. It reduces redundant assignments in generated
Haxe without changing the raw `CpuState` boundary. In the current Crash Bash CFG the protected
slice covers the generated game, so the bundle remains byte-stable; the synthetic leaf fixture
still demonstrates the reduction. More aggressive cross-block constant/copy substitution remains a
later pass and must carry an explicit entry-path guard or equivalent proof.
