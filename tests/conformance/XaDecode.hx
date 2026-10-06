import shim.RawBuf;
import shim.RawMem;

/**
	CD-ROM XA ADPCM (psx-spx, "CDROM XA Audio ADPCM Compression"): synthetic sectors of every
	format — 4-bit stereo and mono at 37800 Hz, 4-bit stereo at 18900 Hz, 8-bit stereo — through
	cd.XaAdpcm, against psx-spx's decode_sector and its 25-point zigzag interpolation written out
	plainly here, pair for pair. Then the FIFO: silent until two sectors' worth is in, taken in
	order, and primed again after running dry.
**/
class XaDecode {
	static var seed = 7;
	static var buf:RawBuf;

	// The reference's state.
	static var oldL = 0;
	static var olderL = 0;
	static var oldR = 0;
	static var olderR = 0;
	static var ring:Array<Int>;
	static var ringR:Array<Int>;
	static var p = 0;
	static var six = 6;
	static var table:Array<Int>;
	static var out:Array<Int>;

	public static function main():Void {
		Conf.feedName("XaDecode");
		buf = RawMem.alloc(0x924);
		cd.XaAdpcm.init();
		table = makeTable();
		ring = [for (_ in 0...32) 0];
		ringR = [for (_ in 0...32) 0];
		out = [];

		// 4-bit stereo 37800 Hz: three sectors, the first two filling the FIFO's prime.
		check("4-bit stereo", 0x01, 3);
		check("4-bit mono", 0x00, 3);
		check("4-bit stereo 18900", 0x05, 2);
		// 8-bit stereo is 1,176 pairs a sector: five to pass the prime.
		check("8-bit stereo", 0x11, 5);

		// Priming: after a flush nothing comes out until two sectors' worth is in.
		cd.XaAdpcm.flush();
		cd.XaAdpcm.reset();
		fill(0x01);
		cd.XaAdpcm.decodeSector(buf);
		Conf.expect("one sector in: still silent", cd.XaAdpcm.pull(), 0);
		cd.XaAdpcm.decodeSector(buf);
		var nonZero = 0;
		for (i in 0...4704) if (cd.XaAdpcm.pull() != 0) nonZero++;
		else {}
		Conf.expect("two sectors in: they play", nonZero > 4000 ? 1 : 0, 1);
		Conf.expect("then empty", cd.XaAdpcm.playing() ? 1 : 0, 0);
		Conf.report("XaDecode");
	}

	/** `sectors` sectors of coding byte `coding` through the decoder and the reference, compared. */
	static function check(label:String, coding:Int, sectors:Int):Void {
		cd.XaAdpcm.flush();
		cd.XaAdpcm.reset();
		resetReference();
		for (s in 0...sectors) {
			fill(coding);
			cd.XaAdpcm.decodeSector(buf);
			reference(coding);
		}
		var mismatches = 0;
		var count = 0;
		while (cd.XaAdpcm.playing() && count < out.length + 16) {
			final got = cd.XaAdpcm.pull();
			// The first pulls of a primed FIFO are real samples; compare from the start.
			if (count < out.length) {
				if (got != out[count]) mismatches++;
				else {}
				Conf.feed(got);
			} else {}
			count++;
		}
		Conf.expect(label + ": pairs", count, out.length);
		Conf.expect(label + ": pairs unlike psx-spx's", mismatches, 0);
	}

	static function next(n:Int):Int {
		seed = (shim.IntMath.mul(seed, 1103515245) + 12345) | 0;
		return ((seed >>> 8) & 0x7FFFFF) % n;
	}

