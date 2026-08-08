# Patches to vendored compilers

reflaxe.CPP is v0.1.0 and we have had to fix things in it. Those fixes live on a branch inside
the submodule (`recompsx-fixes`), which is fine locally but invisible to a fresh clone: the
submodule pin names a commit that exists on no remote. The patches are exported here so the work
is backed up with the rest of the repository and can be reapplied to any checkout.

## Applying

    cd vendor/reflaxe.CPP
    git checkout -b recompsx-fixes <pinned-upstream-commit>
    git am ../../vendor/patches/*.patch

Then re-pin the submodule in the parent repository.

## What is here

- **0001 — unique local names per function.** Haxe's inliner materialises a callee's parameters
  and temporaries as locals in the caller's scope under the callee's own names, so two calls to
  the same inline function in one scope emitted two declarations of the same name and C++
  rejected the second. The `_this` temporary generated for inlined instance methods was the same
  bug. Every declaration and reference already funnels through `Compiler.compileVarName` and Haxe
  gives each variable a unique id, so names are now disambiguated per function body.

  Worth offering upstream. See PROGRESS.md upstream defect 1.

## What is not here, and still hurts

Upstream defect 8 — an `if` with no `else` and more than one statement in its body is deleted
whole — is not fixed. The root cause is somewhere in reflaxe's preprocessor pipeline rather than
in `compileIf`, which looks correct. `tests/spike/ifbody` holds a minimal reproduction, and
`scripts/spike.sh` reports if a future upstream version fixes it. Until then the workarounds are
in AGENTS.md's golden rules.
