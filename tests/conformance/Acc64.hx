import shim.I64;

/**
	`shim.I64` — the 64-bit accumulator the GTE's flags are defined on.

	Every one of the GTE's overflow bits is a statement about a value that does not fit in an Int,
	computed from two that do. If the carry between those two words is wrong anywhere, the flags
	are wrong, and a game reading them draws the wrong thing — silently, because the *values* stay
	plausible. So this tests the carry itself, at every boundary it can be wrong at, before a
	single geometry operation is built on top.

	The cases are chosen where the two words interact: sums that carry out of bit 31, operands
	read as unsigned that a signed comparison would misjudge, and the exact fenceposts of the
	44-bit and 32-bit ranges — one below, at, and one above, on both sides of zero. A range check
	that used `>=` where it needed `>` passes every random test and fails only there.
**/
class Acc64 {
	public static function main():Void {
		Conf.feedName("Acc64");

		// ---- set and sign extension ---------------------------------------------------------------
		probe("set 0", 0);
		probe("set 1", 1);
		probe("set -1", -1);
		probe("set 0x7FFFFFFF", 0x7FFFFFFF);
		probe("set 0x80000000", 0x80000000);
		I64.set(-1);
		Conf.expect("a negative fills the high word", I64.hi, -1);
		I64.set(1);
		Conf.expect("a positive leaves it empty", I64.hi, 0);
		I64.setZero();
		Conf.expect("zero is zero, both words", I64.hi | I64.lo, 0);

		// ---- setShl12: the shift that crosses the word boundary -------------------------------------
		//
		// A translation vector enters the accumulator this way. Past 2^19 the shifted value no
		// longer fits in 32 bits, so this is where a one-word implementation starts lying.
		shl12("shl12 0", 0);
		shl12("shl12 1", 1);
		shl12("shl12 -1", -1);
		shl12("shl12 0x7FFFF", 0x7FFFF);          // the largest that still fits in 32 bits
		shl12("shl12 0x80000", 0x80000);          // the first that does not
		shl12("shl12 0x7FFFFFFF", 0x7FFFFFFF);
		shl12("shl12 0x80000000", 0x80000000);
		I64.setShl12(1);
		Conf.expect("one shifted twelve is four thousand and ninety-six", I64.lo, 4096);
		I64.setShl12(-1);
		Conf.expect("minus one keeps its sign in the high word", I64.hi, -1);
		Conf.expect("and its low word is the shifted pattern", I64.lo, 0xFFFFF000);

		// ---- addSmall: the carry ---------------------------------------------------------------------
		//
		// The whole point. `lo` is unsigned but stored in a signed Int, so the carry cannot be a
		// comparison; these are the cases where getting that wrong shows.
		addCase("0 + 0", 0, 0);
		addCase("1 + 1", 1, 1);
		addCase("carry out of bit 31", 0x80000000, 0x80000000);
		addCase("just short of a carry", 0x7FFFFFFF, 1);
		addCase("all ones plus one", 0xFFFFFFFF, 1);
		addCase("all ones plus all ones", 0xFFFFFFFF, 0xFFFFFFFF);
		addCase("negative plus positive", -1, 5);
		addCase("positive plus negative", 5, -1);
		addCase("a chain that crosses zero downward", 3, -5);

		// Adding a negative must borrow from the high word, not carry into it.
		I64.set(0);
		I64.addSmall(-1);
		Conf.expect("zero minus one is minus one, high word", I64.hi, -1);
		Conf.expect("zero minus one is minus one, low word", I64.lo, -1);

		// Accumulating in sequence, which is what the GTE actually does.
		I64.setZero();
		var i = 0;
		while (i < 40) {
			I64.addSmall(0x10000000);
			i++;
		}
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);

		// ---- products -------------------------------------------------------------------------------
		prod16("16x16 zero", 0, 0);
		prod16("16x16 max positive", 0x7FFF, 0x7FFF);
		prod16("16x16 both most negative", -0x8000, -0x8000);
		prod16("16x16 mixed signs", -0x8000, 0x7FFF);
		prod16("the AVSZ corner", 32767, 65535);        // 2,147,385,345 — just inside 32 bits

