package cd;

import shim.MemA;
import shim.RawBuf;
import shim.RawMem;

/**
	CD-ROM XA ADPCM: the compressed audio a game streams off the disc — Tekken 3's music, every
	movie's soundtrack — which the drive decodes itself and sends to the SPU's CD audio input
	(psx-spx, "CDROM XA Audio ADPCM Compression"). The CPU never sees these sectors: under Setmode
	bit 6 the drive takes each audio sector it reads, passes the ones Setfilter selects (under bit 3)
	to the decoder and delivers only the rest (`Cdrom.deliverSector`).

	A sector is 18 portions of 128 bytes: 16 header bytes (one per block, each a shift and a filter)
	and 28 data words, each holding the next sample of every block — eight 4-bit nibbles or four
	8-bit bytes. Stereo pairs the blocks left and right; mono takes them one after another. Each
	sample is `(t << 12 or 8) >> shift` plus the filter's prediction from the two before,
	`(old * f0 + older * f1 + 32) >> 6`, clamped to 16 bits.

	The drive plays at 44100 Hz, the SPU's rate. 37800 Hz becomes 44100 by psx-spx's 25-point
	zigzag interpolation: every sixth input sample, seven output samples, each a sum of the last 29
	inputs weighted by one of seven tables. 18900 Hz is fed in doubled, each sample twice. psx-spx
	says the formula gives "nearly correct results, but with small rounding errors in some cases":
	the hardware's exact rounding is not known, and this is psx-spx's, term by term.

	**The output is a FIFO the SPU takes one pair from per sample** (`pull`), at the SPU's own
	44100 Hz in emulated time. A sector at 37800 Hz is 2,352 output pairs, and a stream reads one
	sector in eight at double speed — exactly the 44,100 a second the SPU takes, so the FIFO's level
	would touch empty at every sector. It is primed instead: after starting or running dry, nothing
	is taken until two sectors' worth is in, and it then runs a sector ahead of the SPU.

	The FIFO is sound, not state: nothing a game can read depends on it (the SPU's capture buffers,
	which would take the CD's samples into sound RAM, are not modelled), so the digest of a game
	does not change with it. Under a backend that has no audio, it simply fills and drops.
**/
class XaAdpcm {
	/** Stereo pairs the FIFO holds, a power of two: seven sectors at 37800 Hz. */
	static inline var FIFO_PAIRS = 16384;
	/** Pairs to hold before the SPU starts taking them: two sectors at 37800 Hz. */
	static inline var PRIME_PAIRS = 4704;

	static var fifo:RawBuf;
	static var fifoRead = 0;
	static var fifoCount = 0;
	static var primed = false;

	/** The decoder's two previous samples, per channel (mono uses the left). */
	static var oldL = 0;
	static var olderL = 0;
	static var oldR = 0;
	static var olderR = 0;

	/**
		The decoder's words in one buffer at fixed offsets (a word of a buffer is one load on every
		target, as in mdec.Mdec): psx-spx's Table1..Table7, index 1..29 of each at
		table * 29 + index - 1; the interpolation's last 32 inputs per channel; one block's 28
		decoded samples, left and right; the filters' two coefficients.
	**/
	static var tab:RawBuf;
	static inline var ZIG = 0;
	static inline var RING_L = 812;
	static inline var RING_R = 940;
	static inline var BLOCK_L = 1068;
	static inline var BLOCK_R = 1180;
	static inline var POS = 1292;
	static inline var NEG = 1308;
	static inline var TAB_BYTES = 1324;

	/** Where the next input goes in the rings, and the count to six. */
	static var ringPos = 0;
	static var sixStep = 6;

	/** Sectors decoded (diagnostics). */
	public static var sectors(default, null) = 0;

