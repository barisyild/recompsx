package shim;

import shim.RawBuf;

/**
	The JVM twin of the C++ arena: plain accessors over buffers allocated once when the class
	initialises, as on JavaScript. The shape exists so runtime code says the same thing on every
	target; why the C++ side needs it is in `src/shims/cxx/native/recompsx_arena.h`.
**/
class Arena {
	static var _ram:RawBuf = RawMem.alloc(0x200000);
	static var _scratch:RawBuf = RawMem.alloc(0x400);

	public static inline function ram():RawBuf return _ram;
	public static inline function scratch():RawBuf return _scratch;
}
