package shim;

import shim.RawBuf;

/**
	Whole runs of emulated memory at once: the C++ half of the seam (the JavaScript one keeps the
	same static API). The host operations under them are the C this class's header carries (its
	`@:headerCode`, below; C lives in a separate file only in a backend), which also makes the
	per-machine choice — sh4zam on the Dreamcast, the C library elsewhere — so nothing above the
	shim knows which it got.

	The runtime moves memory in bulk in a few places — a VRAM-to-VRAM copy by rows, an upload
	straight from RAM, a sector or a block of wave data by DMA, a fill — where it used to go a
	halfword or a word at a time through the same accessors the CPU uses. Every operation is exact:
	the bytes that land are the bytes the per-element code stored, on any byte order, which the
	BulkPaths conformance test holds both targets to. On the Dreamcast they are sh4zam's
	(src/backend/dreamcast/AGENTS.md: a std function with an sh4zam counterpart uses sh4zam) —
	shz_memmove, shz_memset8, SHZ_PREFETCH; everywhere else the C library and the compiler's builtin.

	Offsets are in bytes. `copy` is memmove: one buffer, overlapping runs, either direction.

	Shaped as `mem.Access` is: a header-only class whose header holds the C, with
	bodies GCC inlines at every call. An extern alone does not work here — an `@:include` on an
	extern class does not follow its `@:nativeFunctionCode` calls into the files that make them.
**/
@:headerOnly
@:headerCode("#ifndef RECOMPSX_BULK_H
#define RECOMPSX_BULK_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(_arch_dreamcast)
#include <sh4zam/shz_mem.h>
#endif

/* `bytes` from src + src_off to dst + dst_off, as memmove: the buffers may be one and may
 * overlap. The callers only overlap where that and an in-order copy agree. */
static inline void recompsx_bulk_copy(unsigned char* dst, int dst_off, const unsigned char* src,
                                      int src_off, int bytes) {
#if defined(_arch_dreamcast)
    shz_memmove(dst + dst_off, src + src_off, (size_t)bytes);
#else
    memmove(dst + dst_off, src + src_off, (size_t)bytes);
#endif
}

/* Whether two runs hold the same bytes. No sh4zam counterpart: the C library's. */
static inline int recompsx_bulk_equal(const unsigned char* a, int a_off, const unsigned char* b,
                                      int b_off, int bytes) {
    return memcmp(a + a_off, b + b_off, (size_t)bytes) == 0;
}

/* Halfwords from which a Dreamcast fill goes to shz_memset8 (see recompsx_bulk_fill16). */
#define RECOMPSX_BULK_FILL8_MIN 64

/* `count` halfwords of `v`, little-endian, from the even byte offset `off`. */
static inline void recompsx_bulk_fill16(unsigned char* m, int off, int count, int v) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    uint16_t* p = (uint16_t*)(void*)(m + off);
    const uint16_t h = (uint16_t)v;
#if defined(_arch_dreamcast)
    /* Long runs — a row of a clear — go to shz_memset8's 64-bit stores from an 8-byte
     * boundary. Its set-up (the value moved through the stack into FPU registers, two fschg)
     * costs more than it saves on a rasterised primitive's short spans: sent there, the spans
     * of Crash 3's shadow made triangle() 3.6 % slower on Flycast. Those, and the ends of a long
     * run, are halfword stores — the smallest code at the call, which is inlined into the
     * rasteriser's span loop. */
    if(count >= RECOMPSX_BULK_FILL8_MIN) {
        while(((uintptr_t)p & 7) != 0) { *p++ = h; count--; }
        const int quads = count >> 2;
        const uint32_t w = (uint32_t)h | ((uint32_t)h << 16);
        shz_memset8(p, ((uint64_t)w << 32) | w, (size_t)quads * 8);
        p += quads * 4;
        count &= 3;
    }
    for(int i = 0; i < count; i++) p[i] = h;
#else
    for(int i = 0; i < count; i++) p[i] = h;
#endif
#else
    for(int i = 0; i < count; i++) {
        m[off + 2 * i] = (unsigned char)(v & 0xFF);
        m[off + 2 * i + 1] = (unsigned char)((v >> 8) & 0xFF);
    }
#endif
}

/* The line holding m + off is wanted soon. A hint: nothing observable changes. */
static inline void recompsx_bulk_prefetch(const unsigned char* m, int off) {
#if defined(_arch_dreamcast)
    SHZ_PREFETCH(m + off);
#else
    __builtin_prefetch(m + off);
#endif
}

#endif")
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
