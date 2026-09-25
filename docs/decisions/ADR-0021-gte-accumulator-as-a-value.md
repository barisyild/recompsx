# ADR-0021: The GTE accumulator is a value, not a static
Status: accepted   Date: 2026-09-25

## Context

Every GTE operation runs three or four multiply-adds into a 44-bit accumulator, checks and
wraps it after each, and reads it once. `shim.I64` kept that accumulator in two static fields
(`hi`, `lo`), so every step loaded and stored both; inlining the operations (ce808eb) removed
the calls but not the field traffic. ADR-0018 had tried a double in that same static field and
found it neutral: the boxed field ate what the arithmetic saved. With the SPU mixer and the
dispatch chain gone, the GTE was the largest bucket of the profile, `rtps` alone a sixth.

## Decision

Add `shim.Acc`, the accumulator as a value: an `abstract` whose operations take an `Acc` and
return one, so a chain of steps lives in a local — a register — and touches no field. On
JavaScript the representation is an integer-valued double, exact below 2^53 by IEEE-754's
rules, which the GTE's domain never leaves (ADR-0018's argument; `GteOps` holds it to
`1cf89aa2`); the one floating-point type is the abstract's private representation, marked
`portable-ok` on its single declaration. On C++ it is a native `int64_t` with the spellings
`shim.I64` already uses. `Gte.hx` writes `var m = Acc.shl12(trX); m = step44(Acc.mac(m, rt11,
vx), …); mac1 = shiftBySf(m, sf);` — `step44`, `shiftBySf` and `mac0From32` take the value.
`shim.I64` stays for `mulShr16Round`, its fixture and any future caller.

## Alternatives

- The static double (ADR-0018): measured neutral; the field was the cost.
- The static pair, inline (ce808eb): kept, and this builds on it.
- Hoisting the GTE register file into locals as well: not part of this change; each register is
  read once per operation and the measurement did not call for it.

## Consequences

Digests unchanged: GteOps `1cf89aa2`, Acc64 `0deeafe0`, game `0e180c28` / `ab13c60f`. Five
interleaved rounds of 9000 frames, four to one for the value: mean 19.55 → 19.24 s, minimum
18.95 → 17.96 s, the GTE's share 29.7 → 27.1 %. The C++ twin is unverified while that path is
paused (ADR-0015); its externs are the tested ones from `shim.I64`, only rearranged.
