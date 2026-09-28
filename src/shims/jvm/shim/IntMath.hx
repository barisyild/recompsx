package shim;

import haxe.Int64;

/**
	Integer arithmetic that behaves identically on every target; see the C++ shim for the rules.

	On the JVM an `Int` is a Java `int`: `*` is a wrapping 32-bit multiply and `%` the truncated
	remainder, which is what MIPS, `-fwrapv` C++ and JavaScript's `Math.imul`/`| 0` give. Division
	goes through a `long` (`haxe.Int64` is one here), because Haxe types `Int / Int` as a float;
	the quotient's low word is the truncated 32-bit one, INT_MIN / -1 included. Java throws on a
	zero divisor where C++ traps, and `core.Ops` handles both cases before calling here.
**/
class IntMath {
	public static inline function div(a:Int, b:Int):Int return (Int64.ofInt(a) / Int64.ofInt(b)).low;

	public static inline function mod(a:Int, b:Int):Int return a % b;

	public static inline function mul(a:Int, b:Int):Int return a * b;

	public static inline function divPow2Trunc(a:Int, shift:Int):Int
		return a < 0 ? -((-a) >> shift) : (a >> shift);

	/** Leading zero bits of the 32-bit pattern; 32 for zero. */
	public static inline function clz32(a:Int):Int return java.lang.Integer.numberOfLeadingZeros(a);
}
