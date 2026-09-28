package shim;

import haxe.io.Bytes;

/**
	The raw byte buffer on the JVM: a `byte[]`, which is what `haxe.io.Bytes` holds there.

	Java has no way to read one array through another type's view, as JavaScript's typed arrays
	do over one ArrayBuffer, so the wide accesses in `RawMem` and `MemA` are composed from bytes,
	little-endian. The byte order is then this code's, not the host's — the JVM's own is big-endian
	by definition — which is also what makes it right everywhere without a startup probe.
**/
class RawBuf {
	public final bytes:Bytes;

	public function new(size:Int) {
		// Rounded up to a word as on the other targets; a new Java array is zero-filled.
		bytes = Bytes.alloc((size + 3) & ~3);
	}
}
