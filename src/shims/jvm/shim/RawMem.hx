package shim;

/**
	Raw memory for the JVM — the same static-function API as the other shims (ADR-0002), so one
	set of runtime code serves every target.

	Every wide access is composed from bytes, little-endian, which is the semantic definition the
	other shims' fast paths must agree with; on this target it is also the only path. HotSpot
	compiles a composed word from a `byte[]` well enough for a headless build whose product is the
	determinism digest.
**/
class RawMem {
	public static function alloc(size:Int):RawBuf {
		return new RawBuf(size);
	}

	// No `free`, as on the other targets: emulated memory is allocated once during init and lives
	// until the process exits.

	public static inline function get8(m:RawBuf, a:Int):Int return m.bytes.get(a);
	public static inline function set8(m:RawBuf, a:Int, v:Int):Void m.bytes.set(a, v & 0xFF);

	public static inline function get16(m:RawBuf, a:Int):Int {
		return get8(m, a) | (get8(m, a + 1) << 8);
	}

	/** Aligned halfword access when the caller already has a halfword index. */
	public static inline function get16Index(m:RawBuf, index:Int):Int return get16(m, index << 1);

	public static inline function get32(m:RawBuf, a:Int):Int {
		return get8(m, a) | (get8(m, a + 1) << 8) | (get8(m, a + 2) << 16) | (get8(m, a + 3) << 24);
	}

	public static inline function set16(m:RawBuf, a:Int, v:Int):Void {
		set8(m, a, v);
		set8(m, a + 1, v >>> 8);
	}

	public static inline function set16Index(m:RawBuf, index:Int, v:Int):Void set16(m, index << 1, v);

	/** `count` halfwords from a halfword index, all one value. */
	public static inline function fill16Index(m:RawBuf, index:Int, count:Int, v:Int):Void {
		var i = 0;
		while (i < count) {
			set16(m, (index + i) << 1, v);
			i++;
		}
	}

	public static inline function set32(m:RawBuf, a:Int, v:Int):Void {
		set8(m, a, v);
		set8(m, a + 1, v >>> 8);
		set8(m, a + 2, v >>> 16);
		set8(m, a + 3, v >>> 24);
	}
}
