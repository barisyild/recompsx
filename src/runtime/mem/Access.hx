package mem;

import shim.RawMem;

/**
	The part of every guest load and store that runs inline at its call site on C++: RAM and the
	scratchpad — a mask, a compare and the access for RAM, a second mask and compare for the
	scratchpad. The ports go out of line, to `Memory`'s `slow` functions (noinline), and
	`Memory`, which owns the address map, forwards its own accessors here: they are the API the
	emitter and the runtime call.

	A class of its own, header-only (`@:headerOnly`), because that is where reflaxe.CPP puts a
	function body, and a body is what another translation unit needs to inline it: every
	generated shard is one. `@:cppInline` with `always_inline` then makes GCC take it at all
	~51,000 sites of Crash Bandicoot: Warped.

	The scratchpad is inline because games put their hottest data there, and it is general, not
	one game's habit: in 300 vblanks Crash 3 made 7.1 M of its 17.1 M accesses to it (a base
	register holding 1F800000h), Crash Bash 13.3 M of 64 M in 1500 (its stack). Out of line it
	cost a call, and GCC had inlined the port handlers into that call, so every scratchpad access
	also paid their prologue.

	On JavaScript these are plain functions, one call per access as before: the bundle's size is
	what ADR-0013 keeps accessors out of generated bodies for.

	The RAM test carries `MemA.likely`, GCC's `__builtin_expect`. Without it GCC made the port
	call the fall-through of every inlined access and put the RAM load out of line: a branch
	away, the load, a branch back — two taken branches for the commonest thing guest code does.
	Crash 3's hottest function showed it at every `lw`; a 4-load block compiles 16 % smaller with
	the hint. The scratchpad keeps its place as the second test.
**/
@:headerOnly
@:headerCode("#include \"recompsx_arena.h\"")
class Access {
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function read8u(a:Int):Int {
		final r = Memory.phys(a) & Memory.RAM_DECODE_MASK;
		if (shim.MemA.likely(r < Memory.RAM_SIZE)) return RawMem.get8(Memory.ram(), r);
		else if ((a & Memory.SCRATCH_MATCH_MASK) == Memory.SCRATCH_BASE)
			return RawMem.get8(Memory.scratch(), a & (Memory.SCRATCH_SIZE - 1));
		else return Memory.slowRead8(Memory.phys(a));
	}

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function read16u(a:Int):Int {
		final r = Memory.phys(a) & Memory.RAM_DECODE_MASK;
		if (shim.MemA.likely(r < Memory.RAM_SIZE)) return shim.MemA.get16(Memory.ram(), r);
		else if ((a & Memory.SCRATCH_MATCH_MASK) == Memory.SCRATCH_BASE)
			return shim.MemA.get16(Memory.scratch(), a & (Memory.SCRATCH_SIZE - 1));
		else return Memory.slowRead16(Memory.phys(a));
	}

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function read32(a:Int):Int {
		final r = Memory.phys(a) & Memory.RAM_DECODE_MASK;
		if (shim.MemA.likely(r < Memory.RAM_SIZE)) return shim.MemA.get32(Memory.ram(), r);
		else if ((a & Memory.SCRATCH_MATCH_MASK) == Memory.SCRATCH_BASE)
			return shim.MemA.get32(Memory.scratch(), a & (Memory.SCRATCH_SIZE - 1));
		else return Memory.slowRead32(Memory.phys(a));
	}

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function write8(a:Int, v:Int):Void {
		final r = Memory.phys(a) & Memory.RAM_DECODE_MASK;
		if (shim.MemA.likely(r < Memory.RAM_SIZE)) RawMem.set8(Memory.ram(), r, v);
		else if ((a & Memory.SCRATCH_MATCH_MASK) == Memory.SCRATCH_BASE)
			RawMem.set8(Memory.scratch(), a & (Memory.SCRATCH_SIZE - 1), v);
		else Memory.slowWrite8(Memory.phys(a), v);
	}

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function write16(a:Int, v:Int):Void {
		final r = Memory.phys(a) & Memory.RAM_DECODE_MASK;
		if (shim.MemA.likely(r < Memory.RAM_SIZE)) shim.MemA.set16(Memory.ram(), r, v);
		else if ((a & Memory.SCRATCH_MATCH_MASK) == Memory.SCRATCH_BASE)
			shim.MemA.set16(Memory.scratch(), a & (Memory.SCRATCH_SIZE - 1), v);
		else Memory.slowWrite16(Memory.phys(a), v);
	}

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function write32(a:Int, v:Int):Void {
		final r = Memory.phys(a) & Memory.RAM_DECODE_MASK;
		if (shim.MemA.likely(r < Memory.RAM_SIZE)) shim.MemA.set32(Memory.ram(), r, v);
		else if ((a & Memory.SCRATCH_MATCH_MASK) == Memory.SCRATCH_BASE)
			shim.MemA.set32(Memory.scratch(), a & (Memory.SCRATCH_SIZE - 1), v);
		else Memory.slowWrite32(Memory.phys(a), v);
	}
}
