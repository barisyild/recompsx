/* recompsx_gte.h — shim.GteFile's one computation: a matrix row times a vector.
 *
 * recompsx_gte_dot3(m, v) is the low 32 bits of the sum of three products of signed halfwords of
 * the GTE's register file: halfwords m, m+1, m+2 with v, v+1, v+2, where halfword h is the low
 * half of word h/2 for an even h and its high half for an odd one. The rotation matrix is kept
 * packed there as the hardware's control registers hold it (gte.Gte.RTP), so a row is three
 * consecutive halfwords, and so is each vertex RTPS/RTPT transforms (VXY0 and VZ0, words 33-34).
 * The products are within 2^30 and the sum wraps, so every target computes the same number: the
 * Haxe twins (the JavaScript and JVM shims) from the words, and this one on any host as below.
 *
 * On the SH-4 it is the multiply-accumulate unit, straight from memory: three `mac.w @Rm+,@Rn+`
 * after a `clrmac`, the sum read once. The C form is three `mul.l`, and the SH-4 has one MACL,
 * so each product waited for the multiplier before the next could start and was read out alone —
 * nine of those were a third of RTPS (about 94 of its 280 cycles in Crash Bash). MAC.W pipelines
 * its accumulation and loads its own operands. Little-endian only, as the Dreamcast is: halfword h
 * is then at byte 2h. With SR.S clear (as nothing on the Dreamcast sets it) MACH:MACL is 64 bits
 * wide and MACL is the wrapped sum; with S set it would saturate at 32 bits instead — the same
 * number wherever the sum is within 2^31, which is gte.Gte.project's premise for calling this.
 *
 * Only the MAC registers are clobbered, and the words read are named as inputs (two per operand:
 * three halfwords from any start span two words), so the compiler orders the asm after the
 * stores that set them without a "memory" clobber — which would make it reload everything it
 * held from the register file after each row. */
#ifndef RECOMPSX_GTE_H
#define RECOMPSX_GTE_H

#include "recompsx_arena.h"

#if defined(__sh__)
#define RECOMPSX_GTE_MACW 1
#endif

static inline __attribute__((always_inline)) int recompsx_gte_dot3(int m, int v) {
#if defined(RECOMPSX_GTE_MACW) && defined(__LITTLE_ENDIAN__)
    const short* pm = (const short*)recompsx_gte + m;
    const short* pv = (const short*)recompsx_gte + v;
    int r;
    __asm__("clrmac\n\t"
            "mac.w   @%1+, @%2+\n\t"
            "mac.w   @%1+, @%2+\n\t"
            "mac.w   @%1+, @%2+\n\t"
            "sts     macl, %0"
            : "=r" (r), "+r" (pm), "+r" (pv)
            : "m" (*(const int (*)[2])(recompsx_gte + (m >> 1))),
              "m" (*(const int (*)[2])(recompsx_gte + (v >> 1)))
            : "macl", "mach");
    return r;
#else
#define RECOMPSX_GTE_HALF(h) ((int)(short)(unsigned short)((unsigned)recompsx_gte[(h) >> 1] >> (((h) & 1) << 4)))
    return (int)((unsigned)(RECOMPSX_GTE_HALF(m) * RECOMPSX_GTE_HALF(v))
               + (unsigned)(RECOMPSX_GTE_HALF(m + 1) * RECOMPSX_GTE_HALF(v + 1))
               + (unsigned)(RECOMPSX_GTE_HALF(m + 2) * RECOMPSX_GTE_HALF(v + 2)));
#undef RECOMPSX_GTE_HALF
#endif
}

#endif
