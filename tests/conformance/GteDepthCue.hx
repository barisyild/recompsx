import core.CpuState;
import gte.Gte;
import gte.GteQuick;

/**
	DPCS and DPCT at their call sites (`GteQuick.dpcs`, `dpct`) against the general form
	(`Gte.cmdDpcs`, `cmdDpct`): the same inputs through both, every data register and the flag word
	compared, and the general form's outputs fed into the digest.

	The call-site form is the general form's 32-bit path only, taken when the far colour is within
	+-2^18 (`Gte.FC_WIDE`, kept by CTC2 21-23) and sf is 1; everything else goes to the general form
	from inside it. So the rounds reach for the edges of that premise — far colours at -2^18 and
	2^18 - 1 and just past them, game-like ones, anything — and for every saturation on the way:
	the first IR clamp (which ignores lm), the colour clamps at 0 and FFh, the last IR clamp with
	and without lm, IR0 at its extremes. The colour FIFO starts from random contents, so DPCT's
	three pushes, each reading the entry the last one moved down, show in the outputs.

	The generator is a 32-bit xorshift in plain Int arithmetic: the same sequence on every target.
**/
class GteDepthCue {
	static var ctx:CpuState;
	static var seed = 0x6C8E9CF5;

	public static function main():Void {
		Conf.feedName("GteDepthCue");
		ctx = new CpuState();
		Gte.init();
		var differ = 0;
		final quick = new Array<Int>();
		for (k in 0...33) quick.push(0);
		final keep = new Array<Int>();
		for (k in 0...10) keep.push(0);
		for (round in 0...24000) {
			setUp(round);
			final sf = (next() & 7) != 0 ? 12 : 0;
			final lm = (next() & 3) == 0;
			final triple = (round & 1) != 0;
			// What the command writes, kept to put back for the general form.
			for (k in 0...3) {
				keep[k] = Gte.getData(ctx, 9 + k);
				keep[3 + k] = Gte.getData(ctx, 20 + k);
				keep[6 + k] = Gte.getData(ctx, 25 + k);
			}
			keep[9] = Gte.getCtrl(ctx, 31);
			if (triple) GteQuick.dpct(sf, lm);
			else GteQuick.dpcs(sf, lm);
			for (reg in 0...32) quick[reg] = Gte.getData(ctx, reg);
			quick[32] = Gte.getCtrl(ctx, 31);
			for (k in 0...3) {
				Gte.setData(ctx, 9 + k, keep[k]);
				Gte.setData(ctx, 20 + k, keep[3 + k]);
				Gte.setData(ctx, 25 + k, keep[6 + k]);
			}
			Gte.setCtrl(ctx, 31, keep[9]);
			if (triple) Gte.cmdDpct(sf, lm);
			else Gte.cmdDpcs(sf, lm);
			for (reg in 0...32) {
				final v = Gte.getData(ctx, reg);
				Conf.feed(v);
				if (v != quick[reg]) differ++;
				else {}
			}
			final f = Gte.getCtrl(ctx, 31);
			Conf.feed(f);
			if (f != quick[32]) differ++;
			else {}
		}
		Conf.expect("call-site DPCS/DPCT against the general form, registers that differ", differ, 0);
		Conf.report("GteDepthCue");
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

	/** A far colour component: at or just past the edges of the 32-bit form, game-like, or anything. */
	static function fc():Int {
		return switch (next() & 7) {
			case 0: -0x40000 + (next() & 3);
			case 1: 0x3FFFF - (next() & 3);
			case 2: 0x40000 + (next() & 3);
			case 3: -0x40001 - (next() & 3);
			case 4: next();
			case _: next() & 0xFFF;
		}
	}

	static function setUp(round:Int):Void {
		// Half the rounds keep every far colour component game-like, so the call-site form runs
		// rather than handing over; the other half reach for the edges.
		final tame = (round & 2) == 0;
		for (reg in 21...24) Gte.setCtrl(ctx, reg, tame ? next() & 0xFFF : fc());
		Gte.setData(ctx, 6, next());                        // RGBC, its code byte included
		for (reg in 20...23) Gte.setData(ctx, reg, next()); // the colour FIFO
		// IR0: the depth cue's 0..1000h, or any sixteen bits.
		Gte.setData(ctx, 8, (next() & 1) == 0 ? next() & 0x1FFF : s16());
		for (reg in 9...12) Gte.setData(ctx, reg, s16());
		for (reg in 25...28) Gte.setData(ctx, reg, next());
		// A flag word left over from before: the command must clear it.
		if ((round & 7) == 0) Gte.setCtrl(ctx, 31, next());
		else {}
	}
}
