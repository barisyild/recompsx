package shim;

/**
	Integer arithmetic that behaves identically on every target. The rules for callers:

	- never write `a / b` on two `Int`s — use `IntMath.div`  // portable-ok: prose
	- use `IntMath.mul` wherever a product can exceed 31 bits

	Haxe's `/` on two `Int`s yields a `Float` on every target, and `Std.int(a / b)` routes 32-bit  // portable-ok: prose
	integer arithmetic through a double. reflaxe.CPP happens to lower that to plain C++ integer
	division today, but "happens to" is not a foundation for a bit-exact emulator, and this
	project forbids floating point outright — partly to stay off the FPU on consoles, partly
	because the rule is only enforceable if it has no exceptions.

	The multiply rule comes from the JavaScript target: `Int * Int` compiles to a double multiply
	there and silently loses low bits above 2^53, where C++ under `-fwrapv` wraps like MIPS does.
	The two targets disagreed over exactly this in the project's first cross-target comparison.

	Semantics match C++ and MIPS: truncation toward zero, and the remainder takes the sign of the
	dividend. Division by zero is the caller's problem — MIPS defines its own results for that
	case and the recompiler emits them explicitly (see docs/specs/tool.md §3, `Ops.div`).

	## Why `@:nativeFunctionCode` and not `untyped __cpp__`

	`__cpp__` is reflaxe's generic code-injection hook — its name is configurable and reflaxe.CPP
	simply picked hxcpp's spelling — and it does work. But `@:nativeFunctionCode` is what
	reflaxe.CPP's own standard library uses for native operations: `cxx.CArray`,
	`cxx.ConstCharPtr` and `cxx.Stdlib` are all built this way. It keeps target code inside a
	declaration instead of scattering it through expressions, and it says exactly what will be
	emitted rather than depending on how the compiler chooses to lower something. `untyped
	__cpp__` remains the escape hatch for statement-level injection, which this cannot express.

	**Both mechanisms splice arguments in as raw source text, with no parentheses of their own.**
	Measured: the template `"({arg0} / {arg1})"` called as `div(y * 31, h - 1)` emits
	`(y * 31 / h - 1)` and returns 42 where 54 is correct. Every placeholder in this project is
	parenthesised by hand, in either mechanism, always. Recorded as upstream defect 7.
**/
class IntMath {
	public static inline function div(a:Int, b:Int):Int return NativeIntOps.div(a, b);
	public static inline function mod(a:Int, b:Int):Int return NativeIntOps.mod(a, b);

	/** 32-bit wrapping multiply — MIPS semantics. Correct here under `-fwrapv`; the JS shim
	    needs `Math.imul`. Callers use this on both targets so the two cannot drift apart. */
	public static inline function mul(a:Int, b:Int):Int return NativeIntOps.mul(a, b);

	/** Truncating division by a power of two differs from a shift for negative numbers
	    (`-1 / 2 == 0` but `-1 >> 1 == -1`). Named so the choice is visible at the call site. */
	public static inline function divPow2Trunc(a:Int, shift:Int):Int
		return a < 0 ? -((-a) >> shift) : (a >> shift);
}

/**
	The native operations themselves. Nothing to include — these are operators, not library calls
	— so the extern carries only the templates.
**/
private extern class NativeIntOps {
	@:nativeFunctionCode("(({arg0}) / ({arg1}))")
	public static function div(a:Int, b:Int):Int;

	@:nativeFunctionCode("(({arg0}) % ({arg1}))")
	public static function mod(a:Int, b:Int):Int;

	@:nativeFunctionCode("(({arg0}) * ({arg1}))")
	public static function mul(a:Int, b:Int):Int;
}
