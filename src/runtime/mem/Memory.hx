package mem;

import shim.RawBuf;
import shim.RawMem;

/**
	The emulated address space.

	Every load and store recompiled game code performs arrives here. The design constraints are
	unusually sharp: it must be fast enough that a 33 MHz machine's memory traffic is not the
	bottleneck, identical to the byte on every target, and static — because reflaxe.CPP cannot
	inline an instance method twice in one scope (ADR-0002), and generated code does several
	accesses per function.

	The fast path is one AND and one branch. `p & 0xFF800000` is zero exactly for the 8 MB window
	that holds main RAM and its three mirrors, which is where essentially all traffic goes; the
	scratchpad, the hardware registers and the BIOS window are handled off the hot path.

	Address folding comes first and is free: KUSEG, KSEG0 and KSEG1 are three views of the same
	memory differing only in cacheability, which this emulator does not model, so masking the top
	three bits collapses them. Games rely on that — display lists are commonly built through
	KSEG1 so that writes are visible to the GPU without a cache flush.

	Only RAM and the scratchpad exist so far. Hardware registers, the BIOS window and the bus
	error path arrive with the subsystems that need them.
**/
class Memory {
	public static inline var RAM_SIZE = 0x200000;      // 2 MB
	public static inline var RAM_MASK = 0x1FFFFF;
	public static inline var SCRATCH_SIZE = 0x400;     // 1 KB of fast memory in the CPU
	static inline var SCRATCH_BASE = 0x1F800000;

	public static var ram:RawBuf;
	public static var scratch:RawBuf;

	/** Reads and writes outside anything mapped, counted so a report can mention them. */
	public static var unmappedAccesses:Int = 0;

	public static function init():Void {
		// Zero-filled, deliberately: emulated state must never start from host memory, or the
		// first run differs from the second and every determinism guarantee is void.
		ram = RawMem.alloc(RAM_SIZE);
		scratch = RawMem.alloc(SCRATCH_SIZE);
	}

	/** Strips the segment. The three cached/uncached views collapse to one physical address. */
	public static inline function phys(a:Int):Int return a & 0x1FFFFFFF;

	/** True for the 8 MB window holding RAM and its mirrors — the hot path's test. */
	static inline function isRam(p:Int):Bool return (p & 0xFF800000) == 0;

	// ---- reads ---------------------------------------------------------------------------------

	public static inline function read8u(a:Int):Int {
		final p = phys(a);
		return isRam(p) ? RawMem.get8(ram, p & RAM_MASK) : slowRead8(p);
	}

	public static inline function read8s(a:Int):Int {
		return (read8u(a) << 24) >> 24;
	}

	public static inline function read16u(a:Int):Int {
		final p = phys(a);
		return isRam(p) ? RawMem.get16(ram, p & RAM_MASK) : slowRead16(p);
	}

	public static inline function read16s(a:Int):Int {
		return (read16u(a) << 16) >> 16;
	}

	public static inline function read32(a:Int):Int {
		final p = phys(a);
		return isRam(p) ? RawMem.get32(ram, p & RAM_MASK) : slowRead32(p);
	}

	// ---- writes --------------------------------------------------------------------------------

	public static inline function write8(a:Int, v:Int):Void {
		final p = phys(a);
		if (isRam(p)) RawMem.set8(ram, p & RAM_MASK, v);
		else slowWrite8(p, v);
	}

	public static inline function write16(a:Int, v:Int):Void {
		final p = phys(a);
		if (isRam(p)) RawMem.set16(ram, p & RAM_MASK, v);
		else slowWrite16(p, v);
	}

	public static inline function write32(a:Int, v:Int):Void {
		final p = phys(a);
		if (isRam(p)) RawMem.set32(ram, p & RAM_MASK, v);
		else slowWrite32(p, v);
	}

	// ---- unaligned access ------------------------------------------------------------------------

