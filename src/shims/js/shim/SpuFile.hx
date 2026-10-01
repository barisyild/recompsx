package shim;

/**
	The SPU's per-voice state, JavaScript half: one Int32Array, the words the C++ half keeps in
	`recompsx_spu` (see the cxx twin for why it is an array at all). Its size is
	RECOMPSX_SPU_WORDS there.
**/
class SpuFile {
	static final f = new js.lib.Int32Array(1176);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
