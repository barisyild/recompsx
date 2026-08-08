package core;

import shim.IntMath;

/**
	Multiply and divide, with the exact results the hardware produces.

	These are functions rather than inline expressions because their edge cases are numerous,
	subtle, and identical at every call site — writing them once and testing them once is worth
	more than the call, which the compiler inlines anyway.

	The cases that matter, all from the psx-spx CPU reference:

	- **Division by zero does not trap.** MIPS defines results: the quotient is −1 for a
	  non-negative dividend and 1 for a negative one, and the remainder is the dividend. Compiled
	  code relies on this — Psy-Q emits an explicit check *after* the divide, so the divide itself
	  must complete.
	- **`0x80000000 / −1` is defined here and undefined in C++.** The true quotient does not fit
	  in 32 bits; the hardware yields 0x80000000 with a remainder of 0. Left to the host it is
	  undefined behaviour, which on x86 raises a hardware exception.
	- **The unsigned forms compare unsigned**, which on a signed 32-bit type means the sign-bit
	  XOR trick, not `<`.
**/
class Ops {
	public static function mult(ctx:CpuState, a:Int, b:Int):Void {
		final neg = (a < 0) != (b < 0);
		var ua = a;
		if (a < 0) ua = -a;
		var ub = b;
		if (b < 0) ub = -b;
		mulUnsigned(ctx, ua, ub);
		if (neg) negate64(ctx);
	}

	public static function multu(ctx:CpuState, a:Int, b:Int):Void {
		mulUnsigned(ctx, a, b);
	}

	/**
		Note the shape of these two functions: every branch body is a **single statement**, a call
		to `setLoHi`.

		That is not style. reflaxe.CPP miscompiles richer branch bodies, and this function found
		three separate shapes of it: a ternary inside a branch, guard clauses ending in `return`,
		and an `if / else if / else` chain with two-statement bodies. All three are natural Haxe,
		all three were correct on JavaScript, and all three were wrong on C++. Reducing each arm
		to one call sidesteps the whole family — and reads better than what it replaced, since the
		branch conditions now sit together and say exactly what the hardware's rules are.

		See PROGRESS.md upstream defect 8. `tests/conformance/Mul.hx` is what caught each attempt.
	**/
	// Deliberately NOT inline: inlining materialises the parameters as locals in the caller, and
	// two calls in one scope then collide (upstream defect 1). Our vendored fork uniquifies those
	// names, but a plain call removes the question entirely and this is not a hot path.
	static function setLoHi(ctx:CpuState, resultLo:Int, resultHi:Int):Void {
		ctx.lo = resultLo;
		ctx.hi = resultHi;
	}

	public static function div(ctx:CpuState, a:Int, b:Int):Void {
		// Division by zero is not a fault here: the hardware defines an answer and compiled code
		// checks for it *after* the divide, so the divide has to complete.
		if (b == 0 && a >= 0) setLoHi(ctx, -1, a);
		else if (b == 0) setLoHi(ctx, 1, a);
		// The one quotient that does not fit in 32 bits. Undefined in C++; defined on the machine.
		else if (a == -2147483648 && b == -1) setLoHi(ctx, -2147483648, 0);
		else setLoHi(ctx, IntMath.div(a, b), IntMath.mod(a, b));
	}

	public static function divu(ctx:CpuState, a:Int, b:Int):Void {
		if (b == 0) setLoHi(ctx, -1, a);
		// A divisor with its top bit set exceeds, as an unsigned value, any dividend without one
		// — so the quotient can only be 0 or 1.
		else if (b < 0 && unsignedLess(a, b)) setLoHi(ctx, 0, a);
		else if (b < 0) setLoHi(ctx, 1, (a - b) | 0);
		else if (a >= 0) setLoHi(ctx, IntMath.div(a, b), IntMath.mod(a, b));
		else divuLargeDividend(ctx, a, b);
	}

	/**
		Unsigned division where the dividend's top bit is set but the divisor's is not.

		A signed division would read the dividend as negative, so the dividend is halved, divided,
		and the result corrected — the standard technique for doing unsigned division on a type
		that only offers a signed one.
	**/
	static function divuLargeDividend(ctx:CpuState, a:Int, b:Int):Void {
		final half = a >>> 1;
		var q = IntMath.mul(IntMath.div(half, b), 2);
		var r = (a - IntMath.mul(q, b)) | 0;
		if (!unsignedLess(r, b)) q = (q + 1) | 0;
		if (!unsignedLess(r, b)) r = (r - b) | 0;
		setLoHi(ctx, q, r);
	}

	/** The unsigned comparison, on a type that only has signed ones. */
	public static inline function unsignedLess(a:Int, b:Int):Bool
		return (a ^ 0x80000000) < (b ^ 0x80000000);

	/**
		32×32 → 64, from 16-bit halves.

		Deliberately not `haxe.Int64`: it allocates an object per intermediate on both of this
		project's targets, and this is one of the hottest operations in the machine (ADR-0004).
		Every partial product below fits in 32 bits, so the whole thing is ordinary integer
		arithmetic that behaves identically everywhere.
	**/
	static function mulUnsigned(ctx:CpuState, a:Int, b:Int):Void {
		final al = a & 0xFFFF, ah = a >>> 16;
		final bl = b & 0xFFFF, bh = b >>> 16;

		final ll = IntMath.mul(al, bl);
		final lh = IntMath.mul(al, bh);
		final hl = IntMath.mul(ah, bl);
		final hh = IntMath.mul(ah, bh);

		// Sum the middle terms, keeping the carry out of bit 31.
		final mid = ((ll >>> 16) + (lh & 0xFFFF) + (hl & 0xFFFF)) | 0;

		ctx.lo = ((ll & 0xFFFF) | (mid << 16)) | 0;
		ctx.hi = (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) | 0;
	}

	/** Two's-complement negation of the 64-bit hi:lo pair. */
	static function negate64(ctx:CpuState):Void {
		// The negation carries into the high word exactly when the low word was zero.
		var carry = 0;
		if (ctx.lo == 0) carry = 1;
		final lo = (~ctx.lo + 1) | 0;
		final hi = (~ctx.hi + carry) | 0;
		ctx.lo = lo;
		ctx.hi = hi;
	}
}
