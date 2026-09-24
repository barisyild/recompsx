# ADR-0019: Structured control flow with a recorded-target `resume`
Status: accepted   Date: 2026-09-25

## Context

The optimized emitter kept a `while (true) switch (bb)` block dispatcher for every function
whose control flow it could not reduce to sequences, single-block loops and if/else choices:
632 of Crash Bash's 1576 functions, including its hottest ones, because every multi-block
`for`/`while` loop, every loop with more than one exit and every chain of forward branches
(`if (x) goto later`) fell outside those rules. A dispatcher hides the loops from the host
compiler, merges every local at the switch and takes an indirect jump per block. Haxe has no
labelled `break`/`continue` and no `goto`, so the Relooper's answer — a label variable — is
the only structured form available on both targets.

## Decision

Reuse the existing entry-routing local `resume` as the label. Every block resets it on arrival;
every part of a sequence is guarded by it. A natural loop (dominator-defined, reducible by
construction) becomes a native `while (true)` once its body, with back-edges and exit edges cut,
reduces to one region; a transfer to its header is `resume = -1; continue`, a transfer out of
it is `resume = <target>; break`, and the loop ends with `if (resume >= 0 && resume != header)
break`. A sequence is a forward run: consecutive regions in address order, entered only at the
first, whose internal edges all point forward; a jump past the next part is `resume = <target>`
and the guards skip to it. Recovered jump tables record their targets the same way and are
never placed where a `break` would be needed, since on C++ a `break` inside a `switch` leaves
the switch. Nothing inside a native loop may reach the dispatcher; the emitter throws if it
would. Interior entries, pumps, cycle charges and register publication are unchanged.

## Alternatives

- Duplicate bodies for interior entries so loops need no guards. Rejected by ADR-0007/0008:
  code size on consoles.
- Emit `goto` on the C++ target only. Rejected: two shapes of generated code, and the Haxe
  analyzer would not understand either.
- Keep the dispatcher and rely on the JIT. Rejected by measurement below.

## Consequences

The dispatcher remains for computed transfers that cannot be cut out of a loop and for
irreducible CFGs: 9 functions of Crash Bash's 1576, down from 632. The `Regions`, `Yielding`
and `Codegen` fixtures keep their digests (`d6b90d6e`, `203c40c1`, `632ff691`), the game
digests are unchanged at 3000, 9000 and 18000 frames (`0e180c28`, `ab13c60f`, `31c46089`),
and the tool tests assert the new shapes.

Timing on JavaScript is neutral within the noise of the measuring machine: interleaved runs,
minimum of three, 9000 frames 27.08 s against 28.19 s wall and 33.35 s against 31.55 s user;
18000 frames 48.97 s against 49.95 s wall and 55.26 s against 53.54 s user. V8 handled the
`switch` dispatcher about as well as it handles the structured form; the one function that
gained is the vblank wait loop, whose self time fell 44 %. The decision stands on the shape:
the structured output is what the C++ compilers of the console targets optimise — loops they
can see, locals they can keep in registers across them, no indirect jump per block — and that
effect is unmeasured while the C++ path is paused (ADR-0015). It must be measured there
before the shape is credited with anything.
