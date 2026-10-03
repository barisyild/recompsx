package shim;

/** The GPU's hot state, JVM half: one `int[]` (see the cxx twin for why it is an array). */
class GpuFile {
	static final f = new haxe.ds.Vector<Int>(64);
	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;

	/** The polygon core is the SH-4's (ADR-0047): here the C form draws every packet. */
	public static inline function poly(ram:RawBuf, at:Int, op:Int, second:Int):Int return 1;
	public static inline function polyChecked(op:Int):Void {}
}
