package kernel;

import core.Runtime;

/**
	The kernel heap.

	psx-spx: `InitHeap(addr, size)` "Initializes the address and size of the heap". The game hands
	the kernel a region of its own RAM and the kernel allocates inside it — so this is not a host
	allocation, and must never become one. Every byte lives in emulated memory where the game can
	see it, because games do look: Psy-Q's own libraries walk heap block headers.

	Deliberately deterministic: first fit, ascending, 8-byte aligned, no coalescing surprises and
	no dependence on host allocator behaviour. Two runs of the same game must return the same
	addresses in the same order, or the frame digests that gate this project stop meaning anything.
**/
class KHeap {
	/** Where the game's heap region starts, or 0 if `InitHeap` has not been called. */
	public static var base(default, null) = 0;

	/** How large the game said it is. */
	public static var size(default, null) = 0;

	public static function init(addr:Int, len:Int):Void {
		// Align up to 8: the BIOS hands out 8-byte-aligned blocks, and code that assumes it will
		// otherwise fault on a `lw` in a way that looks like a memory bug rather than a heap one.
		base = (addr + 7) & ~7;
		size = len - (base - addr);
		if (size < 0) size = 0;
		else {}
		Runtime.noteOnce(0xA0039, "A0(39h) InitHeap — " + size + " bytes at " + hex(base));
		// A zero-length heap means the size argument was read from memory that is still empty:
		// nothing loads the executable's payload into emulated RAM yet, so every load returns 0.
		// Worth saying out loud rather than letting a silent 0 look like a game fact.
		if (size == 0) Runtime.noteOnce(0xA00391, "  heap size is 0 — is the program image loaded?");
		else {}
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
