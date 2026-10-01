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

	// A span's index (mem.Memory.span) into the one array RAM and the scratchpad share: RAM at 0,
	// the scratchpad at mem.Memory.SCRATCH_OFFSET (RECOMPSX_SCRATCH_OFFSET). The same widths and
	// casts as MemA's and RawMem's accesses to either, so a span access is the fast path's own.
	@:nativeFunctionCode("((int)(*(((unsigned char*)&recompsx_mem) + ({arg0}))))")
	public static function spanGet8(i:Int):Int;

	@:nativeFunctionCode("((int)(*((unsigned short*)(((unsigned char*)&recompsx_mem) + ({arg0})))))")
	public static function spanGet16(i:Int):Int;

	@:nativeFunctionCode("(*((int*)(((unsigned char*)&recompsx_mem) + ({arg0}))))")
	public static function spanGet32(i:Int):Int;

	@:nativeFunctionCode("((void)(*(((unsigned char*)&recompsx_mem) + ({arg0})) = ((unsigned char)({arg1}))))")
	public static function spanSet8(i:Int, v:Int):Void;

	@:nativeFunctionCode("((void)(*((unsigned short*)(((unsigned char*)&recompsx_mem) + ({arg0}))) = ((unsigned short)({arg1}))))")
	public static function spanSet16(i:Int, v:Int):Void;

	@:nativeFunctionCode("((void)(*((int*)(((unsigned char*)&recompsx_mem) + ({arg0}))) = ({arg1})))")
	public static function spanSet32(i:Int, v:Int):Void;

	// A span as such (shim.Span): the arena's address at index `i`, null for none. Each access
	// through one is its address plus the access's offset, so the compiler addresses the run from
	// one register (see Span). The widths and casts are spanGet's and spanSet's.
	@:nativeFunctionCode("(((unsigned char*)&recompsx_mem) + ({arg0}))")
	public static function spanAt(i:Int):Span;

	@:nativeFunctionCode("((unsigned char*)0)")
	public static function spanNone():Span;

	@:nativeFunctionCode("((({arg0})) != 0)")
	public static function spanOk(s:Span):Bool;

	@:nativeFunctionCode("((int)((({arg0})) - ((unsigned char*)&recompsx_mem)))")
	public static function spanIndex(s:Span):Int;

	@:nativeFunctionCode("((int)(*(({arg0}) + ({arg1}))))")
	public static function spanRead8(s:Span, k:Int):Int;

	@:nativeFunctionCode("((int)(*((unsigned short*)(({arg0}) + ({arg1})))))")
	public static function spanRead16(s:Span, k:Int):Int;

	@:nativeFunctionCode("(*((int*)(({arg0}) + ({arg1}))))")
	public static function spanRead32(s:Span, k:Int):Int;

	@:nativeFunctionCode("((void)(*(({arg0}) + ({arg1})) = ((unsigned char)({arg2}))))")
	public static function spanWrite8(s:Span, k:Int, v:Int):Void;

	@:nativeFunctionCode("((void)(*((unsigned short*)(({arg0}) + ({arg1}))) = ((unsigned short)({arg2}))))")
	public static function spanWrite16(s:Span, k:Int, v:Int):Void;

	@:nativeFunctionCode("((void)(*((int*)(({arg0}) + ({arg1}))) = ({arg2})))")
	public static function spanWrite32(s:Span, k:Int, v:Int):Void;
}
