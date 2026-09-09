import core.CpuState;
import gte.Gte;

/**
	The GTE: register file, flags, and the geometry operations games draw with.

	Named `GteOps` rather than `Gte` so the test cannot shadow the module it is testing, and so the
	C++ target's bare `GteOps.h` cannot collide with the runtime's `gte_Gte.h`.

	Two kinds of case, deliberately mixed. Where the right answer can be worked out by hand — an
	identity matrix, a triangle with a known area, a value one past a saturation limit — the test
	asserts it, so a failure names the arithmetic. Everywhere else the whole register file is fed
	into the digest after each operation, so a difference between JavaScript and C++ shows up even
	where nobody knew what to expect. That second half is the one that matters: the GTE's flags are
	set by 44-bit intermediates, and a carry that differs between targets produces plausible
	numbers on both.

	Vectors come from the psx-spx formulas in `docs/specs/runtime.md` §5 and from arithmetic done
	here; no emulator was consulted for a single expected value.
**/
class GteOps {
	static var ctx:CpuState;

	public static function main():Void {
		Conf.feedName("GteOps");
		ctx = new CpuState();
		Gte.init();

		registerFile();
		flagComposition();
		lzcsEdges();
		irgbRoundTrip();
		sxyFifo();
		nclipTriangles();
		avszDepths();
		rtpsIdentity();
		rtpsSaturation();
		divisionEdges();
		sfLmMatrix();
		mvmvaSweep();
		mvmvaFarColorBug();
		arithmeticOps();
		colorInterpolation();
		lightingFamily();

		Conf.report("GteOps");
	}

	// ---- every register, written and read back ----------------------------------------------------

	static function registerFile():Void {
		// The probes are the values that reveal a missing sign extension, a missing mask, or a
		// register that silently ignores half of what it is given.
		final probes = [0, 1, -1, 0x7FFF, 0x8000, 0xFFFF, 0x12345678, 0x80000000, 0x0000FFFF];
		for (reg in 0...32) {
			for (p in probes) {
				Gte.setData(ctx, reg, p);
				Conf.feed(Gte.getData(ctx, reg));
			}
		}
		for (reg in 0...32) {
			for (p in probes) {
				Gte.setCtrl(ctx, reg, p);
				Conf.feed(Gte.getCtrl(ctx, reg));
			}
		}

		// The ones with a stated rule, asserted rather than merely folded in.
		Gte.setData(ctx, 1, 0x8000);
		Conf.expect("VZ0 sign-extends", Gte.getData(ctx, 1), -0x8000);
		Gte.setData(ctx, 7, 0x12345);
		Conf.expect("OTZ keeps sixteen bits", Gte.getData(ctx, 7), 0x2345);
		Gte.setData(ctx, 9, 0xFFFF8001);
		Conf.expect("IR1 sign-extends", Gte.getData(ctx, 9), -0x7FFF);
		Gte.setData(ctx, 6, 0x11223344);
		Conf.expect("RGBC is kept whole", Gte.getData(ctx, 6), 0x11223344);
		Gte.setData(ctx, 23, 0xDEADBEEF);
		Conf.expect("RES1 stores anything", Gte.getData(ctx, 23), 0xDEADBEEF);

		// H is unsigned where it is used and sign-extended where it is read: the hardware bug.
		Gte.setCtrl(ctx, 26, 0x8000);
		Conf.expect("H reads back sign-extended", Gte.getCtrl(ctx, 26), 0xFFFF8000);
		Gte.setCtrl(ctx, 26, 0x1234);
		Conf.expect("a small H is unchanged", Gte.getCtrl(ctx, 26), 0x1234);

		// A matrix pair goes in packed and comes back packed, through unpacked storage.
		Gte.setCtrl(ctx, 0, 0x7FFF8001);
		Conf.expect("RT11/RT12 survive the round trip", Gte.getCtrl(ctx, 0), 0x7FFF8001);
		Gte.setCtrl(ctx, 4, 0x8000);
		Conf.expect("RT33 alone sign-extends", Gte.getCtrl(ctx, 4), 0xFFFF8000);

		// Read-only registers ignore writes.
		Gte.setData(ctx, 30, 0x0000FFFF);
		final before = Gte.getData(ctx, 31);
		Gte.setData(ctx, 31, 0);
		Conf.expect("LZCR ignores writes", Gte.getData(ctx, 31), before);
	}

