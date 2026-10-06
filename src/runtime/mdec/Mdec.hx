package mdec;

import shim.MemA;
import shim.RawBuf;
import shim.RawMem;

/**
	The Macroblock Decoder: JPEG-style blocks — run-length coded DCT coefficients — decoded into
	pixels (psx-spx, "Macroblock Decoder (MDEC)"). A game's movie player decodes each frame's
	bitstream into this run-length form on the CPU, sends it in through DMA0, takes the pixels out
	through DMA1 and uploads them to VRAM; some games decode their still pictures the same way.

	Registers: 1F801820h is the command and parameter port (and, read, the data port), 1F801824h
	the status (read) and the control and reset register (write). Commands:
	- MDEC(1) decodes macroblocks: its low 16 bits are the parameter words that follow, the
	  run-length data; bits 25-28 are the output's bit 15, signedness and depth (4, 8, 24, 15 bit).
	- MDEC(2) takes the quant tables: 64 bytes for luminance, and 64 more for colour with bit 0.
	- MDEC(3) takes the scale table, 64 signed halfwords with 14 fractional bits.

	**Decoded when asked for.** The parameter words of MDEC(1) wait in `input` until output is
	wanted — a DMA1 transfer or a read of the data port — and then whole macroblocks are decoded
	until there is enough, as the hardware's FIFOs pace the two channels against each other. So
	the order a game starts the channels in does not matter, and nothing holds more than one
	macroblock of pixels: a DMA1 transfer the data cannot fill yet waits (`Dma`) for more input.

	**The output is in the order DMA1 writes it to RAM:** a colour macroblock as 16x16 pixels, row
	by row, as DMA1 reorders the four 8x8 blocks the hardware produces; a monochrome one as 8x8.
	A program reading the data port itself gets the same order, where the hardware gives it block
	by block — no known program does.

	**The arithmetic is exact and the same on every target:** integers only. psx-spx gives the
	inverse DCT as two passes of a matrix product with the scale table, each sum rounded as
	`(sum + 0FFFh) >> 13`, and says the hardware rounds somewhere about like that; that is what is
	done here. A table with the standard one's symmetry (every game's) is taken half a row at a time
	(the even and the odd frequencies apart), which regroups the same products and sums exactly, so
	it gives the full product's results with half the multiplications. The colour conversion uses
	psx-spx's factors (1.402, 0.3437, 0.7143, 1.772) in twelve fractional bits, rounded; psx-spx does
	not know the hardware's resolution there either.
**/
class Mdec {
	static inline var CMD_REG = 0x1F801820;
	static inline var STATUS_REG = 0x1F801824;

	/** Parameter words one MDEC(1) can carry (its low 16 bits). */
	static inline var INPUT_WORDS = 0x10000;
	/** Words in the largest macroblock: 16x16 pixels at 24 bits. */
	static inline var OUT_WORDS = 192;

	/** The command being carried out (its word) and the parameter words still to come. */
	static var command = 0;
	static var remaining = 0;
	/** What the parameters of the current command are: 0 none, 1 macroblocks, 2 quant tables, 3 scale. */
	static var kind = 0;
	/** Parameter words of MDEC(2) and (3) taken so far. */
	static var tableAt = 0;

	/** Output format, from MDEC(1) (and reflected by the other commands): depth 0..3 = 4, 8, 24, 15. */
	static var depth = 0;
	static var signedOut = false;
	static var bit15 = false;

	/** DMA0/DMA1 requests enabled (control register bits 30, 29). */
	static var enableIn = false;
	static var enableOut = false;

	/** MDEC(1)'s parameter words as halfwords: `inputEnd` received, `inputAt` decoded so far. */
	static var input:RawBuf;
	static var inputEnd = 0;
	static var inputAt = 0;

	/** One decoded macroblock waiting to go out: `outLen` words of which `outAt` have. */
	static var output:RawBuf;
	static var outLen = 0;
	static var outAt = 0;

