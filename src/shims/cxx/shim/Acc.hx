package shim;

/**
	The GTE's 44-bit accumulator as a value, C++ half: a native `int64_t` in a local. The same
	API as the JavaScript twin, which holds an exact double; the spellings below are the ones
	`shim.I64`'s native accumulator already uses, so nothing here is untested C++ — only its
	arrangement. See the JavaScript twin for why a value beats the static pair.
**/
abstract Acc(cxx.num.Int64) {
	inline function new(v:cxx.num.Int64) this = v;
	inline function raw():cxx.num.Int64 return this;

	public static inline function zero():Acc return new Acc(NA64.ext(0));
	public static inline function of(v:Int):Acc return new Acc(NA64.ext(v));
	public static inline function shl12(v:Int):Acc return new Acc(NA64.shl12(v));
	public static inline function add(m:Acc, p:Int):Acc return new Acc(m.raw() + NA64.ext(p));
	public static inline function mac(m:Acc, a:Int, b:Int):Acc return new Acc(m.raw() + NA64.mul(a, b));
	public static inline function check44(m:Acc):Int return NA64.check44(m.raw());
	public static inline function check32(m:Acc):Int return NA64.check32(m.raw());
	public static inline function wrap44(m:Acc):Acc return new Acc(NA64.wrap44(m.raw()));
	public static inline function low32(m:Acc):Int return NA64.low(m.raw());
	public static inline function shr12(m:Acc):Int return NA64.shr12(m.raw());
	public static inline function shr16(m:Acc):Int return NA64.shr16(m.raw());
}

/** Every placeholder parenthesised: `@:nativeFunctionCode` splices text (golden rule 1). */
private extern class NA64 {
	@:nativeFunctionCode("((int64_t)({arg0}))")
	public static function ext(v:Int):cxx.num.Int64;

	@:nativeFunctionCode("(((int64_t)({arg0})) * ((int64_t)({arg1})))")
	public static function mul(a:Int, b:Int):cxx.num.Int64;

	@:nativeFunctionCode("(((int64_t)({arg0})) << 12)")
	public static function shl12(v:Int):cxx.num.Int64;

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
}
