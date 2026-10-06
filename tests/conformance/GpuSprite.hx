/**
	Textured rectangles, GP0(64h-7Fh) (psx-spx, "GPU Render Rectangle Commands"): the texel at the
	top-left corner from the third word, the next texel a pixel to the right and down — or the one
	before, under GP0(E1h)'s X- and Y-flip — wrapping at 256 and through the texture window, from
	the page GP0(E1h) set or the last textured polygon's attribute set. Clipped to the drawing area,
	the texel at the clipped edge being the one that lands there. A zero texel is transparent, bit
	15 says whether a texel blends, the colour modulates unless the texture is raw.

	They had been drawn as rectangles of the command's colour: Tekken 3 writes every name, timer and
	caption as raw-textured sprites of colour 0, and each was a black box.
**/
class GpuSprite {
	static inline var CLUT_Y = 500;

	public static function main():Void {
		Conf.feedName("GpuSprite");
		mem.Memory.init();
		gpu.Gpu.init();
		area(0, 0, 1023, 511);

		// A palette: 0 transparent, 1-15 colours, 9-15 with bit 15 (they blend when asked to).
		final clut = [for (i in 0...16) i == 0 ? 0 : ((i * 2) | ((31 - i * 2) << 5) | ((i & 7) << 12) | (i >= 9 ? 0x8000 : 0))];
		uploadRow(0, CLUT_Y, clut);
		// A 4-bit page at x 512: texel u, v holds (u + 3v) mod 16, so that every texel is told apart
		// from its neighbours along both axes.
		for (v in 0...16) {
			final row = [for (h in 0...64) 0];
			for (u in 0...256) row[u >> 2] |= ((u + 3 * v) & 15) << ((u & 3) << 2);
			uploadRow(512, v, row);
		}
		// A 15-bit page at x 640: texel u, v holds a colour made of both, 0 at u = 5.
		for (v in 0...8) uploadRow(640, v, [for (u in 0...32) u == 5 ? 0 : ((u & 31) | ((v * 3) << 5) | (((u + v) & 31) << 10))]);
		// An 8-bit page at x 704: texel u, v holds palette index (u ^ v) & 15.
		for (v in 0...8) uploadRow(704, v, [for (h in 0...16) (((2 * h) ^ v) & 15) | ((((2 * h + 1) ^ v) & 15) << 8)]);

		final clutAttr = (CLUT_Y << 6) << 16;
		gp0(0xE1000008);                                  // page 512, 4-bit, no flips

		// Raw, 8x4 at 100,50 from texel 1,2.
		sprite(0x65000000, 100, 50, clutAttr | (2 << 8) | 1, 8, 4);
		Conf.expect("raw 4-bit: the corner texel", vram(100, 50), clut[tex4(1, 2)]);
		Conf.expect("raw 4-bit: one right", vram(101, 50), clut[tex4(2, 2)]);
		Conf.expect("raw 4-bit: one down", vram(100, 51), clut[tex4(1, 3)]);
		Conf.expect("raw 4-bit: the last pixel", vram(107, 53), clut[tex4(8, 5)]);
		Conf.expect("raw 4-bit: nothing past the width", vram(108, 50), 0);

		// X-flip: texels count down from the corner's.
		gp0(0xE1001008);
		sprite(0x65000000, 100, 60, clutAttr | (2 << 8) | 14, 8, 4);
		Conf.expect("x-flip: the corner texel", vram(100, 60), clut[tex4(14, 2)]);
		Conf.expect("x-flip: one right is one before", vram(101, 60), clut[tex4(13, 2)]);
		Conf.expect("x-flip: rows still count up", vram(101, 61), clut[tex4(13, 3)]);
		// Y-flip as well.
		gp0(0xE1003008);
		sprite(0x65000000, 120, 60, clutAttr | (9 << 8) | 14, 8, 4);
		Conf.expect("x- and y-flip: one down is one up", vram(121, 61), clut[tex4(13, 8)]);
		gp0(0xE1000008);

		// Wrapping at 256: texels 252..255, then 0..3.
		sprite(0x65000000, 140, 50, clutAttr | (1 << 8) | 252, 8, 1);
		Conf.expect("the last texel of a row", vram(143, 50), clut[tex4(255, 1)]);
		Conf.expect("wraps to texel 0", vram(144, 50), clut[tex4(0, 1)]);

		// The texture window: U's bit 3 masked and offset to 1, so texels 8..15 repeat.
		gp0(0xE2000000 | 1 | (1 << 10));
		sprite(0x65000000, 160, 50, clutAttr | (4 << 8) | 0, 24, 1);
		Conf.expect("window: texel 0 reads as 8", vram(160, 50), clut[tex4(8, 4)]);
		Conf.expect("window: texel 16 reads as 24", vram(176, 50), clut[tex4(24, 4)]);
		gp0(0xE2000000);

		// The drawing area clips; the texel at the clipped edge is the one that falls there.
		area(205, 52, 230, 70);
		sprite(0x65000000, 200, 50, clutAttr | (0 << 8) | 0, 16, 8);
		Conf.expect("clipped on the left: texel 5 at x 205", vram(205, 52), clut[tex4(5, 2)]);
		Conf.expect("outside the area: untouched", vram(204, 52), 0);
		area(0, 0, 1023, 511);

		// Modulated by the command's colour: half red, full green, double blue (clamped).
		sprite(0x64000000 | 0x40 | (0x80 << 8) | (0xFF << 16), 100, 70, clutAttr | (2 << 8) | 1, 4, 1);
		Conf.expect("modulated", vram(100, 70), modulate(clut[tex4(1, 2)], 0x40, 0x80, 0xFF));

		// A zero texel is transparent: on row 1, index (u + 3) & 15 is 0 at u = 13.
		fill(100, 80, 8, 1, 0x1234);
		sprite(0x65000000, 100, 80, clutAttr | (1 << 8) | 10, 8, 1);
		Conf.expect("index 0 leaves the pixel", vram(103, 80), 0x1234);
		Conf.expect("its neighbour draws", vram(102, 80), clut[tex4(12, 1)]);

		// Semi-transparent, additive (E1 bits 5-6 = 1): texels with bit 15 add, the rest overwrite.
		gp0(0xE1000028);
		fill(100, 90, 16, 1, 0x0421);                     // 1, 1, 1
		sprite(0x67000000, 100, 90, clutAttr | (0 << 8) | 0, 16, 1);
		final t9 = clut[tex4(9, 0)], t2 = clut[tex4(2, 0)];
		Conf.expect("an opaque texel overwrites", vram(102, 90), t2);
		Conf.expect("a bit-15 texel adds", vram(109, 90), add555(0x0421, t9) | 0x8000);
		gp0(0xE1000008);

		// The fixed sizes: 1x1 (6Dh), 8x8 (75h), 16x16 (7Dh).
		sprite(0x6D000000, 250, 50, clutAttr | (3 << 8) | 6, 0, 0);
		Conf.expect("1x1", vram(250, 50), clut[tex4(6, 3)]);
		Conf.expect("1x1 is one pixel", vram(251, 50), 0);
		sprite(0x75000000, 260, 50, clutAttr | (0 << 8) | 0, 0, 0);
		Conf.expect("8x8: its last pixel", vram(267, 57), clut[tex4(7, 7)]);
		Conf.expect("8x8: no ninth", vram(268, 57), 0);
		sprite(0x7D000000, 280, 50, clutAttr | (0 << 8) | 0, 0, 0);
		Conf.expect("16x16: its last pixel", vram(295, 65), clut[tex4(15, 15)]);

		// 15-bit, raw: the texels themselves; a zero one transparent.
		gp0(0xE100010A);
		sprite(0x65000000, 100, 100, (3 << 8) | 2, 8, 2);
		Conf.expect("15-bit: the texel", vram(100, 100), tex15(2, 3));
		Conf.expect("15-bit: zero is transparent", vram(103, 100), 0);
		Conf.expect("15-bit: next row", vram(104, 101), tex15(6, 4));

		// 8-bit through the palette.
		gp0(0xE100008B);
		sprite(0x65000000, 120, 100, clutAttr | (5 << 8) | 3, 8, 2);
		Conf.expect("8-bit: the texel", vram(121, 100), clut[(4 ^ 5) & 15]);

		// A textured polygon's page attribute sets the page sprites use: a raw triangle naming the
		// 15-bit page, then a sprite with no GP0(E1h) of its own.
		gp0(0xE1000008);
		gp0(0x25000000);
		gp0(vertex(300, 100));
		gp0(clutAttr | 0);
		gp0(vertex(304, 100));
		gp0((0x10A << 16) | 4);                           // page 640, 15-bit
		gp0(vertex(300, 104));
		gp0(4 << 8);
		sprite(0x65000000, 320, 100, (1 << 8) | 7, 4, 1);
		Conf.expect("a polygon's page carries over to sprites", vram(320, 100), tex15(7, 1));

		for (y in 48...112) {
			var row = 0;
			for (x in 96...330) row = (shim.IntMath.mul(row, 31) + gpu.Vram.get(x, y)) | 0;
			Conf.feed(row);
		}
		Conf.report("GpuSprite");
	}

