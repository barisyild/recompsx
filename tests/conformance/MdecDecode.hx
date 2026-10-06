import shim.RawBuf;
import shim.RawMem;

/**
	The MDEC (psx-spx, "Macroblock Decoder (MDEC)"): run-length blocks in, pixels out, at every
	depth, against psx-spx's decoder written out plainly here.

	mdec.Mdec takes the inverse DCT half a row at a time when the scale table has the standard
	one's symmetry (every game's), and decodes only when output is wanted. The reference below is
	psx-spx's rl_decode_block, real_idct_core and yuv_to_rgb as written — the full sum, one pixel
	at a time. Their pixels must be the same: the regrouping is meant to change nothing. The same
	input under a table without the symmetry runs the full sum the device keeps for it.

	A movie frame's data ends padded with FE00h halfwords to whole DMA blocks. Once only padding
	is left the device reads as idle: Tekken 3's player waits on the busy bit after every frame,
	and with the padding counted as input it timed out on each one.
**/
class MdecDecode {
	static inline var CMD = 0x1F801820;
	static inline var STATUS = 0x1F801824;

	/** psx-spx's standard scale table (MDEC(3)), as the halfwords games send. */
	static final SCALE = [
		0x5A82, 0x5A82, 0x5A82, 0x5A82, 0x5A82, 0x5A82, 0x5A82, 0x5A82,
		0x7D8A, 0x6A6D, 0x471C, 0x18F8, 0xE707, 0xB8E3, 0x9592, 0x8275,
		0x7641, 0x30FB, 0xCF04, 0x89BE, 0x89BE, 0xCF04, 0x30FB, 0x7641,
		0x6A6D, 0xE707, 0x8275, 0xB8E3, 0x471C, 0x7D8A, 0x18F8, 0x9592,
		0x5A82, 0xA57D, 0xA57D, 0x5A82, 0x5A82, 0xA57D, 0xA57D, 0x5A82,
		0x471C, 0x8275, 0x18F8, 0x6A6D, 0x9592, 0xE707, 0x7D8A, 0xB8E3,
		0x30FB, 0x89BE, 0x7641, 0xCF04, 0xCF04, 0x7641, 0x89BE, 0x30FB,
		0x18F8, 0xB8E3, 0x6A6D, 0x8275, 0x7D8A, 0x9592, 0x471C, 0xE707];

	/** psx-spx's standard quant table (MDEC(2)), luminance; colour gets it doubled. */
	static final QUANT = [
		0x02, 0x10, 0x10, 0x13, 0x10, 0x13, 0x16, 0x16, 0x16, 0x16, 0x16, 0x16, 0x1A, 0x18, 0x1A, 0x1B,
		0x1B, 0x1B, 0x1A, 0x1A, 0x1A, 0x1A, 0x1B, 0x1B, 0x1B, 0x1D, 0x1D, 0x1D, 0x22, 0x22, 0x22, 0x1D,
		0x1D, 0x1D, 0x1B, 0x1B, 0x1D, 0x1D, 0x20, 0x20, 0x22, 0x22, 0x25, 0x26, 0x25, 0x23, 0x23, 0x22,
		0x23, 0x26, 0x26, 0x28, 0x28, 0x28, 0x30, 0x30, 0x2E, 0x2E, 0x38, 0x38, 0x3A, 0x45, 0x45, 0x53];

	static final ZIGZAG = [0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42, 3, 8, 12, 17, 25,
		30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53, 10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46,
		51, 55, 60, 21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63];

	/** ZIGZAG inverted: the natural position of the k-th coefficient sent (psx-spx's zagzig). */
	static var zagzig:Array<Int>;

	static var seed = 12345;
	static var ram:RawBuf;

