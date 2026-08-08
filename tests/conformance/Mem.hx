import shim.RawMem;

/**
	Cross-target memory conformance.

	`shim.RawMem` is the one place each target is allowed to be different — the C++ shim indexes a
	raw pointer, the JS shim reads typed-array views when an address is aligned and falls back to
	byte composition when it is not. Two implementations that must produce identical bytes is
	exactly the situation a cross-target digest exists for.

	The cases that matter here are the ones a real game produces: every alignment (MIPS `lwl`/`lwr`
	compose unaligned words from aligned reads, so the emulator sees both), values with the high
	bit set, and reads that straddle a 4-byte boundary. The digest covers all of it; a handful of
	answers are asserted outright because getting them wrong should say *what* broke, not just
	that something did.
**/
class Mem {
	static inline var SIZE = 4096;

	public static function main():Void {
		Conf.feedName("mem");
		final m = RawMem.alloc(SIZE);

		// Fresh memory must be zero. Emulated state starting from host garbage would be
		// non-deterministic before the first instruction ran.
		var i = 0;
		var nonZero = 0;
		while (i < SIZE) {
			nonZero += RawMem.get8(m, i);
			i++;
		}
		Conf.expect("alloc is zero-filled", nonZero, 0);

		// Byte writes at every alignment, read back as bytes, halfwords and words.
		i = 0;
		while (i < 256) {
			RawMem.set8(m, i, i ^ 0xA5);
			i++;
		}
		i = 0;
		while (i < 250) {
			Conf.feed(RawMem.get8(m, i));
			Conf.feed(RawMem.get16(m, i));      // includes odd addresses
			Conf.feed(RawMem.get32(m, i));      // includes all four alignments
			i++;
		}

		// Word writes at every alignment. The little-endian byte order is the contract; the JS
		// view path and the C++ pointer path must lay bytes down identically.
		final values = [
			0x00000000, 0x00000001, 0x000000FF, 0x0000FF00, 0x00FF0000, 0xFF000000,
			0x12345678, 0xDEADBEEF, 0x7FFFFFFF, 0x80000000, -1, -2147483648, 0x0F0F0F0F
		];
		var vi = 0;
		while (vi < values.length) {
			var off = 0;
			while (off < 4) {
				final at = 1024 + vi * 16 + off;
				RawMem.set32(m, at, values[vi]);
				Conf.feed(RawMem.get32(m, at));
				// The individual bytes, which is where an endianness mistake shows up
				Conf.feed(RawMem.get8(m, at));
				Conf.feed(RawMem.get8(m, at + 1));
				Conf.feed(RawMem.get8(m, at + 2));
				Conf.feed(RawMem.get8(m, at + 3));
				// And the halves, aligned and not
				Conf.feed(RawMem.get16(m, at));
				Conf.feed(RawMem.get16(m, at + 1));
				Conf.feed(RawMem.get16(m, at + 2));
				off++;
			}
			vi++;
		}

		// Halfword writes at both alignments.
		vi = 0;
		while (vi < values.length) {
			var off = 0;
			while (off < 2) {
				final at = 2048 + vi * 8 + off;
				RawMem.set16(m, at, values[vi]);
				Conf.feed(RawMem.get16(m, at));
				Conf.feed(RawMem.get8(m, at));
				Conf.feed(RawMem.get8(m, at + 1));
				off++;
			}
			vi++;
		}

		// Explicit little-endian statements, so a byte-order regression names itself.
		// Byte 68 is set too, because the straddling reads below depend on it.
		RawMem.set32(m, 64, 0x12345678);
		RawMem.set8(m, 68, 0x9A);
		Conf.expect("LE byte 0 is the low byte", RawMem.get8(m, 64), 0x78);
		Conf.expect("LE byte 1", RawMem.get8(m, 65), 0x56);
		Conf.expect("LE byte 2", RawMem.get8(m, 66), 0x34);
		Conf.expect("LE byte 3 is the high byte", RawMem.get8(m, 67), 0x12);
		Conf.expect("get32 round-trips", RawMem.get32(m, 64), 0x12345678);
		Conf.expect("get16 low half", RawMem.get16(m, 64), 0x5678);
		Conf.expect("get16 high half", RawMem.get16(m, 66), 0x1234);
		Conf.expect("unaligned get16 straddles", RawMem.get16(m, 65), 0x3456);
		Conf.expect("unaligned get32 straddles", RawMem.get32(m, 65), 0x9A123456);

		// set8 masks to a byte; the emulator relies on this for `sb`.
		RawMem.set8(m, 80, 0x1FF);
		Conf.expect("set8 keeps only 8 bits", RawMem.get8(m, 80), 0xFF);

		// Writes with the high bit set must read back identically, not sign-mangled.
		RawMem.set32(m, 96, -1);
		Conf.expect("all-ones round-trips", RawMem.get32(m, 96), -1);
		Conf.expect("all-ones as bytes", RawMem.get8(m, 96), 0xFF);
		RawMem.set32(m, 100, -2147483648);
		Conf.expect("INT_MIN round-trips", RawMem.get32(m, 100), -2147483648);

		Conf.report("mem");
	}
}
