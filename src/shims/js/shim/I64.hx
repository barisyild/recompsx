package shim;

/**
	A 64-bit signed accumulator, built out of two Ints.

	The GTE is why this exists. Its matrix operations accumulate into 44-bit registers and set
	overflow flags on the *intermediate* value after every single multiply-add, so the arithmetic
	cannot be done in 32 bits and cannot be done approximately: a game reads those flags and
	changes what it draws. `docs/specs/backend.md` §4 names this module and ADR-0004 fixes its
	shape — hand-rolled hi:lo pairs, never `haxe.Int64`, which allocates an object per intermediate
	on both of this project's targets and measured six times slower on exactly this workload.

	**One accumulator, not a value type.** Every operation reads and writes the same two static
	fields. That is not a limitation to work around: a value type would mean allocation or copying
	per intermediate, which is the cost this design exists to avoid, and the GTE's use is strictly
	sequential — set, accumulate three or four products, test, shift, store. Nothing nests. The
	one place that needed a second 64-bit value at the same time is `mulShr16Round`, which keeps
	its own locals rather than a second accumulator.

	`hi` holds bits 63..32 as a signed Int; `lo` holds bits 31..0 and is read as *unsigned* by
	every operation here, which is why the carry logic is explicit rather than a comparison.

	**This file is duplicated byte-for-byte in `src/shims/cxx/shim/I64.hx`.** It is a shim so that
	the C++ side can one day be `int64_t` — where the whole of this becomes one machine
	instruction — without the runtime changing. Until that happens the two copies must stay
	identical, and `tests/conformance/Acc64.hx` is what says they are: it runs on both targets and
	their digests must match.
**/
class I64 {
	/** Bits 63..32, signed. */
	public static var hi:Int = 0;

	/** Bits 31..0, read as unsigned. */
	public static var lo:Int = 0;

	/** The accumulator becomes a sign-extended 32-bit value. */
	public static inline function set(v:Int):Void {
		lo = v;
		hi = v >> 31;
	}

	public static inline function setZero():Void {
		lo = 0;
		hi = 0;
	}

	/**
		The accumulator becomes `v << 12`, exactly.

		This is how a translation vector enters an MAC accumulation: the GTE holds TR as a plain
		32-bit value and adds it already scaled. `v << 12` overflows 32 bits for any v past 2^19,
		so the shift is done across both words — the low word keeps what a 32-bit shift would give
		and the high word takes the twelve bits that fell off the top, sign included.
	**/
	public static inline function setShl12(v:Int):Void {
		lo = (v << 12) | 0;
		hi = v >> 20;
	}

	/** Adds a sign-extended 32-bit value. */
	public static inline function addSmall(p:Int):Void {
		final sum = (lo + p) | 0;
		// Carry out of bit 31, computed rather than compared: `lo` and `p` are both being read as
		// unsigned here, and Haxe has no unsigned Int to compare them with. This is the standard
		// identity — a carry happens when both inputs had the bit set, or when either did and the
		// result did not.
		final carry = ((lo & p) | ((lo | p) & ~sum)) >>> 31;
		hi = (hi + (p >> 31) + carry) | 0;
		lo = sum;
	}

	/**
		Accumulates `a * b` where the product is known to fit in 32 bits.

		The GTE's matrix rows are this case and nothing else: a signed 16-bit matrix element times
		a signed 16-bit vector element is at most 2^30. So is IR0 times IRn, and so is ZSF times
		SZn — 32767 × 65535 = 2,147,385,345, which clears the 32-bit ceiling by 98,302 and is the
		reason `AVSZ` accumulates four separate products instead of one product of a sum.

		Callers that cannot promise that use `addProductWide`, which costs four multiplies.
	**/
	public static inline function addProduct16(a:Int, b:Int):Void {
		addSmall(IntMath.mul(a, b));
	}

