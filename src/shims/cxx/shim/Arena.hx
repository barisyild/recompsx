package shim;

import shim.RawBuf;

/**
	The emulated machine's memories as link-time constants rather than pointers.

	Every call here compiles to the bare name of a C array, which is an address the linker fixes —
	so `Arena.ram()` inside a generated memory access becomes a literal, not a load of a load.
	The rationale, with the measurement behind it, is in `native/recompsx_arena.h`; the short
	version is that a pointer costs two dependent loads per access and cannot be held in a
	register across stores, and an array costs neither.

	These are functions rather than variables on purpose: a variable would be a pointer again.
**/
@:include("recompsx_arena.h", true)
extern class Arena {
	@:nativeFunctionCode("(recompsx_ram)")
	public static function ram():RawBuf;

	@:nativeFunctionCode("(recompsx_scratch)")
	public static function scratch():RawBuf;
}
