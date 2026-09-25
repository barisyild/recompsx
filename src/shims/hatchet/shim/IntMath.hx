package shim;

/**
	Integer arithmetic that behaves identically on every target (see the C++ twin in
	`src/shims/cxx` for the rules). Hatchet half: an `extern class` whose bodies are inline C++ in
	`native/recompsx_hatchet.h`, so every call compiles to the operator itself.
**/
@:include("<recompsx_hatchet.h>")
extern class IntMath {
	public static function div(a:Int, b:Int):Int;
	public static function mod(a:Int, b:Int):Int;
	public static function mul(a:Int, b:Int):Int;
	public static function divPow2Trunc(a:Int, shift:Int):Int;
	public static function clz32(a:Int):Int;
}
