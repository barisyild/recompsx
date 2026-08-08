# ADR-0004: Integer semantics across targets
Status: accepted   Date: 2026-08-08

## Context

This project's product is arithmetic. A recompiled PS1 game is millions of 32-bit integer
operations, and the promise is that they produce identical results on every target. Haxe's `Int`
does not provide that by itself, and the ways it fails are silent.

Measured on the two targets in use (`tests/spike/i64`, now `tests/conformance/Arith.hx`):

| Expression | JavaScript | reflaxe.CPP (`-fwrapv`) | MIPS hardware |
|---|---|---|---|
| `0x7FFFFFFF + 1` | `2147483648` | `-2147483648` | `-2147483648` |
| `-0x80000000 - 1` | `-2147483649` | `2147483647` | `2147483647` |
| `a * b` past 2^53 | low bits lost | wraps | wraps |
| `a / b` | `Float` | `Float` | integer |
| `a << n`, `a >> n`, `a >>> n` | wraps correctly | wraps correctly | ✓ |

JavaScript numbers are doubles, so `+` and `-` simply do not wrap; C++ under `-fwrapv` does.
Every `addu`, `subu`, `addi` and `addiu` in generated code sits exactly on this fault line. The
first game to add two large numbers would diverge between targets, silently, and the digest would
report a mismatch with no indication of where it came from.

## Decision

Three rules, applied everywhere in `src/runtime`, `src/shims`, `shared/` and all generated code.

1. **Wrap every result that can overflow with `| 0`.** The recompiler emits
   `RD = (RS + RT) | 0;`, not `RD = RS + RT;`. On JavaScript this forces the int32 wrap; on C++
   it is folded away at `-O2`. Applies to `+`, `-` and unary negation. Shifts already wrap on
   both and are left alone; bitwise operations cannot leave the range.
2. **Multiply through `IntMath.mul`.** `Math.imul` on JS, plain `*` on C++. Plain `*` is only
   acceptable where the product provably fits in 31 bits.
3. **Divide through `IntMath.div` / `IntMath.mod`.** `/` on two `Int`s yields `Float` on every
   target, which the no-floating-point rule forbids outright.

**64-bit values are hi/lo pairs of `Int`, not `haxe.Int64`.** `haxe.Int64` *is* a hi/lo pair —
`abstract Int64(___Int64)` over a class holding `high:Int32, low:Int32` — but it is a **class**,
so every intermediate allocates on any target lacking a native override, and neither of ours has
one (the overrides ship for hxcpp, JVM, C# and HashLink; reflaxe.CPP is not hxcpp, and JS has
none). Measured on the GTE accumulator workload, 3M iterations: `haxe.Int64` 41 ms, hand-rolled
hi/lo 7 ms — about 6x, plus allocation pressure in the hottest loop in the emulator.

So `shim.I64` exposes only the operations the machine actually needs — 32×32→64 multiply,
add with carry, arithmetic shift, and the 44-bit range test the GTE's FLAG bits are defined on —
over explicit `Int` fields. Being the same integer arithmetic on both targets, it is bit-identical
by construction rather than by agreement between two native implementations.

## Alternatives

- **`haxe.Int64` everywhere.** Simplest and genuinely portable, and its source is a fine
  reference for the algorithms. Rejected on measurement: allocation per intermediate in the GTE
  inner loop.
- **Native `int64_t` on C++, hi/lo on JS.** Faster on C++, but then the two targets implement
  64-bit arithmetic differently and agreement becomes something to verify rather than something
  guaranteed. Available later if profiling demands it, gated on the conformance digest.
- **Wrap only where analysis proves overflow possible.** Would remove most `| 0`s, but it costs
  an analysis pass to save an operation that C++ folds away and JS executes in one cycle.

## Consequences

- `tests/conformance/Arith.hx` runs every affected operation over boundary values on both targets
  and must produce the same digest (`f975e3f9` today). It is step 2 of `scripts/test.sh`, ahead
  of the emulator digest, because an arithmetic divergence would make that one meaningless.
- The emission tables in `docs/specs/tool.md` Appendix A carry `| 0` on every wrapping result.
- Reviewers have a short rule to apply: in portable code, a bare `+`, `-` or `*` whose result is
  stored as an `Int` is suspect unless the range is obvious.
