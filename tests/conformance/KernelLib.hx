/**
	Cross-target conformance for the kernel's C library and heap.

	These run on emulated memory, byte at a time, and every one of them is the kind of thing that
	quietly differs between targets — signed comparisons that return a difference rather than a
	sign, overlapping copies, an allocator whose addresses have to be reproducible.

	The heap matters most. Its answers are *addresses*, and a game stores them, compares them and
	indexes off them, so an allocator that returned different addresses on two targets would
	diverge everything downstream from it. Pinning the exact sequence here is what makes it safe
	to say the allocation order is deterministic.
**/
class KernelLib {
	static inline var HEAP = 0x80100000;
	static inline var WORK = 0x80010000;

	public static function main():Void {
		mem.Memory.init();
		kernel.Kernel.init();

		strings();
		blocks();
		numbers();
		heap();

		Conf.report("KernelLib");
	}

	// ---- helpers ---------------------------------------------------------------------------

	/**
		Writes a NUL-terminated string into emulated memory and returns its address.

		Byte codes rather than a Haxe string: `String.charCodeAt` does not compile under
		reflaxe.CPP, which indexes the string to a `char` and then emits a method call on it. The
		portable subset says strings are cold-path only, and this is the reason.
	**/
	static function put(addr:Int, codes:Array<Int>):Int {
		for (i in 0...codes.length) mem.Memory.write8(addr + i, codes[i]);
		mem.Memory.write8(addr + codes.length, 0);
		return addr;
	}

	static function feedBytes(addr:Int, n:Int):Void {
		for (i in 0...n) Conf.feed(mem.Memory.read8u(addr + i));
	}

	// ---- the tests ----------------------------------------------------------------------------

	static function strings():Void {
		Conf.feedName("strings");
		final a = put(WORK, [0x72, 0x65, 0x63, 0x6f, 0x6d, 0x70, 0x73, 0x78]  /* "recompsx" */);
		final b = put(WORK + 0x20, [0x72, 0x65, 0x63, 0x6f, 0x6d, 0x70]  /* "recomp" */);
		final c = put(WORK + 0x40, [0x52, 0x45, 0x43, 0x4f, 0x4d, 0x50, 0x53, 0x58]  /* "RECOMPSX" */);

		Conf.feed(kernel.KLib.strlen(a));
		Conf.feed(kernel.KLib.strlen(b));
		Conf.feed(kernel.KLib.strlen(put(WORK + 0x60, []  /* "" */)));

		// Comparisons return a byte difference, not just a sign, and the sign of that difference
		// is what a game branches on.
		Conf.feed(call2(0x17, a, b));
		Conf.feed(call2(0x17, b, a));
		Conf.feed(call2(0x17, a, a));
		Conf.feed(call2(0x17, a, c));
		Conf.feed(call3(0x18, a, b, 6));
		Conf.feed(call3(0x18, a, b, 8));

		// Copies write into emulated memory, so the bytes are the answer, not the return value.
		Conf.feed(call2(0x19, WORK + 0x80, a));
		feedBytes(WORK + 0x80, 10);
		Conf.feed(call3(0x1A, WORK + 0xA0, b, 10));
		feedBytes(WORK + 0xA0, 12);   // strncpy pads to the full length with zeroes
		Conf.feed(call2(0x15, put(WORK + 0xC0, [0x61, 0x62, 0x63]  /* "abc" */), b));
		feedBytes(WORK + 0xC0, 12);

		// Searching: found, not found, and the last occurrence rather than the first.
		Conf.feed(call2(0x1E, a, 0x6D) - WORK);
		Conf.feed(call2(0x1E, a, 0x7A));
		Conf.feed(call2(0x1F, put(WORK + 0xE0, [0x61, 0x58, 0x62, 0x58, 0x63]  /* "aXbXc" */), 0x58) - WORK);
		Conf.feed(call2(0x24, a, b) - WORK);
		Conf.feed(call2(0x24, b, a));

		Conf.feed(call1(0x25, 0x61));
		Conf.feed(call1(0x25, 0x41));
		Conf.feed(call1(0x26, 0x5A));
		Conf.feed(call1(0x26, 0x30));
	}