	// ---- FLAG: stored bits, and the one that is computed --------------------------------------------

	static function flagComposition():Void {
		Gte.setCtrl(ctx, 31, 0xFFFFFFFF);
		Conf.expect("FLAG keeps only its defined bits, plus the computed top one",
			Gte.getCtrl(ctx, 31), 0xFFFFF000);
		Gte.setCtrl(ctx, 31, 0);
		Conf.expect("an empty FLAG has no error bit", Gte.getCtrl(ctx, 31), 0);

		// Every bit in the error mask must raise bit 31 on its own; every bit outside it must not.
		for (bit in 12...31) {
			Gte.setCtrl(ctx, 31, 1 << bit);
			final v = Gte.getCtrl(ctx, 31);
			Conf.feed(v);
			final inMask = ((1 << bit) & 0x7F87E000) != 0;
			Conf.expect("bit " + bit + " raises the error bit exactly when it should",
				(v < 0) ? 1 : 0, inMask ? 1 : 0);
		}
	}

	// ---- LZCS: counting the bits that match the sign -------------------------------------------------

	static function lzcsEdges():Void {
		lzc("zero is thirty-two zeroes", 0, 32);
		lzc("minus one is thirty-two ones", -1, 32);
		lzc("one has thirty-one leading zeroes", 1, 31);
		lzc("the top bit set is one leading one", 0x80000000, 1);
		lzc("the largest positive has one zero", 0x7FFFFFFF, 1);
		lzc("a byte", 0x000000FF, 24);
		lzc("a halfword boundary", 0x00010000, 15);
		lzc("negative, one bit clear", 0xFFFEFFFF, 15);
		lzc("negative, low bits set", 0xFFFFFFFE, 31);
	}

	static function lzc(label:String, v:Int, expected:Int):Void {
		Gte.setData(ctx, 30, v);
		Conf.expect(label, Gte.getData(ctx, 31), expected);
		Conf.expect(label + " keeps the source", Gte.getData(ctx, 30), v);
	}

	// ---- IRGB / ORGB --------------------------------------------------------------------------------

	static function irgbRoundTrip():Void {
		// Writing the packed form spreads it over IR1-3 at 0x80 apiece; reading composes it back.
		Gte.setData(ctx, 28, 0x7FFF);
		Conf.expect("IRGB fills IR1", Gte.getData(ctx, 9), 0x1F * 0x80);
		Conf.expect("IRGB fills IR2", Gte.getData(ctx, 10), 0x1F * 0x80);
		Conf.expect("IRGB fills IR3", Gte.getData(ctx, 11), 0x1F * 0x80);
		Conf.expect("and reads back as five bits each", Gte.getData(ctx, 29), 0x7FFF);

		Gte.setData(ctx, 28, (1) | (2 << 5) | (3 << 10));
		Conf.expect("a mixed colour survives the round trip", Gte.getData(ctx, 29),
			(1) | (2 << 5) | (3 << 10));

		// Out-of-range IR values clamp on the way out rather than wrapping.
		Gte.setData(ctx, 9, -1);
		Gte.setData(ctx, 10, 0x7FFF);
		Gte.setData(ctx, 11, 0x800);
		Conf.expect("a negative component reads as zero", Gte.getData(ctx, 29) & 0x1F, 0);
		Conf.expect("an oversized one reads as full", (Gte.getData(ctx, 29) >> 5) & 0x1F, 0x1F);
		Conf.expect("an exact one reads exactly", (Gte.getData(ctx, 29) >> 10) & 0x1F, 0x10);
	}

	// ---- the screen FIFO ------------------------------------------------------------------------------

