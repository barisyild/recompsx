import shim.RawMem;

/**
	Every falling envelope, silent and sounding, arrives at the same place.

	With sound off, a release, a decay and a falling sustain are taken a stretch of equal steps at
	a time (`Spu.fallRun`) instead of tick by tick. `SpuAdvance` holds the silent path to the
	sounding one on six hand-picked voices; this does the same across the whole parameter space
	of the falling phases: every release shift linear and exponential, every decay shift towards
	several sustain levels, every falling sustain shift and step in both modes. Each round keys
	all 24 voices on with a different pitch and waveform, releases them in waves (some from the
	top, some mid-attack, one restarted mid-release), and snapshots every voice after every
	batch; the silent snapshots must equal the sounding ones.
**/
class SpuFall {
	static inline var WAVE = 0x2000;      // two blocks, looping
	static inline var ONESHOT = 0x3000;   // two blocks, the second ends without a repeat
	static inline var LONG = 0x4000;      // four blocks, looping

	public static function main():Void {
		Conf.feedName("spufall");
		final sounding = run(true);
		final silent = run(false);
		Conf.expect("as many snapshots silent as sounding", silent.length, sounding.length);
		var same = 0;
		var firstDiff = -1;
		var i = 0;
		while (i < sounding.length) {
			Conf.feed(sounding[i]);
			if (i < silent.length && sounding[i] == silent[i]) same++;
			else if (firstDiff < 0) firstDiff = i;
			else {}
			i++;
		}
		Conf.expect("first snapshot that differs", firstDiff, -1);
		Conf.expect("the silent path matches the sounding path at every snapshot", same, sounding.length);
		Conf.report("spufall");
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
		reg(0x1F801D80, 0x3FFF);
		reg(0x1F801D82, 0x3FFF);
		reg(0x1F801DAA, 0xC000);

		final out:Array<Int> = [];
		// Fast attack (shift 0), decay to full: every voice sits at the top before its release.
		final top = 0x000F;
		// Releases, exponential then linear: shifts 0..31 each.
		var round = 0;
		while (round < 4) {
			var v = 0;
			while (v < 24) {
				final shift = (round * 24 + v) & 31;
				final exponential = round < 2 ? 0x20 : 0;
				setVoice(v, top, exponential | shift);
				v++;
			}
			releaseRound(out, round);
			round++;
		}
		// Decays: every shift, towards sustain levels 0..15, sustaining flat afterwards.
		round = 0;
		while (round < 2) {
			var v = 0;
			while (v < 24) {
				final shift = (v + round * 8) & 15;
				final level = (v * 5 + round * 3) & 15;
				setVoice(v, (shift << 4) | level, 0x001F);
				v++;
			}
			sustainRound(out, round);
			round++;
		}
		// Falling sustains: every shift and step, exponential and linear, from a decay target
		// of a half, a quarter and full.
		round = 0;
		while (round < 4) {
			var v = 0;
			while (v < 24) {
				final shift = (round * 24 + v) & 31;
				final step = (v + round) & 3;
				final exponential = (round & 1) == 0 ? 0x8000 : 0;
				final level = v % 3 == 0 ? 0x7 : (v % 3 == 1 ? 0x3 : 0xF);
				setVoice(v, level, exponential | 0x4000 | (shift << 8) | (step << 6) | 0x20 | (v & 15));
				v++;
			}
			sustainRound(out, round);
			round++;
		}
		return out;
	}

	/** Key on, release in three waves (top, mid-attack, a restart mid-release), run it down. */
	static function releaseRound(out:Array<Int>, round:Int):Void {
		reg(0x1F801D88, 0xFFFF);
		reg(0x1F801D8A, 0x00FF);
		step(out, 3);                        // mid-attack for the early wave
		reg(0x1F801D8C, 0x0303);             // voices 0,1,8,9: release before reaching the top
		step(out, 97);
		reg(0x1F801D8C, 0xFCFC);
		reg(0x1F801D8E, 0x00FF);             // everyone else: release from the top
		batches(out);
		reg(0x1F801D88, 0x0010);             // voice 4 restarts while its release is running
		step(out, 11);
		reg(0x1F801D8C, 0x0010);
		batches(out);
		batches(out);
	}

	/** Key on, let decay and sustain run, then release everything and run it down. */
	static function sustainRound(out:Array<Int>, round:Int):Void {
		reg(0x1F801D88, 0xFFFF);
		reg(0x1F801D8A, 0x00FF);
		batches(out);
		batches(out);
		reg(0x1F801D8C, 0xFFFF);
		reg(0x1F801D8E, 0x00FF);
		batches(out);
		batches(out);
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
		while (v < 24) {
			out.push(spu.Spu.voiceState(v));
			v++;
		}
		out.push(spu.Spu.read16(0x1F801D9C));
		out.push(spu.Spu.read16(0x1F801D9E));
	}

	/** One voice: a waveform and a pitch that vary with the voice, and the given envelope. */
	static function setVoice(v:Int, adsrLo:Int, adsrHi:Int):Void {
		final base = 0x1F801C00 + v * 0x10;
		final start = v % 3 == 0 ? WAVE : (v % 3 == 1 ? ONESHOT : LONG);
		final pitch = v % 4 == 0 ? 0x1000 : (v % 4 == 1 ? 0x0800 : (v % 4 == 2 ? 0x3FFF : 0x0155));
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

	static function reg(addr:Int, value:Int):Void {
		spu.Spu.write16(addr, value);
	}
}
