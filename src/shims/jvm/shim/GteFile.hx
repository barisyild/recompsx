package shim;

/** The GTE's register file, JVM half: one `int[]` (see the cxx twin for why it is an array). */
class GteFile {
	static final f = new haxe.ds.Vector<Int>(656);

	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;

	/** A matrix row times a vector, three signed halfwords by three (see the cxx twin). */
	public static inline function dot3(m:Int, v:Int):Int {
		return (IntMath.mul(half(m), half(v)) + IntMath.mul(half(m + 1), half(v + 1))
			+ IntMath.mul(half(m + 2), half(v + 2))) | 0;
	}

	static inline function half(h:Int):Int return (f[h >> 1] << (16 - ((h & 1) << 4))) >> 16;
}