	static function blocks():Void {
		Conf.feedName("blocks");
		for (i in 0...16) mem.Memory.write8(WORK + i, i * 17);

		Conf.feed(call3(0x2A, WORK + 0x100, WORK, 16));
		feedBytes(WORK + 0x100, 16);

		Conf.feed(call3(0x2B, WORK + 0x120, 0xAB, 8));
		feedBytes(WORK + 0x120, 10);

		// The two overlap directions. Forward-overlapping is the one a naive copy gets wrong.
		for (i in 0...16) mem.Memory.write8(WORK + 0x140 + i, i + 1);
		Conf.feed(call3(0x2C, WORK + 0x144, WORK + 0x140, 12));
		feedBytes(WORK + 0x140, 16);

		for (i in 0...16) mem.Memory.write8(WORK + 0x160 + i, i + 1);
		Conf.feed(call3(0x2C, WORK + 0x160, WORK + 0x164, 12));
		feedBytes(WORK + 0x160, 16);

		// bcopy has its arguments the other way round from memcpy, which is exactly the sort of
		// thing that would otherwise be discovered by a game corrupting itself.
		for (i in 0...8) mem.Memory.write8(WORK + 0x180 + i, 0x50 + i);
		Conf.feed(call3(0x27, WORK + 0x180, WORK + 0x190, 8));
		feedBytes(WORK + 0x190, 8);

		Conf.feed(call3(0x2D, WORK + 0x100, WORK, 16));
		Conf.feed(call3(0x2D, WORK + 0x100, WORK + 0x120, 4));
		Conf.feed(call3(0x2E, WORK, 34, 16) - WORK);
		Conf.feed(call3(0x2E, WORK, 0xFE, 16));
	}

	static function numbers():Void {
		Conf.feedName("numbers");
		Conf.feed(call1(0x0E, -5));
		Conf.feed(call1(0x0E, 5));
		Conf.feed(call1(0x0E, 0));
		// Its own negation does not fit, and the hardware answer is the value back unchanged.
		Conf.feed(call1(0x0E, -2147483648));

		Conf.feed(call1(0x10, put(WORK, [0x31, 0x32, 0x33, 0x34]  /* "1234" */)));
		Conf.feed(call1(0x10, put(WORK, [0x2d, 0x34, 0x32]  /* "-42" */)));
		Conf.feed(call1(0x10, put(WORK, [0x20, 0x20, 0x2b, 0x37, 0x61, 0x62, 0x63]  /* "  +7abc" */)));
		Conf.feed(call1(0x10, put(WORK, [0x7a, 0x7a, 0x7a]  /* "zzz" */)));

		// The generator must produce the same stream everywhere, from the same seed, forever.
		call1(0x30, 1);
		for (_ in 0...16) Conf.feed(call0(0x2F));
		call1(0x30, 0x12345678);
		for (_ in 0...8) Conf.feed(call0(0x2F));
	}

	static function heap():Void {
		Conf.feedName("heap");
		kernel.KHeap.init(HEAP, 0x4000);
		Conf.feed(kernel.KHeap.base - HEAP);
		Conf.feed(kernel.KHeap.size);

		// Addresses, in order. A game stores these, so they are part of the contract.
		final a = call1(0x33, 64);
		final b = call1(0x33, 128);
		final c = call1(0x33, 32);
		Conf.feed(a - HEAP);
		Conf.feed(b - HEAP);
		Conf.feed(c - HEAP);
		Conf.feed(kernel.KHeap.liveBlocks);

		// Freeing the middle and reallocating the same size must reuse the hole.
		call1(0x34, b);
		Conf.feed(kernel.KHeap.liveBlocks);
		final d = call1(0x33, 128);
		Conf.feed(d - HEAP);
		Conf.feed(d == b ? 1 : 0);

		// Two adjacent frees must merge, or the heap fragments into uselessness.
		call1(0x34, a);
		call1(0x34, d);
		final big = call1(0x33, 192);
		Conf.feed(big - HEAP);
		Conf.feed(big == a ? 1 : 0);

		// calloc zeroes; realloc copies.
		final z = call2(0x37, 8, 4);
		Conf.feed(z - HEAP);
		feedBytes(z, 32);
		for (i in 0...16) mem.Memory.write8(z + i, i + 1);
		final grown = call2(0x38, z, 256);
		Conf.feed(grown - HEAP);
		feedBytes(grown, 16);

		// And the failure that must not crash: more than the heap holds.
		Conf.feed(call1(0x33, 0x100000));
		Conf.feed(kernel.KHeap.liveBlocks);
	}

	// ---- calling the kernel the way a game does ----------------------------------------------

	// Through the real A0 dispatch, with arguments in registers, because the argument *wiring* is
	// as much a part of this as the functions are.
	static var ctx = new core.CpuState();

	static function call0(fn:Int):Int {
		kernel.Kernel.call(ctx, 0xA0, fn);
		return ctx.v0;
	}

	static function call1(fn:Int, a0:Int):Int {
		ctx.a0 = a0;
		return call0(fn);
	}

	static function call2(fn:Int, a0:Int, a1:Int):Int {
		ctx.a1 = a1;
		return call1(fn, a0);
	}

	static function call3(fn:Int, a0:Int, a1:Int, a2:Int):Int {
		ctx.a2 = a2;
		return call2(fn, a0, a1);
	}
}
