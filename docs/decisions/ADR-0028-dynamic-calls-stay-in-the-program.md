# ADR-0028: Generated code dispatches its own calls through registers
Status: accepted   Date: 2026-09-27

## Context

Every call the analysis left dynamic — `jalr`, and a `jal` into an overlay window — was emitted as
`Runtime.call(ctx, t)`. The runtime cannot name the generated tables, so it reached them through
the dispatcher the program bound at startup (`Runtime.bindDispatch(FnTable.call)`). On C++ a call
therefore passed `Runtime.call`, its out-of-line body (`callOnce` inlined, with the rescan and
kernel-stub paths), a `std::function`, and `FnTable.call` (the overlay, table and relocatable
lookups inlined) before reaching the dispatch switch. Each of those frames saved the registers its
cold paths needed. Disassembled on the Dreamcast, about 150 instructions per call.

Crash Bandicoot: Warped calls through registers constantly: 730,308 dispatches in vblanks
4700–5000 of its medieval demo, about 2,400 a frame (450,513 calls plus 279,795 tail jumps,
ADR-0026). 98.4 % of them are to fixed code outside every overlay window, at a few dozen addresses.
Profiling Flycast put `Runtime::call`, `FnTable::call` and `FnTable::dispatch` at 6.8 % of the frame.
Two earlier rounds (the dispatcher no longer copied, a two-compare window span check, a cache in
`FnTable.call`) took 2080.3 to 1944.2 M cycles. The cache then needed a check of the overlay window
version on every call, which ate its whole gain (1953.0 M).

## Decision

**Emit calls through registers as `FnTable.run(ctx, t)`, a generated function that keeps the
answers.** `run` is `Runtime.call`'s loop with `FnTable`'s direct-mapped cache in front: on a hit it
goes straight to the dispatch switch, on a miss it asks the runtime's own route
(`Runtime.callOnce`: the bound dispatcher, a rescan of a window, a report), and `FnTable.call`
keeps the answer. Tail jumps the callee leaves loop inside `run`, at a fixed host depth, as they do
in `Runtime.call`. A slot is one 16-byte record (address, handle, block); an empty slot holds an
address that maps to another slot, so a hit is one compare. Answers are kept only for addresses
outside every window, and `OverlayMgr` calls back (`watchWindows`) when the windows change, so the
hot path reads no version. On C++ the cold paths are kept out of line: `Runtime.callOnce`,
`Runtime.badHandle` (which switch fell through is now an integer, so no dispatch switch builds a
`std::string`), `FnTable.buildFlat`, and `Runtime.call` and `Runtime.unwinding`. The last two
matter because every generated call site reaches `unwinding` behind its own test of the token:
once `call` had shrunk to a token check and the bound loop, the compiler inlined both, with the
`std::function` call, into every such site — 2,393 copies in Crash 3 and 2,029 in Crash Bash,
600 bytes more in Crash Bash's hottest function, and a slower frame than before the change.

The runtime's own calls into guest code — callbacks, handlers, thread switches, longjmp, a tail
left for `Runtime.unwinding` — still enter through `Runtime.call`, which hands the address to the
loop the program bound (`Runtime.bindRun(FnTable.run)`), its own loop until one is. That matters
more than the runtime's few calls suggest: a tail chain continues in whichever loop takes it.
Crash 3's renderer is entered by a static call and hops once per primitive (ADR-0026), so its
~280,000 hops in the range went to `Runtime.unwinding`, then `Runtime.call`, then `callOnce`, one
by one, until `call` handed them over. Fixtures that are compiled without a program keep
`Runtime.call` and its own loop (`Emitter.dynamicCall`).

## Alternatives

- **Keep `Runtime.call`, make its path cheaper.** Done twice (see Context). What is left is the
  frames themselves, and the runtime can only reach the tables through a bound function value.
- **Let the runtime reference `FnTable` directly.** The runtime compiles and is tested with no
  generated program present (conformance tests bind their own dispatchers). That property is worth
  more than one indirect call on the runtime's own, rare, calls.
- **Check the window version on each call.** Correct, but measured: it cost as much as the cache
  saved.
- **Guarded direct calls to the targets a profile recorded.** Removes the dispatch entirely for the
  hottest sites (one Crash 3 site makes 46 % of the calls, to two targets), but needs a per-game
  profile artifact. Not ruled out; this decision makes every other call cheap first.

## Consequences

- Generated code depends on `FnTable.run`; every program the tool writes has it. Fixtures written
  by `TestCodegen` exercise `Runtime.call`; the Dispatch conformance test covers `run`: a miss, a
  kept answer, and a window declared after an answer was kept.
- `OverlayMgr.windowsVersion` is gone; windows changing is a callback.
- Measured, Crash 3 in profiling Flycast, vblanks 4700–5000: 1953.0 M cycles with the versioned
  cache, 1909.9 M with `FnTable.run` from generated code, 1880.2 M once `Runtime.call` hands over
  too, 1872.8 M with `call` and `unwinding` out of line (2080.3 M before any of the dispatch
  work). The dispatch functions went from `Runtime::call` 476 + `FnTable::call` 341 + `residentAt`
  208 + `std::function` 146 ms to `FnTable::run` 166 + `FnTable::dispatch` 130 + `FnTable::call`
  51 ms. Crash Bash, vblanks 18800–20300: 6414.8 -> 6400.9 M; its dispatch fell from 367 to 100
  ms, and LTO spent part of that inlining one more `Memory.read32` into its hottest function.
  Digests unchanged on JS and C++.
- What is left is the dispatch switch and the frames around each call. Removing those needs the
  targets known at generation time — the per-game profile in Alternatives.
