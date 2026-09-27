package shim;

/**
	Whole runs of emulated memory at once (see the C++ twin for the contract). Hatchet half: the
	bodies are inline C++ in `native/recompsx_hatchet.h`, over the reflaxe.CPP shim's
	`recompsx_bulk.h`.
**/
@:include("<recompsx_hatchet.h>")
extern class Bulk {
	public static function copy(dst:RawBuf, dstOff:Int, src:RawBuf, srcOff:Int, bytes:Int):Void;
	public static function equal(a:RawBuf, aOff:Int, b:RawBuf, bOff:Int, bytes:Int):Bool;
	public static function fill16(m:RawBuf, byteOff:Int, count:Int, v:Int):Void;
	public static function prefetch(m:RawBuf, off:Int):Void;
}
