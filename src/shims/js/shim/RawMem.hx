package shim;

import js.lib.Uint8Array;

/**
	Raw memory for the JavaScript target. Same static-function shape as the C++ shim — the shape
	is dictated by reflaxe.CPP's inlining behaviour (ADR-0002), and the JS side matches it rather
	than taking the liberty it could, so that one set of runtime code serves both.

	The 16- and 32-bit accessors are composed from bytes here too, for the same reason: identical
	arithmetic on every target is what makes a cross-target determinism digest meaningful. A
	DataView with an explicit endianness would be marginally faster and would break that property
	the first time a target disagreed about anything.
**/
class RawMem {
	public static function alloc(size:Int):RawBuf {
		return new Uint8Array(size); // JS typed arrays are already zero-filled
	}

	public static function free(m:RawBuf):Void {
		// Garbage collected. Present so runtime code reads the same on both targets.
	}

	public static inline function get8(m:RawBuf, a:Int):Int return m[a];
	public static inline function set8(m:RawBuf, a:Int, v:Int):Void m[a] = v & 0xFF;

	public static inline function get16(m:RawBuf, a:Int):Int
		return get8(m, a) | (get8(m, a + 1) << 8);

	public static inline function get32(m:RawBuf, a:Int):Int
		return get8(m, a) | (get8(m, a + 1) << 8) | (get8(m, a + 2) << 16) | (get8(m, a + 3) << 24);

	public static inline function set16(m:RawBuf, a:Int, v:Int):Void {
		set8(m, a, v);
		set8(m, a + 1, v >>> 8);
	}

	public static inline function set32(m:RawBuf, a:Int, v:Int):Void {
		set8(m, a, v);
		set8(m, a + 1, v >>> 8);
		set8(m, a + 2, v >>> 16);
		set8(m, a + 3, v >>> 24);
	}
}
