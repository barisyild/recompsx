import cxx.num.Int64;

/**
	Which spellings of 64-bit arithmetic survive the trip through reflaxe.CPP?

	`shim.I64` wants to become a native `int64_t` — SH-4 has `dmuls.l` (32x32 -> 64 in one
	instruction) and `addc`, against the five operations our hand-rolled accumulator spends on a
	carry bit and the four multiplies it spends building a wide product. The obstacle is that
	`cxx.num.Int64` is declared `extern abstract Int64 to Int from Int`, so Haxe's typer resolves
	operators through `to Int` and reflaxe emits 32-bit arithmetic that is widened afterwards —
	silently losing any product that leaves 32 bits.

	This file is the map of what is safe. Nothing is meant to run: the emitted C++ is the answer,
	and `scripts/spike.sh` re-asks the question on every pin change.
**/
extern class N64 {
	@:nativeFunctionCode("(((int64_t)({arg0})) * ((int64_t)({arg1})))")
	public static function mul(a:Int, b:Int):Int64;

	@:nativeFunctionCode("(((int64_t)({arg0})) << 12)")
	public static function shl12(v:Int):Int64;

	@:nativeFunctionCode("((({arg0}) > 0x7FFFFFFFFFFLL) ? 1 : ((({arg0}) < -0x80000000000LL) ? -1 : 0))")
	public static function check44(v:Int64):Int;

	@:nativeFunctionCode("((int64_t)((((uint64_t)({arg0})) & 0xFFFFFFFFFFFULL) << 20) >> 20)")
	public static function wrap44(v:Int64):Int64;
}

class Nat64 {
	public static var acc:Int64 = 0;

	public static function main():Void {
		final a:Int = 0x40000000;
		final b:Int = 4;

		// 1. the naive spelling — the one that LIES
		final naive:Int64 = (a : Int64) * (b : Int64);

		// 2. the spelling we intend to use everywhere instead
		acc = N64.mul(a, b);

		// 3. accumulate: both sides already int64_t
		acc = acc + N64.mul(a, b);

		// 4. state entering an accumulation
		acc = N64.shl12(a);

		// 5. the range check and the 44-bit wrap, both needing >32-bit constants
		final over:Int = N64.check44(acc);
		acc = N64.wrap44(acc);

		// 6. getting results back out — shifts and truncation of a declared int64_t
		final s12:Int = cast(acc >> 12, Int);
		final s16:Int = cast(acc >> 16, Int);
		final low:Int = cast(acc, Int);

		trace(naive, over, s12, s16, low);
	}
}
