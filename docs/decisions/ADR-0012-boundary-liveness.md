# ADR-0012: Boundary-aware register liveness
Status: accepted   Date: 2026-09-21

## Context

Scalar GPR lowering made generated Haxe use locals, but every returning call, due pump and
syscall reloaded the complete function-wide `used` set. That was safe but emitted redundant
`ctx` reads in large functions. The generator cannot assume a MIPS ABI: runtime calls, kernel
HLE and callbacks can observe or modify any register, and cooperative suspension can resume at
an interior block.

## Decision

Run a backwards register liveness pass over `FunctionIR`. Publish every function-written GPR
before an external boundary, then reload only the values required by the continuation, the
current block after a pump, or the remaining instructions after a syscall. Seed function exits
with the complete written set because `emitReturn` publishes the architectural register file;
this keeps callback and cooperative state observable even when a register is not read by later
guest instructions. Keep `RegisterMask` as an `Int`-backed build-time abstraction and emit no
runtime mask, table or wrapper.

## Alternatives

- Reload every used register everywhere. Rejected because it increases generated source and
  native memory traffic without improving fidelity.
- Use callee read/write summaries to narrow stores before calls. Deferred because due pumps and
  callbacks make a syntactic callee summary insufficient for the generic runtime boundary.
- Represent the runtime register file as an abstract over an array. Rejected by the existing
  static-field/accessor measurements: it adds indirection to the hot path and weakens reflaxe.CPP
  lowering; named `CpuState` fields remain the portable target representation.

## Consequences

The pass is generic over arbitrary discovered CFGs and preserves all interior entries. Source
size reduction is expected at post-boundary reloads, while publication remains conservative.
`Codegen` and `Yielding` fixtures cover callback mutation, cooperative resumption and observable
register state. JS is the fast development gate; the default two-target gate remains required
before a release or push that changes the portable runtime/codegen contract.
