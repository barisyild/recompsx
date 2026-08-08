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

	public static inline function mod(a:Int, b:Int):Int
		return a % b;

	public static inline function mul(a:Int, b:Int):Int
		return js.Syntax.code("Math.imul({0}, {1})", a, b);

	public static inline function divPow2Trunc(a:Int, shift:Int):Int
		return a < 0 ? -((-a) >> shift) : (a >> shift);
}