	static function sxyFifo():Void {
		Gte.setData(ctx, 12, 0x11111111);
		Gte.setData(ctx, 13, 0x22222222);
		Gte.setData(ctx, 14, 0x33333333);
		Conf.expect("writing SXY2 does not disturb the queue", Gte.getData(ctx, 12), 0x11111111);

		Gte.setData(ctx, 15, 0x44444444);
		Conf.expect("writing the mirror pushes: oldest is gone", Gte.getData(ctx, 12), 0x22222222);
		Conf.expect("the middle moved down", Gte.getData(ctx, 13), 0x33333333);
		Conf.expect("and the new one is on top", Gte.getData(ctx, 14), 0x44444444);
		Conf.expect("the mirror reads the top without popping", Gte.getData(ctx, 15), 0x44444444);
		Conf.expect("and reading it again changes nothing", Gte.getData(ctx, 12), 0x22222222);
	}

	// ---- NCLIP: the winding test ------------------------------------------------------------------------

	static function nclipTriangles():Void {
		// A right triangle with legs of 100: twice its area, sign carrying the winding.
		triangle(0, 0, 100, 0, 0, 100);
		exec(0x06);
		// x0*y1 + x1*y2 + x2*y0 - x0*y2 - x1*y0 - x2*y1, which for this triangle is
		// 0 + 100*100 + 0 - 0 - 0 - 0. Twice the area, with the sign carrying the winding.
		Conf.expect("a triangle wound this way has a positive signed area",
			Gte.getData(ctx, 24), 10000);

		triangle(0, 0, 0, 100, 100, 0);
		exec(0x06);
		Conf.expect("reversing the winding flips the sign", Gte.getData(ctx, 24), -10000);

		triangle(0, 0, 50, 50, 100, 100);
		exec(0x06);
		Conf.expect("three points on a line enclose nothing", Gte.getData(ctx, 24), 0);

		// The corners, where the products are largest.
		triangle(0x3FF, 0x3FF, -0x400, 0x3FF, 0x3FF, -0x400);
		exec(0x06);
		Conf.feed(Gte.getData(ctx, 24));
		Conf.feed(Gte.getCtrl(ctx, 31));

		// Values a game could only get by writing the FIFO directly, which it may.
		triangle(0x7FFF, 0x7FFF, -0x8000, 0x7FFF, 0x7FFF, -0x8000);
		exec(0x06);
		Conf.feed(Gte.getData(ctx, 24));
		Conf.feed(Gte.getCtrl(ctx, 31));
	}

	static function triangle(x0:Int, y0:Int, x1:Int, y1:Int, x2:Int, y2:Int):Void {
		Gte.setData(ctx, 12, packXY(x0, y0));
		Gte.setData(ctx, 13, packXY(x1, y1));
		Gte.setData(ctx, 14, packXY(x2, y2));
	}

	static inline function packXY(x:Int, y:Int):Int {
		return (x & 0xFFFF) | (y << 16);
	}

	// ---- AVSZ: the ordering-table key --------------------------------------------------------------------

	static function avszDepths():Void {
		Gte.setData(ctx, 16, 100);
		Gte.setData(ctx, 17, 200);
		Gte.setData(ctx, 18, 300);
		Gte.setData(ctx, 19, 400);

		// The factor is a plain multiplier applied before a shift of twelve, so a factor of 4096/n
		// turns the sum of n depths into their average.
		Gte.setCtrl(ctx, 29, 0x555);             // 4096/3, rounded down
		exec(0x2D);
		Conf.expect("AVSZ3 averages the last three", Gte.getData(ctx, 7), 299);
		Conf.feed(Gte.getData(ctx, 24));

		Gte.setCtrl(ctx, 30, 0x400);             // 4096/4
		exec(0x2E);
		Conf.expect("AVSZ4 averages all four", Gte.getData(ctx, 7), 250);
		Conf.feed(Gte.getData(ctx, 24));

		// Saturation both ways: a huge factor overflows OTZ, a negative one drives it below zero.
		Gte.setData(ctx, 16, 0xFFFF);
		Gte.setData(ctx, 17, 0xFFFF);
		Gte.setData(ctx, 18, 0xFFFF);
		Gte.setData(ctx, 19, 0xFFFF);
		Gte.setCtrl(ctx, 30, 0x7FFF);
		exec(0x2E);
		Conf.expect("an overflowing average clamps high", Gte.getData(ctx, 7), 0xFFFF);
		Conf.expect("and says so", (Gte.getCtrl(ctx, 31) >> 18) & 1, 1);

		Gte.setCtrl(ctx, 30, -0x8000);
		exec(0x2E);
		Conf.expect("a negative average clamps low", Gte.getData(ctx, 7), 0);
		Conf.expect("and says so too", (Gte.getCtrl(ctx, 31) >> 18) & 1, 1);
		Conf.feed(Gte.getCtrl(ctx, 31));
	}

