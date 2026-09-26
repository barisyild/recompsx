import core.CpuState;
import gte.Gte;

/**
	RTPS and RTPT over a wide random sweep: every output register and the flag word, after each.

	`GteOps` checks the perspective transform where the answer can be worked out by hand; this is
	the other half — thousands of transforms nobody worked out, fed whole into the digest, so that
	a rewrite of the transform for speed must reproduce the one before it to the bit, flags
	included. The inputs are drawn to reach every branch the arithmetic has: all three IR
	saturations with and without `lm`, SZ3 below zero and above 0xFFFF, the divide's overflow, SX
	and SY clamps, MAC0 past 32 bits, and translations beyond 2^30 where the 44-bit checks and
	wraps apply — besides the ordinary vertices games send. The queues start from random contents
	each time, so the order of the pushes shows.

	The generator is a 32-bit xorshift in plain Int arithmetic: the same sequence on every target.
**/
class GteProject {
	static var ctx:CpuState;
	static var seed = 0x2545F491;

	public static function main():Void {
		Conf.feedName("GteProject");
		ctx = new CpuState();
		Gte.init();
		for (round in 0...12000) {
			setUp(round);
			final sf = (next() & 1) != 0 ? 0x80000 : 0;
			final lm = (next() & 3) == 0 ? 0x400 : 0;
			final op = (round & 1) == 0 ? 0x01 : 0x30;
			// The emitter's direct entries and the decoded word both reach the transform.
			if ((round & 2) == 0) Gte.execute(ctx, op | sf | lm);
			else if (op == 0x01) Gte.cmdRtps(sf != 0 ? 1 : 0, lm != 0);
			else Gte.cmdRtpt(sf != 0 ? 1 : 0, lm != 0);
			for (reg in 0...32) Conf.feed(Gte.getData(ctx, reg));
			Conf.feed(Gte.getCtrl(ctx, 31));
		}
		Conf.report("GteProject");
	}

	static function next():Int {
		var x = seed;
		x = (x ^ (x << 13)) | 0;
		x = x ^ (x >>> 17);
		x = (x ^ (x << 5)) | 0;
		seed = x;
		return x;
	}

	/** A 16-bit signed value: anything, or the extremes. */
	static function s16():Int {
		return switch (next() & 3) {
			case 0: -0x8000;
			case 1: 0x7FFF;
			case _: ((next() << 16) >> 16);
		}
	}

	/** A translation for the wild rounds: near the 2^30 edge of the unchecked path, far enough
		out that the 44-bit accumulator overflows either way, or anything at all. */
	static function t32():Int {
		return switch (next() & 7) {
			case 0: 0x3FFFFFFF - (next() & 3);
			case 1: -0x3FFFFFFF + (next() & 3);
			case 2: 0x40000000 + (next() & 0xFFFF);
			case 3: -0x40000000 - (next() & 0xFFFF);
			case 4: 0x7FFFF000 + (next() & 0xFFF);
			case 5: -0x80000000 + (next() & 0xFFF);
			case _: next();
		}
	}

	/**
		Half the rounds look like a game: rotations of at most 1.0, model coordinates in the
		thousands, the camera ahead of the model, a screen centre, a depth cue that stays inside
		0..1.0 — the path nearly every vertex takes, where nothing saturates. The other half
		reach for every edge at once.
	**/
	static function setUp(round:Int):Void {
		final wild = (round & 4) != 0;
		for (r in 0...4) Gte.setCtrl(ctx, r, (mat(wild) & 0xFFFF) | (mat(wild) << 16));
		Gte.setCtrl(ctx, 4, mat(wild));
		if (wild) {
			for (r in 5...8) Gte.setCtrl(ctx, r, (next() & 1) == 0 ? t32() : ((next() << 12) >> 12));
			Gte.setCtrl(ctx, 24, (next() & 1) == 0 ? next() : ((next() << 8) >> 8));
			Gte.setCtrl(ctx, 25, (next() & 1) == 0 ? next() : ((next() << 8) >> 8));
			Gte.setCtrl(ctx, 26, next() & 0xFFFF);
			Gte.setCtrl(ctx, 27, (next() << 16) >> 16);
			Gte.setCtrl(ctx, 28, next());
			for (v in 0...3) {
				Gte.setData(ctx, v * 2, (s16() & 0xFFFF) | (s16() << 16));
				Gte.setData(ctx, v * 2 + 1, s16());
			}
		} else {
			Gte.setCtrl(ctx, 5, (next() << 22) >> 22);
			Gte.setCtrl(ctx, 6, (next() << 22) >> 22);
			Gte.setCtrl(ctx, 7, 0x800 + (next() & 0x1FFF));
			Gte.setCtrl(ctx, 24, (160 << 16) + ((next() << 20) >> 12));
			Gte.setCtrl(ctx, 25, (120 << 16) + ((next() << 20) >> 12));
			Gte.setCtrl(ctx, 26, 0x100 + (next() & 0x1FF));
			Gte.setCtrl(ctx, 27, (next() & 1) == 0 ? 0 : -(next() & 0x3F));
			Gte.setCtrl(ctx, 28, 0x400000 + (next() & 0x3FFFFF));
			for (v in 0...3) {
				Gte.setData(ctx, v * 2, (((next() << 22) >> 22) & 0xFFFF) | (((next() << 22) >> 22) << 16));
				Gte.setData(ctx, v * 2 + 1, (next() << 22) >> 22);
			}
		}
		for (reg in 12...15) Gte.setData(ctx, reg, next());
		for (reg in 16...20) Gte.setData(ctx, reg, next());
		// A flag word left over from before: the command must clear it, whichever entry it came by.
		if ((round & 7) == 0) Gte.setCtrl(ctx, 31, next());
		else {}
	}

	/** A matrix entry: within 1.0 for a game's rotation, anything 16 bits hold otherwise. */
	static function mat(wild:Bool):Int {
		return wild && (next() & 1) == 0 ? s16() : ((next() << 19) >> 19);
	}
}
