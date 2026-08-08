package kernel;

import core.Runtime;
import mem.Memory;

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

	// Block header, in emulated memory ahead of every allocation:
	//   +0  size of the payload in bytes
	//   +4  1 if in use, 0 if free
	// Eight bytes, which also keeps every payload 8-aligned — the BIOS hands out aligned blocks
	// and code that assumes it faults on a `lw` in a way that looks like a memory bug, not a
	// heap one.
	static inline var HEADER = 8;
	static inline var OFF_SIZE = 0;
	static inline var OFF_USED = 4;

	/** How many blocks are live. A leak shows up here before it shows up as a crash. */
	public static var liveBlocks(default, null) = 0;

	public static function init(addr:Int, len:Int):Void {
		// Align up to 8: the BIOS hands out 8-byte-aligned blocks, and code that assumes it will
		// otherwise fault on a `lw` in a way that looks like a memory bug rather than a heap one.
		base = (addr + 7) & ~7;
		size = len - (base - addr);
		if (size < 0) size = 0;
		else {}
		liveBlocks = 0;
		// One free block covering everything. Allocation splits it; freeing merges neighbours.
		if (size > HEADER) writeHeader(base, size - HEADER, false);
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

	// ---- allocation ---------------------------------------------------------------------------

	/**
		First fit, ascending, splitting what it finds.

		Deterministic by construction: the same sequence of calls returns the same addresses on
		every run and every platform, which it must, or the frame digests that gate this project
		compare two different programs. That rules out anything driven by host allocator state —
		and there is no host allocation here anyway, since the heap is a region of the game's own
		RAM and Psy-Q's libraries walk these headers themselves.
	**/
	public static function malloc(bytes:Int):Int {
		if (base == 0 || bytes <= 0) return 0;
		else {}
		final want = (bytes + 7) & ~7;
		var p = base;
		final end = base + size;
		while (p + HEADER <= end) {
			final blockSize = Memory.read32(p + OFF_SIZE);
			final used = Memory.read32(p + OFF_USED) != 0;
			if (!used && blockSize >= want) return take(p, blockSize, want);
			else {}
			// A zero-length free block would loop forever; treat it as the end of the heap.
			if (blockSize <= 0) return exhausted(bytes);
			else {}
			p += HEADER + blockSize;
		}
		return exhausted(bytes);
	}

	static function take(p:Int, blockSize:Int, want:Int):Int {
		// Split only when the tail can hold a header and something worth having.
		if (blockSize >= want + HEADER + 8) {
			writeHeader(p + HEADER + want, blockSize - want - HEADER, false);
			Memory.write32(p + OFF_SIZE, want);
		} else {}
		Memory.write32(p + OFF_USED, 1);
		liveBlocks++;
		return p + HEADER;
	}

	static function exhausted(bytes:Int):Int {
		Runtime.reportOnce(0x58000000, "malloc could not satisfy " + bytes + " bytes");
		return 0;
	}

	public static function free(ptr:Int):Void {
		if (ptr == 0) return;
		else {}
		final p = ptr - HEADER;
		if (p < base || p >= base + size) return badFree(ptr);
		else {}
		Memory.write32(p + OFF_USED, 0);
		liveBlocks--;
		coalesce();
	}

	static function badFree(ptr:Int):Void {
		Runtime.reportOnce(0x58000001, "free of " + hex(ptr) + ", which is not in the heap");
	}

	/**
		Merges every run of adjacent free blocks.

		A whole-heap sweep rather than merging with the neighbour, because finding the block
		*before* a given one needs a backward link the BIOS layout does not have. The heap is
		small and frees are not a hot path.
	**/
	static function coalesce():Void {
		var p = base;
		final end = base + size;
		while (p + HEADER <= end) {
			final blockSize = Memory.read32(p + OFF_SIZE);
			if (blockSize <= 0) return;
			else {}
			final next = p + HEADER + blockSize;
			if (Memory.read32(p + OFF_USED) == 0 && next + HEADER <= end
					&& Memory.read32(next + OFF_USED) == 0) {
				Memory.write32(p + OFF_SIZE, blockSize + HEADER + Memory.read32(next + OFF_SIZE));
			} else {
				p = next;
			}
		}
	}

	public static function realloc(ptr:Int, bytes:Int):Int {
		if (ptr == 0) return malloc(bytes);
		else if (bytes <= 0) return freeAndReturnNull(ptr);
		else return moveTo(ptr, bytes);
	}

	static function freeAndReturnNull(ptr:Int):Int {
		free(ptr);
		return 0;
	}

	static function moveTo(ptr:Int, bytes:Int):Int {
		final oldSize = Memory.read32(ptr - HEADER + OFF_SIZE);
		if (oldSize >= bytes) return ptr;
		else {}
		final fresh = malloc(bytes);
		if (fresh == 0) return 0;
		else {}
		Memory.copyRam(fresh, ptr, oldSize);
		free(ptr);
		return fresh;
	}

	static function writeHeader(p:Int, payload:Int, used:Bool):Void {
		Memory.write32(p + OFF_SIZE, payload);
		Memory.write32(p + OFF_USED, used ? 1 : 0);
	}
}
