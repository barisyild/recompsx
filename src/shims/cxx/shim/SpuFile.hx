package shim;

/**
	The SPU's per-voice state, C++ half: one word per value in `recompsx_spu`, a link-time array
	beside the GTE's and the GPU's register files (`native/recompsx_arena.h`). As `Array<Int>`s each
	of the twenty-one per-voice tables was a shared pointer to a vector — three dependent loads for
	an element on every access, and the voice sync at every batch (`spu.Spu.syncVoices`) read twelve
	of them for each of 24 voices. Here an element is one base the compiler keeps in a register plus
	an index (spu.Spu.SpuArray names each table's offset).

	Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1).
**/
@:include("recompsx_arena.h", true)
extern class SpuFile {
	@:nativeFunctionCode("(recompsx_spu[({arg0})])")
	public static function get(i:Int):Int;

	@:nativeFunctionCode("(recompsx_spu[({arg0})] = ({arg1}))")
	public static function set(i:Int, v:Int):Void;
}
