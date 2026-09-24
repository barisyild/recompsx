# ADR-0016: Forward conservative stack word traffic in generated blocks
Status: accepted  Date: 2026-09-21

## Context

Scalar GPR lowering already removes many register-file reads and writes, but compiler-generated
MIPS still uses the emulated memory for ordinary stack spills and reloads. A whole-program stack
promotion pass would need alias information that a generic PS1 executable does not provide: `$sp`
and `$fp` can be adjusted, pointers can escape, and hardware registers share the address space.
The JavaScript iteration target needs a safe code-size and memory-traffic win without changing the
raw-memory boundary that the later reflaxe.CPP target will use.

## Decision

Add a build-time pass over each original basic-block body. It records only aligned word `sw` and
`lw` instructions whose base register is `$sp` or `$fp` and whose signed immediate identifies the
same slot.

- A later store to the exact slot removes the earlier store when no intervening memory or control
  effect was seen.
- A load from the exact slot is replaced by an assignment from the stored source GPR when the
  base register and source GPR versions are unchanged.
- Any other memory operation, stack/frame-pointer write, trap, control effect or unknown effect
  clears the facts. The pass does not cross a call, branch, delay slot or scheduler boundary.
- The original instruction and cycle counts remain authoritative, and loads to `$zero` still
  execute because memory reads may have device side effects.

This is intentionally a forwarding pass, not a claim that all stack addresses are ordinary RAM or
that a guest stack can be represented entirely by Haxe locals. Full stack-slot promotion can be
considered after cross-block alias facts and escape handling exist.

## Consequences

Generated Haxe can avoid common spill reloads and superseded stores while retaining `Memory` calls
for uncertain accesses. The pass is generic across games and stays compatible with the scalar
CpuState boundary. It currently cannot remove traffic across blocks or prove non-overlap between
different `$sp`/`$fp` slots, so further gains require a conservative CFG memory analysis.