		prodWide("wide 1x1", 1, 1);
		prodWide("wide -1x-1", -1, -1);
		prodWide("wide -1x1", -1, 1);
		prodWide("wide max", 0x7FFFFFFF, 0x7FFFFFFF);
		prodWide("wide min x min", 0x80000000, 0x80000000);
		prodWide("wide min x -1", 0x80000000, -1);
		prodWide("wide big mixed", 0x12345678, -0x765432);
		prodWide("wide 65536 squared", 65536, 65536);
		prodWide("wide crossing the word", 0x10000000, 0x10);

		// A product accumulated on top of an existing value, not into an empty one.
		I64.set(1000);
		I64.addProductWide(0x10000, 0x10000);
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);

		// ---- the range checks, at their exact edges --------------------------------------------------
		//
		// 2^43 is high word 0x800. One below the limit, exactly the limit, one past: a check that
		// used the wrong comparison passes the first and third and fails only the middle.
		check44("44: zero", 0, 0, 0);
		check44("44: largest inside", 0x7FF, 0xFFFFFFFF, 0);
		check44("44: one past the top", 0x800, 0, 1);
		check44("44: far above", 0x7FFFFFF, 0, 1);
		check44("44: smallest inside", -0x800, 0, 0);
		check44("44: one below the bottom", -0x800, -1, 0);       // hi -0x800, lo 0xFFFFFFFF > -2^43
		check44("44: genuinely below", -0x801, 0xFFFFFFFF, -1);
		check44("44: far below", -0x7FFFFFF, 0, -1);

		check32("32: zero", 0, 0, 0);
		check32("32: largest positive Int", 0, 0x7FFFFFFF, 0);
		check32("32: one past it", 0, 0x80000000, 1);
		check32("32: high word set", 1, 0, 1);
		check32("32: most negative Int", -1, 0x80000000, 0);
		check32("32: one below", -1, 0x7FFFFFFF, -1);
		check32("32: far below", -2, 0, -1);

		// ---- wrap44 -----------------------------------------------------------------------------------
		//
		// Overflow wraps rather than saturating, and the wrap is what the next accumulation step
		// sees. Sign extension from bit 43 is the part that is easy to write and hard to notice
		// missing.
		wrap("wrap: inside stays", 0x123, 0x45678901);
		wrap("wrap: bit 43 clear", 0x7FF, 0xFFFFFFFF);
		wrap("wrap: bit 43 set becomes negative", 0x800, 0);
		wrap("wrap: above the range folds in", 0x1234, 0xABCDEF01);
		wrap("wrap: negative stays negative", -1, 0xFFFFFFFF);
		wrap("wrap: far above", 0x7FFFFFF, 0x11111111);

		// ---- the shifts -------------------------------------------------------------------------------
		shifts("shift: zero", 0, 0);
		shifts("shift: low word only", 0, 0x12345678);
		shifts("shift: across the boundary", 0x123, 0x45678901);
		shifts("shift: negative", -1, 0xFFFFF000);
		shifts("shift: minimum", -0x800, 0);
		shifts("shift: high bit of the low word", 0, 0x80000000);

		// ---- mulShr16Round ----------------------------------------------------------------------------
		//
		// The last step of the division, where the product passes 2^32 and the rounding decides a
		// screen coordinate.
		round("round 0x0", 0, 0);
		round("round 1x1", 1, 1);
		round("round exactly half", 1, 0x8000);
		round("round just under half", 1, 0x7FFF);
		round("round just over half", 1, 0x8001);
		round("round 0x1FFFF x 0x20080", 0x1FFFF, 0x20080);   // the largest pair the GTE produces
		round("round 0x10000 x 0x10000", 0x10000, 0x10000);
		round("round 0xFFFF x 0xFFFF", 0xFFFF, 0xFFFF);
		round("round 0x1FFFF x 1", 0x1FFFF, 1);
		Conf.expect("one times one rounds to nothing", I64.mulShr16Round(1, 1), 0);
		Conf.expect("half a unit rounds up", I64.mulShr16Round(1, 0x8000), 1);
		Conf.expect("a whole unit is a whole unit", I64.mulShr16Round(1, 0x10000), 1);

		Conf.report("Acc64");
	}

	static function probe(label:String, v:Int):Void {
		I64.set(v);
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);
	}

	static function shl12(label:String, v:Int):Void {
		I64.setShl12(v);
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);
		// The same value reached the long way: shifting is twelve doublings, and a doubling is an
		// addition of the value to itself. Agreement pins the shift against arithmetic that cannot
		// itself be shifted wrongly.
		I64.set(v);
		var i = 0;
		while (i < 12) {
			I64.addPair(I64.hi, I64.lo);
			i++;
		}
		Conf.expect(label + " matches twelve doublings, high", I64.hi, hiOfShl12(v));
		Conf.expect(label + " matches twelve doublings, low", I64.lo, (v << 12) | 0);
	}

	static inline function hiOfShl12(v:Int):Int {
		return v >> 20;
	}

	static function addCase(label:String, a:Int, b:Int):Void {
		I64.set(0);
		I64.lo = a;          // the low word as a raw bit pattern, read as unsigned
		I64.hi = 0;
		I64.addSmall(b);
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);
	}

	static function prod16(label:String, a:Int, b:Int):Void {
		I64.setZero();
		I64.addProduct16(a, b);
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);
		// The narrow path and the wide path must agree wherever both are legal.
		final nhi = I64.hi, nlo = I64.lo;
		I64.setZero();
		I64.addProductWide(a, b);
		Conf.expect(label + " narrow equals wide, high", I64.hi, nhi);
		Conf.expect(label + " narrow equals wide, low", I64.lo, nlo);
	}

	static function prodWide(label:String, a:Int, b:Int):Void {
		I64.setZero();
		I64.addProductWide(a, b);
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);
		// Multiplication commutes; an asymmetric sign correction would not.
		final fhi = I64.hi, flo = I64.lo;
		I64.setZero();
		I64.addProductWide(b, a);
		Conf.expect(label + " commutes, high", I64.hi, fhi);
		Conf.expect(label + " commutes, low", I64.lo, flo);
	}

	static function check44(label:String, hi:Int, lo:Int, expected:Int):Void {
		I64.hi = hi;
		I64.lo = lo;
		Conf.expect(label, I64.check44(), expected);
	}

	static function check32(label:String, hi:Int, lo:Int, expected:Int):Void {
		I64.hi = hi;
		I64.lo = lo;
		Conf.expect(label, I64.check32(), expected);
	}

	static function wrap(label:String, hi:Int, lo:Int):Void {
		I64.hi = hi;
		I64.lo = lo;
		I64.wrap44();
		Conf.feed(I64.hi);
		Conf.feed(I64.lo);
		// Whatever came out is inside the range, and wrapping it again changes nothing.
		Conf.expect(label + " lands inside 44 bits", I64.check44(), 0);
		final whi = I64.hi, wlo = I64.lo;
		I64.wrap44();
		Conf.expect(label + " is idempotent, high", I64.hi, whi);
		Conf.expect(label + " is idempotent, low", I64.lo, wlo);
	}

	static function shifts(label:String, hi:Int, lo:Int):Void {
		I64.hi = hi;
		I64.lo = lo;
		Conf.feed(I64.low32());
		Conf.feed(I64.shr12());
		Conf.feed(I64.shr16());
		// Shifting by sixteen twice is shifting by thirty-two, which is the high word.
		I64.hi = hi;
		I64.lo = lo;
		final once = I64.shr16();
		I64.lo = once;
		I64.hi = hi >> 16;
		Conf.expect(label + " twice by sixteen reaches the high word", I64.shr16(), hi);
	}

	static function round(label:String, a:Int, b:Int):Void {
		Conf.feed(I64.mulShr16Round(a, b));
		Conf.expect(label + " commutes", I64.mulShr16Round(a, b), I64.mulShr16Round(b, a));
	}
}