	/**
		The tables and the blocks being decoded, 64 words each, in one buffer at fixed offsets: the
		quant tables (luminance, colour), the scale table, the scale table over 8 (the 13 bits the
		hardware uses) transposed for the passes, the three blocks, the passes' scratch and the
		zigzag's inverse. A word of a buffer is one load on every target, where an `Array<Int>` on
		reflaxe.CPP is a vector behind a shared pointer — the Dreamcast spent a third of a movie
		frame in the IDCT through them, and passing one to a function bumps an atomic count.
	**/
	static var tables:RawBuf;
	static inline var IQ_Y = 0;
	static inline var IQ_UV = 256;
	static inline var SCALE = 512;
	static inline var BASIS = 768;
	static inline var BLK_CR = 1024;
	static inline var BLK_CB = 1280;
	static inline var BLK_Y = 1536;
	static inline var TEMP = 1792;
	static inline var ZAGZIG = 2048;
	/** A macroblock's colour terms, one per Cr/Cb sample, shared by its four luminance pixels. */
	static inline var CHROMA_R = 2304;
	static inline var CHROMA_G = 2560;
	static inline var CHROMA_B = 2816;
	static inline var TABLE_BYTES = 3072;

	/** The rows and the columns of the block `rlDecode` filled that hold a non-zero coefficient,
	    a bit each: what the passes may skip (`pass`). */
	static var rowMask = 0;
	static var colMask = 0;

	/** Whether the scale table has the standard one's symmetry (the even-odd passes apply). */
	static var symmetric = false;

	static inline function tget(off:Int, i:Int):Int return MemA.get32(tables, off + (i << 2));
	static inline function tset(off:Int, i:Int, v:Int):Void MemA.set32(tables, off + (i << 2), v);

	/** The block whose pixels are being produced or taken in (status bits 16-18): 0..3 Y1..Y4, 4 Cr (or Y), 5 Cb. */
	static var currentBlock = 4;

	/** Macroblocks decoded (diagnostics). */
	public static var macroblocks(default, null) = 0;

	public static function init():Void {
		input = RawMem.alloc(INPUT_WORDS * 4);
		output = RawMem.alloc(OUT_WORDS * 4);
		tables = RawMem.alloc(TABLE_BYTES);
		for (i in 0...TABLE_BYTES >> 2) MemA.set32(tables, i << 2, 0);
		final zz = [0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42, 3, 8, 12, 17, 25, 30, 41, 43,
			9, 11, 18, 24, 31, 40, 44, 53, 10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
			21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63];
		for (i in 0...64) tset(ZAGZIG, zz[i], i);
		// No scale table until MDEC(3): psx-spx says such software decodes to flat mid-grey,
		// which an all-zero table gives.
		setBasis();
		reset();
		macroblocks = 0;
	}

	static function reset():Void {
		command = 0;
		remaining = 0;
		kind = 0;
		tableAt = 0;
		depth = 0;
		signedOut = false;
		bit15 = false;
		inputEnd = 0;
		inputAt = 0;
		outLen = 0;
		outAt = 0;
		currentBlock = 4;
	}

	public static inline function contains(p:Int):Bool {
		return p == CMD_REG || p == STATUS_REG;
	}

	public static function read(p:Int):Int {
		if (p == CMD_REG) return readData();
		else return status();
	}

	public static function write(p:Int, v:Int):Void {
		if (p == CMD_REG) writeWord(v);
		else control(v);
	}

	/** 1F801824h written: bit 31 resets (the tables stay, psx-spx), bits 30 and 29 enable the requests. */
	static function control(v:Int):Void {
		if ((v & 0x80000000) != 0) reset();
		else {}
		enableIn = (v & 0x40000000) != 0;
		enableOut = (v & 0x20000000) != 0;
	}

	/** 1F801824h read. */
	static function status():Int {
		final out = available();
		var s = 0;
		if (!out) s |= 0x80000000;                                   // data-out FIFO empty
		else {}
		if (remaining > 0 || (kind == 1 && (out || inputLeft()))) s |= 0x20000000;   // busy
		else {}
		if (enableIn && remaining > 0) s |= 0x10000000;               // DMA0 wanted
		else {}
		if (enableOut && out) s |= 0x08000000;                        // DMA1 wanted
		else {}
		s |= depth << 25;
		if (signedOut) s |= 0x01000000;
		else {}
		if (bit15) s |= 0x00800000;
		else {}
		s |= (currentBlock & 7) << 16;
		s |= (remaining - 1) & 0xFFFF;
		return s;
	}

