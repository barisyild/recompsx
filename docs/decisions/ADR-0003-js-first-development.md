# ADR-0003: Develop on JavaScript, design for reflaxe.CPP
Status: accepted   Date: 2026-08-08

## Context

Within the first hours of real use, reflaxe.CPP was caught **silently deleting code**. The worst
shape is the guard clause:

```haxe
if (x > 0) { log += "guarded;"; return; }
log += "fellthrough;";
```

compiles to a function containing only `log += "fellthrough;"`. No error, no warning — the
function does the opposite of what it reads as. Three further `if`-dropping shapes were found
inside loops (body assigns to the loop-condition variable; body contains a ternary; nested
branches), plus `untyped __cpp__` splicing arguments without parentheses, which silently changed
`(y*31)/(h-1)` into `(y*31/h)-1`. Haxe's own `--interp` and `-js` targets compile the identical
sources correctly, so these are reflaxe.CPP's alone. Full list: `PROGRESS.md`, upstream defects.

This matters more here than it would elsewhere. recompsx's product is millions of lines of
machine-written branches. A deleted branch in hand-written code is findable; a deleted branch in
generated code is invisible, and every emulation bug becomes a two-unknown problem: is the GTE
wrong, or did the compiler eat a branch?

## Decision

**JavaScript is the development and verification target. reflaxe.CPP is the target the project
is shaped for.** Both are built on every test run.

- Emulator logic is written and verified against the JS build, whose feedback loop is seconds
  and whose compiler is mature.
- Every constraint reflaxe.CPP imposes still applies everywhere, including in code that will
  only ever run on JS: the portable subset, static accessors and integer-handle dispatch
  (ADR-0002), `IntMath` instead of `/` and `*`, no guard clauses, no ternaries or nested branches
  in loop bodies. JavaScript's freedoms are not taken. The project must remain buildable and
  correct on reflaxe.CPP at all times, because consoles are the destination and JS can never go
  there.
- `scripts/test.sh` builds both and compares headless digests. **When they disagree, JavaScript
  is the reference**, and the divergence is either a portability leak in our code or a
  reflaxe.CPP miscompilation — both worth finding immediately.

## Alternatives

- **Fix reflaxe.CPP first.** The defects are real and worth reporting upstream, but their depth
  is unknown, and stopping the project to debug someone else's expression compiler trades a known
  schedule for an unknown one. The fork-and-fix door stays open (ADR-0001) and gets easier once
  we have a reference implementation to diff against.
- **Continue on C++ with workarounds.** Fastest route to a console-ready build, but the
  workarounds cover the shapes we happened to find, not the ones we have not, and every future
  bug stays ambiguous.
- **Drop reflaxe.CPP.** Not an option: it is the only path to the platforms this project exists
  for. If it ever becomes untenable, ADR-0001's standing fallback is emitting C++ directly from
  our own emitter — which the tool is already structured to do.

## Consequences

- Cross-target determinism — the project's central promise — became measurable at M0 instead of
  M8. It has already paid: the first comparison diverged, and the cause was ours (FNV-1a's
  32-bit multiply written as `*`, which wraps in C++ but loses low bits in JavaScript). That is a
  bug we would otherwise have shipped into every hash in the project.
- `IntMath.mul` joins `IntMath.div` as mandatory. Plain `*` is only safe when the product
  provably fits in 31 bits.
- The JS backend is Node-headless for now. A browser backend will need the main loop inverted —
  a browser cannot block in `while (!quit)` — so the runtime will grow a `stepFrame()` that the
  platform drives. Consoles want that shape too, so it is worth doing properly when it arrives.
- Two shim directories must stay in step. That is a real cost, and it is also the mechanism that
  keeps target-specific assumptions out of the runtime: `Vram.data` was typed as `cxx.CArray`
  until the JS target made the leak obvious, and is now `shim.RawBuf`.
