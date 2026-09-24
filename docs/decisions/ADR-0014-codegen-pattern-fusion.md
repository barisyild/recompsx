# ADR-0014: Fuse closed instruction patterns before Haxe emission
Status: accepted   Date: 2026-09-21

## Context

The generated program is already scalar at the GPR level, but short MIPS idioms still became
separate Haxe statements. Some pairs only create a constant, while multiply/divide followed
immediately by `mflo` or `mfhi` performs a helper call and then reads the same architectural
result pair. These shapes occur across games and can be recognized without whole-program alias
analysis.

## Decision

Add a build-time `PatternMatcher` over adjacent instructions in each basic-block body. The first
patterns are:

- `lui rt, imm; ori/addiu rt, rt, imm` → one constant assignment;
- `mult/multu/div/divu; mflo/mfhi` → one `core.Ops` fused result helper;
- a discarded `mflo/mfhi` still emits the underlying multiply/divide because HI:LO is observable.

The original `FunctionIR` instructions remain authoritative for register masks, instruction
count and cycle accounting. The matcher never crosses a delay slot, control transfer, trap,
memory access or scheduler boundary. A failed match falls back to ordinary emission.

## Alternatives

- Match text after Haxe emission. Rejected because it loses MIPS delay-slot and effect metadata,
  and can change output without a corresponding IR proof.
- Fuse arbitrary load/store sequences. Deferred because RAM aliases, MMIO and DMA make a local
  textual match unsound; those require the separate memory-promotion analysis.
- Route every instruction through a generic runtime pattern table. Rejected because it adds a
  dispatch cost to ordinary code and turns a static compilation problem into interpretation.

## Consequences

The output is shorter and gives the Haxe/C++ optimizer recognizable operation boundaries while
preserving architectural HI:LO state. The optimization is generic over discovered MIPS CFGs and
has no game-specific addresses. Tool generation checks the emitted helper forms, and the
`Codegen` conformance fixture compares all signed/unsigned low/high forms on JavaScript and
reflaxe.CPP (`a71569d0` after the zero-destination case was added).
