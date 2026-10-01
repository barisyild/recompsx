package shim;

/**
	The GPU's hot state, JavaScript half: one Int32Array, the words the C++ half keeps in
	`recompsx_gpu` (see the cxx twin for why it is an array at all).
**/
class GpuFile {
	static final f = new js.lib.Int32Array(64);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
