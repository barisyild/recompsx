package shim;

/** The GTE's register file, JVM half: one `int[]` (see the cxx twin for why it is an array). */
class GteFile {
	static final f = new haxe.ds.Vector<Int>(128);

	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
