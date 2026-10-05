package mem;

#if recompsx_fastmem
/**
	Fastmem's way back into the runtime (ADR-0049): the backend's TLB-miss handler, finding a guest
	access to a page the MMU does not map (a port, the BIOS, nothing), emulates it through these —
	the slow paths every target's decode reaches for the same addresses, with the clock the
	generated code stored before the access (shim.P0). `size` is the SH-4 access's: 0 a byte, 1 a
	halfword, 2 a word; loads come back as the SH-4 would have loaded them, sign-extended.

	A Dreamcast build that defines `recompsx_fastmem` for Haxe must define RECOMPSX_FASTMEM for C as
	well, so that the arena is laid out as Memory.SCRATCH_OFFSET says: checked here.
**/
@:cppFileCode("#include \"recompsx_arena.h\"
#include \"mem_Memory.h\"
#if !RECOMPSX_FASTMEM
#error \"recompsx_fastmem (Haxe) needs RECOMPSX_FASTMEM=1 (C): the arena's layout\"
#endif
static_assert(RECOMPSX_SCRATCH_OFFSET == 0x204000, \"Memory.SCRATCH_OFFSET as the arena lays it out\");
extern \"C\" __attribute__((used, externally_visible)) int rx_fm_read(int size, int addr) {
	if (size == 0) return (int)(signed char)mem::Memory::slowRead8(addr);
	else if (size == 1) return (int)(short)mem::Memory::slowRead16(addr);
	else return mem::Memory::slowRead32(addr);
}
extern \"C\" __attribute__((used, externally_visible)) void rx_fm_write(int size, int addr, int v) {
	if (size == 0) mem::Memory::slowWrite8(addr, v);
	else if (size == 1) mem::Memory::slowWrite16(addr, v);
	else mem::Memory::slowWrite32(addr, v);
}
")
class Fastmem {
	/** Referenced from Memory.init, so that the class — and the glue above — is compiled in. */
	public static function keep():Void {}
}
#end
