package shim;

/**
	The GTE's 44-bit accumulator as a value, on JavaScript: one integer-valued double held in a
	local, never a field.

	`shim.I64` is the same accumulator as a static hi:lo pair, and stays for its fixture and for
	callers that want it. The GTE's operations, though, run three or four multiply-adds on a
	value they then read once, and what those cost on the static pair was the loads and stores
	of two fields per step; a value in a local lives in a register. ADR-0018 measured the double
	as a static field and found it neutral — the boxed field ate the gain; as a local it is the
	representation V8 does best.

	Exactness is the same argument as ADR-0018's: every operation here — add, multiply,
	floor-divide by a power of two, compare — is exact on integers below 2^53 by IEEE-754's
	rules, and the GTE never leaves that domain: 44-bit accumulators wrapped after every step,
	16×16 and 16×17-bit products. The C++ twin is a native `int64_t`, exact everywhere. `GteOps`
	pins the two against each other on every operation.

	The one floating-point type in the portable subset's reach is the private representation
	of this abstract; nothing above it sees anything but Ints and `Acc`.
**/
typedef AccRaw = Float;   // portable-ok: ADR-0021 — integer-valued, exact below 2^53, this file only

abstract Acc(AccRaw) {
	inline function new(v:AccRaw) this = v;
	inline function raw():AccRaw return this;

	public static inline function zero():Acc return new Acc(0);
	/** A sign-extended 32-bit value. */
	public static inline function of(v:Int):Acc return new Acc(v);
	/** `v << 12`, exactly: a translation vector entering an MAC sum. */
	public static inline function shl12(v:Int):Acc return new Acc(v * 4096.0);
	/** Plus a sign-extended 32-bit value. */
	public static inline function add(m:Acc, p:Int):Acc return new Acc(m.raw() + p);
	/** Plus `a * b`, exact below 2^53 — 16×16 or 16×17 bits in every GTE use. */
	public static inline function mac(m:Acc, a:Int, b:Int):Acc return new Acc(m.raw() + 1.0 * a * b);
	/** Outside the 44-bit signed range: +1 above, -1 below, 0 inside. */
	public static inline function check44(m:Acc):Int
		return m.raw() > 8796093022207.0 ? 1 : (m.raw() < -8796093022208.0 ? -1 : 0);
	/** The same for the 32-bit range, which MAC0's flags are defined on. */
	public static inline function check32(m:Acc):Int
		return m.raw() > 2147483647.0 ? 1 : (m.raw() < -2147483648.0 ? -1 : 0);
	/** Truncated to 44 bits, sign-extended from bit 43: the value modulo 2^44 in the signed range. */
	public static inline function wrap44(m:Acc):Acc {
		final t = m.raw() + 8796093022208.0;
		return new Acc(t - js.lib.Math.floor(t / 17592186044416.0) * 17592186044416.0 - 8796093022208.0);
	}
	/** The low 32 bits. */
	public static inline function low32(m:Acc):Int return Std.int(m.raw());
	/** The low 32 bits of the value shifted right by 12. */
	public static inline function shr12(m:Acc):Int return Std.int(js.lib.Math.floor(m.raw() / 4096.0));
	/** The low 32 bits of the value shifted right by 16. */
	public static inline function shr16(m:Acc):Int return Std.int(js.lib.Math.floor(m.raw() / 65536.0));
}
