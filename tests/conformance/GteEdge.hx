import core.CpuState;
import gte.Gte;

/**
	RTPS and RTPT where the transform's 32-bit forms begin and end (`Gte.project`): vector
	components at +-2^14, translations at +-2^30, quotients at 0xFFFF and 0x10000, and screen and
	depth-cue sums at the edge of 32 bits, with the matrix entries that make the products largest.
	Every output register and the flag word after each, into the digest.

	`GteProject` reaches every branch of the arithmetic; this reaches every edge of the premises a
	faster form rests on. Its digest was taken with the general forms alone, before the 32-bit ones
	existed, so a shortcut that is not exact at its own boundary changes it.

	The generator is a 32-bit xorshift in plain Int arithmetic: the same sequence on every target.
**/
class GteEdge {
	static var ctx:CpuState;
	static var seed = 0x1F3D5B79;

	public static function main():Void {
		Conf.feedName("GteEdge");
		ctx = new CpuState();
		Gte.init();
		for (round in 0...20000) {
			setUp();
			final sf = (next() & 3) != 0 ? 0x80000 : 0;
			final lm = (next() & 3) == 0 ? 0x400 : 0;
			final rtpt = (round & 1) != 0;
			if ((round & 2) == 0) Gte.execute(ctx, (rtpt ? 0x30 : 0x01) | sf | lm);
			else if (rtpt) Gte.cmdRtpt(sf != 0 ? 1 : 0, lm != 0);
			else Gte.cmdRtps(sf != 0 ? 1 : 0, lm != 0);
			for (reg in 0...32) Conf.feed(Gte.getData(ctx, reg));
			Conf.feed(Gte.getCtrl(ctx, 31));
		}
		Conf.report("GteEdge");
	}

	static function next():Int {
		var x = seed;
		x = (x ^ (x << 13)) | 0;
		x = x ^ (x >>> 17);
		x = (x ^ (x << 5)) | 0;
		seed = x;
		return x;
	}

	static function setUp():Void {
		for (r in 0...4) Gte.setCtrl(ctx, r, (entry() & 0xFFFF) | (entry() << 16));
		Gte.setCtrl(ctx, 4, entry());
		final tz = translation();
		Gte.setCtrl(ctx, 5, translation());
		Gte.setCtrl(ctx, 6, translation());
		Gte.setCtrl(ctx, 7, tz);
		// A quarter of the rounds zero the depth row, so that SZ3 is TRZ and H can be set against
		// it: the quotient lands on either side of 0x10000 and on the divide's own overflow.
		final pinned = (next() & 3) == 0;
		if (pinned) {
			Gte.setCtrl(ctx, 3, Gte.getCtrl(ctx, 3) & 0xFFFF);
			Gte.setCtrl(ctx, 4, 0);
		} else {}
		final sz = tz < 0 ? 0 : (tz > 0xFFFF ? 0xFFFF : tz);
		Gte.setCtrl(ctx, 26, pinned ? (sz + (next() & 1) - (next() & 1)) & 0xFFFF : next() & 0xFFFF);
		Gte.setCtrl(ctx, 24, offset());
		Gte.setCtrl(ctx, 25, offset());
		Gte.setCtrl(ctx, 27, (next() & 1) == 0 ? (next() << 16) >> 16 : ((next() & 1) == 0 ? -0x8000 : 0x7FFF));
		Gte.setCtrl(ctx, 28, offset());
		for (v in 0...3) {
			Gte.setData(ctx, v * 2, (component() & 0xFFFF) | (component() << 16));
			Gte.setData(ctx, v * 2 + 1, component());
		}
		for (reg in 12...15) Gte.setData(ctx, reg, next());
		for (reg in 16...20) Gte.setData(ctx, reg, next());
		if ((next() & 7) == 0) Gte.setCtrl(ctx, 31, next());
		else {}
	}

	/** A vector component: on an edge of +-2^14 or of 16 bits, or anywhere within +-2^14. */
	static function component():Int {
		if ((next() & 1) == 0) {
			return switch (next() & 7) {
				case 0: -0x8000;
				case 1: -0x4001;
				case 2: -0x4000;
				case 3: -0x3FFF;
				case 4: 0x3FFE;
				case 5: 0x3FFF;
				case 6: 0x4000;
				case _: 0x7FFF;
			}
		} else {
			return (next() << 18) >> 17;
		}
	}

	/** A matrix entry: an extreme, a half, or anything 16 bits hold. */
	static function entry():Int {
		return switch (next() & 7) {
			case 0: -0x8000;
			case 1: 0x7FFF;
			case 2: -0x4000;
			case 3: 0x3FFF;
			case _: (next() << 16) >> 16;
		}
	}

	/** A translation: on an edge of +-2^30 or of 32 bits, or a game's. */
	static function translation():Int {
		return switch (next() & 15) {
			case 0: -0x80000000;
			case 1: -0x40000001;
			case 2: -0x40000000;
			case 3: -0x3FFFFFFF;
			case 4: 0x3FFFFFFF;
			case 5: 0x40000000;
			case 6: 0x7FFFFFFF;
			case _: (next() << 12) >> 12;
		}
	}

	/** A screen offset or DQB: next to either end of 32 bits, a screen centre, or anything. */
	static function offset():Int {
		return switch (next() & 3) {
			case 0: 0x7FFF0000 + (next() & 0xFFFF);
			case 1: -0x80000000 + (next() & 0xFFFF);
			case 2: (160 << 16) + ((next() << 20) >> 12);
			case _: next();
		}
	}
}
