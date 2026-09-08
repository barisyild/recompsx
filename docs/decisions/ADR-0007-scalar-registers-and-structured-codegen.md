# ADR-0007: Scalar registers and structured code generation
Status: accepted   Date: 2026-09-08

## Context

The emitter already performs static translation: MIPS instructions are decoded at build time,
known calls become Haxe calls, and generated execution never fetches or decodes an opcode.
However, every multi-block function used a block dispatcher and nearly every guest instruction
read or wrote shared `CpuState` fields. Haxe's analyzer had little local data flow to optimize.
Generated code therefore resembled a register-machine listing even when its CFG was simple.

The output must preserve every block's entry index for `longjmp`, threads and indirect dispatch;
overlay call policy must also remain unchanged. Generating an optimized entry body plus a
separate resume body would duplicate code on consoles with limited memory.

## Decision

Lower each function's used GPRs to primitive Haxe locals, using `RegisterPlan` to identify its
read/write set. Initialize every used local from `CpuState` even on an interior entry. Publish
written registers before guest/kernel calls, normal returns and due scheduler pumps. After a
returning call or pump, reload all used registers without assuming a guest calling convention.
If an unwind token is set, return immediately before publishing stale locals over restored
state. HI/LO and coprocessor state remain in their existing helpers; memory helpers defer guest
callbacks to the pump and do not observe the cached GPRs.

Emit address-ordered linear chains as Haxe sequences, with entry guards that skip the prefix
when resuming. Emit conditional self-loops as native `while`, including within a larger block
dispatcher. Keep the dispatcher for other CFGs and computed switch targets. Emit each block
once, and retain its original entry index. Do not remove pump sites or merge guest cycle charges.

Keep `gen --no-opt` as a differential reference using context fields and block dispatch. Both
modes include correctness fixes: 32-bit cycle wrapping, JALR to `$zero` treated as a tail jump
throughout discovery/table recovery/emission (no link or call-return continuation), actual
conditional calls for BLTZAL/BGEZAL, and immediate halt/unwind checks after pumps. A one-block
unconditional loop must also retain a loop instead of emitting an undeclared `bb` variable.
Generated direct callers check every call/barrier; `Runtime.call` guards external entry while
unwinding. Function entries only check for a new token when a pump was due, avoiding a redundant
branch on every ordinary call. `Runtime.pump` stops before queued callbacks/IRQs if a scheduler
event or callback has requested an unwind.

Branch conditions/targets are captured before the slot; links are written before the slot,
including unconditional link writes for conditional calls. Discarded loads still perform the
read. These follow the [psx-spx CPU specification](https://psx-spx.consoledev.net/cpuspecifications/).
Optimization does not add load-delay accuracy, overflow exceptions or instruction-cache modeling.

## Alternatives

- Reconstructing source-level variables and the original call ABI would require assumptions
  about register preservation, stack aliasing and hand-written assembly. Scalar GPR locals
  expose optimizable data flow while preserving the existing machine-state interface.
- Removing every dispatcher requires more general CFG structuring. This change only structures
  regions it can prove, with a deterministic fallback and no duplicated resume implementation.
- Keeping all context stores avoids synchronization logic but prevents useful constant/copy
  propagation and dead-write elimination by the already-enabled Haxe analyzer.

## Consequences and verification

Generated source includes explicit register synchronization. These cold boundaries increase
Haxe source size; binary size and whole-game timings must be measured alongside a loop benchmark.
The common loop path has no GPR publish/reload unless an event is due.

`TestCodegen` assembles synthetic programs and emits both implementations into ignored output.
`scripts/conformance.sh Codegen` compiles and runs that output on JS and reflaxe.CPP, compares
all GPRs, HI/LO, cycles, PC and unwind state, and asserts independent expected results. It covers
native and multi-block loops, resumed blocks/call returns, delay slots, direct/indirect and
conditional calls, register changes during callbacks, unwind, memory widths, discarded MMIO
reads, recovered tables, arithmetic, self-moves and cycle overflow. The code-shape experiment
passed on both targets before full-game verification. `scripts/bench-codegen.sh` rebuilds both
modes and measures identical 50-million-iteration MIPS xorshift workloads, alternating modes
and reporting five-run medians after warm-up. Host timing never enters guest state.

Scalar locals exposed a separate reflaxe bug: `RemoveReassignedVariableDeclarationsImpl` moved
the same declaration twice after constant propagation. The 17-instruction `constantStores`
fixture reproduced `Uncaught exception Logic error` before patch 0005 and passed after it.
The same pass also missed reads inside variable initializers and nested blocks, moving a
declaration past its uses and producing undeclared C++ identifiers. The five-instruction
`loadThenRedefine` and `storeThenRedefine` fixtures reproduced those build failures. The fix
tracks both kinds of reads and removes a declaration from the candidate list once moved;
the exported patch is in
`vendor/patches/0005-reflaxe-reassigned-local-declarations.patch`. Existing vendor changes and
submodule pins are preserved. `scripts/setup.sh` applies the exported patch idempotently.

Immediate pump unwinding changes the final state sampled by headless hashes: the old emitter
continued executing after the requested halt until a later call returned. On this checkout,
the old 3000-frame Crash Bash digest was `d8ab3d52`; both corrected emitter modes on JS and
optimized C++ produce `6bd5e3fd`. This is a correctness change shared by both modes, not an
optimization-induced divergence. Full acceptance output and measured results are recorded in
`PROGRESS.md`.