	/**
		Accumulates `a * b` for any two signed 32-bit values.

		The unsigned product comes from 16-bit halves, then the sign is corrected: reading a
		negative operand as unsigned adds 2^32 times the other operand, so subtracting that back
		out of the high word is the whole of the difference between signed and unsigned here.
	**/
	public static function addProductWide(a:Int, b:Int):Void {
		final al = a & 0xFFFF, ah = a >>> 16;
		final bl = b & 0xFFFF, bh = b >>> 16;

		final ll = IntMath.mul(al, bl);
		final lh = IntMath.mul(al, bh);
		final hl = IntMath.mul(ah, bl);
		final hh = IntMath.mul(ah, bh);

		final mid = ((ll >>> 16) + (lh & 0xFFFF) + (hl & 0xFFFF)) | 0;
		final plo = ((ll & 0xFFFF) | (mid << 16)) | 0;
		var phi = (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) | 0;

		if (a < 0) phi = (phi - b) | 0;
		else {}
		if (b < 0) phi = (phi - a) | 0;
		else {}

		addPair(phi, plo);
	}

	/** Adds a 64-bit value given as its two words. */
	public static inline function addPair(ahi:Int, alo:Int):Void {
		final sum = (lo + alo) | 0;
		final carry = ((lo & alo) | ((lo | alo) & ~sum)) >>> 31;
		hi = (hi + ahi + carry) | 0;
		lo = sum;
	}

	/**
		Whether the accumulator has left the 44-bit signed range: +1 above, -1 below, 0 inside.

		Only the high word is examined, and that is exact rather than an approximation. The largest
		44-bit value is `0x7FF_FFFFFFFF`, whose high word is 0x7FF and whose low word is already
		all ones — so any value above it has a high word above 0x7FF. The smallest is
		`-0x800_00000000`, high word -0x800 with a low word of zero, so anything below it has a
		high word below -0x800.
	**/
	public static inline function check44():Int {
		return hi > 0x7FF ? 1 : (hi < -0x800 ? -1 : 0);
	}

	/** The same question for the 32-bit signed range, which is what MAC0's flags are defined on. */
	public static inline function check32():Int {
		return (hi > 0 || (hi == 0 && lo < 0)) ? 1 : ((hi < -1 || (hi == -1 && lo >= 0)) ? -1 : 0);
	}

	/**
		Truncates to 44 bits, sign-extending from bit 43.

		The hardware's accumulators are 44 bits wide, so an overflow does not saturate — it wraps,
		and the flag is the only record that it happened. Every accumulation step does this after
		its check, which is what makes a long chain of adds reproduce the hardware rather than
		merely detecting that it would have differed.
	**/
	public static inline function wrap44():Void {
		hi = ((hi & 0xFFF) << 20) >> 20;
	}

	/** The low 32 bits, which is the accumulator itself when no shift is asked for. */
	public static inline function low32():Int {
		return lo;
	}

	/** The low 32 bits of the value shifted right by 12 — the `sf=1` result. */
	public static inline function shr12():Int {
		return (lo >>> 12) | (hi << 20);
	}

	/** The low 32 bits of the value shifted right by 16 — the screen-coordinate scale. */
	public static inline function shr16():Int {
		return (lo >>> 16) | (hi << 16);
	}

	/**
		`(a * b + 0x8000) >> 16` for non-negative operands, in full precision.

		The last step of the GTE's division, where the product genuinely exceeds 32 bits: a
		17-bit quotient estimate times an 18-bit divisor is up to 2^35. Kept off the accumulator
		and out of its own locals so it can be called while an accumulation is in progress.
	**/
	public static function mulShr16Round(a:Int, b:Int):Int {
		final al = a & 0xFFFF, ah = a >>> 16;
		final bl = b & 0xFFFF, bh = b >>> 16;

		final ll = IntMath.mul(al, bl);
		final lh = IntMath.mul(al, bh);
		final hl = IntMath.mul(ah, bl);
		final hh = IntMath.mul(ah, bh);

		final mid = ((ll >>> 16) + (lh & 0xFFFF) + (hl & 0xFFFF)) | 0;
		final plo = ((ll & 0xFFFF) | (mid << 16)) | 0;
		final phi = (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) | 0;

		final sum = (plo + 0x8000) | 0;
		final carry = ((plo & 0x8000) | ((plo | 0x8000) & ~sum)) >>> 31;
		return (sum >>> 16) | (((phi + carry) | 0) << 16);
	}
}
