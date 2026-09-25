package shim;

/**
	Raw memory for the JavaScript target — same static-function API as the C++ shim, dictated by
	ADR-0002, so one set of runtime code serves both.

	Wide accesses take the typed-array-view fast path when the address is aligned and the host is
	little-endian (verified once at startup, not assumed). The byte-composed path remains for the
	unaligned case and for the hypothetical big-endian host, and is the semantic definition: the
	fast path is an optimisation that must be invisible, and the cross-target digest in
	`scripts/test.sh` is what holds it to that.

	Alignment note: MIPS guarantees `lw`/`sw` are 4-aligned and `lh`/`sh` 2-aligned (unaligned
	access goes through `lwl`/`lwr`, which the recompiler composes from aligned reads), so in
	practice the aligned branch is the one that runs. The branch predicate is two cheap tests
	against constants, which JITs hoist happily.
**/
class RawMem {
	/** True when Int32Array reads bytes in little-endian order — measured, not assumed. */
	static final LE:Bool = detectLE();

	static function detectLE():Bool {
		final probe = new RawBuf(4);
		probe.i32[0] = 0x11223344;
		final le = probe.u8[0] == 0x44;
		// The aligned accessors (MemA) read typed-array elements directly, which is only the
		// byte-composed value on a little-endian host. No JavaScript engine runs big-endian
		// today; if one ever does, stopping here is better than a digest that quietly differs.
		if (!le) js.Syntax.code("throw new Error('recompsx: big-endian host; the aligned accessors assume little-endian')");
		else {}
		return le;
	}

	public static function alloc(size:Int):RawBuf {
		return new RawBuf(size); // typed arrays are born zero-filled
	}

	// There is deliberately no `free`. Emulated memory — RAM, VRAM, SPU RAM, scratchpad — is
	// allocated once during init and lives until the process exits; the portable subset forbids
	// allocation after boot, so there is no release path to write. (An attempt at one also ran
	// into reflaxe.CPP emitting `cxx.Stdlib.free` unqualified, where C++ resolved it to the
	// enclosing member function instead of the C library — worth knowing if one is ever needed.)

	public static inline function get8(m:RawBuf, a:Int):Int return m.u8[a];
	public static inline function set8(m:RawBuf, a:Int, v:Int):Void m.u8[a] = v & 0xFF;

	public static inline function get16(m:RawBuf, a:Int):Int {
		return (LE && (a & 1) == 0) ? m.u16[a >> 1]
			: get8(m, a) | (get8(m, a + 1) << 8);
	}

	/** Aligned halfword access when the caller already has a halfword index. */
	public static inline function get16Index(m:RawBuf, index:Int):Int {
		return LE ? m.u16[index] : get16(m, index << 1);
	}

	public static inline function get32(m:RawBuf, a:Int):Int {
		return (LE && (a & 3) == 0) ? m.i32[a >> 2]
			: get8(m, a) | (get8(m, a + 1) << 8) | (get8(m, a + 2) << 16) | (get8(m, a + 3) << 24);
	}

	public static inline function set16(m:RawBuf, a:Int, v:Int):Void {
		if (LE && (a & 1) == 0) {
			m.u16[a >> 1] = v;
		} else {
			set8(m, a, v);
			set8(m, a + 1, v >>> 8);
		}
	}

	public static inline function set16Index(m:RawBuf, index:Int, v:Int):Void {
		if (LE) {
			m.u16[index] = v;
		} else {
			set16(m, index << 1, v);
		}
	}

	/**
		`count` halfwords from a halfword index, all one value. The typed array's own `fill`
		stores exactly what `set16Index` would, element by element, and is a single native call
		where the loop was a store per pixel of every opaque span and clear the rasteriser draws.
	**/
	public static inline function fill16Index(m:RawBuf, index:Int, count:Int, v:Int):Void {
		if (LE) {
			js.Syntax.code("{0}.fill({1}, {2}, {3})", m.u16, v, index, index + count);
		} else {
			var i = 0;
			while (i < count) {
				set16(m, (index + i) << 1, v);
				i++;
			}
		}
	}

	public static inline function set32(m:RawBuf, a:Int, v:Int):Void {
		if (LE && (a & 3) == 0) {
			m.i32[a >> 2] = v;
		} else {
			set8(m, a, v);
			set8(m, a + 1, v >>> 8);
			set8(m, a + 2, v >>> 16);
			set8(m, a + 3, v >>> 24);
		}
	}
}