	public static function main():Void {
		Conf.feedName("MdecDecode");
		zagzig = [for (k in 0...64) ZIGZAG.indexOf(k)];
		ram = RawMem.alloc(0x10000);
		mdec.Mdec.init();
		mdec.Mdec.write(STATUS, 0x80000000);
		mdec.Mdec.write(STATUS, 0x60000000);
		Conf.expect("idle after a reset", mdec.Mdec.read(STATUS), 0x8004FFFF);
		sendTables(SCALE);

		// Four colour macroblocks of each depth and sign, and eight monochrome ones.
		final stream = makeStream(4, 6);
		decodeAndCheck("24-bit", stream, 4, 2, false, false);
		decodeAndCheck("15-bit", stream, 4, 3, false, true);
		decodeAndCheck("24-bit signed", stream, 4, 2, true, false);
		final mono = makeStream(8, 1);
		decodeAndCheck("8-bit", mono, 8, 1, false, false);
		decodeAndCheck("4-bit", mono, 8, 0, false, false);
		decodeAndCheck("8-bit signed", mono, 8, 1, true, false);

		// Sparse blocks, as a movie's mostly are: the DC alone, then the first few coefficients in
		// zigzag order — the passes' shortcuts (zero columns, the DC-only and low-frequency rows).
		decodeAndCheck("24-bit, DC only", makeSparse(4, 6, 0), 4, 2, false, false);
		decodeAndCheck("24-bit, first 5", makeSparse(4, 6, 5), 4, 2, false, false);
		decodeAndCheck("15-bit, first 20", makeSparse(4, 6, 20), 4, 3, false, true);
		decodeAndCheck("8-bit, first 9", makeSparse(8, 1, 9), 8, 1, false, false);

		// Without the standard table's symmetry: the device's full sum.
		final odd = SCALE.copy();
		odd[9] = 0x6A00;
		odd[50] = 0x8000;
		sendTables(odd);
		decodeAndCheck("24-bit, asymmetric scale", stream, 4, 2, false, false);
		decodeAndCheck("24-bit, asymmetric, first 5", makeSparse(4, 6, 5), 4, 2, false, false);
		sendTables(SCALE);

		// Padding at the end of the data: busy until the last macroblock is out, idle after.
		final padded = stream.copy();
		for (i in 0...10) padded.push(0xFE00);
		if ((padded.length & 1) != 0) padded.push(0xFE00);
		else {}
		command(0x30000000, padded);
		Conf.expect("busy while pixels wait", (mdec.Mdec.read(STATUS) >>> 29) & 1, 1);
		final got = mdec.Mdec.dmaOut(ram, 0, 4 * 192);
		Conf.expect("every pixel out", got, 4 * 192);
		Conf.expect("idle with only padding left", (mdec.Mdec.read(STATUS) >>> 29) & 1, 0);
		Conf.expect("and the output FIFO empty", (mdec.Mdec.read(STATUS) >>> 31) & 1, 1);

		// An incomplete macroblock keeps it busy: the rest of the data is still to come.
		final cut = stream.slice(0, stream.length - 6);
		command(0x30000000, cut);
		mdec.Mdec.dmaOut(ram, 0, 4 * 192);
		Conf.expect("busy on a partial macroblock", (mdec.Mdec.read(STATUS) >>> 29) & 1, 1);
		Conf.report("MdecDecode");
	}

	/** MDEC(2) with both tables (colour = luminance doubled, clamped), then MDEC(3). */
	static function sendTables(scale:Array<Int>):Void {
		mdec.Mdec.write(CMD, 0x40000001);
		for (t in 0...2) {
			for (i in 0...16) {
				var w = 0;
				for (b in 0...4) {
					var q = QUANT[(i << 2) + b];
					if (t == 1) q = q * 2 > 255 ? 255 : q * 2;
					else {}
					w |= q << (b << 3);
				}
				mdec.Mdec.write(CMD, w);
			}
		}
		mdec.Mdec.write(CMD, 0x60000000);
		for (i in 0...32) mdec.Mdec.write(CMD, (scale[i << 1] & 0xFFFF) | (scale[(i << 1) + 1] << 16));
		currentScale = scale;
	}

	static function next(n:Int):Int {
		seed = (shim.IntMath.mul(seed, 1103515245) + 12345) | 0;
		return ((seed >>> 8) & 0x7FFFFF) % n;
	}

