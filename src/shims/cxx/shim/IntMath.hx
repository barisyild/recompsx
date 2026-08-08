package shim;

/**
	Integer division and remainder.

	Haxe's `/` operator on two `Int`s produces a `Float` — always, on every target. The usual  // portable-ok: prose
	workaround, `Std.int(a / b)`, routes 32-bit integer arithmetic through a double. For values
	this size that is numerically exact, so it is not a correctness problem; it is a problem
	because this project forbids floating point outright, wants no FPU dependency on consoles,
	and enforces the rule with a grep that cannot tell a "safe" Float from an unsafe one.  // portable-ok: prose

	So: **never write `a / b` in runtime, shim, shared or generated code. Use `IntMath.div`.**
	`%` on two `Int`s is already integer-only and may be used directly, but `IntMath.mod` is
	provided so both halves of a division read the same way.

	Semantics match C++ and MIPS: truncation toward zero, and the remainder takes the sign of the
	dividend. Division by zero is the caller's problem — MIPS defines its own results for that
	case and the recompiler emits them explicitly (see docs/specs/tool.md §3, `Ops.div`).
**/
class IntMath {
	// Each placeholder is parenthesised individually. reflaxe.CPP splices the argument's source
	// text in verbatim with no protective parentheses of its own, so `div(y * 31, h - 1)` with a
	// naive "({0} / {1})" emits `(y * 31 / h - 1)` — silently the wrong arithmetic. Verified
	// 2026-08-08; recorded as upstream defect 7 in PROGRESS.md. Any future `__cpp__` in this
	// project must parenthesise every placeholder for the same reason.
	public static inline function div(a:Int, b:Int):Int
		return untyped __cpp__("(({0}) / ({1}))", a, b);

	public static inline function mod(a:Int, b:Int):Int
		return untyped __cpp__("(({0}) % ({1}))", a, b);

	/** 32-bit wrapping multiply. Plain `a * b` is already correct here under `-fwrapv`, but the
	    JS target needs `Math.imul` to avoid losing low bits above 2^53. Callers use `IntMath.mul`
	    on both targets so the two cannot drift apart. */
	public static inline function mul(a:Int, b:Int):Int
		return untyped __cpp__("(int)((int32_t)({0}) * (int32_t)({1}))", a, b);

	/** Truncating division by a power of two behaves differently from a shift for negative
	    numbers (`-1 / 2 == 0`, but `-1 >> 1 == -1`). Named so the choice is visible at the
	    call site rather than implied. */
	public static inline function divPow2Trunc(a:Int, shift:Int):Int
		return a < 0 ? -((-a) >> shift) : (a >> shift);
}
