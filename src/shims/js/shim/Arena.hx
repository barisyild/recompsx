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

	/** Where a span index (mem.Memory.span) enters the scratchpad: mem.Memory.SCRATCH_OFFSET, the
	    C arena's RECOMPSX_SCRATCH_OFFSET. There the two are one array; here, two buffers. */
	static inline var SCRATCH_AT = 0x2000A0;

	public static inline function spanGet8(i:Int):Int
		return i >= SCRATCH_AT ? RawMem.get8(_scratch, i - SCRATCH_AT) : RawMem.get8(_ram, i);

	public static inline function spanGet16(i:Int):Int
		return i >= SCRATCH_AT ? MemA.get16(_scratch, i - SCRATCH_AT) : MemA.get16(_ram, i);

	public static inline function spanGet32(i:Int):Int
		return i >= SCRATCH_AT ? MemA.get32(_scratch, i - SCRATCH_AT) : MemA.get32(_ram, i);

	public static inline function spanSet8(i:Int, v:Int):Void {
		if (i >= SCRATCH_AT) RawMem.set8(_scratch, i - SCRATCH_AT, v);
		else RawMem.set8(_ram, i, v);
	}

	public static inline function spanSet16(i:Int, v:Int):Void {
		if (i >= SCRATCH_AT) MemA.set16(_scratch, i - SCRATCH_AT, v);
		else MemA.set16(_ram, i, v);
	}

	public static inline function spanSet32(i:Int, v:Int):Void {
		if (i >= SCRATCH_AT) MemA.set32(_scratch, i - SCRATCH_AT, v);
		else MemA.set32(_ram, i, v);
	}

	// A span as such (shim.Span): here its index, -1 for none (the cxx twin keeps an address).
	public static inline function spanAt(i:Int):Span return i;
	public static inline function spanNone():Span return -1;
	public static inline function spanOk(s:Span):Bool return s >= 0;
	public static inline function spanIndex(s:Span):Int return s;
	public static inline function spanRead8(s:Span, k:Int):Int return spanGet8(s + k);
	public static inline function spanRead16(s:Span, k:Int):Int return spanGet16(s + k);
	public static inline function spanRead32(s:Span, k:Int):Int return spanGet32(s + k);
	public static inline function spanWrite8(s:Span, k:Int, v:Int):Void spanSet8(s + k, v);
	public static inline function spanWrite16(s:Span, k:Int, v:Int):Void spanSet16(s + k, v);
	public static inline function spanWrite32(s:Span, k:Int, v:Int):Void spanSet32(s + k, v);
}
