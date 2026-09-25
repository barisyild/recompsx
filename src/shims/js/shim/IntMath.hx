package shim;

/**
	Integer arithmetic that behaves identically on every target. See the C++ shim for the full
	rationale; the rules for callers are the same:

	- never write `a / b` on two `Int`s — use `IntMath.div`
	- use `IntMath.mul` wherever a product can exceed 31 bits

	The multiply rule exists because of this target. JavaScript numbers are doubles, and Haxe
	emits a plain `a * b` for `Int * Int`, which silently loses low bits once the exact product
	passes 2^53. `Math.imul` performs a true 32-bit wrapping multiply, which is what MIPS does and
	what the C++ target does under `-fwrapv`. Without it the two targets would disagree, and the
	determinism digest would catch it as a mysterious divergence rather than an obvious bug.
**/
class IntMath {
	public static inline function div(a:Int, b:Int):Int
		return js.Syntax.code("(({0} / {1}) | 0)", a, b);

	/** Truncated to a word like `div`: JavaScript's `%` takes the dividend's sign even when the
	    remainder is zero, and `-4 % 2` is -0 — a double, not an Int, that C++ never produces.
	    Stored into a register field (MIPS DIV leaves its remainder in HI) it turned that field
	    into a boxed double for good, and register moves carried it to the others. */
	public static inline function mod(a:Int, b:Int):Int
		return js.Syntax.code("(({0} % {1}) | 0)", a, b);

	public static inline function mul(a:Int, b:Int):Int
		return js.Syntax.code("Math.imul({0}, {1})", a, b);

	public static inline function divPow2Trunc(a:Int, shift:Int):Int
		return a < 0 ? -((-a) >> shift) : (a >> shift);

	/** Leading zero bits of the 32-bit pattern; 32 for zero. One instruction on every host. */
	public static inline function clz32(a:Int):Int
		return js.Syntax.code("Math.clz32({0})", a);
}