	// ---- RTPS with a matrix whose answer is known ----------------------------------------------------------

	static function rtpsIdentity():Void {
		identityTransform();
		// A point one unit along each axis, at a depth the divider can handle.
		setVector(0, 100, 200, 300);
		Gte.setCtrl(ctx, 26, 300);               // H equal to the depth: the divide gives 1.0
		exec(0x01);

		Conf.expect("the identity leaves X where it was", Gte.getData(ctx, 25), 100);
		Conf.expect("and Y", Gte.getData(ctx, 26), 200);
		Conf.expect("and Z", Gte.getData(ctx, 27), 300);
		Conf.expect("the depth reaches the queue", Gte.getData(ctx, 19), 300);
		// n = (H*0x10000 + SZ3/2) / SZ3 = 0x10000 exactly when H == SZ3; SX = OFX + IR1*n >> 16.
		Conf.expect("the screen X is the camera X", sxOf(Gte.getData(ctx, 14)), 100);
		Conf.expect("the screen Y is the camera Y", syOf(Gte.getData(ctx, 14)), 200);
		Conf.expect("nothing overflowed", Gte.getCtrl(ctx, 31), 0);

		// A translation with no rotation.
		identityTransform();
		// TR enters the accumulator already scaled by 0x1000, so it is written in the same units
		// the result comes out in — no hand-scaling.
		Gte.setCtrl(ctx, 5, 10);
		Gte.setCtrl(ctx, 6, 20);
		Gte.setCtrl(ctx, 7, 30);
		setVector(0, 1, 2, 3);
		Gte.setCtrl(ctx, 26, 33);
		exec(0x01);
		Conf.expect("translation adds", Gte.getData(ctx, 25), 11);
		Conf.expect("on every axis", Gte.getData(ctx, 26), 22);
		Conf.expect("including depth", Gte.getData(ctx, 27), 33);

		// A permutation matrix — a "rotation" that stays exact in integers.
		zeroMatrix();
		Gte.setCtrl(ctx, 0, packXY(0, 0x1000));       // RT11=0, RT12=0x1000
		Gte.setCtrl(ctx, 1, packXY(0, -0x1000));      // RT13=0, RT21=-0x1000
		Gte.setCtrl(ctx, 2, packXY(0, 0));
		Gte.setCtrl(ctx, 3, packXY(0, 0));
		Gte.setCtrl(ctx, 4, 0x1000);                  // RT33
		Gte.setCtrl(ctx, 5, 0); Gte.setCtrl(ctx, 6, 0); Gte.setCtrl(ctx, 7, 0);
		setVector(0, 7, 11, 13);
		Gte.setCtrl(ctx, 26, 13);
		exec(0x01);
		Conf.expect("a quarter turn sends Y to X", Gte.getData(ctx, 25), 11);
		Conf.expect("and minus X to Y", Gte.getData(ctx, 26), -7);
		Conf.expect("leaving Z alone", Gte.getData(ctx, 27), 13);

		// RTPT does the same three times and only the last drives the depth cue.
		identityTransform();
		setVector(0, 10, 20, 300);
		setVector(1, 30, 40, 300);
		setVector(2, 50, 60, 300);
		Gte.setCtrl(ctx, 26, 300);
		exec(0x30);
		Conf.expect("RTPT leaves the first vertex at the bottom of the queue",
			sxOf(Gte.getData(ctx, 12)), 10);
		Conf.expect("the second in the middle", sxOf(Gte.getData(ctx, 13)), 30);
		Conf.expect("and the third on top", sxOf(Gte.getData(ctx, 14)), 50);
		feedAll();
	}

	// ---- saturation, one case per flag ---------------------------------------------------------------------