	/** A sector: header, the subheader (twice) with `coding`, 18 portions of random headers and data. */
	static function fill(coding:Int):Void {
		for (i in 0...0x924) RawMem.set8(buf, i, 0);
		RawMem.set8(buf, 4, 1);
		RawMem.set8(buf, 5, 0);
		RawMem.set8(buf, 6, 0x64);
		RawMem.set8(buf, 7, coding);
		for (portion in 0...18) {
			final at = 12 + portion * 128;
			for (h in 0...8) {
				// Shifts 0..15 (13-15 reserved, acting as 9) and filters 0..3.
				final v = next(16) | (next(4) << 4);
				RawMem.set8(buf, at + 4 + h, v);
			}
			for (k in 0...4) RawMem.set8(buf, at + k, RawMem.get8(buf, at + 4 + k));
			for (k in 0...4) RawMem.set8(buf, at + 12 + k, RawMem.get8(buf, at + 8 + k));
			for (d in 0...112) RawMem.set8(buf, at + 16 + d, next(256));
		}
	}

	static function resetReference():Void {
		oldL = 0; olderL = 0; oldR = 0; olderR = 0;
		for (i in 0...32) { ring[i] = 0; ringR[i] = 0; }
		p = 0;
		six = 6;
		out = [];
	}

	// ---- psx-spx's decoder, as written -----------------------------------------------------------

	static function reference(coding:Int):Void {
		final stereo = (coding & 3) == 1;
		final half = ((coding >> 2) & 3) == 1;
		final eight = ((coding >> 4) & 3) == 1;
		for (portion in 0...18) {
			final src = 12 + portion * 128;
			if (eight) {
				// Four blocks a data word, a byte each; stereo pairs them left and right.
				var blk = 0;
				while (blk < 4) {
					final l = decode28(src, blk, 0, true, true);
					if (stereo) {
						final r = decode28(src, blk + 1, 0, true, false);
						for (j in 0...28) output(l[j], r[j], half);
						blk += 2;
					} else {
						for (j in 0...28) output(l[j], l[j], half);
						blk++;
					}
				}
			} else {
				for (blk in 0...4) {
					if (stereo) {
						final l = decode28(src, blk, 0, false, true);
						final r = decode28(src, blk, 1, false, false);
						for (j in 0...28) output(l[j], r[j], half);
					} else {
						final a = decode28(src, blk, 0, false, true);
						for (j in 0...28) output(a[j], a[j], half);
						final b = decode28(src, blk, 1, false, true);
						for (j in 0...28) output(b[j], b[j], half);
					}
				}
			}
		}
	}

	/** decode_28_nibbles (or its 8-bit form): block `blk`, nibble `nib`, into 28 samples. */
	static function decode28(src:Int, blk:Int, nib:Int, eight:Bool, left:Bool):Array<Int> {
		final hdr = eight ? RawMem.get8(buf, src + 4 + blk) : RawMem.get8(buf, src + 4 + blk * 2 + nib);
		var shift = hdr & 0x0F;
		if (shift > 12) shift = 9;
		else {}
		final filter = (hdr >> 4) & 3;
		final f0 = [0, 60, 115, 98][filter];
		final f1 = [0, 0, -52, -55][filter];
		var old = left ? oldL : oldR;
		var older = left ? olderL : olderR;
		final res:Array<Int> = [];
		for (j in 0...28) {
			var t = 0;
			if (eight) {
				t = RawMem.get8(buf, src + 16 + blk + j * 4);
				if (t >= 128) t -= 256;
				else {}
				t = t * 256;
			} else {
				t = (RawMem.get8(buf, src + 16 + blk + j * 4) >> (nib * 4)) & 15;
				if (t >= 8) t -= 16;
				else {}
				t = t * 4096;
			}
			var s = (t >> shift) + ((old * f0 + older * f1 + 32) >> 6);
			if (s < -32768) s = -32768;
			else {}
			if (s > 32767) s = 32767;
			else {}
			res.push(s);
			older = old;
			old = s;
		}
		if (left) { oldL = old; olderL = older; }
		else { oldR = old; olderR = older; }
		return res;
	}

	static function output(l:Int, r:Int, half:Bool):Void {
		output37800(l, r);
		if (half) output37800(l, r);
		else {}
	}

