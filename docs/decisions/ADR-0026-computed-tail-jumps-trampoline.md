# ADR-0026: A computed jump that does not come back is run by the nearest caller
Status: accepted   Date: 2026-09-26

## Context

A `jr` through a register other than `$ra`, with no recovered table, was emitted as a call by
address followed by a return: `Runtime.call(ctx, t); return;`. On hardware it is a jump — the stack
does not grow. Threaded code that hops between routines through pointers grows the host stack by one
frame per hop. Crash Bandicoot: Warped's renderer does this once per primitive (`lw $t9, 112($v1);
jr $t9`, and back), and in its first gameplay level exhausted the JavaScript stack
(`RangeError: Maximum call stack size exceeded`, alternating `f_800418cc` / `f_80041a3c`).

## Decision

**Emit such a jump as a request, and let the caller run it.** `Runtime.tail(ctx, t)` stores the
target in `ctx.tailTarget`, sets `ctx.unwindToken = Runtime.TAIL`, and the function returns. The
nearest code that continues after a call runs pending tails in a loop at a fixed depth:
`Runtime.call` (every dynamic call and every kernel-initiated callback), generated code through the
after-call line — now `if (ctx.unwindToken != 0 && Runtime.unwinding(ctx)) return;`, the same single
compare on the common path — `Cooperative.afterCallAt`, and `Runtime.settle` for a resumed frame.
Applies to unresolved computed jumps, a jump table's default arm, and tail calls whose target is
dispatched by address. Direct static tail calls are unchanged.

## Alternatives

- **A global trampoline for every call.** Would bound all recursion, at the cost of every call
  becoming a return to a dispatcher loop; nothing measured needs it.
- **Jump-table hints listing each routine's continuations.** Per-game, incomplete by construction,
  and it would fold a whole renderer into one function.
- **A bigger host stack.** Not available on every target, and only moves the limit.

## Consequences

- Semantics are unchanged: conformance digests identical before and after (Codegen 317d8a54,
  Regions 9420e9fd), Crash Bash digests identical (9000 2ff36a18, 30000 288ed8d6).
- Harnesses that enter generated functions directly must drain a pending tail themselves
  (`Codegen.finishTail` in the conformance suite).
- `CpuState.tailTarget` is transient: it is only meaningful while the token is `TAIL`.