	/** A word for 1F801820h: a command, or the next parameter of the one under way. */
	public static function writeWord(v:Int):Void {
		if (remaining <= 0) begin(v);
		else param(v);
	}

	static function begin(v:Int):Void {
		command = v;
		final op = (v >>> 29) & 7;
		// Bits 25-28 go to the status for every command (psx-spx).
		depth = (v >>> 27) & 3;
		signedOut = (v & 0x04000000) != 0;
		bit15 = (v & 0x02000000) != 0;
		tableAt = 0;
		if (op == 1) {
			kind = 1;
			remaining = v & 0xFFFF;
			// A new picture: what the last one left undecoded is dropped.
			inputEnd = 0;
			inputAt = 0;
			outLen = 0;
			outAt = 0;
		} else if (op == 2) {
			kind = 2;
			remaining = (v & 1) != 0 ? 32 : 16;
		} else if (op == 3) {
			kind = 3;
			remaining = 32;
		} else {
			// MDEC(0) and MDEC(4..7) do nothing; their low bits show in the status without the
			// "minus one" and without waiting for parameters.
			kind = 0;
			remaining = 0;
		}
	}

	static function param(v:Int):Void {
		remaining--;
		if (kind == 1) {
			if (inputEnd + 2 <= INPUT_WORDS * 2) {
				RawMem.set16(input, inputEnd << 1, v & 0xFFFF);
				RawMem.set16(input, (inputEnd + 1) << 1, (v >>> 16) & 0xFFFF);
				inputEnd += 2;
			} else {}
		} else if (kind == 2) {
			// Four unsigned bytes a word: the luminance table, then the colour one.
			final t = tableAt < 16 ? IQ_Y : IQ_UV;
			final at = (tableAt & 15) << 2;
			tset(t, at, v & 0xFF);
			tset(t, at + 1, (v >> 8) & 0xFF);
			tset(t, at + 2, (v >> 16) & 0xFF);
			tset(t, at + 3, (v >> 24) & 0xFF);
			tableAt++;
		} else if (kind == 3) {
			// Two signed halfwords a word.
			tset(SCALE, tableAt << 1, ((v & 0xFFFF) << 16) >> 16);
			tset(SCALE, (tableAt << 1) + 1, v >> 16);
			tableAt++;
			if (remaining == 0) setBasis();
			else {}
		} else {}
		if (remaining == 0 && kind != 1) kind = 0;
		else {}
	}

	/** DMA0: `words` words from RAM at `addr` into the command port. */
	public static function dmaIn(ram:RawBuf, addr:Int, words:Int):Void {
		var a = addr;
		for (i in 0...words) {
			writeWord(RawMem.get32(ram, a & 0x1FFFFC));
			a += 4;
		}
	}

	/**
		DMA1: up to `words` words of pixels into RAM at `addr`, decoding as needed. Returns how many
		went — fewer than asked when the input has run out for now.
	**/
	public static function dmaOut(ram:RawBuf, addr:Int, words:Int):Int {
		var done = 0;
		var a = addr;
		while (done < words) {
			if (outAt >= outLen && !decodeNext()) break;
			else {}
			final n = (outLen - outAt) < (words - done) ? (outLen - outAt) : (words - done);
			for (i in 0...n) {
				RawMem.set32(ram, a & 0x1FFFFC, RawMem.get32(output, (outAt + i) << 2));
				a += 4;
			}
			outAt += n;
			done += n;
		}
		return done;
	}

	/** 1F801820h read: the next word of pixels, or 0 when there is none. */
	static function readData():Int {
		if (outAt >= outLen && !decodeNext()) return 0;
		else {}
		final w = RawMem.get32(output, outAt << 2);
		outAt++;
		return w;
	}

	/** Whether a word of output is there, or can be decoded from the input already received. */
	static function available():Bool {
		if (outAt < outLen) return true;
		else if (kind != 1 && remaining <= 0 && inputAt >= inputEnd) return false;
		else return complete();
	}

	// ---- decoding ----------------------------------------------------------------------------

	/** Halfword `i` of the input. */
	static inline function half(i:Int):Int return RawMem.get16(input, i << 1);

