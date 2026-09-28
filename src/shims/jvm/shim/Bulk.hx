package shim;

import shim.RawBuf;

/**
	Whole runs of emulated memory at once, JVM half (see the C++ twin for the contract). Byte
	loops over `RawMem`, in the direction that keeps an overlapping copy a memmove.
**/
class Bulk {
	public static function copy(dst:RawBuf, dstOff:Int, src:RawBuf, srcOff:Int, bytes:Int):Void {
		if (dst == src && dstOff > srcOff) {
			var i = bytes - 1;
			while (i >= 0) {
				RawMem.set8(dst, dstOff + i, RawMem.get8(src, srcOff + i));
				i--;
			}
		} else {
			var i = 0;
			while (i < bytes) {
				RawMem.set8(dst, dstOff + i, RawMem.get8(src, srcOff + i));
				i++;
			}
		}
	}

	public static function equal(a:RawBuf, aOff:Int, b:RawBuf, bOff:Int, bytes:Int):Bool {
		var i = 0;
		while (i < bytes) {
			if (RawMem.get8(a, aOff + i) != RawMem.get8(b, bOff + i)) return false;
			else {}
			i++;
		}
		return true;
	}

	public static inline function fill16(m:RawBuf, byteOff:Int, count:Int, v:Int):Void {
		RawMem.fill16Index(m, byteOff >> 1, count, v);
	}

	public static inline function prefetch(m:RawBuf, off:Int):Void {}
}
