package shim;

/**
	A 64-bit signed accumulator, built out of two Ints.

	The GTE is why this exists. Its matrix operations accumulate into 44-bit registers and set
	overflow flags on the *intermediate* value after every single multiply-add, so the arithmetic
	cannot be done in 32 bits and cannot be done approximately: a game reads those flags and
	changes what it draws. `docs/specs/backend.md` §4 names this module and ADR-0004 fixes its
	shape — hand-rolled hi:lo pairs, never `haxe.Int64`, which allocates an object per intermediate
	on both of this project's targets and measured six times slower on exactly this workload.

	**One accumulator, not a value type.** Every operation reads and writes the same two static
	fields. That is not a limitation to work around: a value type would mean allocation or copying
	per intermediate, which is the cost this design exists to avoid, and the GTE's use is strictly
	sequential — set, accumulate three or four products, test, shift, store. Nothing nests. The
	one place that needed a second 64-bit value at the same time is `mulShr16Round`, which keeps
	its own locals rather than a second accumulator.

	`hi` holds bits 63..32 as a signed Int; `lo` holds bits 31..0 and is read as *unsigned* by
	every operation here, which is why the carry logic is explicit rather than a comparison.

	**This file is duplicated byte-for-byte in `src/shims/cxx/shim/I64.hx`.** It is a shim so that
	the C++ side can one day be `int64_t` — where the whole of this becomes one machine
	instruction — without the runtime changing. Until that happens the two copies must stay
	identical, and `tests/conformance/Acc64.hx` is what says they are: it runs on both targets and
	their digests must match.
**/
class I64 {
	/** The accumulator itself. A declared `int64_t` — which is the one context where the type
	    survives, as the spike shows. */
	public static var acc:cxx.num.Int64 = 0;

	/** Bits 63..32, signed. A property now, because the storage is no longer split — and
	    writable because `tests/conformance/Acc64.hx` builds its cases by setting the words
	    directly, and the gate is not something to bend so that it passes. */
	public static var hi(get, set):Int;
	static inline function get_hi():Int return N64.high(acc);
	static inline function set_hi(v:Int):Int {
		acc = N64.pair(v, N64.low(acc));
		return v;
	}

	/** Bits 31..0, read as unsigned by every operation here. */
	public static var lo(get, set):Int;
	static inline function get_lo():Int return N64.low(acc);
	static inline function set_lo(v:Int):Int {
		acc = N64.pair(N64.high(acc), v);
		return v;
	}

	/** The accumulator becomes a sign-extended 32-bit value. */
	public static inline function set(v:Int):Void acc = N64.ext(v);

	public static inline function setZero():Void acc = N64.ext(0);

	/** The accumulator becomes `v << 12`, exactly — how a translation vector enters an MAC
	    accumulation, and a shift that leaves 32 bits for any v past 2^19. */
	public static inline function setShl12(v:Int):Void acc = N64.shl12(v);

	/** Adds a sign-extended 32-bit value. */
	public static inline function addSmall(p:Int):Void acc = acc + N64.ext(p);

	/** Accumulates `a * b`. The narrow and wide cases are the same instruction now, so the
	    distinction the hand-rolled version had to make — four multiplies or one — is gone. */
	public static inline function addProduct16(a:Int, b:Int):Void acc = acc + N64.mul(a, b);

	public static inline function addProductWide(a:Int, b:Int):Void acc = acc + N64.mul(a, b);

	/** Adds a 64-bit value given as a high word and an unsigned low word. */
	public static inline function addPair(ahi:Int, alo:Int):Void acc = acc + N64.pair(ahi, alo);

	/** Whether the accumulator has left the 44-bit signed range: +1 above, -1 below, 0 inside. */
	public static inline function check44():Int return N64.check44(acc);

	/** The same question for 32 bits, which is what MAC0 is judged against. */
	public static inline function check32():Int return N64.check32(acc);

	/** Truncates to 44 bits, sign-extending from bit 43. The hardware wraps rather than
	    saturating, and the flag is the only record that it happened. */
	public static inline function wrap44():Void acc = N64.wrap44(acc);

	public static inline function low32():Int return N64.low(acc);
	public static inline function shr12():Int return N64.shr12(acc);
	public static inline function shr16():Int return N64.shr16(acc);

	/** `(a * b + 0x8000) >> 16` in full precision — the last step of the GTE's division, where
	    a 17-bit quotient estimate times an 18-bit divisor genuinely exceeds 32 bits. Kept off the
	    accumulator so it can be called while an accumulation is in progress. */
	public static inline function mulShr16Round(a:Int, b:Int):Int return N64.mulRound(a, b);
}

/**
	The spellings themselves. Placeholders are parenthesised by hand because `@:nativeFunctionCode`
	splices its arguments as raw text (golden rule 1), and the 64-bit constants carry `LL`/`ULL`
	suffixes because a bare literal past 2^31 is not one on a 32-bit target.
**/
private extern class N64 {
	@:nativeFunctionCode("((int64_t)({arg0}))")
	public static function ext(v:Int):cxx.num.Int64;

	@:nativeFunctionCode("(((int64_t)({arg0})) * ((int64_t)({arg1})))")
	public static function mul(a:Int, b:Int):cxx.num.Int64;

	@:nativeFunctionCode("(((int64_t)({arg0})) << 12)")
	public static function shl12(v:Int):cxx.num.Int64;

	@:nativeFunctionCode("((((int64_t)({arg0})) << 32) | ((int64_t)((uint32_t)({arg1}))))")
	public static function pair(ahi:Int, alo:Int):cxx.num.Int64;

	@:nativeFunctionCode("((int)(({arg0}) >> 32))")
	public static function high(v:cxx.num.Int64):Int;

	@:nativeFunctionCode("((int)({arg0}))")
	public static function low(v:cxx.num.Int64):Int;

	@:nativeFunctionCode("((int)(({arg0}) >> 12))")
	public static function shr12(v:cxx.num.Int64):Int;

	@:nativeFunctionCode("((int)(({arg0}) >> 16))")
	public static function shr16(v:cxx.num.Int64):Int;

	@:nativeFunctionCode("((({arg0}) > 0x7FFFFFFFFFFLL) ? 1 : ((({arg0}) < -0x80000000000LL) ? -1 : 0))")
	public static function check44(v:cxx.num.Int64):Int;

	@:nativeFunctionCode("((({arg0}) > 0x7FFFFFFFLL) ? 1 : ((({arg0}) < -0x80000000LL) ? -1 : 0))")
	public static function check32(v:cxx.num.Int64):Int;

	@:nativeFunctionCode("((int64_t)(((uint64_t)(({arg0}) & 0xFFFFFFFFFFFLL)) << 20) >> 20)")
	public static function wrap44(v:cxx.num.Int64):cxx.num.Int64;

	@:nativeFunctionCode("((int)((((int64_t)({arg0})) * ((int64_t)({arg1})) + 0x8000LL) >> 16))")
	public static function mulRound(a:Int, b:Int):Int;
}
