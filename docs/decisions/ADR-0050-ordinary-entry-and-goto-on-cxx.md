# ADR-0050: On C++, a generated function's ordinary entry apart from its resumes, and its dispatcher's jumps as `goto`
Status: accepted   Date: 2026-10-04

## Context

A generated function can be entered at a later block — a return elsewhere (ADR-0027), a computed
jump into the middle, a cooperative resume — so its body is guarded for that: in a structured
function each part tests `resume` (`resume < 0 || resume == N`), and a function the structurer
cannot reduce is a `while (true) switch (bb)` whose every jump goes back through the switch. Haxe
has no `goto`, and the guards are how the same source serves JavaScript and C++.

On the Dreamcast both cost what the instruction cache cannot afford (docs/perf/dreamcast-ledger.md,
E-138, E-140). GCC threads the guards into a path for each value `resume` can hold, and those paths
were most of a function's code: one of Crash 3's shards compiled to 66.9 KB, 27.7 KB with `entry`
known to be 0. A resume is rare, the ordinary entry is every call, and the hot paths lay spread
over lines the cache filled for nothing — the generated code's instruction fills are capacity
misses, a quarter of Crash 3's gameplay frame. And a dispatcher's jump was a bound check, a table
load and a `braf` on the SH-4, the table in the code and read through the operand cache: 49 of
Crash 3's functions, 1.2 ms of its gameplay demo.

## Decision

**On reflaxe.CPP (`#if (cxx && !recompsx_cooperative)`), the recompiler writes each function's
body once, as `<name>__body` with `inline __attribute__((always_inline))`, and two functions around
it: `<name>`, which calls it with `entry` 0 — a hand-over target (ADR-0045) with its `entry` when
that is not above 0, the -2 and -3 other functions enter it at — and `<name>__at`,
`__attribute__((cold, noinline))`, which takes every other entry (Program.splitEntry).** The C++
compiler inlines the body into both; in `<name>` the guards fold away. A dispatcher's case starts
with a label (`rx_bb_<first index it lists>`), and a jump to a known block sets `bb` and goes to
the label of the case that holds it (Emitter.dispatchJump); the case's `resume = bb` steers to the
block as the switch's entry did, and a target known only at run time still goes through the
switch. Every other build compiles exactly what it compiled before: the conditions select the old
text.

## Alternatives

- **Leave the cloning to GCC** (IPA-CP for `entry` 0): its unit-growth limit (10 %) refuses
  functions of this size, and an explicit split is deterministic.
- **A resume copy for every target**: JavaScript's output would double, for a cost (code size, not
  speed) that only consoles' instruction caches pay.
- **Restructure the 49 functions instead**: they are irreducible as they stand; `goto` makes any
  control flow cheap to express on the one target that has it.
- **GCC's inliner given more room** (E-142): measured nothing; what it inlined cost its code.

## Consequences

- The image grows by the cold copies (Crash 3 +1 MB), placed apart from the hot code by the
  placement (they never run in a window), and the C++ transpile takes longer.
- `untyped __cpp__` carries a label or a `goto` as a statement — the statement-level injection
  golden rule 1 reserves it for. Labels sit at the head of a case's braced block, before any
  declaration, so no jump crosses an initialisation.
- Exact by construction, and held to it: the tool's tests, JavaScript's digests (Crash 3 47853ef7
  at 5000, Crash Bash 95e17b07 at 20300), the Dreamcast's digests and TA hash on the r138 builds.