	/** Output37800Hz and ZigZagInterpolate, psx-spx's pseudo-code. */
	static function output37800(l:Int, r:Int):Void {
		ring[p & 31] = l;
		ringR[p & 31] = r;
		p++;
		six--;
		if (six == 0) {
			six = 6;
			for (t in 0...7) {
				var sl = 0;
				var sr = 0;
				for (i in 1...30) {
					sl += (ring[(p - i) & 31] * table[t * 29 + i - 1]) >> 15;
					sr += (ringR[(p - i) & 31] * table[t * 29 + i - 1]) >> 15;
				}
				if (sl < -32768) sl = -32768;
				else {}
				if (sl > 32767) sl = 32767;
				else {}
				if (sr < -32768) sr = -32768;
				else {}
				if (sr > 32767) sr = 32767;
				else {}
				out.push((sl & 0xFFFF) | (sr << 16));
			}
		} else {}
	}

	/** psx-spx's table, as printed there: one row per index 1..29, a column per Table1..Table7. */
	static function makeTable():Array<Int> {
		final rows = [
			[0, 0, 0, 0, -0x0001, 0x0002, -0x0005],
			[0, 0, 0, -0x0001, 0x0003, -0x0008, 0x0011],
			[0, 0, -0x0001, 0x0003, -0x0008, 0x0010, -0x0023],
			[0, -0x0002, 0x0003, -0x0008, 0x0011, -0x0023, 0x0046],
			[0, 0, -0x0002, 0x0006, -0x0010, 0x002B, -0x0017],
			[-0x0002, 0x0003, -0x0005, 0x0005, 0x000A, 0x001A, -0x0044],
			[0x000A, -0x0013, 0x001F, -0x001B, 0x006B, -0x00EB, 0x015B],
			[-0x0022, 0x003C, -0x004A, 0x00A6, -0x016D, 0x027B, -0x0347],
			[0x0041, -0x004B, 0x00B3, -0x01A8, 0x0350, -0x0548, 0x080E],
			[-0x0054, 0x00A2, -0x0192, 0x0372, -0x0623, 0x0AFA, -0x1249],
			[0x0034, -0x00E3, 0x02B1, -0x05BF, 0x0BCD, -0x16FA, 0x3C07],
			[0x0009, 0x0132, -0x039E, 0x09B8, -0x1780, 0x53E0, 0x53E0],
			[-0x010A, -0x0043, 0x04F8, -0x11B4, 0x6794, 0x3C07, -0x16FA],
			[0x0400, -0x0267, -0x05A6, 0x74BB, 0x234C, -0x1249, 0x0AFA],
			[-0x0A78, 0x0C9D, 0x7939, 0x0C9D, -0x0A78, 0x080E, -0x0548],
			[0x234C, 0x74BB, -0x05A6, -0x0267, 0x0400, -0x0347, 0x027B],
			[0x6794, -0x11B4, 0x04F8, -0x0043, -0x010A, 0x015B, -0x00EB],
			[-0x1780, 0x09B8, -0x039E, 0x0132, 0x0009, -0x0044, 0x001A],
			[0x0BCD, -0x05BF, 0x02B1, -0x00E3, 0x0034, -0x0017, 0x002B],
			[-0x0623, 0x0372, -0x0192, 0x00A2, -0x0054, 0x0046, -0x0023],
			[0x0350, -0x01A8, 0x00B3, -0x004B, 0x0041, -0x0023, 0x0010],
			[-0x016D, 0x00A6, -0x004A, 0x003C, -0x0022, 0x0011, -0x0008],
			[0x006B, -0x001B, 0x001F, -0x0013, 0x000A, -0x0005, 0x0002],
			[0x000A, 0x0005, -0x0005, 0x0003, -0x0001, 0, 0],
			[-0x0010, 0x0006, -0x0002, 0, 0, 0, 0],
			[0x0011, -0x0008, 0x0003, -0x0002, 0x0001, 0, 0],
			[-0x0008, 0x0003, -0x0001, 0, 0, 0, 0],
			[0x0003, -0x0001, 0, 0, 0, 0, 0],
			[-0x0001, 0, 0, 0, 0, 0, 0]];
		final t:Array<Int> = [for (_ in 0...7 * 29) 0];
		for (i in 0...29) for (k in 0...7) t[k * 29 + i] = rows[i][k];
		return t;
	}
}
