package shim;

import shim.RawBuf;

/**
	Aligned 16/32-bit access, JavaScript half. Deliberately identical to the byte-composed
	`RawMem` accessors: JS is the reference target (ADR-0003) and its behaviour must not move
	when a native target grows a fast path. The type exists so runtime code can say "this access
	is aligned by architecture" in one vocabulary on every target; only the C++ shim cashes that
	promise in for a direct load. See the cxx twin for the full contract.
**/
class MemA {
	public static inline function get16(m:RawBuf, a:Int):Int return RawMem.get16(m, a);
	public static inline function get32(m:RawBuf, a:Int):Int return RawMem.get32(m, a);
	public static inline function set16(m:RawBuf, a:Int, v:Int):Void RawMem.set16(m, a, v);
	public static inline function set32(m:RawBuf, a:Int, v:Int):Void RawMem.set32(m, a, v);
}
