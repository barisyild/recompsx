package shim;

/** The scheduler's state, JVM half: one `int[]` (see the cxx twin for why it is an array). */
class SchedFile {
	static final f = new haxe.ds.Vector<Int>(16);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
