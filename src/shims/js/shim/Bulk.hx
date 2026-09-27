package shim;

import shim.RawBuf;

/**
	Whole runs of emulated memory at once, JavaScript half (see the C++ twin for the contract).

	Within one buffer `copyWithin` is memmove and allocates nothing. Between two buffers a view
	would be an allocation per call — the page's collector would see one per row of every upload
	(ADR-0023) — so those are loops over the widest view both offsets allow.
**/
class Bulk {
	public static function copy(dst:RawBuf, dstOff:Int, src:RawBuf, srcOff:Int, bytes:Int):Void {
		if (dst == src) {
			js.Syntax.code("{0}.copyWithin({1}, {2}, {3})", dst.u8, dstOff, srcOff, srcOff + bytes);
		} else if (((dstOff | srcOff | bytes) & 3) == 0) {
			final d = dstOff >> 2, s = srcOff >> 2, n = bytes >> 2;
			var i = 0;
			while (i < n) {
				dst.i32[d + i] = src.i32[s + i];
				i++;
			}
		} else if (((dstOff | srcOff | bytes) & 1) == 0) {
			final d = dstOff >> 1, s = srcOff >> 1, n = bytes >> 1;
			var i = 0;
			while (i < n) {
				dst.u16[d + i] = src.u16[s + i];
				i++;
			}
		} else {
			var i = 0;
			while (i < bytes) {
				dst.u8[dstOff + i] = src.u8[srcOff + i];
				i++;
			}
		}
	}

	public static function equal(a:RawBuf, aOff:Int, b:RawBuf, bOff:Int, bytes:Int):Bool {
		var i = 0;
		while (i < bytes) {
			if (a.u8[aOff + i] != b.u8[bOff + i]) return false;
			else {}
			i++;
		}
		return true;
	}

	public static inline function fill16(m:RawBuf, byteOff:Int, count:Int, v:Int):Void {
		RawMem.fill16Index(m, byteOff >> 1, count, v);
	}

	/** A hint for a cache this target does not expose. */
	public static inline function prefetch(m:RawBuf, off:Int):Void {}
}