	/**
		Whether input is left to decode. Padding (FE00h) is passed over first, as the hardware does
		before a block: a movie frame's data is padded to whole DMA blocks with it, and the MDEC is
		idle — not busy, as a game waiting on it needs to see — once only padding remains.
	**/
	static function inputLeft():Bool {
		while (inputAt < inputEnd && half(inputAt) == 0xFE00) inputAt++;
		return inputAt < inputEnd;
	}

	/**
		Whether the input from `inputAt` holds a whole macroblock — six blocks in colour, one in
		monochrome — so that decoding it will not run dry. Padding (FE00h) before a block is skipped,
		as rl_decode_block does.
	**/
	static function complete():Bool {
		var i = inputAt;
		final blocks = depth >= 2 ? 6 : 1;
		for (b in 0...blocks) {
			while (i < inputEnd && half(i) == 0xFE00) i++;
			if (i >= inputEnd) return false;
			else {}
			i++;   // the DCT word
			var k = 0;
			while (true) {
				if (i >= inputEnd) return false;
				else {}
				final n = half(i);
				i++;
				k = k + ((n >> 10) & 63) + 1;
				if (k > 63) break;
				else {}
			}
		}
		return true;
	}

	/** The next macroblock into `output`, if the input holds one. */
	static function decodeNext():Bool {
		if (kind != 1 || !complete()) return false;
		else {}
		if (depth >= 2) {
			currentBlock = 4;
			rlDecode(BLK_CR, IQ_UV);
			currentBlock = 5;
			rlDecode(BLK_CB, IQ_UV);
			chroma();
			currentBlock = 0;
			rlDecode(BLK_Y, IQ_Y);
			toRgb(0, 0);
			currentBlock = 1;
			rlDecode(BLK_Y, IQ_Y);
			toRgb(8, 0);
			currentBlock = 2;
			rlDecode(BLK_Y, IQ_Y);
			toRgb(0, 8);
			currentBlock = 3;
			rlDecode(BLK_Y, IQ_Y);
			toRgb(8, 8);
			outLen = depth == 2 ? 192 : 128;
		} else {
			currentBlock = 4;
			rlDecode(BLK_Y, IQ_Y);
			toMono();
			outLen = depth == 1 ? 16 : 8;
		}
		outAt = 0;
		macroblocks++;
		return true;
	}

	static inline function signed10(n:Int):Int return ((n & 0x3FF) << 22) >> 22;

	/** psx-spx's rl_decode_block: the coefficients into the block at `blk`, dequantised by the
	    table at `qt`, then the inverse DCT. */
	static function rlDecode(blk:Int, qt:Int):Void {
		for (i in 0...64) tset(blk, i, 0);
		while (half(inputAt) == 0xFE00) inputAt++;
		var n = half(inputAt);
		inputAt++;
		var k = 0;
		final q = (n >> 10) & 63;
		var v = signed10(n) * tget(qt, 0);
		var rows = 0;
		var cols = 0;
		while (true) {
			if (q == 0) v = signed10(n) << 1;
			else {}
			v = v < -0x400 ? -0x400 : (v > 0x3FF ? 0x3FF : v);
			final at = q > 0 ? tget(ZAGZIG, k) : k;
			tset(blk, at, v);
			rows |= v != 0 ? 1 << (at >> 3) : 0;
			cols |= v != 0 ? 1 << (at & 7) : 0;
			n = half(inputAt);
			inputAt++;
			k = k + ((n >> 10) & 63) + 1;
			if (k > 63) break;
			else {}
			v = (signed10(n) * tget(qt, k) * q + 4) >> 3;
		}
		rowMask = rows;
		colMask = cols;
		idct(blk);
	}

	/** The scale table over 8, transposed (row `x`, column `z` = table[x + z*8] >> 3), and whether
	    the even-odd halves apply: every frequency row symmetric or antisymmetric about the middle. */
	static function setBasis():Void {
		var sym = true;
		for (z in 0...8) {
			for (x in 0...8) {
				tset(BASIS, (x << 3) + z, tget(SCALE, x + (z << 3)) >> 3);
			}
			for (x in 0...4) {
				final a = tget(SCALE, x + (z << 3)) >> 3;
				final b = tget(SCALE, (7 - x) + (z << 3)) >> 3;
				if ((z & 1) == 0 ? a != b : a != -b) sym = false;
				else {}
			}
		}
		symmetric = sym;
	}

