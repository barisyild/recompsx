package shim;

/**
	The root counters' state, JavaScript half: one Int32Array, the words the C++ half keeps in
	`recompsx_timers` (see the cxx twin for why it is an array at all). Its size is
	RECOMPSX_TIMER_WORDS there.
**/
class TimerFile {
	static final f = new js.lib.Int32Array(40);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;
}
