package recomp;

/**
	PlayStation address arithmetic.

	The R3000A has no MMU in any meaningful sense: the three segments are hard-wired views of the
	same physical memory, differing only in whether they are cached. Games use all three — Psy-Q
	links code at 0x80010000 (KSEG0, cached), DMA structures are often built through 0xA0000000
	(KSEG1, uncached) so writes are visible to the hardware immediately, and some code passes
	KUSEG addresses around. All three must fold to the same place or the same pointer arithmetic
	will silently address two different bytes.
**/
class Vaddr {
	public static inline var RAM_BASE  = 0x80000000;
	public static inline var RAM_SIZE  = 0x200000;    // 2 MB, the retail console
	public static inline var RAM_MASK  = 0x1FFFFF;

	/** Strips the segment, leaving a physical address. KUSEG, KSEG0 and KSEG1 all collapse. */
	public static inline function phys(a:Int):Int return a & 0x1FFFFFFF;

	/** True if the address lands in main RAM, through any segment. */
	public static inline function isRam(a:Int):Bool {
		final p = phys(a);
		return p >= 0 && p < 0x800000;   // 2 MB mirrored four times
	}

	/** Offset into the 2 MB RAM image, mirrors folded. */
	public static inline function ramOffset(a:Int):Int return phys(a) & RAM_MASK;

	/** Normalises any segment view to the cached KSEG0 form we use as the canonical name for a
	    RAM address, so a function discovered through 0xA0011000 and one through 0x80011000 are
	    recognised as the same function rather than compiled twice. */
	public static inline function canonRam(a:Int):Int return RAM_BASE | ramOffset(a);

	/** Lowercase 0x-prefixed 8-digit hex — the form every diagnostic in the tool uses. */
	public static function hex(a:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((a >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}

	public static function hex16(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 12;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}
}
