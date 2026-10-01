package shim;

/** The root counters' state, JVM half: one `int[]` (see the cxx twin for why it is an array). */
class TimerFile {
	static final f = new haxe.ds.Vector<Int>(40);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
