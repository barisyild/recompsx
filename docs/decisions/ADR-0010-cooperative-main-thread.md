# ADR-0010: Optional cooperative execution of generated machine code
Status: accepted   Date: 2026-09-09

## Context

The browser must execute on its main thread. The earlier local JS artifact had suspension code
that was absent from the Haxe sources, so rebuilding from the optimized emitter lost that path.
Suspension must preserve MIPS state, original event timing, nested calls and delay slots, and
must remain compatible with reflaxe.CPP and independently compiled overlays.

## Decision

Emit suspension support behind `-D recompsx_cooperative`. At original function/loop safe points,
check a guest-cycle deadline **before** the existing pump. Publish scalar registers only when
suspending. Capture the compiled function handle, stable block entry and whether its entry
pump is still pending; propagate a dedicated unwind token back to the launcher. After a guest
call, capture the caller's continuation after the call and its delay slot. Tail calls retain
no caller frame. Generated statements and delay slots are never replayed.

`Cooperative.step` runs the deepest continuation, then the pending callers. A further suspension
prepends newly captured frames to the remaining callers using two fixed buffers allocated at
boot. Capacity is 4096 frames (six Int arrays, 96 KiB of payload); overflow fails explicitly.
The generated handle table pins suspended code to its original universe even when another
overlay replaces the address lookup. Deduplicated functions retain their body owner's handle.
Register state is shared through `CpuState`, not stored separately in continuation frames.

Resumption skips already performed entry pumps. A same-cycle guard ensures forced checkpoint
testing makes progress. Guest longjmp discards abandoned suspended callers; HALT propagates
immediately. Runtime pumps and kernel HLE calls are atomic because their native continuations
are not generated machine blocks. Long HLE calls can therefore exceed the requested slice.

The JS shim owns requestAnimationFrame/timer scheduling, wall-clock pacing and pause state.
Wall time never enters machine state. Node drives the same continuation runner synchronously;
the C++ conformance harness does too. With the define absent, the emitter retains the ordinary
synchronous path and no continuation buffers are allocated.

`scripts/build-web.sh` regenerates from a game config, compiles with the normal analyzer/ES6/DCE
flags, and links the served bundle to ignored build output. A SHA-256 manifest identifies the
artifact and supplies the URL cache key. Generated JS is never edited by hand.

## Validation and limits

`Yielding` compares full CPU state and timing hints against synchronous execution across the
regional CFG fixtures, nested calls, delay slots, tail transfers, callbacks and nonlocal unwind.
It also checks continuation identity after the address dispatcher is changed. Both JS and
reflaxe.CPP run the same fixture. Game checks compare normal and forced checkpoint frequency
against a synchronous build of the same sources; results belong in `PROGRESS.md`.

This feature restores reproducible browser execution. It does not establish compatibility with
every behavioral difference in the old local bundle. CD/GTE/overlay fidelity remains separate
from whether the continuation machinery preserves the current runtime's behavior.