	static function tex4(u:Int, v:Int):Int return ((u & 255) + 3 * v) & 15;

	static function tex15(u:Int, v:Int):Int
		return u == 5 ? 0 : ((u & 31) | ((v * 3) << 5) | (((u + v) & 31) << 10));

	static function modulate(t:Int, r:Int, g:Int, b:Int):Int {
		final rr = ((t & 31) << 3) * r >> 7, gg = (((t >> 5) & 31) << 3) * g >> 7, bb = (((t >> 10) & 31) << 3) * b >> 7;
		return ((rr > 255 ? 255 : rr) >> 3) | (((gg > 255 ? 255 : gg) >> 3) << 5) | (((bb > 255 ? 255 : bb) >> 3) << 10);
	}

	static function add555(back:Int, front:Int):Int {
		var out = 0;
		for (c in 0...3) {
			final s = ((back >> (c * 5)) & 31) + ((front >> (c * 5)) & 31);
			out |= (s > 31 ? 31 : s) << (c * 5);
		}
		return out;
	}

	/** A sprite: command and colour, its corner, its texture word, and its size if variable. */
	static function sprite(cmd:Int, x:Int, y:Int, tex:Int, w:Int, h:Int):Void {
		gp0(cmd);
		gp0(vertex(x, y));
		gp0(tex);
		if (((cmd >>> 27) & 3) == 0) gp0(w | (h << 16));
		else {}
	}

	static function vertex(x:Int, y:Int):Int return (x & 0xFFFF) | (y << 16);

	static function area(x0:Int, y0:Int, x1:Int, y1:Int):Void {
		gp0(0xE3000000 | x0 | (y0 << 10));
		gp0(0xE4000000 | x1 | (y1 << 10));
	}

	static function fill(x:Int, y:Int, w:Int, h:Int, v:Int):Void {
		for (j in 0...h) uploadRow(x, y + j, [for (_ in 0...w) v]);
	}

	/** One row of halfwords by a CPU-to-VRAM transfer. */
	static function uploadRow(x:Int, y:Int, halves:Array<Int>):Void {
		final n = halves.length;
		gp0(0xA0000000);
		gp0(x | (y << 16));
		gp0(n | (1 << 16));
		var i = 0;
		while (i < n) {
			final lo = halves[i] & 0xFFFF;
			final hi = i + 1 < n ? halves[i + 1] & 0xFFFF : 0;
			gp0(lo | (hi << 16));
			i += 2;
		}
	}

	static function vram(x:Int, y:Int):Int return gpu.Vram.get(x, y);

	static inline function gp0(word:Int):Void {
		gpu.Gpu.writeGp0(word);
	}
}
