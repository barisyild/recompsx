package shim;

import shim.RawBuf;

/**
	Whole runs of emulated memory at once: the C++ half of the seam (the JavaScript one keeps the
	same static API). The operations and their exactness are described in
	`native/recompsx_bulk.h`, which also holds the per-machine choice — sh4zam on the Dreamcast,
	the C library elsewhere — so nothing above the shim knows which it got.

	Offsets are in bytes. `copy` is memmove: one buffer, overlapping runs, either direction.

	Shaped as `mem.Access` is: a header-only class whose header includes the native one, with
	bodies GCC inlines at every call. An extern alone does not work here — an `@:include` on an
	extern class does not follow its `@:nativeFunctionCode` calls into the files that make them.
**/
@:headerOnly
@:headerCode("#include \"recompsx_bulk.h\"")
class Bulk {
	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function copy(dst:RawBuf, dstOff:Int, src:RawBuf, srcOff:Int, bytes:Int):Void
		BulkNative.copy(dst, dstOff, src, srcOff, bytes);

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function equal(a:RawBuf, aOff:Int, b:RawBuf, bOff:Int, bytes:Int):Bool
		return BulkNative.equal(a, aOff, b, bOff, bytes);

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function fill16(m:RawBuf, byteOff:Int, count:Int, v:Int):Void
		BulkNative.fill16(m, byteOff, count, v);

	@:cppInline
	@:specifier("__attribute__((always_inline))")
	public static function prefetch(m:RawBuf, off:Int):Void
		BulkNative.prefetch(m, off);
}

extern class BulkNative {
	@:nativeFunctionCode("recompsx_bulk_copy(({arg0}), ({arg1}), ({arg2}), ({arg3}), ({arg4}))")
	public static function copy(dst:RawBuf, dstOff:Int, src:RawBuf, srcOff:Int, bytes:Int):Void;

	@:nativeFunctionCode("(recompsx_bulk_equal(({arg0}), ({arg1}), ({arg2}), ({arg3}), ({arg4})) != 0)")
	public static function equal(a:RawBuf, aOff:Int, b:RawBuf, bOff:Int, bytes:Int):Bool;

	@:nativeFunctionCode("recompsx_bulk_fill16(({arg0}), ({arg1}), ({arg2}), ({arg3}))")
	public static function fill16(m:RawBuf, byteOff:Int, count:Int, v:Int):Void;

	@:nativeFunctionCode("recompsx_bulk_prefetch(({arg0}), ({arg1}))")
	public static function prefetch(m:RawBuf, off:Int):Void;
}
