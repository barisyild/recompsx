# ADR-0015: Use JavaScript-only gates during the current codegen iteration
Status: accepted   Date: 2026-09-21

## Context

The JavaScript backend is the active reference target and completes the recompiler/game loop in
seconds. Whole-program reflaxe.CPP generation is currently too slow for repeated codegen work,
which makes it a poor inner-loop check even though the C++ target remains required for the later
console path.

## Decision

Make JavaScript-only validation the default for `scripts/conformance.sh` and `scripts/test.sh`.
Keep all reflaxe.CPP build files, shims and checks in the repository. Restore the two-target gate
explicitly with `RECOMPSX_JS_ONLY=0`.

## Consequences

Codegen changes can be iterated quickly while JS remains the behavioral reference. The deferred
target is still one command away and is not silently removed from the project. The current
snapshot records JS validation as the acceptance signal until the C++ path is resumed.
