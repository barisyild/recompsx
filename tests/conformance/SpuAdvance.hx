import shim.RawMem;

/**
	The silent path arrives where the sounding path arrives.

	With sound off the SPU advances a voice from event to event instead of sample by sample, and
	the claim is that nothing a game can read is different for it: the envelope's level, phase and
	counter, the position within the block, the block address, the loop point, ENDX. This runs one
	scenario twice — the same waveforms, registers, key-ons and key-offs, the same batch lengths —
	once mixing and once silent, snapshots every voice after every batch, and requires the two
	sets of snapshots to be identical. The batch lengths are chosen so runs are cut by every
	boundary there is: one sample, a block's worth, a period's worth, the buffer, the catch-up cap.

	Cross-target rather than single-target because the run arithmetic is shifts and a ceiling
	division on values that approach 2^26, and two targets agreeing on the digest of the sounding
	snapshots is what says the reference itself is stable.
**/
class SpuAdvance {
	static inline var DUMMY = 0x1000;
	static inline var WAVE = 0x2000;      // two blocks, looping
	static inline var ONESHOT = 0x3000;   // two blocks, the second ends without a repeat
	static inline var LONG = 0x4000;      // four blocks, looping

	public static function main():Void {
		Conf.feedName("spuadvance");
		final sounding = run(true);
		final silent = run(false);
		Conf.expect("as many snapshots silent as sounding", silent.length, sounding.length);
		var same = 0;
		var i = 0;
		while (i < sounding.length) {
			Conf.feed(sounding[i]);
			if (i < silent.length && sounding[i] == silent[i]) same++;
			else {}
			i++;
		}
		Conf.expect("the silent path matches the sounding path at every snapshot", same, sounding.length);
		Conf.report("spuadvance");
	}

	static function run(output:Bool):Array<Int> {
		spu.Spu.init();
		spu.Spu.outputEnabled = output;

		writeBlock(WAVE, 8, 0, 0x04, true);
		writeBlock(WAVE + 16, 8, 0, 0x03, false);
		writeBlock(ONESHOT, 9, 1, 0x04, true);
		writeBlock(ONESHOT + 16, 9, 2, 0x01, false);
		writeBlock(LONG, 7, 3, 0x04, true);
		writeBlock(LONG + 16, 7, 4, 0x00, false);
		writeBlock(LONG + 32, 8, 1, 0x00, true);
		writeBlock(LONG + 48, 8, 2, 0x03, false);
		silentBlock(DUMMY);

		// Six voices, six shapes: immediate rates, periods past a tick (shifts above eleven),
		// an exponential attack that slows above three quarters, an exponential fall in sustain,
		// a pitch of zero that never moves, a pitch above the cap, a one-shot that releases itself.
		voice(0, WAVE, 0x1000, 0x000F, 0x00C0);
		voice(1, ONESHOT, 0x0800, 0x3035, 0xCDA6);
		voice(2, LONG, 0x4000, 0xBBFF, 0x8C4C);
		voice(3, WAVE, 0x0123, 0x00FF, 0x7FFF);
		voice(4, ONESHOT, 0x0000, 0x000F, 0x00C0);
		voice(5, LONG, 0x5000, 0x2C0F, 0x001F);
		reg(0x1F801D80, 0x3FFF);
		reg(0x1F801D82, 0x3FFF);
		reg(0x1F801DAA, 0xC000);

		final out:Array<Int> = [];
		reg(0x1F801D88, 0x003F);            // key on all six
		batches(out);
		reg(0x1F801D8C, 0x0005);            // key off 0 and 2: release at their rates
		batches(out);
		reg(0x1F801C34, 0x2000);            // voice 3 doubles its pitch mid-flight
		reg(0x1F801D88, 0x0002);            // voice 1 restarts while its release is running
		batches(out);
		reg(0x1F801D8C, 0x003F);            // everything off, and enough batches to run it down
		batches(out);
		batches(out);
		return out;
	}

	static function batches(out:Array<Int>):Void {
		step(out, 1);
		step(out, 7);
		step(out, 28);
		step(out, 100);
		step(out, 3);
		step(out, 512);
		step(out, 1);
		step(out, 2048);
		step(out, 4097);
		step(out, 60);
		step(out, 30);
		step(out, 5);
		step(out, 999);
	}

	static function step(out:Array<Int>, n:Int):Void {
		spu.Spu.mixBatchForTest(n);
		var v = 0;
		while (v < 6) {
			out.push(spu.Spu.voiceState(v));
			v++;
		}
		out.push(spu.Spu.read16(0x1F801D9C));
	}

	static function voice(v:Int, start:Int, pitch:Int, adsrLo:Int, adsrHi:Int):Void {
		final base = 0x1F801C00 + v * 0x10;
		reg(base, 0x3FFF);
		reg(base + 2, 0x3FFF);
		reg(base + 4, pitch);
		reg(base + 6, start >> 3);
		reg(base + 8, adsrLo);
		reg(base + 0xA, adsrHi);
	}

	static function writeBlock(at:Int, shift:Int, filter:Int, flags:Int, rising:Bool):Void {
		RawMem.set8(spu.Spu.ram, at, (filter << 4) | shift);
		RawMem.set8(spu.Spu.ram, at + 1, flags);
		var i = 0;
		while (i < 14) {
			final a = rising ? (i & 7) : (7 - (i & 7));
			final b = rising ? ((i + 4) & 15) : (15 - ((i + 4) & 15));
			RawMem.set8(spu.Spu.ram, at + 2 + i, (b << 4) | (a & 0x0F));
			i++;
		}
	}

	static function silentBlock(at:Int):Void {
		RawMem.set8(spu.Spu.ram, at, 0);
		RawMem.set8(spu.Spu.ram, at + 1, 0x07);
		var i = 0;
		while (i < 14) {
			RawMem.set8(spu.Spu.ram, at + 2 + i, 0);
			i++;
		}
	}

	static function reg(addr:Int, value:Int):Void {
		spu.Spu.write16(addr, value);
	}
}
