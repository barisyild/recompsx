package shim;

import js.lib.ArrayBuffer;
import js.lib.Int32Array;
import js.lib.Uint16Array;
import js.lib.Uint8Array;

/**
	The raw byte buffer on JavaScript: one ArrayBuffer with three typed views over it.

	The views are the performance answer for this target. A byte-composed `get32` runs at about
	600 Mops/s under Node's JIT — already ~60× what a real-time PS1 needs — but a single
	`Int32Array` read doubles that for free, and more importantly it keeps wide accesses one
	indexed load instead of four, which is the shape JIT compilers optimise hardest.

	The views read in *host* byte order, which is why the C++ shim cannot use this trick as its
	default (a big-endian console would silently disagree). Here it is sound: every JavaScript
	platform of consequence is little-endian, matching the PS1, and `RawMem` verifies that once at
	startup rather than assuming it.
**/
class RawBuf {
	public final u8:Uint8Array;
	public final u16:Uint16Array;
	public final i32:Int32Array;

	public function new(size:Int) {
		// Views over a buffer require length multiples of their element size.
		final b = new ArrayBuffer((size + 3) & ~3);
		u8 = new Uint8Array(b);
		u16 = new Uint16Array(b);
		i32 = new Int32Array(b);
	}
}
