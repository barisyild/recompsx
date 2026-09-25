package shim;

/**
	The static 64-bit accumulator (see the C++ twin). Hatchet half: a native `long long` in
	`native/recompsx_hatchet.h`. The `hi`/`lo` word properties the conformance test writes are not
	offered here; nothing in the runtime uses them.
**/
@:include("<recompsx_hatchet.h>")
extern class I64 {
	public static function set(v:Int):Void;
	public static function setZero():Void;
	public static function setShl12(v:Int):Void;
	public static function addSmall(p:Int):Void;
	public static function addProduct16(a:Int, b:Int):Void;
	public static function addProductWide(a:Int, b:Int):Void;
	public static function addPair(ahi:Int, alo:Int):Void;
	public static function check44():Int;
	public static function check32():Int;
	public static function wrap44():Void;
	public static function low32():Int;
	public static function shr12():Int;
	public static function shr16():Int;
	public static function mulShr16Round(a:Int, b:Int):Int;
}
