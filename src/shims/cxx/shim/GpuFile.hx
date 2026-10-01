package shim;

/**
	The GPU's hot state, C++ half: one word per variable in `recompsx_gpu`, a link-time array beside
	the GTE's register file (`native/recompsx_arena.h`), for the same reason (see GteFile): on the
	SH-4 every static is an address loaded from the literal pool before the access itself, and the
	triangle path (`gpu.Gpu.polygonHw` with its inlined helpers) read some forty of them per
	primitive. An element of one array is a base the compiler keeps in a register plus a
	displacement — the first sixteen words one instruction away. Indices are constants at every use.

	Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1).
**/
@:include("recompsx_arena.h", true)
extern class GpuFile {
	@:nativeFunctionCode("(recompsx_gpu[({arg0})])")
	public static function get(i:Int):Int;

	@:nativeFunctionCode("(recompsx_gpu[({arg0})] = ({arg1}))")
	public static function set(i:Int, v:Int):Void;
}