	static function rtpsSaturation():Void {
		// A matrix element and a vector element both at their maximum drive MAC1 past what IR1
		// can hold.
		zeroMatrix();
		Gte.setCtrl(ctx, 0, packXY(0x7FFF, 0));
		Gte.setCtrl(ctx, 4, 0x1000);
		setVector(0, 0x7FFF, 0, 100);
		Gte.setCtrl(ctx, 26, 100);
		exec(0x01);
		Conf.expect("IR1 saturates high", Gte.getData(ctx, 9), 0x7FFF);
		Conf.expect("and flags it", (Gte.getCtrl(ctx, 31) >> 24) & 1, 1);
		feedAll();

		// The same, negative, with lm clamping to zero instead of -0x8000.
		Gte.setCtrl(ctx, 0, packXY(-0x8000, 0));
		setVector(0, 0x7FFF, 0, 100);
		exec(0x01);
		Conf.expect("IR1 saturates low without lm", Gte.getData(ctx, 9), -0x8000);
		execLm(0x01);
		Conf.expect("and to zero with it", Gte.getData(ctx, 9), 0);
		feedAll();

		// A translation big enough to leave the 44-bit accumulator.
		identityTransform();
		Gte.setCtrl(ctx, 5, 0x7FFFFFFF);
		setVector(0, 0x7FFF, 0x7FFF, 0x7FFF);
		exec(0x01);
		Conf.feed(Gte.getCtrl(ctx, 31));
		feedAll();

		// Screen coordinates outside the visible range clamp and flag.
		identityTransform();
		setVector(0, 0x7FFF, 0x7FFF, 100);
		Gte.setCtrl(ctx, 26, 100);
		Gte.setCtrl(ctx, 24, 0x7FFFFFF);          // a huge X offset
		exec(0x01);
		Conf.expect("SX clamps to the right edge", sxOf(Gte.getData(ctx, 14)), 0x3FF);
		Conf.expect("and flags it", (Gte.getCtrl(ctx, 31) >> 14) & 1, 1);
		// The other edge needs IR1 itself negative: an offset cannot outweigh a saturated IR1
		// times a unit quotient, which is already most of the Int range.
		Gte.setCtrl(ctx, 24, 0);
		setVector(0, -0x8000, 0, 100);
		exec(0x01);
		Conf.expect("and to the left edge when IR1 is negative",
			sxOf(Gte.getData(ctx, 14)), -0x400);
		Conf.expect("flagged on that side too", (Gte.getCtrl(ctx, 31) >> 14) & 1, 1);
		feedAll();
	}

	// ---- the divider ----------------------------------------------------------------------------------------

	static function divisionEdges():Void {
		identityTransform();

		// H exactly equal to the depth: the quotient is one, and everything downstream is exact.
		divide(1000, 1000);
		Conf.expect("H equal to the depth gives unity", Gte.getData(ctx, 8) >= 0 ? 1 : 0, 1);
		feedAll();

		// Half the depth is a half.
		divide(500, 1000);
		feedAll();

		// H at twice the depth is exactly the point the hardware refuses.
		divide(2000, 1000);
		Conf.expect("twice the depth overflows the divider",
			(Gte.getCtrl(ctx, 31) >> 17) & 1, 1);
		Conf.expect("and the overflow reaches bit 31", Gte.getCtrl(ctx, 31) < 0 ? 1 : 0, 1);
		feedAll();

		// One below that is the largest quotient it will produce.
		divide(1999, 1000);
		Conf.expect("one short of it does not overflow", (Gte.getCtrl(ctx, 31) >> 17) & 1, 0);
		feedAll();

		// A depth of zero cannot be normalised at all.
		divide(1, 0);
		Conf.expect("a zero depth overflows", (Gte.getCtrl(ctx, 31) >> 17) & 1, 1);
		feedAll();

		// The extremes of the divisor's range, where the normalisation shift is 0 and 15.
		divide(0xFFFF, 0xFFFF);
		feedAll();
		divide(1, 1);
		feedAll();
		divide(0x7FFF, 0x8000);
		feedAll();
		divide(0xFFFE, 0x7FFF);
		feedAll();
	}

	/** Runs one RTPS whose only interesting part is H over SZ3. */
	static function divide(hv:Int, depth:Int):Void {
		setVector(0, 0, 0, depth);
		Gte.setCtrl(ctx, 26, hv);
		exec(0x01);
	}

