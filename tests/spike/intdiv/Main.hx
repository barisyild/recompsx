package;

// (b) the mechanism reflaxe.CPP's own std uses for native operations
extern class NativeOps {
	@:nativeFunctionCode("(({arg0}) / ({arg1}))")
	public static function div(a:Int, b:Int):Int;
	@:nativeFunctionCode("(({arg0}) * ({arg1}))")
	public static function mul(a:Int, b:Int):Int;
	// Same template WITHOUT inner parens, to find out whether the substitution protects us.
	@:nativeFunctionCode("({arg0} / {arg1})")
	public static function divUnsafe(a:Int, b:Int):Int;
}

class Main {
	public static function main():Void {
		final y = 7, h = 5;

		// (a) reflaxe's configurable injection, parenthesised by hand
		final a:Int = untyped __cpp__("(({0}) / ({1}))", y * 31, h - 1);

		// (b) @:nativeFunctionCode on an extern — does IT parenthesise arguments?
		final b:Int = NativeOps.div(y * 31, h - 1);

		// (c) plain portable Haxe, no injection anywhere
		final c:Int = Std.int((y * 31) / (h - 1));

		trace("expected 54 (217/4):");
		trace("  (a) __cpp__            = " + a);
		trace("  (b) nativeFunctionCode = " + b);
		trace("  (c) Std.int(a/b)       = " + c);

		// negative operands: C++ and MIPS both truncate toward zero
		trace("expected -3 (-7/2):");
		trace("  (a) = " + (untyped __cpp__("(({0}) / ({1}))", -7, 2) : Int));
		trace("  (b) = " + NativeOps.div(-7, 2));
		trace("  (c) = " + Std.int(-7 / 2));

		// wrapping multiply
		trace("does nativeFunctionCode parenthesise for us? expected 54:");
		trace("  divUnsafe(7*31, 5-1) = " + NativeOps.divUnsafe(y * 31, h - 1));

		trace("expected -2 (0x7FFFFFFF*2 wrapped):");
		trace("  (b) = " + NativeOps.mul(0x7FFFFFFF, 2));
	}
}
