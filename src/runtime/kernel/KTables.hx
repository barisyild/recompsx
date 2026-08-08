package kernel;

import mem.Memory;

/**
	The kernel's own structures, laid out in emulated RAM where games can read them.

	Nothing in this runtime needs them — the dispatch happens natively. Games need them: they call
	`GetB0Table`, walk the result, and sometimes patch an entry to hook a BIOS function. A table
	that does not exist turns that into a read of zero and a jump to nowhere, which is one of the
	harder failures to diagnose from the far end.

	Addresses are the retail ones, from psx-spx "Kernel Memory": the table of tables at 100h, with
	the A0, B0 and C0 dispatch tables at 200h, 874h and 674h. Each entry points into the BIOS
	window at 1FC01000h, one unique stub address per function, so that a game which reads a table
	entry and jumps to it lands somewhere the runtime recognises as a kernel call rather than in
	the middle of its own code.
**/
class KTables {
	static inline var TABLE_OF_TABLES = 0x100;
	static inline var A0_TABLE = 0x200;
	static inline var C0_TABLE = 0x674;
	static inline var B0_TABLE = 0x874;

	/** One stub per function, eight bytes apart, in the BIOS window. */
	public static inline var STUB_BASE = 0x1FC01000;
	static inline var STUB_STRIDE = 8;

	static inline var A0_COUNT = 0xB0;
	static inline var B0_COUNT = 0x60;
	static inline var C0_COUNT = 0x1E;

	public static function init():Void {
		fill(A0_TABLE, 0xA0, A0_COUNT);
		fill(B0_TABLE, 0xB0, B0_COUNT);
		fill(C0_TABLE, 0xC0, C0_COUNT);

		// The table of tables, which is how a game finds the rest.
		Memory.write32(TABLE_OF_TABLES + 0x00, 0);            // ExCB
		Memory.write32(TABLE_OF_TABLES + 0x08, 0);            // PCB
		Memory.write32(TABLE_OF_TABLES + 0x10, 0);            // TCB
		Memory.write32(TABLE_OF_TABLES + 0x20, 0);            // EvCB
	}

	static function fill(table:Int, vector:Int, count:Int):Void {
		for (i in 0...count) Memory.write32(table + (i << 2), stubFor(vector, i));
	}

	/**
		The address a table entry points at.

		Unique per (vector, function) so that a jump through a table entry is identifiable. The
		BIOS window is not executable here, so anything landing there is a kernel call that came in
		by an unusual route — and `Runtime.call` can say so with the number attached.
	**/
	public static function stubFor(vector:Int, fn:Int):Int {
		final v = vector == 0xA0 ? 0 : (vector == 0xB0 ? 1 : 2);
		return STUB_BASE + ((v * 0x100 + fn) * STUB_STRIDE);
	}

	/** The reverse: which kernel call a BIOS-window address means, or -1. */
	public static function callAt(addr:Int):Int {
		final off = (addr - STUB_BASE);
		if (off < 0 || (off % STUB_STRIDE) != 0) return -1;
		else {}
		final index = Std.int(off / STUB_STRIDE);
		if (index >= 0x300) return -1;
		else return index;
	}

	public static function a0Table():Int return A0_TABLE;
	public static function b0Table():Int return B0_TABLE;
	public static function c0Table():Int return C0_TABLE;
}
