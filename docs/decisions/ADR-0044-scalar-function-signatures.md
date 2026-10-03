# ADR-0044: Recover scalar function signatures for bounded functions
Status: accepted   Date: 2026-10-01

## Context

The owner asked for generated Haxe with ordinary parameters and return values instead of
CpuState traffic. ADR-0029 remains the general register model: local register copies across
unknown calls were both expensive and unsound. Signature recovery needs proof of every
observable output, not an assumption that a MIPS caller ignores caller-saved registers.
The research example is rev.ng's
[register-to-argument/return promotion](https://docs.rev.ng/references/artifacts/#enforce-abi-artifact).
This implementation uses our own MIPS IR and does not depend on rev.ng.

## Decision

Add a build-time `ScalarPlan` to lift short register-only leaves into value SSA. Moves share
values, every other definition gets a fresh value, and every final GPR value is compared with
its incoming value. The first stage recovers a helper returning `Int` only when exactly one GPR changes. Its
parameters are the incoming values reachable from that output; dead pure definitions are
omitted, while all original instructions and cycles are charged. Emit an ordinary static
Haxe method named `<function>_value`, without CpuState, allocation or forced inlining.

The first implementation accepts one basic block, at most 32 instructions and six live inputs,
ending in `jr ra` and its delay slot. A whitelist admits nontrapping integer arithmetic, bit
operations and comparisons. Memory, coprocessors, HI/LO, traps, calls, branches, changed return
addresses, hooks and relocatable functions keep their existing generated bodies. Multiple
outputs initially keep that path, even if the extra output is an ABI scratch register; the
multiple-result extension below removes this restriction. These bounds
are conservative implementation limits, not a recovered calling convention.

The next stage also admits `lb/lbu/lh/lhu/lw` behind a plain-memory span proof. Track affine
addresses through moves, `addiu`, constant `addu/subu`, and constant construction: each load
must address the same incoming GPR plus a constant, or an absolute constant. Bound the relative
offsets to signed 16 bits, as `Memory.span` requires. This initial stage rejects load-dependent pointers, different
bases, incompatible alignment requirements and constant ranges known to be outside RAM or
scratchpad. Preflight **every** original read, including dead results and loads into `$zero`;
dropping a device read based on result liveness would lose a hardware side effect.

After the normal entry checkpoint/pump, compute `Memory.span` over the entire read range and
check each access's required alignment. Only the successful arm calls the helper. Its
`readMemory:shim.Span` parameter is an arena index on JS and a pointer on C++; it is not an
allocated memory object. The helper uses `Memory.spanRead*`, has no CpuState parameter, and
may discard unused RAM reads. The span counts toward the six-parameter limit. Guard failure
falls through to the original emitted body without having read memory, changed a register,
or charged cycles. Thus MMIO ordering, mirror boundaries and existing unaligned behavior
remain on the general path. Memory helpers initially go through the callee wrapper; the later
caller-span borrowing extension below can reuse an existing proof. This avoids duplicating
full span preflight at each call site. That stage introduces no stores, memory privatization
or stack recovery; the ordered-memory extension below adds plain stores and multiple spans.

Keep each accepted function's CpuState entry wrapper and its checkpoint/pump prologue. Inside
it, call the scalar helper and publish the one result. A direct caller may invoke a register-only
helper itself only when its existing code-residency proof identifies the callee, no event is due, and
no cooperative entry work can run. Otherwise call the wrapper. The cooperative guard must not
call `wantsYield`: that would count a stress checkpoint twice. It checks the necessary deadline,
enabled/stress and resume conditions instead, conservatively retaining the slow path. Preserve
the existing after-call unwind/resumption logic, cycles, instruction/block counters and spans.

Resolve summaries in the callee's universe; a hook in that universe prevents scalar calls.
When bodies are deduplicated, forward the scalar signature as well as the CpuState entry to the
same owner, including its span parameter when present. `--no-scalar` disables only this pass
for controlled comparisons; `--no-opt` disables it with the other optimizations. All analysis
is static and game-independent.

### Call summaries and caller-specific outputs

`FunctionSummary` records semantic input GPRs, may-writes, never-written registers, effects,
and direct/indirect/tail call edges. Local must-definitions intersect CFG predecessors;
callee inputs are read after the link write and delay slot. Resolve callees with the existing
overlay residency rule, then union summaries across the call graph to a fixed point, including
recursion. Unresolved calls, traps and hooks are conservative; hook changes invalidate summaries.
Checked nonlocal returns carry a separate effect: they unwind frames without running another
callee before the caller's continuation, so they do not imply all-GPR clobbers. These may-write masks also serve the existing span
refresh analysis. `ADDI/ADD/SUB` now explicitly carry their overflow trap effect in machine IR.
This conservatively constrains optimization; it does not implement the runtime's still-missing
arithmetic overflow exceptions (the current emitter continues to wrap those operations).
Summaries follow what is emitted (2026-10-02, ledger E-075): an unproved ADD/ADDI/SUB keeps
TRAP, so projection and the scalar lift still refuse it, but it no longer makes its function read
and write every register — no handler runs, since no overflow exception is raised. As a trap into
unknown code it had made each caller of such a function take all its spans again after the call
(Crash 3's renderer helper f_80041b7c). Emulating overflow exceptions would bring both back
together: the emitted trap and the summary's unknown effects.
Inputs can be overestimated and are not a recovered calling convention or enough to lower
arbitrary functions: calls do not kill input dependencies, and preservation means never-written,
not saved-and-restored.

`BoundaryLiveness` separately computes the registers needed after each call. Every return,
unknown transfer, loop pump, entry, memory access, coprocessor/HI:LO effect, trap and next call
requires full state. Only an overwrite on **every** path before any read or observation can
remove a result. Branch operands are read before the delay slot. Memory reads into `$zero`
are still boundaries. This is stricter than ordinary ABI liveness.

For a resident, unhooked, pure bounded leaf called with `jal`, the caller may use a specialized
`(...):Int` helper when only one changed result remains live. Value SSA drops the other results
and their unused computations/inputs. The original callee wrapper still publishes every result
for public dispatch and other callers. Projected calls additionally fall back on any existing unwind token, since
unwinding might bypass the caller's proven overwrites. Entry events, cooperative checkpoints,
instruction/block/cycle accounting and after-call checks keep the earlier rules. The memory
extension below preserves the complete access preflight. Indirect/conditional/tail calls and
relocatable callers remain excluded.

This stage does not reconstruct arbitrary partial state at runtime. It proves omitted values
are overwritten before the next observation; if that proof fails, all outputs remain on the
full-state path. The CFG and multiple-result stages below extend this proof; stack recovery and
internal observations remain future work. `--no-scalar` disables caller projections as well as whole-function scalar helpers.

### Project memory results without weakening access checks

Caller-specific result liveness also applies to bounded memory leaves/acyclic functions at
resident, unhooked direct `jal` sites. Program's summary gate admits control and memory effects;
calls, traps, unknown state and nonlocal returns still reject projection. The value analysis
must independently prove every access. Lift every original instruction and retain the entire
memory/alias preflight before removing dead register outputs. Ordered writes and original
path accounting remain graph roots. Only result-dependent pure work, reads from already
proved plain memory and unused result transport can disappear. Discarding every read result
can produce a Void helper with no body parameters; its entry still checks every original
access and takes the full original callee on failure, so MMIO reads are never discarded.

If the caller already supplies complete borrowed spans, reuse them only when the projected
plan's emitted preflight exactly matches the full plan's preflight. This conservative
build-time equality preserves the earlier donor-liveness, offsets, alignment and alias
proofs. Otherwise a caller-specific entry adapter constructs the complete preflight itself,
inside the same slow-entry guard as other projections. No new spans are added to the caller.
That adapter also handles constant and checked loaded addresses which cannot borrow an
incoming register's span. Entry events, pending resumes, cooperative checks and pre-existing
unwind tokens all fall back to the full original entry before any helper effect.

Helpers/adapters have call-site-specific names. Memory bodies stay outside the pure scalar
pool; the fallback retains its original owning class even if the projection is emitted in
a different shard. Public callee entries and other callers keep their full outputs. Pointer
results omitted before a caller overwrite do not change the existing span invalidation and
refresh rules. This proves local unobservability, not a caller-saved ABI convention, and does
not add recovery across internal guest calls or observation points.

`ScalarBorrow` adds fixtures for partial/all-dead read results, ordered/aliasing stores,
conditional accounting, overwritten pointer results, incomplete/missing donor spans,
constant/dependent addresses, a different fallback owner, and rejection when an observation
or one branch can still see an output. Every public caller/callee entry, entry-event offset,
cooperative resume and existing unwind is compared with original code. Dead-result FIFO reads
test that both borrowed and newly constructed preflight take the effectful original fallback.
Program-level tests exercise the residency/summary callbacks and hook invalidation, preventing
an older pure-only summary filter from silently disabling this path in real game generation.

### Share equal memory projections within a class

A memory projection is still emitted beside its caller as a helper plus its `_projected_` or
`_withSpans_` adapter, under call-site names. `Program` now shares one such pair between the call
sites of one emitted class (shard) when the two pairs' complete texts are equal after only the
pair's own two names are replaced by placeholders (`ProjectionShare`). Everything else is text and
so part of the key: parameters, the `Int`/`Void` shape and ScalarResult words, which registers are
published, every span, alias, alignment and sample check of the preflight, ordered memory effects,
signedness and `| 0` wrapping, path/cycle/instruction/block accounting, the fallback owner and
callee, the borrowed or fresh form and the entry-event, resume and unwind guards. No address,
hash, algebraic normalization or partial equality decides sharing. The first pair in shard
emission order keeps its names; later call sites are renamed to it and their copies are not
emitted. Only which name a call site uses changes; what it executes is the same text.

Whole pairs are shared rather than helpers alone. A pair of equal text runs identically at every
site and needs no new key; sharing only the helper would make adapters call other sites' helpers
and would need a separate proof that their remaining adapter differences are harmless. The measured
repetitions were whole pairs. Memory projections still stay outside the pure `ScalarValues` pool.

Sharing never crosses a class, so a shared method is always defined where it is called. It runs
after `Program.bodyOf` has compared the complete original texts across universes, with every
site-specific name: a body forwarded to another universe runs that owner's own projections, and
identical overlay code with different fallback owners keeps different texts and is not forwarded.
Names and order follow shard order, so repeated writes are byte-identical and no extra module is
generated. `--no-projection-share` emits every pair at its own site for comparisons; with it, both
games' generated Haxe and ES6 JS are byte-identical to the preceding stage.

`TestProjectionShare` writes whole programs: equal fresh and equal borrowed pairs share while
staying apart from each other; a different dead result and the same code at another callee stay
distinct; output is deterministic; the opt-out and a hook on the callee behave as before; equal
pairs in two shards stay in each shard; overlay bodies forwarded to an owner rely on the owner's
shared pair. Unit tests check that one constant splits a key, that a pair lacking its adapter is
never shared and that attachments which are not the end of the caller's text are an error.
`ScalarShare` executes a class assembled by the same code against the reference at every public
entry, over mirrored, scratchpad and boundary addresses, MMIO fallback, cooperative slices, due
events and existing unwinds, on JS and reflaxe.CPP; deliberately weakening the key to "same callee
and form" makes it fail (60 mismatches). For both games, an out-of-tree check confirmed that every
call site runs a pair whose text equals its own pre-sharing pair and that no other text changed.
Emitted pairs fall from 73 to 48 in Crash 3 and from 108 to 69 in Crash Bash; ES6 JS shrinks by
41,985 and 82,888 bytes. Timing on a loaded host shows no established change (PROGRESS.md); the
gain recorded here is code size, not speed.

### GTE operations and unaligned loads as ordered effects

`ScalarGraph` admits coprocessor 2 and LWL/LWR where effects are ordered (helpers, never value
regions). The GTE register file is one global state in program order, so:

- MTC2, CTC2 and every COP2 command with a name in the emitter's table are ordered effects,
  roots of the graph like stores, under their block's reach predicate in a CFG. A word the
  table does not know needs `Gte.execute` with the CPU state; its function keeps its body.
- MFC2 and CFC2 are values materialized where they stand (`ScalarPlan.emitHelper` keeps a
  GTE helper's results in order and never moves a read into its `return`). A read has no
  effect, the SXY FIFO's mirror included, so a dead one is dropped and one on a path is not
  predicated: in a CFG it reads the state its path has reached and is used only there.
- LWC2 and SWC2 are a checked 4-byte span access followed or preceded by that write or read.
- Helpers call `Gte.readData`, `writeData`, `readControl` and `writeControl`, which need no CPU
  state; `getData` and the others delegate to them, so other code is unchanged. NCLIP, AVSZ3
  and AVSZ4 run inline, RTPS as a call, E-031's rule for code holding guest registers as locals.
- A GTE helper never enters the pure pool, a GTE projection stays with its caller, and a child
  call that touches the GTE is its parent's effect (`coprocessor` propagates). `Program`'s
  projection gate admits coprocessor flags: the whitelist itself still rejects coprocessor 0.

LWL and LWR read the aligned word holding the addressed byte and merge it (`Memory.spanLwl`,
`spanLwr`). Preflight checks that byte without an alignment condition: RAM and the scratchpad
start and end on word boundaries in the arena, so the word lies in the byte's region, and an
arena index has its guest address's alignment. They are always real loads in program order:
never forwarded from a store, never sampled at entry and never an address root. SWL/SWR stay out.

A CFG block that no path from entry zero reaches — a constant branch's other arm, as after
`bgez $zero` — is no longer lifted: its accesses are not preflighted and its effects never run.
Before, such an arm's spans were checked at every call although nothing could execute them.
When every path costs the same, the CFG's packed accounting word is a constant
(`ScalarPlan.pathAccounting()` is false): callers charge it lane by lane and the helper does not
store it in `ScalarResult.accounting` (Crash 3 63 → 53 stores, Crash Bash 102 → 86).

`TestScalarCop` checks what is admitted and in which order a helper emits it, and writes the
`ScalarCop` fixture: twelve guest functions (RTPS leaves, LWC2/SWC2 with a forwarded read, the
inline commands, GTE effects on one CFG arm, the SXY FIFO, LZCS and IRGB, LWL/LWR pairs and lone
halves, a reader shaped like Crash 3's stream decoder, unaligned reads around stores, a GTE child
call, a GTE projection, a lone result read before a command, a pruned arm). The conformance group
runs every entry against the reference over RAM, mirrors, scratchpad and failing boundaries, all
four alignments, cooperative slices, entry events, an MMIO fallback and existing unwinds,
comparing CPU state, memory and all 64 GTE registers, on JS and reflaxe.CPP. Removing the LWR
merge, the predicate on GTE effects or the ordered emission each makes it fail.

Coverage: Crash 3 151 → 171 helpers, Crash Bash 175 → 180. By the Dreamcast model's per-function
instruction counts, recovered functions run 1.71 % of the generated code's instructions in Crash
3's gameplay window (0.36 % before), 0.33 % on its title screen (0.13 %) and 1.00 % in Ballistix
(0.25 %). No speed change is established (ledger E-067, E-068): issue time is unchanged and the
conflict-free differences are instruction fills that follow the layout. The hottest acyclic GTE
and LWL functions stay out — Crash 3's stream reader and matrix routines index memory with a
computed register (base plus index), which no span is anchored at, and Crash Bash's f_800330cc
is over the body budget — and the CpuState is only about 15 % of their SH-4 instructions, which
bounds what recovering them could save.

### Share equivalent projected calculations

The initial implementation emitted a helper in each caller, named
`<callee>_value_from_<caller>_<site>`. `Program` now interns these pure calculations in a generated
`ScalarValues` class. `ScalarPlan.sharedBody` normalizes live input names by argument position
and live SSA names by definition order, removing gaps left by dead definitions. The entire
normalized signature and body are the key: constants, operand order, shift counts and explicit
32-bit wraps participate. No address-only matching, hash collision risk or algebraic equivalence
assumption is involved. Different guest registers or omitted computations can share code;
different calculations at the same overlay address cannot.

The caller still selects the resident callee, proves output liveness, guards entry work/unwinds,
maps guest inputs/outputs, falls back to its own original wrapper and charges its own original
instruction/block/cycle counts. Those facts are deliberately excluded from the pure calculation
key. All shared methods are static `Int` computations, without CpuState, runtime allocation or
forced inline. All memory helpers stay outside the pool. Standalone emitters without a pool
retain self-contained caller-owned helpers; normal program generation always shares projections.

The pool is emitted after the shards, in stable first-use order, and only if it is used. Rewriting
a program clears both the helper pool and function-body ownership map; opt-outs remove stale
generated modules along with the rest of the generated Haxe. This also keeps repeated writes,
hook changes and overlay body deduplication from leaving references to missing methods.

### Prove nontrapping arithmetic within a block

`InstructionIR` initially marks `ADD/ADDI/SUB` as possibly trapping. `FunctionIR` now visits
each basic block with a fresh `RegisterRanges` analysis. Immutable signed word intervals track
constants, masks, shifts, comparisons and arithmetic. Overflow proofs use guarded integer
comparisons against MIN/MAX; they never compute an overflowing proof bound or use host Float.
Wrapped unsigned operations widen to unknown unless both operands are constants or the
result interval is provably representable. Same-register subtraction is exactly zero.

Only a proved arithmetic instruction loses `Effect.TRAP`. Its decoded opcode, register effects
and guest cost stay unchanged. `ScalarPlan` admits these proved signed operations with the same
explicit `| 0` result wrapping as unsigned arithmetic. Same SSA-value subtraction, XOR and
ordered comparisons simplify to zero; AND/OR simplify to the operand. This can remove parameters
and dead computations without inventing an ABI. Summaries and span analysis see the same refined IR.

Every addressable block starts with unknown registers, except `$zero`. An interior dispatch or
resume need not carry its predecessor's values. Memory accesses, coprocessors, HI/LO helpers,
unknown instructions and unproved traps clear facts. In particular, byte/halfword load width
is not used as a range proof: successful access and load completion have not been proved.
The [PS1 CPU specification](https://psx-spx.consoledev.net/ps1/cpu/cpuspecifications/) describes
overflow traps, load faults and delayed load visibility. Existing runtime omissions of those
behaviors remain documented in the tool specification; this pass does not implement them.
Calls execute after their delay slot, so only the link destination becomes unknown before that
slot; the continuation is a new block with no inherited facts. Relocatable link PCs are never
treated as constants. Possible overflow remains conservative even for writes into `$zero`.

This is local proof infrastructure, not general CFG value SSA. On the two current game images,
both regenerated ES6 bundles are byte-identical to the pooled-helper stage: Crash 3 remains
24,993,264 bytes/13 helpers and Crash Bash 23,724,273 bytes/18 helpers (including the pool).
There is no measured game optimization gain from this extension. `TestRegisterRanges` checks
interval containment and overflow proofs over signed edge/interior values. `RangeCodegen`
executes emitted optimized/reference code for safe and unsafe arithmetic, branch/call delay
slots, interior entries, checked reads, FIFO fallback, event halts and cooperative suspension.
The existing `ScalarCalls` trap-barrier fixture now uses an unknown input, since adding seven
to literal zero is provably nontrapping; its changed digest reflects that fixture change.

### Acyclic CFG values and path-dependent accounting

`ScalarGraph` supplies the shared instruction-to-value lift. `ScalarCfg` accepts an acyclic
CFG within the analysis/body budgets below and the six-parameter bound. Topological processing
associates each edge with a reachability predicate and register-value environment. At joins,
phi selections merge unequal values under those predicates; equal values remain shared. Branch
operands become values before lifting the delay slot. All terminal environments participate in
the output/preservation proof, including scratch registers. Caller projections retain the existing
boundary-liveness proof. Parameters include both result and timing dependencies: a branch input
remains required for a constant result when its paths have unequal costs. If the result, effects
and accounting are independent of that input, the recovered signature can omit it.

Only effect-free integer operations may be evaluated speculatively in the resulting value DAG.
Checked memory is guarded by block reachability as described below; coprocessors, HI/LO,
unproved traps, unknown transfers, changed return addresses and internal pumps are
excluded. The composed-call extension below admits proved direct calls with an additional
observation-window guard. Any backward-edge pump is excluded,
even in an otherwise acyclic graph. Thus intermediate computations have no architectural observer.
Helpers have scalar/span arguments and an Int or Void return, with no CpuState or register array. Haxe sees
immutable locals and conditional expressions, not a basic-block dispatcher. No heap tuple,
allocation, forced inline, workers or JIT are introduced.

The selected path's cycle/instruction/block counts are packed into a second return word: ten
bits each, with checked whole-DAG upper bounds of 1023 per lane. Reachability predicates select
each block's charge; unselected calculations charge no guest instructions. The helper writes
`core.ScalarResult.accounting` immediately before returning. Its adapter/caller consumes it
immediately, before another helper/runtime call, pump or observation, and adds the counts with
word wrapping. Fixed-cost single-block helpers keep their immediate counts and do not use it.
This is a compiler ABI temporary, not a guest register file or saved emulated state. Its safety
depends on the no-callback/no-suspension, non-reentrant helper contract; a transparent forwarding
helper and checked plain-memory accessors are the only allowed calls. Reentrant or recursive helpers require a different return
protocol. This avoids allocating a tuple on JS or C++ merely to return value plus accounting.

The entry adapter retains its events/checkpoints. Only entry zero uses the CFG helper; public
interior entries and resumptions into later blocks execute the original body using the actual
CpuState. Direct-call guards and projected-call unwind checks are unchanged. Selected results
and counters are published before the next observation. Shared CFG helper keys include their
accounting computation, so equal output formulas with unequal path costs cannot alias; fixed
linear accounting remains outside the key.

`ScalarPredicates` interns comparisons by immutable SSA operands and applies Boolean identities
at generation time: complementary paths recover their incoming reach predicate, repeated tests
share their captured value, and phis under the same or opposite condition select the known arm.
Exact affine value identity can prove equal phi inputs. Different loads are never equated merely
because they read the same guest address or write the same register. In particular, a store and
reload can produce a new condition. These proofs remove redundant guards without moving effects.
They describe ordinary entry only; an arm proved unreachable there remains a valid public
interior entry in the original body.

`ScalarAccounting` groups original block charges by their simplified reach predicates. Equal-cost
disjoint paths share a charge under their union; complementary paths select between two costs.
An unconditional charge becomes a literal. The existing whole-DAG lane bounds still apply, and
every selected original block contributes exactly once. Predicate simplification and accounting
run entirely in the build-time tool, with no runtime cache, extra ABI word or allocation.

`ScalarCfg` conformance executes all six conditional branches, joined/nested diamonds,
same-target edges, predicate-changing delay slots, multiple exits, constant results with unequal
and equal costs, repeated tests with entry-unreachable arms, projected/public outputs, consecutive
calls, interior entries, event halts and suspension traces. Tool tests cover complete three-input
Boolean truth tables, SSA identity, cost-sensitive pooling, cross-universe sharing, hooks and opt-outs.
Games gain two whole-function helpers in Crash 3, and one whole-function plus three shared
projected helpers in Crash Bash; the latter gains ten specialized call sites. These are static
coverage counts; size/timing evidence is in PROGRESS.md. Loops, effectful regions, stack recovery
and reconstruction at internal observations remain future work. This stage implements bounded
acyclic value SSA, not complete ABI recovery.

### Multiple results and exact boundary reconstruction

The single-changed-GPR restriction is removed for both linear and acyclic helpers. Every final
GPR still participates in the output proof; there is no special treatment for `v0/v1` or scratch
registers. A value equal to its incoming register is preserved, including exact wrapped affine
identities such as decrementing and then restoring `sp`. Phi merges also recognize this identity.
No memory save/restore or calling-convention assumption supplies that proof.

The caller reconstructs constants and values of the form incoming GPR plus a known word offset.
It captures any original input needed by reconstruction before publishing any output. Aliases
reuse the same value. Only distinct computed results cross the helper boundary: the first uses
the ordinary Int return, and subsequent results use `core.ScalarResult.value1` through `value29`.
Slot numbers describe positions in this helper's result signature, never guest register numbers.
If every output is reconstructable, one still uses the ordinary return. A memory setter with
no changed GPR can instead return Void, as described below. Only live computation/timing inputs count toward the six-parameter limit; captured
reconstruction inputs do not become unnecessary helper parameters.

These additional words inherit the accounting word's non-reentrant protocol. The helper may not
call out, pump or suspend; memory helpers can only access their already validated plain spans.
After a return, the caller binds **all** additional result words to locals, publishes reconstructed
and computed outputs, and consumes accounting before any helper/runtime call or observation.
Transparent forwarding preserves the entire signature. No arrays, tuples, allocation or fixed
register file are introduced. Unused slots are removed by full DCE; the two current game builds
use at most `value4` at that stage. Observable device effects and recursive helpers remain outside this ABI.

Caller projections can retain several outputs while dropping others proved dead by the existing
boundary analysis. They remain preferred even when a full multi-result callee is available.
The original entry still publishes every architectural output. Pure helper interning includes
every result computation, order, arity and CFG accounting in its normalized body, while register
destinations, reconstruction expressions and fixed linear costs remain call-specific. Different
secondary calculations cannot share merely because their first returned value matches.

`ScalarResults` compares generated optimized/reference code for distinct and aliased outputs,
overwritten incoming operands, constants, restored registers, 30 simultaneous changed GPRs,
checked memory, multiple-output CFGs, projected/public calls, consecutive helpers, forwarding,
event halts and cooperative suspension. Independent formulas check the arithmetic results.
Alignment rejection tests execute the generated guard without making an invalid aligned-MemA
access; MMIO and aligned boundary fallbacks execute the real bodies. Misaligned `lw` still has
no portable result until address errors are implemented (the existing tool/runtime limitation).
Coverage grows from 15 to 33 helpers in Crash 3 and from 22 to 38 in Crash Bash; the latter has
46 projected call sites. These are static coverage counts, not a claim of game speedup. Full
size, test and timing evidence is recorded in PROGRESS.md.

### Ordered plain-memory effects and multiple memory parameters

Linear signature recovery also accepts `sb/sh/sw`. Every access must still have an address
expressible as an incoming GPR plus a constant, or an absolute constant, and must pass a
plain-RAM/scratchpad/alignment proof. Several address bases form several `shim.Span` parameters;
distant offsets may use separate spans so no individual range exceeds the existing arithmetic
bounds. The initial signature carries every span; the sample-lowering extension below omits
body-unused spans while retaining their preflight. Parameter names make no non-aliasing
promise: distinct inputs may name overlapping bytes, another RAM mirror, or a scratchpad alias.

Before running the helper, the adapter computes and validates **all** spans. These metadata
operations perform no guest reads or writes for input/constant spans; the dependent-read
extension below adds checked, side-effect-free RAM samples. A failed check falls through to the entire original
body. It cannot leave a speculative RAM write behind or consume a FIFO before that fallback.
Known-invalid constant ranges reject the helper at build time. Unknown loaded pointers, data-dependent
addresses, unaligned access instructions, calls, traps, coprocessors and HI/LO retain their
original paths. CFG memory uses the reachability rules below. Entry checkpoints and due-event pumps precede all
memory work, including resumption. No device access is sent through a plain span.

Each store is an ordered effect node and a mandatory liveness root in `ScalarGraph`; its source
value contributes to the signature even if no GPR result uses it. Live loads, calculations and
stores are emitted in their original order. In particular, a returned load before an aliasing
store must be materialized before that store, not folded into the final `return` expression.
Unused reads may disappear only inside the fully proved plain-memory path. Stores are never
discarded by register liveness or pooled by the pure-expression interner. Memory value reuse
requires the byte-range proof below, never a no-alias assumption about input pointers.

Helpers that only modify memory return `Void`, with no dummy result or `ScalarResult` traffic.
Helpers with GPR results retain the ordinary Int/multiple-result protocol. Deduplicated bodies
forward the complete typed signature, including Void setters. Memory helpers retain their
original adapter unless a caller can borrow all checked spans as described below; neither
caller projections nor the pure helper pool admits them. `--no-scalar` remains the whole-pass opt-out.
No runtime storage, heap object, forced inline, worker or game-specific rule is added. This
recovers explicit memory parameters; it does not privatize guest RAM or erase observable stack
stores merely because a stack pointer is restored.

`ScalarEffects` runs emitted helpers and the original stream with bytewise memory and full
machine-state comparisons. Fixtures cover Void/forwarded setters, a returned old load,
aliased and distinct bases, RAM/scratchpad mirrors, mixed-width stores and odd span bases,
mirror-crossing fallback, two loaded values before a swap, restored stack pointers,
MMIO reads into zero, MMIO writes after a RAM update, alignment rejection without undefined
dereferences, suspension changing input memory, and a due event before the first store.
Tool tests verify real state-free signatures, retained effects, the parameter budget, distant
constant spans, known-device rejection and exclusion from the pure pool.

This expands full helper coverage from 30 to 99 in C3 and 32 to 106 in CB, including 24/5 Void
setters. JS grows by 46,157/31,447 bytes. Five paired runs retain all game digests but do not
establish a speed gain: medians are about 1.0%/2.9% higher with overlapping ranges. Keep the
distinction between recovered source structure and performance; guard/call overhead and memory
computation remain targets for further work. Raw samples and acceptance are in PROGRESS.md.

### Memory values within a checked linear helper

`ScalarMemoryValues` tracks SSA values for byte ranges during generation. A load fully covered
by a preceding load or store can use that value directly, or extract its little-endian bytes
and perform the load's exact sign/zero extension. Only the low written bytes of a store input
are known. An exact repeated load also shares its result ABI word. Tracking is local to one
linear helper and adds no runtime cache, field or allocation.
Extraction uses arithmetic `>>` before the final truncation: the discarded high bits do not
affect the result. A nested `>>>` would leave a C++ unsigned operand for the following `>>`,
breaking signed extension in the pinned reflaxe compiler (PROGRESS.md upstream defect 11).

A store invalidates every overlapping fact in its own span and **all** facts in other spans.
Different spans may alias through distinct pointers, cached/uncached addresses, or RAM mirrors;
even distant offsets from the same input can occupy separate spans. Within one successfully
checked span, offsets name contiguous storage, so non-overlapping ranges are distinct bytes.
Partially overwritten wider values cannot serve a later wider load. A previous narrow value
can survive a disjoint write; facts are never merged speculatively across partial stores.
Every store remains emitted in instruction order, even when a later load is forwarded.

All original accesses, including eliminated loads and reads into zero, still enter the complete
preflight. MMIO therefore executes the original stream, preserving repeated FIFO reads and
device writes. Entry/resume pumps and guest accounting are unchanged. A forwarded word may
recover an exact incoming pointer or constant; subsequent accesses can then use that proved
affine identity. An actual memory-dependent pointer, or one invalidated by a possible aliasing
write, still rejects the helper. No guest memory is replaced with a private host object.

`ScalarEffects` covers 32 emitted programs with full state/counter and bytewise comparisons,
including signed/unsigned extraction, truncated stores, repeated loads, partial overlap,
disjoint stores, original values retained after overwriting registers, recovered pointers,
distinct spans over a 2 MB RAM mirror, FIFO fallback and cooperative resumption.
`ScalarResults` also verifies one result word for duplicate reads. The two current games have
no eligible repeated accesses: all 40 C3 / 38 CB generated Haxe files remain byte-identical to
the preceding stage, with 99 / 106 full helpers. This is a general transformation with verified
synthetic coverage, not a measured game speedup; broader effectful function recovery is needed
before expecting this rule to affect those games.

### Checked memory across acyclic control flow

`ScalarCfg` also accepts the same affine plain-memory accesses as linear recovery. Every
load that remains is a conditional expression under its block's reach predicate; every store
is an explicit conditional statement. Only the selected path performs memory effects. Pure
calculations may still be evaluated eagerly, and phi selections choose final register values.
Branch operands are captured before the delay slot, including when the slot overwrites a
condition register or the memory supplying an earlier condition load. Topological ordering
retains the order of all selected effects, including multiple return paths and aliases.

Preflight is conservative across the whole function: **all** possible spans must pass before
the helper runs. The dependent-read extension below samples only checked plain-memory sources
during preflight. An unused path with a bad span can cause a fallback, but cannot cause
an MMIO access or partial execution. This accepts affine input/constant addresses; differing
pointer values merged at a join remain ineligible unless their exact affine identity agrees.
Known device addresses, unproved load-dependent addresses and incompatible span alignment also
retain the original body; the dependent-read extension below adds precise read provenance.
There are no additional checkpoints, and backward-edge pumps still
reject the helper. The existing entry checkpoint/pump runs before any preflight or computation.

`ScalarGraph.beginBlock` receives a snapshot of the facts on actual incoming CFG edges, never
those from the previous block in topological emission order. `ScalarMemoryValues.intersect`
retains only the same span, byte range, extension and immutable value on every predecessor.
An untaken arm's write cannot justify a load in another arm. A partial overwrite or possibly
aliased span invalidates the fact; identical load expression text does not identify a memory
version. Within each block, byte-range forwarding retains the same reach predicate.

The adapter nests its span preflight inside `entry == 0`; other public entries retain the
original CFG and current machine state. Path accounting is returned even by Void setters.
Helpers can return both memory-dependent GPR values and the original cycle/instruction/block
counts without adding CpuState, runtime allocation or a basic-block dispatch loop. Memory
helpers remain excluded from pure pooling. Caller-specific projection retains their whole
preflight as described above; other callers use the full entry adapter unless the checked-span
borrowing proof below succeeds. Size/parameter limits
and `--no-scalar` are unchanged.

`ScalarMemoryCfg` compares 22 programs at every discovered public block entry, including
conditional reads/writes, old load values, aliasing branch arms, mixed widths, equal/different
pointer phis, loaded conditions, branch/return delay stores, nested diamonds, early returns,
same-target branches, MMIO reads into zero, untaken FIFO paths, mirror crossings, nested partial
joins, a changed condition after store/reload, cooperative resumption and a due entry event.
Two negative programs retain the original implementation:
an unproved pointer phi and a known device address. Current game coverage and timing evidence
are recorded in PROGRESS.md; more recovered methods alone do not establish a speed gain.

### Compose proved calls without publishing intermediate CpuState

`ScalarCfg` may lift a direct `jal` when static residency resolves an unhooked, nonrelocatable
callee with a complete `ScalarPlan`. `ScalarCall` supplies the callee's ordinary parameters
from the caller's SSA environment and emits a qualified `_value` call. It never expands the
callee body or assumes that scratch registers are dead. The link value is installed before
lifting the delay slot. A recursive analysis caches an in-progress rejection, so neither
self-recursion nor mutual recursion can consume an unfinished signature.

Each return must sample the original incoming `ra` before its delay slot, and the final GPR
environment must also restore it. Copies and common memory facts can prove this, including a
saved stack word across read-only calls and diamonds. Every guest store still occurs in RAM;
there are no private stack objects. The byte-range effect extension below preserves saved
values across disjoint child writes and can guard otherwise uncertain aliases. Unknown and
load-dependent address bases require the dependent-read proof below.

Child memory views must translate to caller input/constant affine addresses. Their complete
byte ranges, anchors and alignment requirements enter the caller's preflight before any
effect. All views may alias. Loaded pointers require the dependent-read extension below;
an exactly reconstructed incoming pointer retains its affine identity. Calls in conditional blocks execute under
their reach predicates. Every secondary result and dynamic accounting word is captured
immediately, before another helper or the parent's publication can overwrite `ScalarResult`.
Pure shared-body normalization renames local SSA identifiers, never ABI member identifiers.

The adapter can omit intermediate guest frames/checkpoints only when their observations are
impossible. Sum upper bounds over every local block and every child call tree. Cycles,
instructions and blocks must each fit their 10-bit accounting lane; local analysis/body
budgets and the six-parameter limit still apply. The entry guard requires no unwind token and a
next-event distance strictly greater than this maximum cycle count. With cooperative execution
enabled, stress yielding must be off and the slice deadline must also lie strictly beyond
the whole tree. Equality, expired deadlines and failed preflight execute the original body,
with every existing checkpoint, frame and unwind. Public interior entries also keep that body.
No runtime callback, worker, allocation or JIT is introduced. This recovers bounded call trees,
not arbitrary ABI signatures or state reconstruction inside a suspended helper.

`ScalarCompose` compares emitted optimized/reference programs across all public root entries,
RAM/scratchpad/mirror boundaries, possible aliases, nested and conditional calls, secondary
results, changing live values at suspension, every event offset through the call bound,
wrapped cycle values, existing unwinds and CD response FIFO fallback. Tool tests reject
recursive, hooked, unknown and unbounded calls and unproved address bases, and check
memory-fact intersections. Public continuation fixtures supply valid aligned live pointers;
misaligned wide fallback semantics remain the pre-existing open runtime limitation.

### Preserve saved values across precisely described writes

`ScalarMemory.stores` records every possible store as a checked-span name, relative offset and
byte width. Exact duplicates are removed, but gaps are retained rather than replaced by one
bounding interval: a saved return word can lie between two writes. The summary includes
conditional stores from every path and translated writes of every nested child. It describes
may-writes, not guaranteed final memory values. A call cannot manufacture a known value merely
because its summary contains a store.

When a child view is translated into the caller's preflight, its writes invalidate only
overlapping facts in that same contiguous checked view. Different views can alias even when
their registers/virtual addresses differ. Composed call-tree analysis may retain a conditional
fact with the list of writes that must be excluded. Reusing that value adds the necessary
physical byte-range separation checks to the complete entry preflight. Unused facts request
no checks. Ordinary noncomposed memory analysis still drops uncertain facts. Immutable CFG
snapshots retain each path's exclusions, and intersections union them before permitting reuse.

`Memory.spansDisjoint` is an ordinary small runtime function, not forced inline. Both spans
must already be valid and every tested byte must lie within their checked ranges. It compares
arena indices plus offsets/widths; no guest memory is read and no host pointers are compared.
This accounts for KSEG/RAM mirrors and the scratchpad's distinct backing. The full validity,
alignment and separation conjunction runs before the first guest effect. An alias, bad span,
due event or slice boundary executes the complete original body. Stores are never speculatively
executed and then repeated in fallback. No ABI rule declares a stack slot private.

Composition also translates every child's required separation into its parent's coordinates.
If both views become one, exact disjointness is proved statically; an overlap rejects the
caller signature. Otherwise the parent checks it at entry. The shared borrowed-span adapter
uses caller spans with the callee anchor offsets folded into each checked range, after all
span-validity checks. Forwarding adapters keep the owner's same preconditions. Symmetric
duplicates are emitted once. When one side is identical, overlapping/adjacent ranges on the
other side merge into an exact connected union; repeat for either side until no further
merge applies. Gaps are never filled. This retains the same truth condition while reducing
guard calls (six checks become one in the current saved-register/three-store example).
More than 16 resulting exclusions rejects the helper as an entry-code
budget; no required condition is ever dropped to fit that budget.

`SpanAlias` checks physical byte overlap, adjacency, negative offsets, mixed widths, symmetry,
RAM mirrors and scratchpad aliases against explicit reference positions on both targets.
The expanded `ScalarCompose` fixtures cover saved-word holes, overlapping bytes, translated
arguments, nested stack frames, conditional clobbers, unioned branch exclusions, a child
precondition collapsing to a known overlap, and the borrowed adapter, including a pointer
changed to an alias while execution is suspended. Physical aliases and
FIFO fallback run against the original emitter, with all public entries and observation tests.

### Checked dependent reads and returned-pointer provenance

`ScalarRead` records a specific immutable load version: its source span, byte offset/width,
signedness and all possible writes preceding that load. Affine arithmetic preserves this
identity plus a wrapped offset; unrelated loads are never equated by expression text.
Only when such a value is used as an address does the plan request a proof that its entry
sample equals the original load. Same-view overlap with an earlier write rejects the plan;
other-view writes require physical `spansDisjoint` conditions. Later writes do not enter this
proof. Unsampled helper loads and all stores remain ordered, so it may use an old pointer
after a store changes its source. The extension below can replace an active read by the
already proved entry value. Forwarded store values retain their existing SSA proof.

Entry emits source spans before their dependent spans. A conditional expression samples a
pointer only after its source is proved aligned plain RAM/scratchpad. Invalid ancestors
produce invalid dependent spans without reading them. All final span/alignment/separation
checks precede the helper and any guest effect. Reading a valid RAM source before a later
alias check is safe: it has no side effect, and failure still executes the entire original
body. There are no speculative writes, MMIO reads, partial fallback suffixes or added pumps.
An invalid pointer on an untaken path may conservatively force fallback without executing
that path. Distinct pointer values at a phi still cannot supply one affine span.

`ScalarCall` recursively translates the child's source spans and read versions, including
outputs which were not themselves dereferenced in the child. Each call gets fresh provenance.
The imported read's prefix is the caller's preceding writes plus the child's writes preceding
that particular read; child writes after it are excluded. Returned numeric values continue
through the ordinary result ABI and retain their dependencies/liveness. This allows a caller
to pass a loaded pointer to a memory helper, or dereference a pointer returned through nested
helpers, without intermediate CpuState publication. The existing observation horizon,
analysis/body/six-parameter bounds and alias-guard budget remain in force. Metadata exists
only in the build-time tool; runtime spans remain allocation-free. Borrowed adapters reject
loaded views because their addresses are unavailable at the caller's input-register boundary.

`ScalarPointers` executes emitted/reference code for chains, affine offsets, signed/narrow
reads, caller/child/nested write prefixes, later writes, distinct versions at repeated calls,
conditional paths, public entries, event offsets, cycle wrapping and suspension mutations.
Guard-only probes cover unaligned intermediate sources without invoking the runtime's existing
unsupported wide-misalignment fallback. Physical aliases force fallback and FIFO source/target
tests verify zero speculative device reads. `ScalarCompose` also admits and tests its
previously rejected returned-pointer case. General changed-pointer continuation recovery,
loops and general ABI/stack recovery remain separate work; this is not complete state removal.

### Reuse checked entry samples as typed inputs

`ScalarSignature` lowers helper parameters after value liveness and the full memory proof.
SSA nodes describe the spans their actual expressions use. Only real load nodes with active
read provenance are candidates: an affine derived value or opaque call result must not be
mistaken for a load merely because it carries an address identity. A selected load uses an
ordinary Int sample parameter, retaining its reach predicate and zero on the untaken path.
All other loads and every store keep their order. The preflight already proves the selected
version equals its entry sample, including exclusions against earlier writes; writes after
the original load do not change the captured numeric value.

If no live expression uses a source span after substitution, omit that span from the body
signature. Keep it in the complete validity/alignment/alias preflight, including dead and
zero-target accesses. This does not authorize a device read or weaken fallback. The same
parameter order is used by ordinary wrappers, shared forwarding wrappers and composed calls;
borrowed adapters still validate their complete views and pass just the body inputs. Loaded
views remain excluded from borrowing. No runtime object, new return ABI or forced inline is
introduced.

Candidates with equal source view, offset, width and signedness share one entry value. Each
guest read version remains distinct and retains its own write exclusions. A later inactive
read with the same source key still performs its real load: it may observe a write which the
earlier version correctly precedes. Signed and unsigned samples are not interchangeable.
The entry emitter also avoids sampling an equal source twice. Greedy selection prefers fewer
total parameters, then more replaced loads, with stable definition-order ties. A selection
must fit the existing six-parameter cap; otherwise the original checked body load remains.
Preflight has a separate six-span cap so removing body arguments cannot grow entry glue
without a bound.

For a composed call, the caller imports every proof span but passes only child body spans.
Child sample arguments are explicit load values at call entry; the child's prior-write proof
validates that placement. Parent lowering can replace these nodes by its own entry samples.
Remaining result provenance, secondary-result capture and instruction/cycle accounting are preserved.
This is not general call inlining, and an opaque child's returned load is not removed by
matching its address provenance alone.

`ScalarPointers` additionally checks shared entry samples across distinct proved versions,
unproved later versions of the same source, signed/unsigned pairs, call propagation, removal
of source-only span parameters and budget fallback. Its optimized/reference executions still
cover all public entries, alias/device fallbacks, events, cycle wrap and suspension mutation.
Static load-site counts and game timing are separate evidence recorded in PROGRESS.md;
fewer generated loads alone does not establish a speed gain.

### Reconstruct already sampled outputs at the boundary

A separate `ScalarValue.sampleRead` proof records unconditional numeric equality to an
immutable read plus a wrapped constant offset. An unconditional real load establishes it;
proved affine arithmetic and moves preserve it. A predicated load or opaque call result
does not establish it merely by carrying `addressRead` provenance. The read must also have
an active entry proof, including all earlier-write exclusions, before using this identity.

Such an output is omitted from the result roots before helper liveness and parameter
selection. The entry adapter publishes the saved sample, with the proved offset, directly
to its destination GPR. A sample needed only for this publication no longer crosses either
the parameter list or the return ABI. Other body uses can still need a sample parameter or
an ordered load when the argument budget is full. Every original span and access remains
in preflight, including reads into zero and accesses whose numeric result is otherwise dead.
Incoming register values needed for reconstruction are captured before any output overwrites
them. A write after the original read may change its source: publication uses the captured
entry value, not a new memory read after the helper.

Memory helpers with entirely reconstructable outputs return `Void`; their effects and
path-accounting return word remain rooted and ordered. Ordinary, borrowed and forwarding
adapters must not assign that call to an Int. Pure-pool helpers keep their existing normal
Int return. Remaining computed outputs still use the normal return plus immediate captures
of secondary words. This changes transport only, not which guest registers are observable.

When composing calls, reconstructable child outputs become explicit sample value nodes
before the child effects. Each retains its own imported read version and caller/child
prefix-write exclusions, even if entry preflight shares equal numeric samples. An existing
node is reused only for the same child read identity. Parent signature lowering can remove
these reads too. A conditional invocation retains its predicate; its samples cannot acquire
unconditional equality and escape the merge. Opaque child returned loads remain actual
calls/returns until an independent body proof permits reconstruction.

The pointer fixtures cover sole/multiple/affine sampled outputs, all-known `Void` helpers,
ordered and conditional writes, overwritten input capture, nested `Void` calls, predicated
calls and distinct versions separated by a possibly aliased write. Whole-state comparisons
include memory, cycle/instruction/block counts, public interior entries, event deadlines,
wraparound, suspension and device fallback. Source transport counts and bounded game timings
remain separate evidence in PROGRESS.md.

### Carry body-proved result equalities across calls

An unconditional child invocation can import the child's `sampleRead` proof for its normal
return or any secondary result. Import the exact source, offset, width, extension and prefix
writes. This proof can be inactive in the child: the caller's later use as an address may
establish its complete entry guard. The caller then reconstructs the result from its own
preflight sample without retaining a numeric dependency on the call. Conditional invocations
do not export unconditional equality, and pointer provenance without the body equality proof
is insufficient. A different-pointer phi still requires the ordinary fallback.

Liveness removes a child call only when no computed result, ordered effect or dynamic
accounting value requires it. All original child spans remain in the parent's preflight,
including a dead load into zero which could have been a device read. A failed guard executes
the entire original body with all its device effects. A surviving primary result still roots
the call even if its secondary capture is reconstructed; an effectful child remains called
even when all numeric outputs are known. Child bodies are not expanded into the caller.

Packed accounting values known constant are added at build time and remain constant across
nested summaries. A fixed child charge is imported directly instead of rooting a call just
to read its ABI accounting word. Dynamic charges retain the original call dependency and
immediate capture. Every removed host call still contributes its guest instructions,
cycles, blocks and original observation horizon; event/deadline and public-entry checks stay.

Narrow memory forwarding also preserves numeric identity. A byte extraction or change of
sign extension is an exact read of its source subrange with its own width, extension and
current prefix-write version. Emit only the existing conversion, not another body load.
Only an unconditional conversion supplies `sampleRead`; its source may become an entry
sample only after excluding every earlier write. In particular a converted value forwarded
from an overlapping prior store cannot be replaced with stale entry bytes. Keeping a fresh
read identity avoids equating signed and unsigned results or different offsets.

Fixtures exercise both return channels, live primary/dead secondary combinations, nested
fixed charges, dynamic child charges, conditional invocations/conversions, writes before
and after the returned read, narrow signedness/offsets and zero-target MMIO fallback.

### Budget the recovered body separately from guest instruction count

The initial 32-guest-instruction cap rejected compact recoverable functions solely by their
original size. The current analysis cap is 256 guest instructions per function, independently
of a maximum helper-body cost of 96. After output reconstruction and value liveness, each live
SSA definition/effect costs one, each transported numeric result costs one, and path-accounting
publication costs one. This is a conservative source-level budget, not a host instruction or
execution-time estimate. Target compiler simplification may reduce the body further.

Dead definitions, NOPs and boundary-only values consume analysis budget and original guest
cycles/instructions, but no emitted-body budget. Every ordered store remains a live effect;
an oversized live expression/effect graph retains the original function. The separate six
helper parameters, six proof spans, sixteen alias exclusions and three 10-bit transitive
accounting lanes remain unchanged. Cycles, public interior entries, checkpoint/deadline
guards, fallback bodies and hook/residency checks are unaffected. Helpers remain ordinary
methods without forced inlining. Internal `ValueRegion`/`ValueCfg` budgets do not change.

The survey in PROGRESS.md distinguishes raw size from loops, unsupported instructions and
unresolved callees; increasing this budget does not claim to solve those other limitations.
Fixtures include long dead prefixes, live arithmetic, larger conditional arms, many ordered
stores, a larger child summarized away, and rejection at the analysis/body budgets. Optimized
and original bodies are compared at public entries, event deadlines and suspension boundaries.

The initial two-game survey adds 11 C3 and 12 CB helpers while leaving all previous helper
bodies unchanged. This expands recovery coverage; it is not an established speed improvement.
JS grows about 44/43 kB and paired timing is mixed (including a possible C3 slowdown). Keep
the concrete timings and correctness evidence in PROGRESS.md; entry/proof and publication
costs must be investigated before claiming a performance benefit from a wider budget.

### Borrowing a direct caller's checked spans

`ScalarBorrow` allows a direct `jal` to use the complete memory helper signature when every
callee span is covered by an existing caller function span on the same incoming GPR, or on a
register proved to hold that address plus a constant offset at the call. The
callee's anchor and complete byte interval must fit, without wrapped range arithmetic. This
does not create new caller spans or widen existing ones. Constant/loaded-address spans, uncovered
intervals, indirect/tail calls and relocatable callers retain the ordinary adapter. Callee
selection uses the existing universe/residency and hook checks.

`CallAliases` tracks exact wrapped affine relations between immutable register-value versions
within the call's block. Every public block entry starts with unrelated values. Observable
effects (including loads, stores, coprocessors, HI/LO, traps and unknown calls) discard all
relations; pure writes invalidate their destination before installing a new value. A copied
value keeps its old version when its source changes. Link writes occur before the delay slot,
and the call snapshot includes that slot, before the callee runs. These are build-time facts,
not a runtime alias table or an assumed calling convention. Same-register coverage remains
preferred; alternate donors are considered in register order for deterministic generation.

An affine donor must cover the callee's complete range and anchor after adjusting for the
proved offset. A nonzero shift must also keep the intermediate input pointer inside the donor
range. The caller rebases it only in the valid arm of a `Memory.spanOk` conditional; a failed
span is passed as `Memory.spanNone` without pointer arithmetic. The shared adapter then checks
alignment using the actual callee input and applies its own anchor offset behind its guard.

Each borrowed **donor** register becomes a use in function-span liveness **after** the delay slot and
**before** the callee's writes. A pointer changed in the body, slot, predecessor path or earlier
call must therefore refresh/step its span even if the caller has no later load through that
register. Entry/resume and loop-pump handling remain the ordinary function-span machinery.
After the call, the existing may-write summaries and unwind checks still govern refreshes.

The fast arm requires every current span to be valid and every callee alignment constraint to
hold. It also uses the same due-event/cooperative-entry guard as pure scalar calls, without
calling `wantsYield` twice. On any failed guard, the full callee adapter performs the original
checkpoint/preflight/fallback. No callee load/store occurs before these guards.
`Memory.spanOffset` rebases only an already valid, proved-covered pointer/index, behind the
shim ABI; it neither decodes an address nor accesses guest memory. Distinct span arguments may
still alias. The complete result signature and original accounting are consumed immediately,
with no additional state, allocation, inline expansion or callback inside the helper.

The guard, rebasing, result publication and accounting live in one generated `_withSpans`
adapter per callee. Callers pass CpuState and spans **anchored at the callee input** after
publishing current state. Passing a failed span is harmless: neither its pointer/index nor
guest memory is dereferenced before the guard. This removes duplicated entry code from all
call sites while the actual `_value` computation retains its state-free signature. The extra
host frame has no guest checkpoint/continuation of its own. Slow entry work belongs only to
the original callee; caller after-call unwinding remains outside the shared adapter. No forced
inline is used. Adapters unused by any borrowed call disappear under full DCE.

`ScalarEntry` emits the same guard and charge formulas for direct pure calls, ordinary scalar
entries and borrowed adapters, preventing those paths from drifting apart. Deduplicated bodies
forward their typed span adapter to the same owner as the CpuState entry and value helper.
The adapter is not registered in the guest dispatch table. Conformance also invokes a forwarded
adapter with aliased/distinct spans and invalid spans to verify fast and full-entry paths.

`ScalarBorrow` conformance compares 32 emitted programs at every public caller entry, covering
positive/negative offsets, last-use body/slot writes, slot steps, preceding unknown calls,
callee pointer writes, multiple aliased spans, CFG stores, partial coverage rejection, constants,
unknown targets, joins and loops. Cooperative tests change pointers/RAM while suspended;
due-event tests halt before callee effects; FIFO tests preserve fallback access order. Tool
checks retain alignment, reject wrapped ranges and disable borrowing for hooks/relocation.
Alias cases exercise body/slot copies, positive/negative shifts, overwritten source versions,
donor refresh/step after its last ordinary access, two shifted spans, and rejection across
memory effects or public block entries. Tool tests check reported affine equalities against
concrete edge-word executions and explicitly verify link timing and observation barriers.
Current game coverage and timing evidence are recorded in PROGRESS.md.

### Pure values at internal observation boundaries

`ValueRegion` brings value SSA into ordinary functions, independently of whole-function helper
eligibility. It lifts consecutive pure body instructions using `ScalarGraph`, bounded to 32 per
interval. Identical expression text with identical operand versions shares one value; moves
share values as before. Backward reachability from every changed final GPR removes unobserved
definitions. Exact constants and incoming-register-plus-offset values are reconstructed without
their original chains. Restored registers need no publication. No ABI output assumptions apply.

Only incoming values reachable from these results are captured, and all captures/computations
precede the first output store. Register swaps and overwritten inputs therefore retain the correct
original values. Every changed result is then published to CpuState before the next instruction
outside the interval. The next interval has a fresh graph and fresh incoming values; it cannot
restore a stale value over a callee's output. This is not ADR-0029's rejected register-cache scheme.

The lift excludes memory (including discarded reads), coprocessors, HI/LO, possible traps,
unknown instructions, control flow and writes to `ra`. Regions stop at body ends, leaving branch
operand capture and delay slots to the existing emitter. Each separately addressable block starts
from its actual state. A span refresh/step also terminates the interval after its defining
instruction: the emitter then performs exactly the original metadata update, with the original
register value. No fields or cached spans remain partially updated at an observation. Looping
leaves retain their established local-register lowering; ordinary loop bodies may contain regions,
but values never cross their back edges or pumps. Guest instruction/cycle/block charges are unchanged.

The emitter compares each candidate with its existing instruction/fusion emission and selects it
only if the candidate has fewer GPR field references. This rejects merely replacing field syntax
with locals. It is a static cost filter; target compilers and execution frequencies determine real
performance. `--no-value-regions` isolates this pass independently of `--no-scalar`/`--no-regions`;
`--no-opt` disables all of them. No runtime class, extra call, allocation, forced inline or worker
is introduced. This establishes state reconstruction at linear internal boundaries, not arbitrary
SSA across effectful CFGs or loops.

`ValueRegions` executes three generated forms: unoptimized reference, optimized without this pass,
and optimized with it. It compares every GPR/HI/LO/counter plus stored data, callback observation
traces, cooperative suspension and a due event halting the loop. Independent arithmetic formulas
cover swaps, constants, aliases, shared expressions, restored values, all word edge cases and
32-instruction chunk boundaries. Fixtures cover FIFO reads into zero, coprocessor and divide
effects, possible versus proved overflow, span resets/steps and interior branch entries. Tool
tests additionally require every effect category and `ra` writes to stop the lift, and verify the
opt-out. The existing staleAcrossCalls and full Codegen/Regions/Yielding fixtures remain gates.

Generated Haxe GPR references fall from 293,125 to 263,907 in Crash 3 and 276,137 to 245,646 in
Crash Bash (static counts, not execution-weighted traffic). ES6 JS grows by 126,966 and 41,800
bytes respectively; the target analyzer eliminates many temporary declarations. Both games are
also compared over 20,000 frames, beyond ADR-0029's known 9,898-frame regression point. Test and
timing evidence is recorded in PROGRESS.md; no speedup follows from the reference counts alone.

### Values across pure structured CFG regions

`ValueCfg` extends the internal-boundary work across 2–16 blocks and at most 32 instructions
of a pure acyclic region. It analyzes actual IR edges, including edges hidden by region
reductions: a back edge, pump or computed transfer rejects the candidate. Only ordinary
branches, direct jumps, fallthrough and unredirected returns are allowed, with at most one
external continuation. Bodies and slots may have no effects or `ra` writes; possible traps,
memory, HI/LO, coprocessors and calls remain observation boundaries. Existing scalar helpers
and looping-leaf locals are not rewritten.

The existing structured Haxe `if/else` performs the merge assignments to typed local variables.
There is no per-expression entry predicate or speculative evaluation of both arms. The public
`resume` guards still steer every interior entry, and predicates still latch before delay slots.
Every register read or possibly written is captured before the region starts: a public entry
that skips a definition must preserve its incoming value. Every possibly written register is
published at return or external control transfer, or after an ordinary fallthrough/recorded
forward escape. Dispatcher exits publish before leaving the local scope. No values survive to
the next observation; this is not a cache across callbacks or suspensions.

`ValueRegion` can simplify pure intervals inside these local scopes, using the same operand
versions and expression sharing as before. Span refresh/step calls still run at their original
positions with the promoted base value; they update host metadata without an emulated effect.
Guest charges remain attached to the original blocks, so public entries and different branch
paths preserve cycles, instruction counts and block counts without a new accounting ABI.

The emitter renders a candidate and its ordinary form, selecting it only when state-reference
count decreases. This static filter does not establish a runtime speedup. `--value-cfg` enables
the experiment; it is off by default. `--no-value-cfg` isolates it while preserving linear value
regions; `--no-value-regions`, `--no-regions` and
`--no-opt` also prevent it. No allocation, helper call, runtime field or forced inline is added.

`ValueCfg` conformance compares the reference, the preceding linear-value optimization and
the CFG extension at every block entry of 23 synthetic programs over signed edge inputs.
Fixtures include joins, crossed edges, multiple returns, reversed layouts, irreducible fallback,
call mutation/observation, stores, span refreshes/steps, cooperative slices and a due loop pump.
Tool tests require real selected scopes, verify the opt-out and reject effects/`ra` writes in
both body and delay slot. Acceptance and two-game JS measurements live in PROGRESS.md.
General loop/effect SSA, interprocedural ABI signatures and stack/data-layout recovery remain open.

Three paired JS runs per game retain every digest, but do not establish a speed gain: C3 median
21.8341 -> 21.5246 s and CB 4.1769 -> 4.2729 s, with overlapping ranges and background-load
variation. The extension removes 779/309 static GPR references while growing ES6 JS by
51,061/17,420 bytes. Keep the tested implementation for opt-in experiments; default output
retains the preceding linear value optimization. Further work should remove computations and
recover useful signatures, rather than assume that promoting more fields to locals is faster.

## Alternatives considered

- Restore register locals across all calls: repeats ADR-0029's publication/liveness problem
  without recovering signatures.
- Return an allocated tuple for every changed register: violates the no-allocation hot path
  and merely replaces CpuState traffic with another aggregate.
- Ignore scratch-register outputs: incorrect for arbitrary hand-written MIPS and assembly
  that observes values the conventional ABI would call clobbered.
- Recover arbitrary CFGs, private stack objects and call groups immediately: defer until
  output/effect analysis and state reconstruction cover their additional boundaries.

## Consequences

This is bounded signature recovery, not whole-program decompilation.
Generated helpers may be clean while the surrounding program still uses CpuState and guest
RAM. The register-only stage produced 5 helpers and 4 direct scalar call sites in Crash 3,
9 helpers and 5 sites in Crash Bash. With checked reads the helper counts are 13 and 16,
respectively (8 and 7 memory helpers). No material game speedup is assumed.
Caller-specific output recovery adds 33 specialized call sites for two callees in Crash Bash,
and none in Crash 3. Pooling replaces its 33 per-site definitions with 2 shared definitions:
49 -> 18 total helpers in Crash Bash, while Crash 3 remains at 13. These are static coverage
counts, not execution frequencies. Helpers are not forced inline.
After the summary/projection extension, ES6 bundles grow by 139,492 bytes for Crash 3 and
21,978 for Crash Bash against the checked-read stage. In particular, conservative arithmetic
trap effects can require extra span refreshes even where no scalar projection is accepted.
Those sizes precede helper pooling; its size/timing measurements are recorded in PROGRESS.md.
Local range proofs are implemented above; cross-block proofs remain future work, and no broad
speed benefit is assumed.
Pooling reduces Crash Bash's ES6 JS by 5,496 bytes to 23,724,273; Crash 3 is byte-identical.
Three runs per version over 3000 headless CB frames give medians 2.7930 s before and 2.7818 s
after, with overlapping ranges and background system activity. This confirms a size reduction,
not a speed gain. Both game digests and the expanded shared-helper conformance tests agree.
The first register-only JS A/B (9000 frames) gave medians 21.0066 s without scalar helpers and
22.3200 s with them, with broad upward drift and opposite ordering in individual pairs; it
does not establish a speed benefit. That stage grew the JS bundle by 837 bytes; the checked
reads add another 1,565 bytes. Timing of the checked-read stage is not established. Full samples
are in PROGRESS.md; widening coverage requires new correctness and performance evidence.

`ScalarCodegen` executes the actual optimized and reference output on signed edge cases for
every supported opcode, checks explicit arithmetic formulas, restored scratch registers,
all GPRs and HI/LO, wraparound cycles, original instruction/block accounting, a due event
halting at callee entry, and cooperative resume/stress checkpoints. Tool tests also cover
rejected effects, output/argument/body limits, mod hooks, overlay residency and deduplication.
Existing `staleAcrossCalls`, `Codegen`, `Regions`, `Yielding` and `Dispatch` remain gates.
`ScalarMemoryCodegen` compares the generated paths over signed/unsigned loads, affine and
constant addresses, mirrored RAM, scratchpad aliases, crossed boundaries and wrapping
addresses. It checks the same registers/accounting, FIFO consumption for dead and `$zero` loads,
due-event entry, and memory changed during a cooperative suspension before the load.
Acceptance outputs and game digests are recorded in PROGRESS.md.
`ScalarCalls` runs 21 caller/callee arrangements over signed edge cases and checks public entry
outputs, both/one-arm overwrites, branch/return delay slots, next-call visibility, MMIO reads,
stores, loop pumps, preexisting unwind tokens, due-entry events and suspension-state traces.
Tool tests cover summary recursion, conditional calls, linking returns through `ra`, copied return addresses,
overlay resolution and hook invalidation. Shared helpers are exercised with different input and
output registers, extra dead definitions and different instruction counts; unequal constants and
noncommutative operand order remain distinct. Program-level tests cover cross-universe sharing,
different code at one overlay address, repeated writes, hook changes and cleanup on opt-out.
The tests execute emitted Haxe on JS and reflaxe.CPP.

## Upstream comparison, 2026-10-01

Research only; the following does not expand this ADR's implemented acceptance rules.
Inspected rev.ng revision `0f1f7d4ac301241db32552d52ab105c17aca4bdc`, alongside its online docs.

rev.ng first represents registers as global CPU state variables (CSVs). Signature recovery is
an explicit analysis/transformation chain, rather than something the target compiler infers
from a state object. Its [artifact descriptions](https://docs.rev.ng/references/artifacts/)
distinguish isolated state-based functions from ABI-enforced argument/return functions.

- [AnalyzeRegisterUsage.cpp](https://github.com/revng/revng/blob/0f1f7d4ac301241db32552d52ab105c17aca4bdc/lib/EarlyFunctionAnalysis/AnalyzeRegisterUsage.cpp)
  uses backward liveness for function inputs and call-site outputs, and reaching definitions
  for output/input candidates in the other direction. Calls carry register-effect summaries.
  [DetectABI.cpp](https://github.com/revng/revng/blob/0f1f7d4ac301241db32552d52ab105c17aca4bdc/lib/EarlyFunctionAnalysis/DetectABI.cpp)
  iterates caller/callee information to a fixed point and suppresses preserved scratch traffic.
- [EnforceABI.cpp](https://github.com/revng/revng/blob/0f1f7d4ac301241db32552d52ab105c17aca4bdc/lib/FunctionIsolation/EnforceABI.cpp)
  rewrites signatures, returns and calls using model prototypes; multiple return registers
  form an LLVM struct value. [PromoteCSVs.cpp](https://github.com/revng/revng/blob/0f1f7d4ac301241db32552d52ab105c17aca4bdc/lib/FunctionIsolation/PromoteCSVs.cpp)
  replaces remaining CSV references with local allocations. LLVM optimization can then remove
  local register traffic. A multi-result LLVM value does not justify allocating JS objects.
- Stack recovery is later: [SegregateStackAccesses.cpp](https://github.com/revng/revng/blob/0f1f7d4ac301241db32552d52ab105c17aca4bdc/lib/PromoteStackPointer/SegregateStackAccesses.cpp)
  separates the function frame, each call's outgoing stack arguments, and incoming stack
  arguments. [Data Layout Analysis](https://docs.rev.ng/references/analyses/#analyze-data-layout-analysis)
  combines access information across functions to infer layouts; this alone does not make
  arbitrary guest memory private host objects.

Execution qualification matters: the [pipeline](https://docs.rev.ng/references/pipeline/)
branches `recompile` from `lift`, and `recompile-isolated` from `isolate`, before ABI enforcement.
The inspected EnforceABI source explicitly marks execution unsupported when removing dynamic
function bodies. The [helper documentation](https://docs.rev.ng/developer-manual/qemu-helpers/)
also explains dropping exceptional paths during decompilation. These are reasons to distinguish
recompilable-looking C from a proven PS1 execution replacement, not a claim that rev.ng cannot
recompile binaries.

The research conclusion was to build per-function and per-call read/output/preserved/effect
summaries, then CFG value SSA and boundary-state reconstruction before general signature lowering. Stack
escape/alias proofs and typed views over guest memory come later. Pumps, MMIO, unknown calls,
overlays and cooperative suspension must observe the original machine state. Current ScalarPlan
covers bounded linear leaves and proved acyclic call trees with checked plain-memory reads/writes and path accounting,
plus conservative caller-specific output recovery. It has no general interprocedural ABI, stack
or data-layout recovery.
