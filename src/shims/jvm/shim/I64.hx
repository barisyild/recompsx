package shim;

import haxe.Int64;

/**
	The 64-bit signed accumulator, JVM half: one native `long`, which is what `haxe.Int64` is on
	this target — no object per value, unlike JavaScript and C++, where ADR-0004 measured it
	allocating and rejected it. The same API and results as the other shims' `I64`;
	`tests/conformance/Acc64.hx` is what holds them to that.

	`hi` and `lo` are properties over the one value, as in the C++ twin, and writable because
	`Acc64` builds its cases by setting the words directly.
**/
class I64 {
	/** The accumulator itself. */
	public static var acc:Int64 = Int64.ofInt(0);

	static final MAX44:Int64 = Int64.make(0x7FF, 0xFFFFFFFF);
	static final MIN44:Int64 = Int64.make(-0x800, 0);
	static final MAX32:Int64 = Int64.make(0, 0x7FFFFFFF);
	static final MIN32:Int64 = Int64.make(-1, 0x80000000);

	/** Bits 63..32, signed. */
	public static var hi(get, set):Int;
	static inline function get_hi():Int return acc.high;
	static inline function set_hi(v:Int):Int {
		acc = Int64.make(v, acc.low);
		return v;
	}

	/** Bits 31..0, read as unsigned by every operation here. */
	public static var lo(get, set):Int;
	static inline function get_lo():Int return acc.low;
	static inline function set_lo(v:Int):Int {
		acc = Int64.make(acc.high, v);
		return v;
	}

	/** The accumulator becomes a sign-extended 32-bit value. */
	public static inline function set(v:Int):Void acc = Int64.ofInt(v);

	public static inline function setZero():Void acc = Int64.ofInt(0);

	/** The accumulator becomes `v << 12`, exactly. */
	public static inline function setShl12(v:Int):Void acc = Int64.ofInt(v) << 12;

	/** Adds a sign-extended 32-bit value. */
	public static inline function addSmall(p:Int):Void acc = acc + Int64.ofInt(p);

	/** Accumulates `a * b`; narrow and wide are one multiply of two longs here. */
	public static inline function addProduct16(a:Int, b:Int):Void acc = acc + Int64.ofInt(a) * Int64.ofInt(b);

	public static inline function addProductWide(a:Int, b:Int):Void acc = acc + Int64.ofInt(a) * Int64.ofInt(b);

	/** Adds a 64-bit value given as a high word and an unsigned low word. */
	public static inline function addPair(ahi:Int, alo:Int):Void acc = acc + Int64.make(ahi, alo);

	/** Whether the accumulator has left the 44-bit signed range: +1 above, -1 below, 0 inside. */
	public static inline function check44():Int return acc > MAX44 ? 1 : (acc < MIN44 ? -1 : 0);

	/** The same question for 32 bits, which is what MAC0 is judged against. */
	public static inline function check32():Int return acc > MAX32 ? 1 : (acc < MIN32 ? -1 : 0);

	/** Truncates to 44 bits, sign-extending from bit 43. */
	public static inline function wrap44():Void acc = (acc << 20) >> 20;

	public static inline function low32():Int return acc.low;
	public static inline function shr12():Int return (acc >> 12).low;
	public static inline function shr16():Int return (acc >> 16).low;

	/** `(a * b + 0x8000) >> 16` in full precision — the last step of the GTE's division. */
	public static inline function mulShr16Round(a:Int, b:Int):Int
		return ((Int64.ofInt(a) * Int64.ofInt(b) + Int64.ofInt(0x8000)) >> 16).low;
}
