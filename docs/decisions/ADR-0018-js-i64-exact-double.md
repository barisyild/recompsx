# ADR-0018: The JavaScript I64 shim as an exact double
Status: rejected   Date: 2026-09-25

## Context

The GTE accumulates into 44-bit registers and flags every intermediate, so the runtime does
its MAC arithmetic through `shim.I64`. On C++ that shim is a native `int64_t`; on JavaScript it
is a hi:lo pair of Ints with explicit carry arithmetic, and every operation is an out-of-line
call. After the rasteriser fix the GTE was the largest bucket of the JS profile (34 %), and a
double holds every integer below 2^53 exactly, which covers the GTE's whole domain (44-bit
accumulators, 16×16 and 16×17-bit products, a 2^35 rounding step). The proposal was one
integer-valued double, every method inline, the floating-point type admitted in that one file.

## Decision

Rejected on measurement. The shim was built, passed `GteOps` bit-for-bit (`1cf89aa2`) and the
game digests, and did not move the clock. Interleaved runs of 9000 frames, minimum of three on
a loaded machine: pair shim 26.84 s, double shim 27.20 s, double shim with the 44-bit wrap
applied only on overflow 29.22 s. A second change tried alongside it, `Gte.execute` as a
`switch` instead of an if-chain, was isolated at +10 % (27.4 s against 25.0 s on a quiet
machine) and is also rejected: whatever V8 makes of Haxe's sparse `switch`, it is slower than
the chain that already puts the common operations first.

The pair is not the naive design it looks like. Its 44-bit check reads only the high word, its
wrap is three integer operations on that word, and integer adds have a one-cycle latency where
the double version's accumulation chain — convert, multiply, add, and a floor-based wrap —
is latency-bound on a value that lives in a boxed static field. Nothing here is cheaper than
what it replaces once the whole chain is counted.

## Alternatives

- `BigInt`: an allocation per intermediate, the shape ADR-0004 measured at six times slower.
- A value-passing accumulator (`I64.mac(m, a, b)` returning the new value) so the chain lives in
  a register on both targets — a local double on JS, a local `int64_t` on C++ — instead of a
  static field. Not tried: it rewrites 89 call sites in `Gte.hx`, and this experiment says the
  static field is not the whole cost. It remains the one representation change left for the
  GTE, and would need the same measurement discipline before it is kept.

## Consequences

No representation change. Golden rule 1 stands without an exception, `Acc64` keeps its full
64-bit cases, and the numbers above are what the next person should beat before proposing a
float representation for this accumulator again.

Measured later the same day, once the SPU mixer was out of the profile: the pair's small
operations made `inline` in the JS shim (`check44`/`check32` as single expressions), together
with `Gte.step44` and `mac0From32`, won every one of five interleaved rounds of 9000 frames —
mean 20.83 → 19.75 s, minimum 20.19 → 18.50 s — with every digest unchanged. Kept
(`ce808eb`). The representation was the wrong lever; the call boundaries around it were a
real one.
