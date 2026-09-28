package mod;

import shim.RawBuf;
import shim.RawMem;

/**
	Memory for mods beyond the machine's 2 MB (ADR-0033): guest-addressable, owned by no game.

	It sits at physical 1F000000h, the start of expansion region 1 — the parallel port, where a
	cheat cartridge or a development board would answer, and where a retail console has nothing.
	Guest code reaches it as 9F000000h (KSEG0) like any pointer a mod hands it, through the memory
	map's slow path: RAM and the I/O page are decoded before it, so the only accesses that pay for
	the extra test are the ones that would have read nothing at all. DMA cannot reach it (the
	hardware's channels address RAM), so data a game DMAs — ordering tables, primitive lists —
	belongs in guest RAM instead; everything the CPU reads is at home here.

	Only a build with `-D recompsx_mods` decodes it, and only once a mod has asked for it; until
	then the region is as unmapped as it always was.
**/
class ModRam {
	/** Physical base. Guest pointers into it are `KSEG0 | BASE`, 9F000000h. */
	public static inline var BASE = 0x1F000000;

	/**
		The first bytes are left zero. The BIOS looks for a device's "Licensed by Sony" string at
		1F000084h, and a game that probes the port the same way must keep finding nothing.
	**/
	public static inline var RESERVED = 0x100;

	public static var size(default, null) = 0;
	static var buf:RawBuf;

	public static function allocate(bytes:Int):Void {
		buf = RawMem.alloc(bytes);
		size = bytes;
	}

	public static inline function contains(p:Int):Bool return p >= BASE && p < BASE + size;

	public static inline function read8(p:Int):Int return RawMem.get8(buf, p - BASE);

	public static inline function read16(p:Int):Int return RawMem.get16(buf, p - BASE);

	public static inline function read32(p:Int):Int return RawMem.get32(buf, p - BASE);

	public static inline function write8(p:Int, v:Int):Void RawMem.set8(buf, p - BASE, v);

	public static inline function write16(p:Int, v:Int):Void RawMem.set16(buf, p - BASE, v);

	public static inline function write32(p:Int, v:Int):Void RawMem.set32(buf, p - BASE, v);
}
