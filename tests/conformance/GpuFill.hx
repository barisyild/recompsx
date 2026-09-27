/**
	GP0(02h), the VRAM fill, against the mask bits.

	psx-spx, "Fill Rectangle in VRAM": the fill "is not affected by the GP0(E6h) mask setting,
	acting as if GP0(E6h).0 and GP0(E6h).1 are both zero", and the 24-bit colour becomes a 15-bit
	word "and additionally sets the mask bit (bit15) to 0". A sprite rectangle, drawn with the same
	mask bits over the same words, obeys both — the contrast is the point, since the two used to
	share one path. Crash Bandicoot: Warped clears its shadow texture with a fill over words whose
	bit 15 is set, and reads it back through a 4-bit palette, where bit 15 is part of an index.
**/
class GpuFill {
	public static function main():Void {
		Conf.feedName("GpuFill");
		mem.Memory.init();
		gpu.Gpu.init();
		gp0(0xE3000000);                                  // drawing area: the whole of VRAM
		gp0(0xE4000000 | (1023 | (511 << 10)));

		// Words with bit 15 set, as a game's upload leaves them.
		upload(32, 16, 48, 8, 0x8888);

		// Both mask bits on: a sprite skips what is protected and marks what it writes.
		gp0(0xE6000003);
		gp0(0x60000000 | 0x0000F8);                       // red, variable size
		gp0(32 | (16 << 16));
		gp0(16 | (2 << 16));
		Conf.expect("the sprite skips protected words", gpu.Vram.get(40, 17), 0x8888);

		// A fill under the same bits writes every word, with bit 15 clear.
		gp0(0x02000000 | 0x00F800);                       // green: 15-bit 03E0h
		gp0(48 | (16 << 16));                             // X in steps of 16
		gp0(20 | (4 << 16));                              // width 20 rounds up to 32
		Conf.expect("the fill ignores the mask check", gpu.Vram.get(48, 16), 0x03E0);
		Conf.expect("and does not set the mask bit", gpu.Vram.get(79, 19), 0x03E0);
		Conf.expect("the width rounds up to sixteens", gpu.Vram.get(79, 16), 0x03E0);
		Conf.expect("rows below it are untouched", gpu.Vram.get(48, 20), 0x8888);
		Conf.expect("so are words left of it", gpu.Vram.get(47, 16), 0x8888);

		// A sprite over unprotected words with "set" on marks them.
		gp0(0xE6000001);
		gp0(0x60000000 | 0x0000F8);
		gp0(48 | (17 << 16));
		gp0(4 | (1 << 16));
		Conf.expect("a sprite with set-mask marks what it draws", gpu.Vram.get(49, 17), 0x801F);

		// A fill over marked words with "check" on: unaffected all the same.
		gp0(0xE6000002);
		gp0(0x02000000);                                  // black
		gp0(48 | (17 << 16));
		gp0(16 | (1 << 16));
		Conf.expect("a fill clears a word the sprite marked", gpu.Vram.get(49, 17), 0);
		gp0(0xE6000000);

		for (y in 14...26) {
			var row = 0;
			for (x in 24...88) row = (shim.IntMath.mul(row, 31) + gpu.Vram.get(x, y)) | 0;
			Conf.feed(row);
		}
		Conf.report("GpuFill");
	}

	/** A CPU-to-VRAM rectangle of one halfword, two to a word. */
	static function upload(x:Int, y:Int, w:Int, h:Int, v:Int):Void {
		gp0(0xA0000000);
		gp0(x | (y << 16));
		gp0(w | (h << 16));
		final words = (w * h + 1) >> 1;
		for (i in 0...words) gp0(v | (v << 16));
	}

	static inline function gp0(word:Int):Void {
		gpu.Gpu.writeGp0(word);
	}
}
