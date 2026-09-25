package shim;

/**
	Raw memory, byte-composed and endian-neutral (see the C++ twin for why). Hatchet half: the
	bodies are inline C++ in `native/recompsx_hatchet.h`.
**/
@:include("<recompsx_hatchet.h>")
extern class RawMem {
	public static function alloc(size:Int):RawBuf;
	public static function get8(m:RawBuf, a:Int):Int;
	public static function set8(m:RawBuf, a:Int, v:Int):Void;
	public static function get16(m:RawBuf, a:Int):Int;
	public static function get16Index(m:RawBuf, index:Int):Int;
	public static function get32(m:RawBuf, a:Int):Int;
	public static function set16(m:RawBuf, a:Int, v:Int):Void;
	public static function set16Index(m:RawBuf, index:Int, v:Int):Void;
	public static function fill16Index(m:RawBuf, index:Int, count:Int, v:Int):Void;
	public static function set32(m:RawBuf, a:Int, v:Int):Void;
}
