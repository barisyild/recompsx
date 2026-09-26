# ADR-0027: A `jr $ra` whose `$ra` was loaded is checked, and a return elsewhere unwinds to it
Status: accepted   Date: 2026-09-26

## Context

Generated code emits `jr $ra` as a return: control goes back to the host caller, which is where
the address the function was called with points. That is only right while `$ra` still holds that
address. Hand-written code reloads return addresses other functions saved. Crash Bandicoot:
Warped's per-object bounding-box test (`0x8003def4`) saves its `$ra` at `100($v1)` in the
scratchpad and calls a helper (`0x8003e000`) for each of eight projected corners; the helper, on
finding a corner on screen, runs `lw $ra, 100($v1); addiu $t8, $zero, 0; jr $ra` — straight back
to the test's caller with "visible". As a plain return it went back into the test, which tried the
next corner and always ended with `$t8 = -1`. Every object using that test — boxes, enemies,
animals, butterflies — was culled; Crash, whose node uses a no-op test, was drawn. Found with
DuckStation as the behavioural oracle: same draw-list nodes, same camera and positions frame for
frame (334 of 334 samples), diverging only inside the test.

The executable holds 56 loads of `$ra` from a base other than `$sp`; most restore a slot the same
function saved, some load another function's.

## Decision

**Check such returns at run time, and unwind a mismatch to the frame it lands in.** Discovery
follows `$ra` through each function (`markCheckedReturns`): the restore of its own stack slot
(`lw $ra, N($sp)` with `sw $ra, N($sp)` in the same function) keeps the entry value; any other
load makes it foreign; any other write keeps the old reading. A `jr $ra` (or `jalr rd, $ra`) that a
foreign load can reach is a checked return: the function keeps `entryRa = ctx.ra` from its first
statement, and the return runs `if (ra != entryRa) Runtime.returnTo(ctx, ra);` before returning.
`returnTo` leaves the target in `ctx.returnTarget` with the token `Runtime.RETURN`. Every
after-call check now names the guest address its call returns to —
`Runtime.unwinding(ctx, <cont>)`, `Cooperative.afterCall(…, cont)` — and ends the token where the
target is its own continuation; other frames return in turn. A cooperative frame records its
continuation and `entryRa`, so a return from resumed code finds its frame among the pending ones
(`Cooperative.returnInto`) and a resumed function checks against its real entry value. A target no
frame continues at is run from the top, as a longjmp is, and reported once.

## Alternatives

- **Recognise the idiom** (a callee loading the slot its caller saved). Needs the base register's
  value across a call; too narrow, and the next game will do it differently.
- **Check every return.** Correct but costs a local and a compare in every function; the proof
  for the own-slot restore is cheap and covers compiled code.
- **Restart at the target from the top (longjmp).** Loses the frames above the target — the draw
  loop that called the test would never resume.

## Consequences

- Crash Bandicoot: Warped draws boxes, enemies and objects (127 checked returns). Crash Bash has 30
  and its digests are unchanged (9000 2ff36a18, 30000 288ed8d6).
- One `Runtime.unwinding` argument per call site, evaluated only when a token is set; one compare
  per checked return.
- Conformance fixture `nonlocalReturn` (Codegen, and Yielding under forced suspensions).
- `tools/recomp/src/recomp/analysis/Discovery.hx` (`markCheckedReturns`), `Emitter.emitReturnCheck`,
  `Runtime.returnTo/unwinding/settle`, `Cooperative` frame `conts`/`ras`.
