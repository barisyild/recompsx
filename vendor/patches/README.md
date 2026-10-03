# Patches to vendored compilers

reflaxe.CPP is v0.1.0 and we have had to fix things in it. Those fixes live on a branch inside
the submodule (`recompsx-fixes`), which is fine locally but invisible to a fresh clone: the
submodule pin names a commit that exists on no remote. The patches are exported here so the work
is backed up with the rest of the repository and can be reapplied to any checkout.

## Applying

0001 and 0007 target `vendor/reflaxe.CPP`; 0002–0006 target `vendor/reflaxe`. Do not apply the whole
directory to one submodule. Check whether a patch is already present before applying it;
several earlier fixes are included in the existing pins. Plain diffs (0004–0006) use `git apply`.

Generated block dispatchers require 0004 and the scalar-register emitter requires 0005;
safe short-circuit guards require 0006. `scripts/setup.sh` applies these idempotently. To apply
0005 manually from the repository root, on a checkout missing it:

    git -C vendor/reflaxe apply --check ../patches/0005-reflaxe-reassigned-local-declarations.patch
    git -C vendor/reflaxe apply ../patches/0005-reflaxe-reassigned-local-declarations.patch
    RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh Codegen

For 0006 on a checkout missing it:

    git -C vendor/reflaxe apply --check ../patches/0006-reflaxe-short-circuit-scopes.patch
    git -C vendor/reflaxe apply ../patches/0006-reflaxe-short-circuit-scopes.patch
    RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ShortCircuit

Keep existing local patches when updating the compiler. No submodule pin change is needed to
apply a working-tree patch.

## What is here

- **0001 — unique local names per function.** Haxe's inliner materialises a callee's parameters
  and temporaries as locals in the caller's scope under the callee's own names, so two calls to
  the same inline function in one scope emitted two declarations of the same name and C++
  rejected the second. The `_this` temporary generated for inlined instance methods was the same
  bug. Every declaration and reference already funnels through `Compiler.compileVarName` and Haxe
  gives each variable a unique id, so names are now disambiguated per function body.

  Worth offering upstream. See PROGRESS.md upstream defect 1.

- **0002–0004 — side effects, block traversal and continue.** Fix the inverted side-effect
  predicate, recursive traversal that overflowed on game-sized blocks, and discarded statements
  preceding `continue`. See PROGRESS.md for the original failures and verification.
- **0005 — moved local declarations are consumed once.** Constant propagation can leave
  multiple assignments before a local's first remaining read. The declaration-moving pass kept
  the old candidate after moving it and converted another assignment into a second declaration
  with the same variable id. `MarkUnusedVariablesImpl` then threw `Logic error`. Remove the
  candidate once it moves, and account for reads in initializers and nested blocks before
  moving anything. `TestCodegen.constantStores`, `loadThenRedefine` and `storeThenRedefine`
  are synthetic MIPS reproductions;
  `scripts/conformance.sh Codegen` must build and pass on both targets (ADR-0007).

- **0006 — keep short-circuit RHS computations conditional.** Expression lowering hoisted
  inlined argument bindings out of the RHS of `&&`/`||`, running skipped calls and even reading
  `Scheduler.due[-1]` before checking for an empty queue. Lower only RHS expressions requiring
  statements to an `if` expression; preserve evaluation order and leave simple operators intact.
  `ShortCircuit` conformance checks calls, assignments, nested branches, while/do-while and order.
  `scripts/spike.sh` requires it to agree on JS/C++ with analyzer optimization and full DCE.

- **0007 — `@:declarationOrder`.** reflaxe.CPP lays a class's instance variables out sorted by
  type and then by name. With this metadata a class keeps the order its source declares, which
  `core.CpuState` uses to put the 16 words generated code names most within the 64 bytes the
  SH-4 reaches with a short displacement (docs/perf/dreamcast-ledger.md E-076). Plain diff,
  `git -C vendor/reflaxe.CPP apply`; `scripts/setup.sh` applies it idempotently. Check the
  order in the transpiled `core_CpuState.h`.

- **reflaxe-cpp-array-is-vector.patch — contiguous Haxe Arrays.** Restored from commit
  `6819782` on `dreamcast-hardware-rendering`, alongside its native memory and dispatch paths.
  `scripts/setup.sh` applies this patch idempotently to `vendor/reflaxe.CPP`; it also preserves
  the existing 0005 patch in `vendor/reflaxe`. See ADR-0009 for the original measurements.
