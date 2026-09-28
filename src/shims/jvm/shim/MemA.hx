package shim;

import shim.RawBuf;

/**
	Aligned 16/32-bit access, JVM half. The other shims cash the alignment promise in for a
	direct load; a `byte[]` has no wider load to give, so these are `RawMem`'s composed accessors
	under the aligned name — the same value by construction. See the cxx twin for the contract.
**/
class MemA {
	/** The C++ shim's branch hint; a condition here is only itself. */
	public static inline function likely(c:Bool):Bool return c;
	public static inline function get16(m:RawBuf, a:Int):Int return RawMem.get16(m, a);
	public static inline function get32(m:RawBuf, a:Int):Int return RawMem.get32(m, a);
	public static inline function set16(m:RawBuf, a:Int, v:Int):Void RawMem.set16(m, a, v);
	public static inline function set32(m:RawBuf, a:Int, v:Int):Void RawMem.set32(m, a, v);
}
