import core.CpuState;
import gte.Gte;

/**
	Every GTE command over a wide random sweep: the whole register file and FLAG after each.

	The companion of `GteProject` for the rest of the instruction set — NCLIP, the averages, MVMVA
	in every combination of matrix, vector and translation, the lighting family, the depth-cue
	family, SQR, OP, GPF and GPL. As there, the point is that a faster formulation must reproduce
	the one before it to the bit, flags included, so the digest was taken on the code before any
	such change. Half the rounds give the registers the ranges a game uses, where nothing
	saturates; the other half give every register anything at all, where everything does.

	The generator is the same 32-bit xorshift as GteProject's, in plain Int arithmetic.
**/
class GteSweep {
	static var ctx:CpuState;
	static var seed = 0x1B873593;

	static final OPS = [0x06, 0x0C, 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x1B, 0x1C, 0x1E, 0x20,
		0x28, 0x29, 0x2A, 0x2D, 0x2E, 0x3D, 0x3E, 0x3F];

	public static function main():Void {
		Conf.feedName("GteSweep");
		ctx = new CpuState();
		Gte.init();
		for (round in 0...16000) {
			setUp((round & 2) != 0);
			final op = OPS[(next() >>> 8) % OPS.length];
			var word = op;
			if ((next() & 3) != 0) word |= 0x80000;              // sf, as games use it
			else {}
			if ((next() & 3) == 0) word |= 0x400;                // lm
			else {}
			word |= next() & 0x7E000;                              // MVMVA's mx, v, cv
			Gte.execute(ctx, word);
			for (reg in 0...32) Conf.feed(Gte.getData(ctx, reg));
			for (reg in 0...32) Conf.feed(Gte.getCtrl(ctx, reg));
		}
		Conf.report("GteSweep");
	}

	static function next():Int {
		var x = seed;
		x = (x ^ (x << 13)) | 0;
		x = x ^ (x >>> 17);
		x = (x ^ (x << 5)) | 0;
		seed = x;
		return x;
	}

	static inline function signedBits(bits:Int):Int {
		return (next() << (32 - bits)) >> (32 - bits);
	}

	static function setUp(wild:Bool):Void {
		if (wild) {
			for (reg in 0...32) if (reg != 15 && reg != 28 && reg != 29 && reg != 31) Gte.setData(ctx, reg, next());
			for (reg in 0...31) Gte.setCtrl(ctx, reg, next());
			// The edges the fast paths are bounded by, reached on purpose.
			switch (next() & 7) {
				case 0: Gte.setCtrl(ctx, 29, (next() & 1) == 0 ? 10922 + (next() & 1) : -10922 - (next() & 1));
				case 1: Gte.setCtrl(ctx, 30, (next() & 1) == 0 ? 8192 + (next() & 1) : -8192 - (next() & 1));
				case 2: Gte.setData(ctx, 12, ((0x3FFF + (next() & 1)) & 0xFFFF) | (-0x4000 << 16));
				case 3: Gte.setCtrl(ctx, 21, (next() & 1) == 0 ? 0x3FFFF + (next() & 1) : -0x3FFFF - (next() & 1));
				case 4: Gte.setCtrl(ctx, 13, 0x3FFFFFFF + (next() & 1));
				case _: {}
			}
		} else {
			// Vertices, normals and IR as a model has them.
			for (v in 0...3) {
				Gte.setData(ctx, v * 2, (signedBits(12) & 0xFFFF) | (signedBits(12) << 16));
				Gte.setData(ctx, v * 2 + 1, signedBits(12));
			}
			Gte.setData(ctx, 6, next());                              // RGBC
			Gte.setData(ctx, 8, next() & 0xFFF);                      // IR0, 0..1.0
			for (reg in 9...12) Gte.setData(ctx, reg, signedBits(13));
			for (reg in 12...15) Gte.setData(ctx, reg, (signedBits(10) & 0xFFFF) | (signedBits(10) << 16));
			for (reg in 16...20) Gte.setData(ctx, reg, next() & 0xFFFF);
			for (reg in 20...23) Gte.setData(ctx, reg, next());
			for (reg in 24...28) Gte.setData(ctx, reg, signedBits(20));
			// Rotation and light matrices within 1.0, the colour matrix positive.
			for (reg in 0...5) Gte.setCtrl(ctx, reg, (signedBits(13) & 0xFFFF) | (signedBits(13) << 16));
			for (reg in 5...8) Gte.setCtrl(ctx, reg, signedBits(12));
			for (reg in 8...13) Gte.setCtrl(ctx, reg, (signedBits(13) & 0xFFFF) | (signedBits(13) << 16));
			for (reg in 13...16) Gte.setCtrl(ctx, reg, next() & 0xFFF);          // BK
			for (reg in 16...21) Gte.setCtrl(ctx, reg, (next() & 0xFFF) | ((next() & 0xFFF) << 16));
			for (reg in 21...24) Gte.setCtrl(ctx, reg, next() & 0xFFF);          // FC
			Gte.setCtrl(ctx, 24, (160 << 16) + signedBits(12));
			Gte.setCtrl(ctx, 25, (120 << 16) + signedBits(12));
			Gte.setCtrl(ctx, 26, 0x100 + (next() & 0xFF));
			Gte.setCtrl(ctx, 27, -(next() & 0xFF));
			Gte.setCtrl(ctx, 28, next() & 0xFFFFFF);
			Gte.setCtrl(ctx, 29, 0x155 + signedBits(6));                          // ZSF3
			Gte.setCtrl(ctx, 30, 0x100 + signedBits(6));                          // ZSF4
		}
	}
}
