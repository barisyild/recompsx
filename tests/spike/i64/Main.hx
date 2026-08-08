package;

import haxe.Int64;

/**
	Which 64-bit representation should `shim.I64` be?

	The workload is the one that matters: the GTE's MAC accumulators. Each step multiplies two
	32-bit values into a 64-bit product, accumulates, and checks whether the result left the
	44-bit range — that check is what sets the FLAG bits games actually read.
**/
class Main {
	static inline var N = 3000000;

	public static function main():Void {
		final t0 = now();
		final a = benchHaxeInt64();
		final t1 = now();
		final b = benchHiLo();
		final t2 = now();

		trace("haxe.Int64  result=" + a + "  ms=" + (t1 - t0));
		trace("hand hi/lo  result=" + b + "  ms=" + (t2 - t1));
	}

	/** haxe.Int64: one object per intermediate on targets without a native override. */
	static function benchHaxeInt64():Int {
		var acc = Int64.make(0, 0);
		var i = 0;
		while (i < N) {
			final prod = Int64.mul(Int64.ofInt(i * 7 + 1), Int64.ofInt(0x1234));
			acc = Int64.add(acc, prod);
			// 44-bit range check, as the GTE does
			final hi = acc.high;
			if (hi > 0x7FF || hi < -0x800) acc = Int64.make(0, 0);
			i++;
		}
		return acc.low;
	}

	/**
		Hand-rolled: the accumulator is two plain Ints, so nothing is allocated and every
		operation is integer arithmetic the JIT already knows how to keep in registers.
		Only the operations the GTE needs, which is why this is viable at all — a general
		Int64 has to handle division and shifts by variable amounts too.
	**/
	static function benchHiLo():Int {
		var accLo = 0, accHi = 0;
		var i = 0;
		while (i < N) {
			// 32x32 -> 64 via 16-bit halves, all products fit in 32 bits
			final x = i * 7 + 1;
			final y = 0x1234;
			final xl = x & 0xFFFF, xh = x >> 16;
			final yl = y & 0xFFFF, yh = y >> 16;
			final ll = xl * yl;
			final lh = xl * yh;
			final hl = xh * yl;
			final hh = xh * yh;
			final mid = (ll >>> 16) + (lh & 0xFFFF) + (hl & 0xFFFF);
			var lo = (ll & 0xFFFF) | (mid << 16);
			var hi = hh + (lh >> 16) + (hl >> 16) + (mid >>> 16);

			// 64-bit add
			final newLo = accLo + lo;
			final carry = (((accLo & lo) | ((accLo | lo) & ~newLo)) >>> 31) & 1;
			accLo = newLo;
			accHi = accHi + hi + carry;

			if (accHi > 0x7FF || accHi < -0x800) { accLo = 0; accHi = 0; }
			i++;
		}
		return accLo;
	}

	static function now():Float {
		#if js
		return js.Syntax.code("Date.now()");
		#else
		return 0.0;
		#end
	}
}
