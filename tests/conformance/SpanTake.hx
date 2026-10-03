import mem.Memory;

/**
	Memory.span's take, over every kind of address a base register can hold — RAM and its mirrors
	in each segment and at both ends, the scratchpad in each segment, at both ends and just past
	them, the register page, the BIOS, the expansion areas — and runs of offsets either side of
	zero: a span is none, or a view each of whose bytes is the one the full decode reads
	(Memory.read8u). Whether each run was taken goes into the digest, so what is taken cannot change
	unseen; every byte of a taken run is checked, the long runs' ends and a stride between.
**/
class SpanTake {
	public static function main():Void {
		Memory.init();
		// Distinct bytes where the runs land: both ends of RAM, around each base, all of the
		// scratchpad, so a view onto the wrong place or the wrong region shows.
		var i = 0;
		while (i < 0x10000) {
			Memory.write8(0x80000000 + i, (i * 7 + 3) & 0xFF);
			Memory.write8(0x801F0000 + i, (i * 11 + 5) & 0xFF);
			i++;
		}
		i = 0;
		while (i < 0x10000) {
			Memory.write8(0x80040000 + i, (i * 5 + 1) & 0xFF);
			i++;
		}
		i = 0;
		while (i < Memory.SCRATCH_SIZE) {
			Memory.write8(Memory.SCRATCH_BASE + i, (i * 13 + 9) & 0xFF);
			i++;
		}
		final bases = [
			// RAM, KSEG0, KUSEG and KSEG1, and the mirrors at 2, 4 and 6 MB
			0x80000000, 0x80000010, 0x80040020, 0x801FFFF0, 0x801FFFFC, 0x80200000, 0x803FFFF8,
			0x807FFFF0, 0x00000020, 0x001FFFF8, 0x00600010, 0xA0000040, 0xA01FFFFC, 0x80800000,
			// the scratchpad: each segment, both ends, just before and just past it
			0x1F800000, 0x1F800004, 0x1F800200, 0x1F8003F8, 0x1F8003FC, 0x1F800400, 0x1F800404,
			0x1F80040C, 0x1F7FFFFC, 0x1F7FFFF0, 0x9F800000, 0x9F800200, 0x9F800400, 0xBF800010,
			// the register page, the BIOS, expansion 1 and 3, the cache control word
			0x1F801000, 0x1F8010F0, 0x1F801800, 0x1FC00000, 0xBFC00000, 0x9FC00100, 0x1F000000,
			0x1F000100, 0x1FA00000, 0x1FE00000, 0xFFFE0130, 0x00800000, 0x1F9FFFFC
		];
		final runs = [
			0, 3, 0, 39, -12, -1, 232, 291, -8, 15, -1024, -1, 1, 1023, -4, 4, 0, 1023,
			-32768, -32765, 32764, 32767, -16, 16, 1020, 1023, -1023, -1020
		];
		for (a in bases) {
			var r = 0;
			while (r < runs.length) {
				final lo = runs[r], hi = runs[r + 1];
				final s = Memory.span(a, lo, hi);
				final taken = Memory.spanOk(s);
				Conf.feed(taken ? 1 : 0);
				if (taken) check(a, s, lo, hi);
				else {}
				r += 2;
			}
		}
		Conf.report('SpanTake');
	}

	/** Every byte of a short run, and of a long one its ends and a stride between. */
	static function check(a:Int, s:shim.Span, lo:Int, hi:Int):Void {
		var k = lo;
		while (k <= hi) {
			Conf.expect('span byte', Memory.spanRead8u(s, k), Memory.read8u((a + k) | 0));
			k = (hi - lo < 64 || k < lo + 8 || k > hi - 8) ? k + 1 : k + 61;
		}
	}
}
