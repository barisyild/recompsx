package shim;

/**
	The GTE's register file, JavaScript half: one Int32Array, the words the C++ half keeps in
	`recompsx_gte`. The indices are constants at every use (see the cxx twin for why the file is
	an array at all).
**/
class GteFile {
	static final f = new js.lib.Int32Array(128);

	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