	/** Run-length blocks: a DC word with a scale, a few AC words with runs, FE00h at the end. */
	static function makeStream(macroblocks:Int, blocksEach:Int):Array<Int> {
		final out:Array<Int> = [];
		for (m in 0...macroblocks * blocksEach) {
			// Now and then the padding a stream may have before a block.
			if (next(5) == 0) out.push(0xFE00);
			else {}
			// A scale of 0 (now and then) takes every value doubled, in natural order.
			final q = next(8) == 0 ? 0 : 1 + next(40);
			out.push((q << 10) | ((next(1024) - 512) & 0x3FF));
			var k = 0;
			while (true) {
				final run = next(12);
				if (k + run + 1 > 63) break;
				else {}
				k += run + 1;
				out.push((run << 10) | ((next(160) - 80) & 0x3FF));
			}
			out.push(0xFE00);
		}
		if ((out.length & 1) != 0) out.push(0xFE00);
		else {}
		return out;
	}

	/** Blocks whose coefficients stop by zigzag index `maxK`: each AC coefficient one place on. */
	static function makeSparse(macroblocks:Int, blocksEach:Int, maxK:Int):Array<Int> {
		final out:Array<Int> = [];
		for (m in 0...macroblocks * blocksEach) {
			out.push(((1 + next(40)) << 10) | ((next(1024) - 512) & 0x3FF));
			for (k in 1...maxK + 1) out.push((next(100) - 50) & 0x3FF);
			out.push(0xFE00);
		}
		if ((out.length & 1) != 0) out.push(0xFE00);
		else {}
		return out;
	}

	/** MDEC(1) with the halfwords as its parameter words, through the command port. */
	static function command(head:Int, halves:Array<Int>):Void {
		final words = halves.length >> 1;
		mdec.Mdec.write(CMD, head | words);
		for (i in 0...words) mdec.Mdec.write(CMD, halves[i << 1] | (halves[(i << 1) + 1] << 16));
	}

	static function decodeAndCheck(label:String, stream:Array<Int>, macroblocks:Int, depth:Int,
			signed:Bool, bit15:Bool):Void {
		final head = 0x20000000 | (depth << 27) | (signed ? 0x04000000 : 0) | (bit15 ? 0x02000000 : 0);
		command(head, stream);
		final per = depth == 2 ? 192 : (depth == 3 ? 128 : (depth == 1 ? 16 : 8));
		final total = per * macroblocks;
		// Out in two pieces, the second asking for more than there is.
		final first = mdec.Mdec.dmaOut(ram, 0, per + 5);
		final rest = mdec.Mdec.dmaOut(ram, (per + 5) << 2, total);
		Conf.expect(label + ": words out", first + rest, total);
		final want = reference(stream, macroblocks, depth, signed, bit15);
		var mismatches = 0;
		for (i in 0...total) {
			final w = RawMem.get32(ram, i << 2);
			Conf.feed(w);
			if (w != want[i]) mismatches++;
			else {}
		}
		Conf.expect(label + ": words unlike psx-spx's decoder", mismatches, 0);
	}

	// ---- psx-spx's decoder, as written ---------------------------------------------------------

	static var refScale:Array<Int> = [];