	// ---- sf and lm, across the operations that read them -------------------------------------------------------

	static function sfLmMatrix():Void {
		identityTransform();
		setVector(0, 1234, -5678, 4096);
		Gte.setCtrl(ctx, 26, 4096);
		for (sf in 0...2) {
			for (lm in 0...2) {
				var imm = 0x01;
				if (sf == 1) imm |= 0x80000;
				else {}
				if (lm == 1) imm |= 0x400;
				else {}
				Gte.execute(ctx, imm);
				feedAll();
			}
		}
	}

	// ---- MVMVA, over every operand combination -------------------------------------------------------------------

	/**
		All sixty-four ways of naming MVMVA's operands, each with the whole register file fed in.

		MVMVA is not one operation but a family: three bits of matrix, two of vector, two of
		translation, and the instruction word decides. A mistake in the *selection* — the light
		matrix read where the colour matrix was asked for, the background colour used as the
		translation — produces perfectly plausible numbers for the wrong question, which is exactly
		the failure a digest catches and an eyeball does not. Sweeping the field pins all of it.
	**/
	static function mvmvaSweep():Void {
		loadDistinctMatrices();
		setVector(0, 100, -200, 300);
		setVector(1, -400, 500, -600);
		setVector(2, 700, -800, 900);
		Gte.setData(ctx, 9, 1111);      // IR1
		Gte.setData(ctx, 10, -2222);    // IR2
		Gte.setData(ctx, 11, 3333);     // IR3
		Gte.setData(ctx, 6, 0x40302010); // RGBC, whose red byte feeds the garbage matrix
		Gte.setData(ctx, 8, 0x555);      // IR0, likewise

		for (mx in 0...4) {
			for (v in 0...4) {
				for (cv in 0...4) {
					Gte.execute(ctx, 0x12 | 0x80000 | (mx << 17) | (v << 15) | (cv << 13));
					feedAll();
				}
			}
		}
	}

	/**
		The far-colour translation, which the hardware does not add correctly.

		psx-spx: the result keeps only the last two products of each row, while FLAG is set as
		though the whole sum had been computed. Both halves are asserted, because an implementation
		that "fixes" the bug passes every other test in this file.
	**/
	static function mvmvaFarColorBug():Void {
		loadDistinctMatrices();
		setVector(0, 0x1000, 0x1000, 0x1000);
		// FC large enough that the omitted first term would be unmissable if it were added.
		Gte.setCtrl(ctx, 21, 0x7000);
		Gte.setCtrl(ctx, 22, 0x7000);
		Gte.setCtrl(ctx, 23, 0x7000);

		Gte.execute(ctx, 0x12 | 0x80000 | (0 << 17) | (0 << 15) | (2 << 13));
		final fcMac1 = Gte.getData(ctx, 25);
		// The same rows with no translation at all: identical but for the first product.
		Gte.execute(ctx, 0x12 | 0x80000 | (0 << 17) | (0 << 15) | (3 << 13));
		final noneMac1 = Gte.getData(ctx, 25);
		// RT11 * VX0, the term the far-colour path throws away, at sf=12.
		final firstTerm = (0x0100 * 0x1000) >> 12;
		Conf.expect("the far-colour path loses the first product of the row",
			noneMac1 - fcMac1, firstTerm);
		feedAll();
	}

