package shim;

/**
	The GTE's register file, JavaScript half: one Int32Array, the words the C++ half keeps in
	`recompsx_gte`. The indices are constants at every use (see the cxx twin for why the file is
	an array at all).
**/
class GteFile {
	static final f = new js.lib.Int32Array(656);

	public static inline function get(i:Int):Int return f[i];
	public static inline function set(i:Int, v:Int):Void f[i] = v;

	/** A matrix row times a vector, three signed halfwords by three (see the cxx twin): halfword h
	    is word h >> 1's low half for an even h, its high half for an odd one. */
	public static inline function dot3(m:Int, v:Int):Int {
		return (IntMath.mul(half(m), half(v)) + IntMath.mul(half(m + 1), half(v + 1))
			+ IntMath.mul(half(m + 2), half(v + 2))) | 0;
	}

	static inline function half(h:Int):Int return (f[h >> 1] << (16 - ((h & 1) << 4))) >> 16;
}
