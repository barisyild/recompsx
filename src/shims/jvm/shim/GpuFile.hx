package shim;

/** The GPU's hot state, JVM half: one `int[]` (see the cxx twin for why it is an array). */
class GpuFile {
	static final f = new haxe.ds.Vector<Int>(64);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
