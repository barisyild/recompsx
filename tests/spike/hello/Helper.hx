package;

// Upstream bug: Sys.println emits std::cout without including <iostream>.
// @:cppInclude is the documented escape hatch; this doubles as a test of that metadata.
@:cppInclude("iostream", true)
class Helper {
	public static function greet(n:Int):Void {
		var i = 0;
		while (i < n) {
			Sys.println("  greeting #" + i);
			i++;
		}
	}

	public static function sum(n:Int):Int {
		var acc = 0;
		var i = 0;
		while (i <= n) { acc += i; i++; }
		return acc;
	}

	// Does Int arithmetic wrap two's-complement? (M0-VERIFY #17 — MIPS semantics depend on it.)
	public static function wrapCheck():Int {
		var x = 0x7FFFFFFF;
		return x + 1; // expect -2147483648
	}

	// Logical vs arithmetic shift, and the unsigned-compare idiom codegen will emit.
	public static function shiftCheck():Int {
		var neg = -1;
		var logical = neg >>> 28;           // expect 15
		var arith = neg >> 28;              // expect -1
		var a = 0x80000000, b = 1;
		var unsignedLess = ((a ^ 0x80000000) < (b ^ 0x80000000)) ? 1 : 0; // expect 0
		return logical * 100 + (arith + 1) * 10 + unsignedLess;           // expect 1500
	}
}
