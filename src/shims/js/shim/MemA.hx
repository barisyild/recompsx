package shim;

import shim.RawBuf;

/**
	Aligned 16/32-bit access, JavaScript half: the typed-array element directly, which is the
	same value the byte-composed `RawMem` accessors produce on a little-endian host — and
	`RawMem` refuses to start on any other, so the two cannot disagree. The type exists so
	runtime code can say "this access is aligned by architecture" in one vocabulary on every
	target; each shim cashes that promise in for a direct load. See the cxx twin for the
	contract. Being a single element access with no branch, it inlines into every guest load and
	store, where the `LE` test and the alignment test used to sit.
**/
class MemA {
	public static inline function get16(m:RawBuf, a:Int):Int return m.u16[a >> 1];
	public static inline function get32(m:RawBuf, a:Int):Int return m.i32[a >> 2];
	public static inline function set16(m:RawBuf, a:Int, v:Int):Void m.u16[a >> 1] = v;
	public static inline function set32(m:RawBuf, a:Int, v:Int):Void m.i32[a >> 2] = v;
}
