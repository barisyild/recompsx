# Patches to vendored compilers

reflaxe.CPP is v0.1.0 and we have had to fix things in it. Those fixes live on a branch inside
the submodule (`recompsx-fixes`), which is fine locally but invisible to a fresh clone: the
submodule pin names a commit that exists on no remote. The patches are exported here so the work
is backed up with the rest of the repository and can be reapplied to any checkout.

## Applying

0001 targets `vendor/reflaxe.CPP`; 0002–0005 target `vendor/reflaxe`. Do not apply the whole
directory to one submodule. Check whether a patch is already present before applying it;
several earlier fixes are included in the existing pins. Plain diffs (0004/0005) use `git apply`.

The scalar-register emitter requires 0005; `scripts/setup.sh` applies it idempotently. To apply
it manually from the repository root, on a checkout missing it:

    git -C vendor/reflaxe apply --check ../patches/0005-reflaxe-reassigned-local-declarations.patch
    git -C vendor/reflaxe apply ../patches/0005-reflaxe-reassigned-local-declarations.patch
    ./scripts/conformance.sh Codegen

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