	/**
		Two passes of psx-spx's real_idct_core: each takes column y of `src` to row y of `dst`.
		A block's coefficients are mostly zero, and a zero coefficient's products add nothing, so
		the first pass leaves the columns that are all zero as zero rows (`(0 + 0FFFh) >> 13` is 0)
		and both take only the terms that can be non-zero: the first pass's column y holds the
		block's rows (`rowMask`), the second pass's the first's rows, which are the block's columns
		(`colMask`). The sums are the full product's, term for term.
	**/
	static function idct(blk:Int):Void {
		pass(blk, TEMP, colMask, rowMask);
		pass(TEMP, blk, 0xFF, colMask);
	}

	/** One pass: the rows of `dst` in `rows` from the columns of `src`, whose coefficients outside
	    `terms` are zero; the other rows zero. */
	static function pass(src:Int, dst:Int, rows:Int, terms:Int):Void {
		final t = tables;
		for (y in 0...8) {
			if (((rows >> y) & 1) == 0 || terms == 0) zeroRow(dst + (y << 5));
			else if (terms == 1) dcRow(src + (y << 2), dst + (y << 5));
			else if ((terms & 0xF0) == 0) lowRow(src + (y << 2), dst + (y << 5));
			else fullRow(src + (y << 2), dst + (y << 5));
		}
	}

	static inline function zeroRow(row:Int):Void {
		for (x in 0...8) MemA.set32(tables, row + (x << 2), 0);
	}

	/** Only the column's first coefficient: out[x] = c0 * basis[x][0]. */
	static function dcRow(at:Int, row:Int):Void {
		final t = tables;
		final c0 = MemA.get32(t, at);
		for (x in 0...8) MemA.set32(t, row + (x << 2), (c0 * MemA.get32(t, BASIS + (x << 5)) + 0xFFF) >> 13);
	}

	/** The column's first four coefficients only (the high frequencies zero). */
	static function lowRow(at:Int, row:Int):Void {
		final t = tables;
		final c0 = MemA.get32(t, at), c1 = MemA.get32(t, at + 32), c2 = MemA.get32(t, at + 64);
		final c3 = MemA.get32(t, at + 96);
		if (symmetric) {
			for (x in 0...4) {
				final b = BASIS + (x << 5);
				final e = c0 * MemA.get32(t, b) + c2 * MemA.get32(t, b + 8);
				final o = c1 * MemA.get32(t, b + 4) + c3 * MemA.get32(t, b + 12);
				MemA.set32(t, row + (x << 2), (e + o + 0xFFF) >> 13);
				MemA.set32(t, row + ((7 - x) << 2), (e - o + 0xFFF) >> 13);
			}
		} else {
			for (x in 0...8) {
				final b = BASIS + (x << 5);
				final s = c0 * MemA.get32(t, b) + c1 * MemA.get32(t, b + 4) + c2 * MemA.get32(t, b + 8)
					+ c3 * MemA.get32(t, b + 12);
				MemA.set32(t, row + (x << 2), (s + 0xFFF) >> 13);
			}
		}
	}

