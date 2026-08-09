import shim.RawMem;

/**
	Cross-target conformance for the sound processor's one job: turning a voice into samples.

	The emulated machine has no way to check its own audio. A game writes waveforms and volumes and
	then hears something or does not, and by the time anyone notices, the cause could be a decoder,
	an envelope, a volume, or a register that never arrived. So the path is exercised here directly,
	from bytes in sound RAM to stereo pairs out, with everything the runtime would set written by
	hand — which also means the test says which of those four it is.

	It is a conformance test rather than a unit test because the arithmetic is the kind that goes
	wrong differently on different targets: a 4-bit sign extension, a shift that must be
	arithmetic, an accumulator that must saturate rather than wrap, and a multiply whose product
	leaves 31 bits. Two targets agreeing on the digest is worth more than any single assertion
	about a sample value, and the assertions here exist to name what broke rather than to prove it.
**/
class SpuVoice {
	static inline var DUMMY = 0x1000;
	static inline var WAVE = 0x2000;

	public static function main():Void {
		Conf.feedName("spuvoice");
		spu.Spu.init();

		// ---- a waveform, written the way a game writes one -----------------------------------
		//
		// Two blocks: one that rises through its 28 samples, one that falls, and the second marked
		// as the end of a loop back to the first. That shape exercises the ADPCM predictor in both
		// directions and makes looping observable — a decoder that ignores the loop flag runs off
		// into whatever follows and the digest changes.
		writeBlock(WAVE, 8, 0, 0x04, true);            // loop start, rising
		writeBlock(WAVE + 16, 8, 0, 0x03, false);      // loop end + repeat, falling

		// The silent block libspu keeps at 0x1000 and points idle voices at: a loop whose every
		// nibble is zero, so the predictor has nothing to predict and the voice plays nothing.
		silentBlock(DUMMY);

		// ---- one voice, set up as libspu would -------------------------------------------------
		reg(0x1F801C00, 0x3FFF);            // volume left, the maximum a non-sweep can hold
		reg(0x1F801C02, 0x3FFF);            // volume right
		reg(0x1F801C04, 0x1000);            // pitch: the recorded rate
		reg(0x1F801C06, WAVE >> 3);         // start address
		// Attack immediate, no decay to speak of, sustain at the top, release immediate. Shift is
		// a rate: zero is the fastest each phase can be, which is what a test wants — the slow
		// settings are correct too and would only make this take four seconds to prove.
		reg(0x1F801C08, 0x000F);            // attack shift 0 step 7, decay shift 0, sustain 15
		reg(0x1F801C0A, 0x00C0);            // sustain rising, release shift 0

		reg(0x1F801D80, 0x3FFF);            // main volume left
		reg(0x1F801D82, 0x3FFF);            // main volume right
		reg(0x1F801DAA, 0xC000);            // SPUCNT: enabled and unmuted

		Conf.expect("sound RAM took the waveform", RawMem.get8(spu.Spu.ram, WAVE + 2) != 0 ? 1 : 0, 1);

		// ---- key on, and listen -------------------------------------------------------------
		reg(0x1F801D88, 0x0001);
		Conf.feed(spu.Spu.keyedOn);

		// Two thousand samples is forty-five milliseconds: long enough for the envelope to climb,
		// the first block to run out, and the loop to be taken.
		final peak = run(2000);
		Conf.expect("a keyed-on voice is not silent", peak > 0 ? 1 : 0, 1);
		Conf.expect("the envelope reached the top", spu.Spu.peakEnv, 0x7FFF);
		Conf.feed(peak);
		Conf.feed(spu.Spu.samplesOut);

		// ---- key off, and stop listening -----------------------------------------------------
		//
		// A voice that will not stop is worse than one that will not start: it is the failure that
		// survives into a game as a stuck note.
		reg(0x1F801D8C, 0x0001);
		run(4000);
		Conf.expect("release silences the voice", tailPeak(2000), 0);

		// ---- a voice pointed at silence stays silent -------------------------------------------
		reg(0x1F801C06, DUMMY >> 3);
		reg(0x1F801D88, 0x0001);
		Conf.expect("the dummy block makes no sound", tailPeak(1000), 0);

		Conf.report("spuvoice");
	}

	/**
		Writes one sixteen-byte ADPCM block by hand.

		`slope` is added to each nibble's value so the block ramps; the point is not to produce a
		pleasant sound but a deterministic one whose samples depend on the predictor, the shift and
		the sign extension all being right.
	**/
	static function writeBlock(at:Int, shift:Int, filter:Int, flags:Int, rising:Bool):Void {
		RawMem.set8(spu.Spu.ram, at, (filter << 4) | shift);
		RawMem.set8(spu.Spu.ram, at + 1, flags);
		var i = 0;
		while (i < 14) {
			// Two nibbles a byte, walking up and down the full four-bit range including negatives.
			final a = rising ? (i & 7) : (7 - (i & 7));
			final b = rising ? ((i + 4) & 15) : (15 - ((i + 4) & 15));
			RawMem.set8(spu.Spu.ram, at + 2 + i, (b << 4) | (a & 0x0F));
			i++;
		}
	}

	/** A block that decodes to nothing: zero differences, looping onto itself forever. */
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

	/** Runs the mixer for n samples and feeds every one into the digest. Returns the peak. */
	static function run(n:Int):Int {
		var peak = 0;
		var i = 0;
		while (i < n) {
			final pair = spu.Spu.mixForTest();
			Conf.feed(pair);
			final l = (pair << 16) >> 16;
			final r = pair >> 16;
			if (abs(l) > peak) peak = abs(l);
			else {}
			if (abs(r) > peak) peak = abs(r);
			else {}
			i++;
		}
		return peak;
	}

	/** The loudest sample in the next n, without feeding them — for asserting silence. */
	static function tailPeak(n:Int):Int {
		var peak = 0;
		var i = 0;
		while (i < n) {
			final pair = spu.Spu.mixForTest();
			final l = (pair << 16) >> 16;
			final r = pair >> 16;
			if (abs(l) > peak) peak = abs(l);
			else {}
			if (abs(r) > peak) peak = abs(r);
			else {}
			i++;
		}
		return peak;
	}

	static inline function abs(v:Int):Int return v < 0 ? -v : v;
}
