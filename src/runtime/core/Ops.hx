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
		final ua = a < 0 ? -a : a;
		final ub = b < 0 ? -b : b;
		mulUnsigned(ctx, ua, ub);
		if (neg) negate64(ctx);
	}

	public static function multu(ctx:CpuState, a:Int, b:Int):Void {
		mulUnsigned(ctx, a, b);
	}

	public static function div(ctx:CpuState, a:Int, b:Int):Void {
		if (b == 0) {
			// Not a fault: the hardware defines an answer, and code checks for it afterwards.
			ctx.lo = a >= 0 ? -1 : 1;
			ctx.hi = a;
		} else if (a == -2147483648 && b == -1) {
			// The one quotient that does not fit. C++ calls this undefined; the hardware does not.
			ctx.lo = -2147483648;
			ctx.hi = 0;
		} else {
			ctx.lo = IntMath.div(a, b);
			ctx.hi = IntMath.mod(a, b);
		}
	}

	public static function divu(ctx:CpuState, a:Int, b:Int):Void {
		if (b == 0) {
			ctx.lo = -1;      // 0xFFFFFFFF
			ctx.hi = a;
		} else if (b < 0) {
			// The divisor has its top bit set, so as an unsigned value it exceeds anything the
			// dividend can be unless the dividend also has it set.
			if (unsignedLess(a, b)) {
				ctx.lo = 0;
				ctx.hi = a;
			} else {
				ctx.lo = 1;
				ctx.hi = (a - b) | 0;
			}
		} else if (a >= 0) {
			ctx.lo = IntMath.div(a, b);
			ctx.hi = IntMath.mod(a, b);
		} else {
			// The dividend's top bit is set but the divisor's is not, so signed division would
			// give the wrong answer. Shift down by one, divide, then correct — the standard
			// technique for unsigned division on a signed type.
			final half = (a >>> 1);
			var q = IntMath.mul(IntMath.div(half, b), 2);
			final r = (a - IntMath.mul(q, b)) | 0;
			if (!unsignedLess(r, b)) {
				q = (q + 1) | 0;
				ctx.hi = (r - b) | 0;
			} else {
				ctx.hi = r;
			}
			ctx.lo = q;
		}
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
		final lo = (~ctx.lo + 1) | 0;
		// The negation carries into the high word exactly when the low word was zero.
		final hi = (~ctx.hi + (ctx.lo == 0 ? 1 : 0)) | 0;
		ctx.lo = lo;
		ctx.hi = hi;
	}
}