	/** The full product, half a row at a time when the table has the standard symmetry. */
	static function fullRow(at:Int, row:Int):Void {
		final t = tables;
		final c0 = MemA.get32(t, at), c1 = MemA.get32(t, at + 32), c2 = MemA.get32(t, at + 64);
		final c3 = MemA.get32(t, at + 96), c4 = MemA.get32(t, at + 128), c5 = MemA.get32(t, at + 160);
		final c6 = MemA.get32(t, at + 192), c7 = MemA.get32(t, at + 224);
		if (symmetric) {
			// out[x] = E + O, out[7 - x] = E - O: the even frequencies are symmetric about the
			// middle and the odd ones antisymmetric, so the products for x serve 7 - x too.
			for (x in 0...4) {
				final b = BASIS + (x << 5);
				final e = c0 * MemA.get32(t, b) + c2 * MemA.get32(t, b + 8) + c4 * MemA.get32(t, b + 16)
					+ c6 * MemA.get32(t, b + 24);
				final o = c1 * MemA.get32(t, b + 4) + c3 * MemA.get32(t, b + 12) + c5 * MemA.get32(t, b + 20)
					+ c7 * MemA.get32(t, b + 28);
				MemA.set32(t, row + (x << 2), (e + o + 0xFFF) >> 13);
				MemA.set32(t, row + ((7 - x) << 2), (e - o + 0xFFF) >> 13);
			}
		} else {
			for (x in 0...8) {
				final b = BASIS + (x << 5);
				final s = c0 * MemA.get32(t, b) + c1 * MemA.get32(t, b + 4) + c2 * MemA.get32(t, b + 8)
					+ c3 * MemA.get32(t, b + 12) + c4 * MemA.get32(t, b + 16) + c5 * MemA.get32(t, b + 20)
					+ c6 * MemA.get32(t, b + 24) + c7 * MemA.get32(t, b + 28);
				MemA.set32(t, row + (x << 2), (s + 0xFFF) >> 13);
			}
		}
	}

	/** A signed 9-bit wrap and a saturation to signed 8 bits (psx-spx's yuv_to_rgb and y_to_mono). */
	static inline function clip(v:Int):Int {
		final w = ((v & 0x1FF) << 23) >> 23;
		return w < -128 ? -128 : (w > 127 ? 127 : w);
	}

	/** Each Cr/Cb sample's three colour terms (psx-spx's yuv_to_rgb, the factors in twelve
	    fractional bits), once a macroblock: four luminance pixels share each. */
	static function chroma():Void {
		for (c in 0...64) {
			final cr = tget(BLK_CR, c), cb = tget(BLK_CB, c);
			tset(CHROMA_R, c, (5743 * cr + 2048) >> 12);
			tset(CHROMA_G, c, (-1408 * cb - 2926 * cr + 2048) >> 12);
			tset(CHROMA_B, c, (7258 * cb + 2048) >> 12);
		}
	}

	/** One 8x8 luminance block (at xx, yy of the macroblock) with its quarter of Cr and Cb, into
	    `output` as 15- or 24-bit pixels of the 16x16 macroblock. */
	static function toRgb(xx:Int, yy:Int):Void {
		final flip = signedOut ? 0 : 0x80;
		for (y in 0...8) {
			for (x in 0...8) {
				final c = (((x + xx) >> 1) + (((y + yy) >> 1) << 3));
				final yv = tget(BLK_Y, x + (y << 3));
				final r = clip(yv + tget(CHROMA_R, c)) ^ flip;
				final g = clip(yv + tget(CHROMA_G, c)) ^ flip;
				final b = clip(yv + tget(CHROMA_B, c)) ^ flip;
				final px = (x + xx) + ((y + yy) << 4);
				if (depth == 2) {
					// 24-bit: R, G, B bytes in that order, 48 bytes a row of 16.
					final at = px * 3;
					RawMem.set8(output, at, r & 0xFF);
					RawMem.set8(output, at + 1, g & 0xFF);
					RawMem.set8(output, at + 2, b & 0xFF);
				} else {
					final w = ((r & 0xFF) >> 3) | (((g & 0xFF) >> 3) << 5) | (((b & 0xFF) >> 3) << 10)
						| (bit15 ? 0x8000 : 0);
					RawMem.set16(output, px << 1, w);
				}
			}
		}
	}

	/** The luminance block as 8- or 4-bit pixels (psx-spx's y_to_mono). */
	static function toMono():Void {
		final flip = signedOut ? 0 : 0x80;
		if (depth == 1) {
			for (i in 0...64) RawMem.set8(output, i, (clip(tget(BLK_Y, i)) ^ flip) & 0xFF);
		} else {
			for (i in 0...32) {
				final lo = ((clip(tget(BLK_Y, i << 1)) ^ flip) & 0xFF) >> 4;
				final hi = ((clip(tget(BLK_Y, (i << 1) + 1)) ^ flip) & 0xFF) >> 4;
				RawMem.set8(output, i, lo | (hi << 4));
			}
		}
	}
}
