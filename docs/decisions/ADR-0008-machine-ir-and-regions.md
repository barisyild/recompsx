# ADR-0008: Machine IR and resumable control-flow regions
Status: accepted   Date: 2026-09-09

## Context

Scalar GPR lowering and native self-loops expose local optimization to Haxe (ADR-0007), but a
single non-linear edge still put the rest of a function behind a block dispatcher. Independent
passes also decoded the same instructions and maintained separate register-effect knowledge.
The next step must work on arbitrary discovered R3000A CFGs, including handwritten assembly;
neither game addresses nor an assumed library/calling convention can justify a transformation.

## Decision

Build a `FunctionIR` between discovery and emission. Keep decoded instructions, explicit GPR
read/write masks and observable-effect flags, original cycle charges, predecessors/successors,
terminators and their delay slots, stable block resume IDs, and the original pump locations.
Use Int-backed `RegisterMask` and `Effect` Haxe abstractions in the tool. These are build-time
types; generated hot paths acquire no objects, closures or runtime IR interpreter.

Reduce single-entry regions deterministically. Sequence a region with its unique-predecessor
continuation; combine ordinary conditional branches with exclusively owned arms meeting at a
common join, an empty arm, or two function exits. Flatten sequences and bound nesting to 32.
Keep residual CFGs behind a dispatcher, including irreducible loops and computed-target checks.
An external conditional exit is not an unconditional edge merely because only one successor
was discovered. Native self-loops retain their existing body and pump behavior.

Emit each original block once. A dispatcher case accepts every original ID in its region; a
local integer routes an interior resume into the right prefix or arm. Once ordinary execution
enters a region, sequential transfers fall through and choices use a latched condition. A
single fully reduced region that exits the function needs no dispatcher. No second copy of
the body exists for resumption. Every original block's cycle increment and safe point remains
in place, and the branch condition is still captured before its delay slot executes.

Keep `--no-regions` as a scalar-register/simple-loop baseline and `--no-opt` as the context-field
reference. Both paths use the same machine IR. Register publication/reload remains conservative
and function-wide: effect flags describe individual instructions, not transitive call effects.
Calls, traps, unknown control transfers and due pumps cannot be assumed to preserve GPRs.

## Alternatives

- A complete SSA optimizer is not required to prove these local region reductions. Deferring it
  keeps this change separately measurable; cross-block data flow can consume the same IR later.
- A separate fast-entry body would remove resume checks but duplicate code. Console code size
  remains part of acceptance, so ordinary calls and arbitrary resumes share one implementation.
- Removing all switches would require a more general structurer and would misrepresent actual
  computed control flow. The residual dispatcher remains a deterministic, tested fallback.
- Promoting game memory to Haxe objects would require alias, DMA and overlay guarantees absent
  here. This change leaves the flat memory model and backend API unchanged.

## Consequences

Resume routing and explicit nesting can increase source and binary size despite reducing
dispatch. Measure both targets and code size; fewer cases are not a timing result. Keep runtime
diagnostic costs separate from codegen measurements. `scripts/bench-regions.sh` compares the same
25-million-iteration synthetic branch/loop workload with and without regions, alternating order
and reporting five-sample medians after warm-up. No game assets are involved in that benchmark.

`Regions` conformance uses synthetic diamonds, nested branches, loops, side entries, a two-entry
irreducible loop, reverse address layout, same-successor branches, unterminated fallthrough
blocks, external exits and eight deterministic forward CFGs. Every valid block entry is run
with varied registers against the reference on JS and reflaxe.CPP. It compares all GPRs,
HI/LO, cycles, PC, unwind state and timing hints; separate expected results cover branch slots,
callbacks, immediate halt, nonlocal unwind and modified jump-table targets. `Codegen` retains
the existing numeric/slot/overlay-independent emitter fixtures. Acceptance results and measured
tradeoffs belong in `PROGRESS.md`.

This does not implement general native multi-block loops, register liveness, or a browser yield
runtime. Stable resume IDs remain available for that separate main-thread browser work.
