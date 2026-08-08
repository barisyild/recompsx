package;

import cxx.CArray;
import cxx.Ptr;
import cxx.ConstCharPtr;
import cxx.Stdlib;
import cxx.num.UInt8;
import cxx.num.UInt16;
import cxx.num.Int64 as CxxInt64;

// ---- flat C bindings (the shape src/shims/cxx/BackendNative.hx will use) ---------------------
@:include("cstub.h") @:topLevel
extern function stub_log(level:Int, msg:ConstCharPtr):Void;

@:include("cstub.h") @:topLevel
extern function stub_sum_u16(data:Ptr<UInt16>, count:Int):Int;

@:include("cstub.h") @:topLevel
extern function stub_fill_u8(data:Ptr<UInt8>, count:Int, value:Int):Void;

@:include("cstub.h") @:topLevel
extern function stub_mix64(a:CxxInt64, b:CxxInt64):CxxInt64;

// ---- dispatch: FnTable Plan B ----------------------------------------------------------------
// Plan A (an Array of function references) is not viable: reflaxe.CPP lowers `Array<(Int)->Int>`
// to `std::deque<std::shared_ptr<std::function<int(int)>>>` — an allocation and an indirect call
// per entry, and the array literal does not even compile. See PROGRESS.md [M0-VERIFY] #18.
//
// Plan B stores packed Int handles in raw memory and dispatches through a generated switch.
// No function values exist anywhere, so nothing can be heap-allocated or type-erased.
class Dispatch {
	// address -> handle lives in raw memory (Mem is the static-accessor shape).
	static inline var TABLE_BASE = 0x100000;

	public static function init():Void {
		Mem.set32(TABLE_BASE + 0, 0);   // "address 0" -> handle 0
		Mem.set32(TABLE_BASE + 4, 1);   // "address 4" -> handle 1
	}

	public static function callByAddr(addr:Int, x:Int):Int
		return dispatch(Mem.get32(TABLE_BASE + addr), x);

	// The generated per-shard dispatch switch. fnDouble/fnNegate are reachable only from here,
	// which is exactly the DCE question: does -dce full keep them alive?
	static function dispatch(handle:Int, x:Int):Int {
		return switch (handle) {
			case 0: fnDouble(x);
			case 1: fnNegate(x);
			default: 0;
		}
	}

	static function fnDouble(x:Int):Int return x * 2;
	static function fnNegate(x:Int):Int return -x;
}

class Verify {
	static var failures = 0;

	static function check(name:String, actual:Int, expected:Int):Void {
		if (actual == expected) {
			trace('  ok   $name = $actual');
		} else {
			trace('  FAIL $name = $actual, expected $expected');
			failures++;
		}
	}

	public static function main():Void {
		trace("=== M0-VERIFY spike ===");

		// #6 raw memory: 2 MB allocation, unchecked indexing, byte-composed accessors
		Mem.alloc(2 * 1024 * 1024);
		Mem.set32(0x1000, 0xDEADBEEF);
		check("get32 roundtrip", Mem.get32(0x1000), 0xDEADBEEF);
		check("get8 low byte", Mem.get8(0x1000), 0xEF);
		check("get8 high byte", Mem.get8(0x1003), 0xDE);
		check("get16 low half", Mem.get16(0x1000), 0xBEEF);
		check("zero init", Mem.get32(0x2000), 0);

		// hot-loop shape: 1M accesses, the pattern generated code will emit constantly
		var acc = 0;
		var i = 0;
		while (i < 1000000) { Mem.set8(i & 0xFFFF, i & 0xFF); acc += Mem.get8(i & 0xFFFF); i++; }
		check("1M rmw loop nonzero", acc != 0 ? 1 : 0, 1);

		// #7 extern C: String -> ConstCharPtr, and a Ptr into the interior of our buffer
		stub_log(1, ConstCharPtr.fromString("extern binding works"));
		Mem.set16(0, 100); Mem.set16(2, 200); Mem.set16(4, 300);
		check("stub_sum_u16 via Ptr", stub_sum_u16(Mem.u16Ptr(0), 3), 600);
		stub_fill_u8(Mem.u8Ptr(0), 4, 0x7F);
		check("stub_fill_u8 wrote", Mem.get32(0), 0x7F7F7F7F);

		// #8 untyped __cpp__ injection (expression form)
		final injected:Int = untyped __cpp__("((int)({0}) * 3 + 1)", 14);
		check("untyped __cpp__", injected, 43);

		// ...and the trap: arguments are spliced in as raw source text with NO parentheses of
		// their own, so every placeholder must be parenthesised by hand. Without the inner
		// parens this evaluates (7*4/3+1) = 10 instead of 28/4 = 7. shim.IntMath depends on
		// getting this right; if this check ever fails, every division in the project is wrong.
		final divided:Int = untyped __cpp__("(({0}) / ({1}))", 7 * 4, 3 + 1);
		check("__cpp__ arg parenthesisation", divided, 7);

		// #9 native int64: 32x32 -> 64 multiply, the GTE/mult primitive
		final a:CxxInt64 = cast 0x12345678;
		final b:CxxInt64 = cast 0x10;
		final prod = a * b;
		check("int64 multiply high", cast(prod >> 32, Int), 0x1);
		check("int64 multiply low", cast(prod & 0xFFFFFFFF, Int), 0x23456780);
		// stub_mix64(3,5) = 15 + 0x9E3779B97F4A7C15; low 16 bits = 0x7C15 + 0xF = 0x7C24.
		// (Written out because Haxe has no 64-bit integer literals.)
		final mixed = stub_mix64(cast 3, cast 5);
		check("int64 through extern", cast(mixed & 0xFFFF, Int), 0x7C24);

		// #11/#18 dispatch table reachability + representation (Plan B)
		Dispatch.init();
		check("dispatch fnDouble", Dispatch.callByAddr(0, 21), 42);
		check("dispatch fnNegate", Dispatch.callByAddr(4, 7), -7);

		// #10 what backs Array<Int>? (init-time use only; never in hot paths)
		final ints:Array<Int> = [3, 1, 4, 1, 5];
		var isum = 0;
		for (v in ints) isum += v;
		check("Array<Int> sum", isum, 14);

		// #16 command-line arguments
		final args = Sys.args();
		// Upstream bug: interpolating `array.length` directly emits `->size()` (size_type),
		// which does not compile against std::string operator+. Bind to an Int first.
		final argc:Int = args.length;
		trace('  args count = $argc');
		if (argc > 0) trace('  args[0] = ${args[0]}');
		check("Sys.args callable", argc >= 0 ? 1 : 0, 1);

		// #17 two's-complement wrap (MIPS semantics depend on it)
		var wrap = 0x7FFFFFFF;
		wrap = wrap + 1;
		check("signed wrap", wrap, -2147483648);

		// Upstream bug: `trace(cond ? a : b)` lowers to a default-constructed DynamicToString,
		// which has no default constructor. Use plain statements instead.
		if (failures == 0) trace("=== ALL CHECKS PASSED ===");
		else trace('=== $failures CHECK(S) FAILED ===');
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
