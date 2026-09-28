package shim;

import haxe.Int64;

/**
	The GTE's 44-bit accumulator as a value, JVM half: a native `long` in a local, as the C++ twin
	holds an `int64_t`. The same API as the JavaScript twin, which holds an exact double; see it
	for why a value beats the static pair. `GteOps` pins the targets against each other.
**/
abstract Acc(Int64) {
	static final MAX44:Int64 = Int64.make(0x7FF, 0xFFFFFFFF);
	static final MIN44:Int64 = Int64.make(-0x800, 0);
	static final MAX32:Int64 = Int64.make(0, 0x7FFFFFFF);
	static final MIN32:Int64 = Int64.make(-1, 0x80000000);

	inline function new(v:Int64) this = v;
	inline function raw():Int64 return this;

	public static inline function zero():Acc return new Acc(Int64.ofInt(0));
	/** A sign-extended 32-bit value. */
	public static inline function of(v:Int):Acc return new Acc(Int64.ofInt(v));
	/** `v << 12`, exactly: a translation vector entering an MAC sum. */
	public static inline function shl12(v:Int):Acc return new Acc(Int64.ofInt(v) << 12);
	/** Plus a sign-extended 32-bit value. */
	public static inline function add(m:Acc, p:Int):Acc return new Acc(m.raw() + Int64.ofInt(p));
	/** Plus `a * b`, exactly. */
	public static inline function mac(m:Acc, a:Int, b:Int):Acc return new Acc(m.raw() + Int64.ofInt(a) * Int64.ofInt(b));
	/** Outside the 44-bit signed range: +1 above, -1 below, 0 inside. */
	public static inline function check44(m:Acc):Int return m.raw() > MAX44 ? 1 : (m.raw() < MIN44 ? -1 : 0);
	/** The same for the 32-bit range, which MAC0's flags are defined on. */
	public static inline function check32(m:Acc):Int return m.raw() > MAX32 ? 1 : (m.raw() < MIN32 ? -1 : 0);
	/** Truncated to 44 bits, sign-extended from bit 43. */
	public static inline function wrap44(m:Acc):Acc return new Acc((m.raw() << 20) >> 20);
	/** The low 32 bits. */
	public static inline function low32(m:Acc):Int return m.raw().low;
	/** The low 32 bits of the value shifted right by 12. */
	public static inline function shr12(m:Acc):Int return (m.raw() >> 12).low;
	/** The low 32 bits of the value shifted right by 16. */
	public static inline function shr16(m:Acc):Int return (m.raw() >> 16).low;
}