	static function reference(stream:Array<Int>, macroblocks:Int, depth:Int, signed:Bool,
			bit15:Bool):Array<Int> {
		// The scale table the device holds now: the last one sent.
		refScale = currentScale;
		final out:Array<Int> = [];
		var at = 0;
		for (m in 0...macroblocks) {
			if (depth >= 2) {
				final cr = [for (_ in 0...64) 0], cb = [for (_ in 0...64) 0], y = [for (_ in 0...64) 0];
				final px = [for (_ in 0...256 * 3) 0];
				at = block(stream, at, cr, true);
				at = block(stream, at, cb, true);
				for (b in 0...4) {
					at = block(stream, at, y, false);
					final xx = (b & 1) << 3, yy = (b >> 1) << 3;
					for (j in 0...8) {
						for (i in 0...8) {
							final c = ((i + xx) >> 1) + (((j + yy) >> 1) << 3);
							final yv = y[i + (j << 3)];
							final r = clip(yv + ((5743 * cr[c] + 2048) >> 12));
							final g = clip(yv + ((-1408 * cb[c] - 2926 * cr[c] + 2048) >> 12));
							final bl = clip(yv + ((7258 * cb[c] + 2048) >> 12));
							final p = ((i + xx) + ((j + yy) << 4)) * 3;
							px[p] = (r ^ (signed ? 0 : 0x80)) & 0xFF;
							px[p + 1] = (g ^ (signed ? 0 : 0x80)) & 0xFF;
							px[p + 2] = (bl ^ (signed ? 0 : 0x80)) & 0xFF;
						}
					}
				}
				if (depth == 2) {
					for (w in 0...192) {
						out.push(px[w * 4] | (px[w * 4 + 1] << 8) | (px[w * 4 + 2] << 16) | (px[w * 4 + 3] << 24));
					}
				} else {
					for (w in 0...128) {
						var word = 0;
						for (h in 0...2) {
							final p = ((w << 1) + h) * 3;
							final v = (px[p] >> 3) | ((px[p + 1] >> 3) << 5) | ((px[p + 2] >> 3) << 10)
								| (bit15 ? 0x8000 : 0);
							word |= v << (h << 4);
						}
						out.push(word);
					}
				}
			} else {
				final y = [for (_ in 0...64) 0];
				at = block(stream, at, y, false);
				final v = [for (i in 0...64) (clip(y[i]) ^ (signed ? 0 : 0x80)) & 0xFF];
				if (depth == 1) {
					for (w in 0...16) out.push(v[w * 4] | (v[w * 4 + 1] << 8) | (v[w * 4 + 2] << 16) | (v[w * 4 + 3] << 24));
				} else {
					for (w in 0...8) {
						var word = 0;
						for (n in 0...8) word |= (v[w * 8 + n] >> 4) << (n << 2);
						out.push(word);
					}
				}
			}
		}
		return out;
	}

	static var currentScale:Array<Int> = SCALE;

	/** rl_decode_block, then real_idct_core: two passes of the full sum. */
	static function block(src:Array<Int>, at:Int, blk:Array<Int>, colour:Bool):Int {
		for (i in 0...64) blk[i] = 0;
		var p = at;
		while (src[p] == 0xFE00) p++;
		var n = src[p];
		p++;
		var k = 0;
		final q = (n >>> 10) & 63;
		final qt0 = colour ? uv(0) : QUANT[0];
		var v = s10(n) * qt0;
		while (true) {
			if (q == 0) v = s10(n) * 2;
			else {}
			v = v < -0x400 ? -0x400 : (v > 0x3FF ? 0x3FF : v);
			if (q > 0) blk[zagzig[k]] = v;
			else blk[k] = v;
			n = src[p];
			p++;
			k += ((n >>> 10) & 63) + 1;
			if (k > 63) break;
			else {}
			v = (s10(n) * (colour ? uv(k) : QUANT[k]) * q + 4) >> 3;
		}
		final tmp = [for (_ in 0...64) 0];
		idctPass(blk, tmp);
		idctPass(tmp, blk);
		return p;
	}

	static function idctPass(src:Array<Int>, dst:Array<Int>):Void {
		for (x in 0...8) {
			for (y in 0...8) {
				var sum = 0;
				for (z in 0...8) sum += src[y + z * 8] * (s16(refScale[x + z * 8]) >> 3);
				dst[x + y * 8] = (sum + 0xFFF) >> 13;
			}
		}
	}

	static function uv(i:Int):Int return QUANT[i] * 2 > 255 ? 255 : QUANT[i] * 2;

	static inline function s10(n:Int):Int return ((n & 0x3FF) << 22) >> 22;

	static inline function s16(n:Int):Int return ((n & 0xFFFF) << 16) >> 16;

	static function clip(v:Int):Int {
		final w = ((v & 0x1FF) << 23) >> 23;
		return w < -128 ? -128 : (w > 127 ? 127 : w);
	}
}