	public static function init():Void {
		fifo = RawMem.alloc(FIFO_PAIRS * 4);
		tab = RawMem.alloc(TAB_BYTES);
		for (i in 0...TAB_BYTES >> 2) MemA.set32(tab, i << 2, 0);
		final pos = [0, 60, 115, 98];
		final neg = [0, 0, -52, -55];
		for (i in 0...4) {
			MemA.set32(tab, POS + (i << 2), pos[i]);
			MemA.set32(tab, NEG + (i << 2), neg[i]);
		}
		final zigzag = [
			// Table1
			0, 0, 0, 0, 0, -0x0002, 0x000A, -0x0022, 0x0041, -0x0054, 0x0034, 0x0009, -0x010A, 0x0400,
			-0x0A78, 0x234C, 0x6794, -0x1780, 0x0BCD, -0x0623, 0x0350, -0x016D, 0x006B, 0x000A, -0x0010,
			0x0011, -0x0008, 0x0003, -0x0001,
			// Table2
			0, 0, 0, -0x0002, 0, 0x0003, -0x0013, 0x003C, -0x004B, 0x00A2, -0x00E3, 0x0132, -0x0043,
			-0x0267, 0x0C9D, 0x74BB, -0x11B4, 0x09B8, -0x05BF, 0x0372, -0x01A8, 0x00A6, -0x001B, 0x0005,
			0x0006, -0x0008, 0x0003, -0x0001, 0,
			// Table3
			0, 0, -0x0001, 0x0003, -0x0002, -0x0005, 0x001F, -0x004A, 0x00B3, -0x0192, 0x02B1, -0x039E,
			0x04F8, -0x05A6, 0x7939, -0x05A6, 0x04F8, -0x039E, 0x02B1, -0x0192, 0x00B3, -0x004A, 0x001F,
			-0x0005, -0x0002, 0x0003, -0x0001, 0, 0,
			// Table4
			0, -0x0001, 0x0003, -0x0008, 0x0006, 0x0005, -0x001B, 0x00A6, -0x01A8, 0x0372, -0x05BF,
			0x09B8, -0x11B4, 0x74BB, 0x0C9D, -0x0267, -0x0043, 0x0132, -0x00E3, 0x00A2, -0x004B, 0x003C,
			-0x0013, 0x0003, 0, -0x0002, 0, 0, 0,
			// Table5
			-0x0001, 0x0003, -0x0008, 0x0011, -0x0010, 0x000A, 0x006B, -0x016D, 0x0350, -0x0623, 0x0BCD,
			-0x1780, 0x6794, 0x234C, -0x0A78, 0x0400, -0x010A, 0x0009, 0x0034, -0x0054, 0x0041, -0x0022,
			0x000A, -0x0001, 0, 0x0001, 0, 0, 0,
			// Table6
			0x0002, -0x0008, 0x0010, -0x0023, 0x002B, 0x001A, -0x00EB, 0x027B, -0x0548, 0x0AFA, -0x16FA,
			0x53E0, 0x3C07, -0x1249, 0x080E, -0x0347, 0x015B, -0x0044, -0x0017, 0x0046, -0x0023, 0x0011,
			-0x0005, 0, 0, 0, 0, 0, 0,
			// Table7
			-0x0005, 0x0011, -0x0023, 0x0046, -0x0017, -0x0044, 0x015B, -0x0347, 0x080E, -0x1249, 0x3C07,
			0x53E0, -0x16FA, 0x0AFA, -0x0548, 0x027B, -0x00EB, 0x001A, 0x002B, -0x0023, 0x0010, -0x0008,
			0x0002, 0, 0, 0, 0, 0, 0];
		for (i in 0...7 * 29) MemA.set32(tab, ZIG + (i << 2), zigzag[i]);
		sectors = 0;
		reset();
		flush();
	}

	/** A new stream: the decoder's history and the interpolation's start over. */
	public static function reset():Void {
		oldL = 0;
		olderL = 0;
		oldR = 0;
		olderR = 0;
		for (i in 0...32) {
			MemA.set32(tab, RING_L + (i << 2), 0);
			MemA.set32(tab, RING_R + (i << 2), 0);
		}
		ringPos = 0;
		sixStep = 6;
	}

	/** Playback stopped: what was decoded and not yet played is gone. */
	public static function flush():Void {
		fifoRead = 0;
		fifoCount = 0;
		primed = false;
	}

	/** Whether there is sound to take: the SPU mixes the CD input only while this holds. */
	public static inline function playing():Bool return fifoCount > 0;

	/**
		The next stereo pair at 44100 Hz, left in the low halfword, or silence while the FIFO is
		priming. Called once per SPU sample while `playing`.
	**/
	public static function pull():Int {
		if (!primed) {
			if (fifoCount < PRIME_PAIRS) return 0;
			else primed = true;
		} else {}
		if (fifoCount == 0) {
			primed = false;
			return 0;
		} else {}
		final p = RawMem.get32(fifo, fifoRead << 2);
		fifoRead = (fifoRead + 1) & (FIFO_PAIRS - 1);
		fifoCount--;
		return p;
	}

