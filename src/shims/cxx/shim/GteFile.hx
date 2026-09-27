package shim;

/**
	The GTE's register file, C++ half: one word per register in `recompsx_gte`, a link-time array
	beside emulated RAM (`native/recompsx_arena.h`).

	Named static fields were one global each, and on the SH-4 a global is an address loaded from
	the literal pool before the load or store itself — RTPS read some thirty of them. An element
	of one array is its base, which the compiler keeps in a register for the whole command, plus
	a displacement: the first sixteen words are one instruction away, the rest two. Indices are
	constants at every use, and the array is its own object, so the compiler can keep an element
	in a machine register as freely as it kept a field.

	Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1).
**/
@:include("recompsx_arena.h", true)
extern class GteFile {
	@:nativeFunctionCode("(recompsx_gte[({arg0})])")
	public static function get(i:Int):Int;

	@:nativeFunctionCode("(recompsx_gte[({arg0})] = ({arg1}))")
	public static function set(i:Int, v:Int):Void;
}
