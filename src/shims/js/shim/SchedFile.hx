package shim;

/**
	The scheduler's state, JavaScript half: one Int32Array, the words the C++ half keeps in
	`recompsx_sched` (see the cxx twin for why it is an array at all). Its size is
	RECOMPSX_SCHED_WORDS there.
**/
class SchedFile {
	static final f = new js.lib.Int32Array(16);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