	/**
		One audio sector, as `Iso9660.wholeSector` reads it: the header at 0, the subheader at 4
		(its coding byte at 7), the 18 portions from 12.
	**/
	public static function decodeSector(buf:RawBuf):Void {
		final coding = RawMem.get8(buf, 7);
		final stereo = (coding & 3) == 1;
		final halfRate = ((coding >> 2) & 3) == 1;
		final eightBit = ((coding >> 4) & 3) == 1;
		// Blocks a portion holds: eight of 4-bit samples (two a data byte), four of 8-bit.
		final blocks = eightBit ? 4 : 8;
		for (portion in 0...18) {
			final at = 12 + (portion << 7);
			var b = 0;
			while (b < blocks) {
				if (stereo) {
					decodeBlock(buf, at, b, eightBit, true);
					decodeBlock(buf, at, b + 1, eightBit, false);
					for (j in 0...28) {
						emit(MemA.get32(tab, BLOCK_L + (j << 2)), MemA.get32(tab, BLOCK_R + (j << 2)), halfRate);
					}
					b += 2;
				} else {
					decodeBlock(buf, at, b, eightBit, true);
					for (j in 0...28) {
						final m = MemA.get32(tab, BLOCK_L + (j << 2));
						emit(m, m, halfRate);
					}
					b++;
				}
			}
		}
		sectors++;
	}

	/**
		Block `b` of a portion into `blockL` (`left`) or `blockR`, through that channel's history.
		A 4-bit block b is the low or high nibble (b & 1) of data byte b >> 1; an 8-bit one is
		data byte b. Its header is byte 4 + b either way.
	**/
	static function decodeBlock(buf:RawBuf, at:Int, b:Int, eightBit:Bool, left:Bool):Void {
		final hdr = RawMem.get8(buf, at + 4 + b);
		var range = hdr & 0x0F;
		if (range > 12) range = 9;
		else {}
		final filter = (hdr >> 4) & 3;
		final f0 = MemA.get32(tab, POS + (filter << 2));
		final f1 = MemA.get32(tab, NEG + (filter << 2));
		var old = left ? oldL : oldR;
		var older = left ? olderL : olderR;
		final out = left ? BLOCK_L : BLOCK_R;
		for (j in 0...28) {
			var t = 0;
			if (eightBit) {
				t = (RawMem.get8(buf, at + 16 + b + (j << 2)) << 24) >> 16;
			} else {
				// `>>`, not `>>>`: on C++ the latter's result is unsigned, and the shifts after it
				// then lose the sign the nibble is moved into.
				final byte = RawMem.get8(buf, at + 16 + (b >> 1) + (j << 2));
				t = (((byte >> ((b & 1) << 2)) & 0x0F) << 28) >> 16;
			}
			var s = (t >> range) + ((old * f0 + older * f1 + 32) >> 6);
			s = s < -0x8000 ? -0x8000 : (s > 0x7FFF ? 0x7FFF : s);
			MemA.set32(tab, out + (j << 2), s);
			older = old;
			old = s;
		}
		if (left) {
			oldL = old;
			olderL = older;
		} else {
			oldR = old;
			olderR = older;
		}
	}

	/** One decoded pair at 37800 Hz (twice at 18900) into the interpolation. */
	static inline function emit(l:Int, r:Int, halfRate:Bool):Void {
		push(l, r);
		if (halfRate) push(l, r);
		else {}
	}

	/** psx-spx's Output37800Hz: into the ring, and every sixth sample seven at 44100 Hz out. */
	static function push(l:Int, r:Int):Void {
		final t = tab;
		MemA.set32(t, RING_L + ((ringPos & 31) << 2), l);
		MemA.set32(t, RING_R + ((ringPos & 31) << 2), r);
		ringPos = (ringPos + 1) & 0x7FFFFFFF;
		sixStep--;
		if (sixStep == 0) {
			sixStep = 6;
			for (n in 0...7) {
				var sl = 0;
				var sr = 0;
				final row = ZIG + n * 116;
				for (i in 1...30) {
					final k = ((ringPos - i) & 31) << 2;
					final c = MemA.get32(t, row + ((i - 1) << 2));
					// Products stay under 2^30 (16-bit samples, coefficients under 8000h).
					sl += (MemA.get32(t, RING_L + k) * c) >> 15;
					sr += (MemA.get32(t, RING_R + k) * c) >> 15;
				}
				sl = sl < -0x8000 ? -0x8000 : (sl > 0x7FFF ? 0x7FFF : sl);
				sr = sr < -0x8000 ? -0x8000 : (sr > 0x7FFF ? 0x7FFF : sr);
				store((sl & 0xFFFF) | (sr << 16));
			}
		} else {}
	}

	/** A pair into the FIFO; dropped when it is full (no one is taking them). */
	static function store(p:Int):Void {
		if (fifoCount >= FIFO_PAIRS) return;
		else {}
		RawMem.set32(fifo, ((fifoRead + fifoCount) & (FIFO_PAIRS - 1)) << 2, p);
		fifoCount++;
	}
}