	/**
		`lwl`/`lwr` and `swl`/`swr`: the MIPS answer to unaligned access.

		A compiler emits them in pairs to move a word at an arbitrary address, each handling the
		part of the word that lies in one aligned word. The merge patterns below are the
		little-endian ones; they are stated as expressions rather than loops because they are
		exactly the four cases, and a table lookup would be slower and no clearer.
	**/
	public static function lwl(a:Int, current:Int):Int {
		final w = read32(a & ~3);
		return switch (a & 3) {
			case 0: (current & 0x00FFFFFF) | (w << 24);
			case 1: (current & 0x0000FFFF) | (w << 16);
			case 2: (current & 0x000000FF) | (w << 8);
			case _: w;
		}
	}

	public static function lwr(a:Int, current:Int):Int {
		final w = read32(a & ~3);
		return switch (a & 3) {
			case 0: w;
			case 1: (current & 0xFF000000) | (w >>> 8);
			case 2: (current & 0xFFFF0000) | (w >>> 16);
			case _: (current & 0xFFFFFF00) | (w >>> 24);
		}
	}

	public static function swl(a:Int, v:Int):Void {
		final aligned = a & ~3;
		final w = read32(aligned);
		write32(aligned, switch (a & 3) {
			case 0: (w & 0xFFFFFF00) | (v >>> 24);
			case 1: (w & 0xFFFF0000) | (v >>> 16);
			case 2: (w & 0xFF000000) | (v >>> 8);
			case _: v;
		});
	}

	public static function swr(a:Int, v:Int):Void {
		final aligned = a & ~3;
		final w = read32(aligned);
		write32(aligned, switch (a & 3) {
			case 0: v;
			case 1: (w & 0x000000FF) | (v << 8);
			case 2: (w & 0x0000FFFF) | (v << 16);
			case _: (w & 0x00FFFFFF) | (v << 24);
		});
	}

	// ---- everything that is not RAM ----------------------------------------------------------

	static inline function isScratch(p:Int):Bool
		return p >= SCRATCH_BASE && p < SCRATCH_BASE + SCRATCH_SIZE;

	static function slowRead8(p:Int):Int {
		if (isScratch(p)) return RawMem.get8(scratch, p - SCRATCH_BASE);
		unmappedAccesses++;
		return 0;
	}

	static function slowRead16(p:Int):Int {
		if (isScratch(p)) return RawMem.get16(scratch, p - SCRATCH_BASE);
		unmappedAccesses++;
		return 0;
	}

	static function slowRead32(p:Int):Int {
		if (isScratch(p)) return RawMem.get32(scratch, p - SCRATCH_BASE);
		unmappedAccesses++;
		return 0;
	}

	static function slowWrite8(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set8(scratch, p - SCRATCH_BASE, v);
		else unmappedAccesses++;
	}

	static function slowWrite16(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set16(scratch, p - SCRATCH_BASE, v);
		else unmappedAccesses++;
	}

	static function slowWrite32(p:Int, v:Int):Void {
		if (isScratch(p)) RawMem.set32(scratch, p - SCRATCH_BASE, v);
		else unmappedAccesses++;
	}

	/** Bulk copy within RAM, for DMA and the kernel's memcpy. */
	public static function copyRam(dst:Int, src:Int, bytes:Int):Void {
		var d = phys(dst) & RAM_MASK;
		var s = phys(src) & RAM_MASK;
		var n = bytes;
		while (n > 0) {
			RawMem.set8(ram, d, RawMem.get8(ram, s));
			d++;
			s++;
			n--;
		}
	}

	/** Loads an image into RAM — a program, or an overlay arriving from the disc. */
	public static function loadInto(addr:Int, src:RawBuf, srcOffset:Int, bytes:Int):Void {
		var d = phys(addr) & RAM_MASK;
		var i = 0;
		while (i < bytes) {
			RawMem.set8(ram, d + i, RawMem.get8(src, srcOffset + i));
			i++;
		}
	}
}