	static function loadDistinctMatrices():Void {
		// Rotation, light and colour matrices with no value in common, so a mis-selected one shows.
		Gte.setCtrl(ctx, 0, packXY(0x0100, 0x0200));
		Gte.setCtrl(ctx, 1, packXY(0x0300, 0x0400));
		Gte.setCtrl(ctx, 2, packXY(0x0500, 0x0600));
		Gte.setCtrl(ctx, 3, packXY(0x0700, 0x0800));
		Gte.setCtrl(ctx, 4, 0x0900);
		Gte.setCtrl(ctx, 5, 11);  Gte.setCtrl(ctx, 6, 22);  Gte.setCtrl(ctx, 7, 33);   // TR
		Gte.setCtrl(ctx, 8, packXY(0x1100, 0x1200));
		Gte.setCtrl(ctx, 9, packXY(0x1300, 0x1400));
		Gte.setCtrl(ctx, 10, packXY(0x1500, 0x1600));
		Gte.setCtrl(ctx, 11, packXY(0x1700, 0x1800));
		Gte.setCtrl(ctx, 12, 0x1900);
		Gte.setCtrl(ctx, 13, 44); Gte.setCtrl(ctx, 14, 55); Gte.setCtrl(ctx, 15, 66);  // BK
		Gte.setCtrl(ctx, 16, packXY(0x2100, 0x2200));
		Gte.setCtrl(ctx, 17, packXY(0x2300, 0x2400));
		Gte.setCtrl(ctx, 18, packXY(0x2500, 0x2600));
		Gte.setCtrl(ctx, 19, packXY(0x2700, 0x2800));
		Gte.setCtrl(ctx, 20, 0x2900);
		Gte.setCtrl(ctx, 21, 77); Gte.setCtrl(ctx, 22, 88); Gte.setCtrl(ctx, 23, 99);  // FC
	}

	/** SQR, OP, GPF and GPL — small, and each wrong in a different way if the shift is wrong. */
	static function arithmeticOps():Void {
		loadDistinctMatrices();
		Gte.setData(ctx, 8, 0x800);       // IR0, the interpolation weight
		Gte.setData(ctx, 9, 0x1000);
		Gte.setData(ctx, 10, -0x0800);
		Gte.setData(ctx, 11, 0x0400);
		for (sf in 0...2) {
			final s = sf == 1 ? 0x80000 : 0;
			Gte.setData(ctx, 9, 0x1000); Gte.setData(ctx, 10, -0x0800); Gte.setData(ctx, 11, 0x0400);
			Gte.execute(ctx, 0x28 | s); feedAll();      // SQR
			Gte.setData(ctx, 9, 0x1000); Gte.setData(ctx, 10, -0x0800); Gte.setData(ctx, 11, 0x0400);
			Gte.execute(ctx, 0x0C | s); feedAll();      // OP
			Gte.setData(ctx, 9, 0x1000); Gte.setData(ctx, 10, -0x0800); Gte.setData(ctx, 11, 0x0400);
			Gte.execute(ctx, 0x3D | s); feedAll();      // GPF
			Gte.setData(ctx, 9, 0x1000); Gte.setData(ctx, 10, -0x0800); Gte.setData(ctx, 11, 0x0400);
			Gte.execute(ctx, 0x3E | s); feedAll();      // GPL
		}
		// The square of a vector cannot be negative however `lm` is set.
		Gte.setData(ctx, 9, -0x1000);
		Gte.execute(ctx, 0x28 | 0x80000);
		final sq = Gte.getData(ctx, 25);
		Conf.expect("a squared component is positive", sq >= 0 ? 1 : 0, 1);
	}

	/**
		The fog family, whose whole point is the intermediate that is *not* saturated by `lm`.

		psx-spx puts it in a footnote: `(FC - MAC)` lands in IR saturated as if `lm` were zero, and
		only the final write obeys the real `lm`. Clamp the intermediate and every negative
		difference becomes zero, so fog brightens where it should darken and no test of the final
		value alone would notice.
	**/
	static function colorInterpolation():Void {
		loadDistinctMatrices();
		Gte.setCtrl(ctx, 21, 0x0040); Gte.setCtrl(ctx, 22, 0x0080); Gte.setCtrl(ctx, 23, 0x00C0);
		for (sf in 0...2) {
			for (lm in 0...2) {
				final imm = (sf == 1 ? 0x80000 : 0) | (lm == 1 ? 0x400 : 0);
				Gte.setData(ctx, 6, 0x01203040);   // RGBC
				Gte.setData(ctx, 8, 0x0800);       // IR0
				Gte.setData(ctx, 9, 0x0200); Gte.setData(ctx, 10, -0x0300); Gte.setData(ctx, 11, 0x0400);
				Gte.execute(ctx, 0x10 | imm); feedAll();   // DPCS
				Gte.setData(ctx, 9, 0x0200); Gte.setData(ctx, 10, -0x0300); Gte.setData(ctx, 11, 0x0400);
				Gte.execute(ctx, 0x11 | imm); feedAll();   // INTPL
				Gte.setData(ctx, 9, 0x0200); Gte.setData(ctx, 10, -0x0300); Gte.setData(ctx, 11, 0x0400);
				Gte.execute(ctx, 0x29 | imm); feedAll();   // DCPL
				Gte.execute(ctx, 0x2A | imm); feedAll();   // DPCT, which consumes the colour FIFO
			}
		}
	}

