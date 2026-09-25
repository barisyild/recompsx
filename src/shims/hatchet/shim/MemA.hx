package shim;

/**
	Aligned 16/32-bit access (see the C++ twin for the contract: callers guarantee alignment,
	and the host is little-endian). Hatchet half: direct loads and stores in
	`native/recompsx_hatchet.h`.
**/
@:include("<recompsx_hatchet.h>")
extern class MemA {
	public static function get16(m:RawBuf, a:Int):Int;
	public static function get32(m:RawBuf, a:Int):Int;
	public static function set16(m:RawBuf, a:Int, v:Int):Void;
	public static function set32(m:RawBuf, a:Int, v:Int):Void;
}
