package shim;

import shim.RawBuf;

import cxx.CArray;
import cxx.Ptr;
import cxx.Stdlib;
import cxx.num.UInt8;
import cxx.num.UInt16;
import cxx.num.Int16;

/**
	Raw memory for the C++ targets: emulated RAM, VRAM, SPU RAM, scratchpad, sector buffers.

	Every accessor is a **static** function taking the buffer as its first argument. That shape is
	forced, not stylistic (ADR-0002): reflaxe.CPP emits a receiver temporary with a fixed name for
	every inlined *instance* method, so two such calls in one scope fail to compile. Static
	functions have no receiver, and these expand to bare pointer indexing — `RawMem.set32(vram, a, v)`
	becomes four `vram[i] = ...` stores with no call at all.

	The 16- and 32-bit accessors are composed from bytes rather than reinterpreting memory. That
	makes them **endian-neutral by construction**: the same bytes land in the same places on a
	little-endian desktop and on a big-endian PowerPC console, with zero backend involvement. It
	also sidesteps unaligned-access traps on architectures that have them. A per-target fast path
	can be added behind a define once profiling says it matters — not before.
**/
class RawMem {
	/** Allocates a zero-filled buffer. Zero-filled matters: emulated state must never start from
	    host garbage, or determinism is gone before the first instruction runs. */
	public static function alloc(size:Int):RawBuf {
		final m:RawBuf = Stdlib.ccast(Stdlib.malloc(size));
		var i = 0;
		while (i < size) { m[i] = 0; i++; }
		return m;
	}

	// There is deliberately no `free`. Emulated memory — RAM, VRAM, SPU RAM, scratchpad — is
	// allocated once during init and lives until the process exits; the portable subset forbids
	// allocation after boot, so there is no release path to write. (An attempt at one also ran
	// into reflaxe.CPP emitting `cxx.Stdlib.free` unqualified, where C++ resolved it to the
	// enclosing member function instead of the C library — worth knowing if one is ever needed.)

	public static inline function get8(m:RawBuf, a:Int):Int return m[a];
	public static inline function set8(m:RawBuf, a:Int, v:Int):Void m[a] = v & 0xFF;

	public static inline function get16(m:RawBuf, a:Int):Int
		return get8(m, a) | (get8(m, a + 1) << 8);

	/** Aligned halfword access when the caller already has a halfword index. */
	public static inline function get16Index(m:RawBuf, index:Int):Int
		return get16(m, index << 1);

	public static inline function get32(m:RawBuf, a:Int):Int
		return get8(m, a) | (get8(m, a + 1) << 8) | (get8(m, a + 2) << 16) | (get8(m, a + 3) << 24);

	public static inline function set16(m:RawBuf, a:Int, v:Int):Void {
		set8(m, a, v);
		set8(m, a + 1, v >>> 8);
	}

	public static inline function set16Index(m:RawBuf, index:Int, v:Int):Void
		set16(m, index << 1, v);

	/** `count` halfwords from a halfword index, all one value. A plain loop the C++ compiler
	    vectorises; the JS twin uses the typed array's `fill`. Same bytes either way. */
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

	/** Base pointer views, for handing buffers to the backend. On a big-endian host these will
	    return a swizzled staging copy instead; that is the one place byte order is allowed to
	    exist, and it stays here rather than leaking into any backend. */
	public static inline function u16Ptr(m:RawBuf):Ptr<UInt16> return Stdlib.ccast(m.toPtr());
	public static inline function s16Ptr(m:RawBuf):Ptr<Int16> return Stdlib.ccast(m.toPtr());
	public static inline function u8Ptr(m:RawBuf):Ptr<UInt8> return m.toPtr();
}