	/**
		The six normal-colour commands and the two colour ones, over both `sf` and both `lm`.

		These are how a model gets lit, and they are built out of two fixed MVMVA steps plus a
		material multiply and an optional depth cue — so a mistake in the *composition* produces
		numbers that are individually plausible and a scene that is wrong, most often black. The
		vectors here give the light and colour matrices distinct values from the rotation matrix,
		so a command reaching for the wrong one shows immediately.
	**/
	static function lightingFamily():Void {
		loadDistinctMatrices();
		setVector(0, 0x0400, -0x0300, 0x0200);
		setVector(1, -0x0100, 0x0500, 0x0300);
		setVector(2, 0x0600, 0x0100, -0x0400);
		Gte.setCtrl(ctx, 21, 0x0180); Gte.setCtrl(ctx, 22, 0x01C0); Gte.setCtrl(ctx, 23, 0x0200);
		final ops = [0x1E, 0x20, 0x13, 0x16, 0x1B, 0x3F, 0x1C, 0x14];
		for (o in 0...ops.length) {
			for (sf in 0...2) {
				for (lm in 0...2) {
					Gte.setData(ctx, 6, 0x02607080);   // RGBC: a material that is not grey
					Gte.setData(ctx, 8, 0x0400);       // IR0
					Gte.setData(ctx, 9, 0x0300);
					Gte.setData(ctx, 10, -0x0200);
					Gte.setData(ctx, 11, 0x0500);
					Gte.execute(ctx, ops[o] | (sf == 1 ? 0x80000 : 0) | (lm == 1 ? 0x400 : 0));
					feedAll();
				}
			}
		}
	}

	// ---- helpers -----------------------------------------------------------------------------------------------

	static function exec(op:Int):Void {
		// sf = 1 is what every real game uses; the sf/lm sweep covers the rest.
		Gte.execute(ctx, op | 0x80000);
	}

	static function execLm(op:Int):Void {
		Gte.execute(ctx, op | 0x80000 | 0x400);
	}

	static function identityTransform():Void {
		zeroMatrix();
		Gte.setCtrl(ctx, 0, packXY(0x1000, 0));       // RT11 = 1.0, RT12 = 0
		Gte.setCtrl(ctx, 1, packXY(0, 0));            // RT13 = 0,   RT21 = 0
		Gte.setCtrl(ctx, 2, packXY(0x1000, 0));       // RT22 = 1.0, RT23 = 0
		Gte.setCtrl(ctx, 3, packXY(0, 0));            // RT31 = 0,   RT32 = 0
		Gte.setCtrl(ctx, 4, 0x1000);                  // RT33 = 1.0
		Gte.setCtrl(ctx, 5, 0);
		Gte.setCtrl(ctx, 6, 0);
		Gte.setCtrl(ctx, 7, 0);
		Gte.setCtrl(ctx, 24, 0);
		Gte.setCtrl(ctx, 25, 0);
		Gte.setCtrl(ctx, 27, 0);
		Gte.setCtrl(ctx, 28, 0);
	}

	static function zeroMatrix():Void {
		for (r in 0...5) Gte.setCtrl(ctx, r, 0);
	}

	static function setVector(v:Int, x:Int, y:Int, z:Int):Void {
		Gte.setData(ctx, v * 2, packXY(x, y));
		Gte.setData(ctx, v * 2 + 1, z);
	}

	static inline function sxOf(v:Int):Int {
		return (v << 16) >> 16;
	}

	static inline function syOf(v:Int):Int {
		return v >> 16;
	}

	/** The whole visible state after an operation — values and flags together. */
	static function feedAll():Void {
		for (reg in 0...32) Conf.feed(Gte.getData(ctx, reg));
		Conf.feed(Gte.getCtrl(ctx, 31));
	}
}
