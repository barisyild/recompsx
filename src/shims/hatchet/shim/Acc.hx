package shim;

/**
	The GTE's 44-bit accumulator as a value (see the C++ twin). Hatchet half: a value class
	(`@:stackOnly`) that is a `long long` in a struct, with inline static operations in
	`native/recompsx_hatchet.h`.
**/
@:include("<recompsx_hatchet.h>")
@:stackOnly
extern class Acc {
	public static function zero():Acc;
	public static function of(v:Int):Acc;
	public static function shl12(v:Int):Acc;
	public static function add(m:Acc, p:Int):Acc;
	public static function mac(m:Acc, a:Int, b:Int):Acc;
	public static function check44(m:Acc):Int;
	public static function check32(m:Acc):Int;
	public static function wrap44(m:Acc):Acc;
	public static function low32(m:Acc):Int;
	public static function shr12(m:Acc):Int;
	public static function shr16(m:Acc):Int;
}
