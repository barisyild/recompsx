package shim;

import shim.RawBuf;

/**
	The JavaScript twin of the C++ arena. There is no pointer-versus-array distinction to make on
	this target — a typed array is a typed array, and its base never costs a load — so these are
	plain accessors over buffers allocated once when the class initialises. The shape exists so
	runtime code can say the same thing on both targets; the reason the C++ side needs it at all
	is measured and written down in `src/shims/cxx/native/recompsx_arena.h`.
**/
class Arena {
	static var _ram:RawBuf = RawMem.alloc(0x200000);
	static var _scratch:RawBuf = RawMem.alloc(0x400);

	public static inline function ram():RawBuf return _ram;
	public static inline function scratch():RawBuf return _scratch;
}
