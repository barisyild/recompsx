class Ovf {
	public static function main():Void {
		// MIPS addu wraps. Does Haxe Int addition wrap on this target?
		var a = 0x7FFFFFFF;
		var b = 1;
		var sum = a + b;
		trace("0x7FFFFFFF + 1     = " + sum + "   (MIPS/C++ give -2147483648)");

		var big = 0x40000000;
		var sum2 = big + big;
		trace("0x40000000 * 2     = " + sum2 + "   (MIPS/C++ give -2147483648)");

		// The portable fix: | 0 is a no-op on wrapping targets and forces wrapping on JS
		trace("(0x7FFFFFFF + 1)|0 = " + ((a + b) | 0));
		trace("(0x40000000+..)|0  = " + ((big + big) | 0));

		// Subtraction and negation too
		var neg = -0x80000000;
		trace("-0x80000000 - 1    = " + (neg - 1) + "   (MIPS/C++ give 2147483647)");
		trace("(-0x80000000-1)|0  = " + ((neg - 1) | 0));

		// Shift left overflow
		trace("0x00FFFFFF << 8    = " + (0x00FFFFFF << 8));
	}
}
