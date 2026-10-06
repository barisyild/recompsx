package gpu;

import core.Irq;
import core.Runtime;
import core.TimeBase;
import shim.Backend;
import shim.MemA;
import shim.RawBuf;
import shim.RawMem;
import shim.GpuFile;

/**
	The GPU's register file: the two ports at 1F801810h and 1F801814h, and the state behind them.

	No rasteriser yet. This is the half a game meets first and the half it can hang on — Psy-Q's
	`ResetGraph` sends GP1 commands and then waits on GPUSTAT, and a status word that never changes
	is why Crash Bash printed `GPU timeout` and `VSync: timeout` before this existed. Drawing
	commands are accepted and counted; what they would draw comes later.

	Bit layout and the reset value from psx-spx "GPU Status Register". Two bits earn comment:

	- **26 and 28, ready for a command and ready for DMA, are always set.** Drawing is instant in
	  this model, so the GPU is never busy. A game polling for readiness gets it immediately, which
	  is the honest answer for a machine that has already finished.
	- **31, even/odd,** is computed from the line counter on every read rather than stored. Games
	  poll it to find the field, and a stored value would need a scanline event to update it — this
	  way the answer is always current and costs one division.
**/
// The hot state (shim.GpuFile) must be declared wherever a GPU access is inlined — ioWrite32
// takes writeGp0 into Memory — and reflaxe does not carry an extern's include along an inlining
// chain; Gte does the same for its register file. Then the polygon core's call (ADR-0047,
// GpuFile.poly): on the SH-4 a `jsr` into scripts/sh4/poly.blk's assembly, the GPU file and guest
// RAM as memory it reads and writes; with RECOMPSX_GPU_POLY_CHECK it runs on a copy of the file
// beside the C form instead, which then decides, and the two are compared (polyChecked).
@:headerCode("#include \"recompsx_arena.h\"
#ifndef RECOMPSX_GPU_POLY
#define RECOMPSX_GPU_POLY
#if defined(__sh__) && defined(__LITTLE_ENDIAN__) && !defined(RECOMPSX_GPU_NO_ASM)
extern \"C\" void recompsx_gpu_poly(void);
extern \"C\" void recompsx_gpu_poly2(void);
static inline __attribute__((always_inline)) int recompsx_gpu_poly_run(const unsigned char* ram, int at, int op, int* g, int second) {
	register int r0 __asm__(\"r0\");
	register const unsigned char* r4 __asm__(\"r4\") = ram;
	register int r5 __asm__(\"r5\") = at;
	register int r6 __asm__(\"r6\") = op;
	register int* r7 __asm__(\"r7\") = g;
	void (*fn)(void) = second ? recompsx_gpu_poly2 : recompsx_gpu_poly;
	__asm__ __volatile__(\"jsr @%5\\n\\tnop\"
	        : \"=r\" (r0), \"+r\" (r4), \"+r\" (r5), \"+r\" (r6), \"+r\" (r7)
	        : \"r\" (fn)
	        : \"r1\", \"r2\", \"r3\", \"pr\", \"macl\", \"mach\", \"t\", \"memory\");
	return r0;
}
#if RECOMPSX_GPU_POLY_CHECK
#include <cstdio>
#include \"backend_c_api.h\"
struct recompsx_gpu_poly_state { int shadow[64]; int before[64]; int rc; unsigned calls, drawn, rejected, declined, bad; unsigned rec[8]; uint32_t* at; };
inline recompsx_gpu_poly_state& recompsx_gpu_poly_st() { static recompsx_gpu_poly_state s; return s; }
inline int recompsx_gpu_poly_check(const unsigned char* ram, int at, int op) {
	recompsx_gpu_poly_state& s = recompsx_gpu_poly_st();
	for(int i = 0; i < 64; i++) s.shadow[i] = s.before[i] = recompsx_gpu[i];
	/* The core writes its record where the sink says (ADR-0051): kept aside here, and the sink and
	 * the line put back, so that the C form, which decides, records the triangle itself in the
	 * same place, where recompsx_gpu_poly_checked compares the two. */
	uint32_t* next = bp_gpu_sink.next;
	const uint16_t tris = *bp_gpu_sink.tris;
	const int room = bp_gpu_sink.end - next >= 16;
	unsigned line[8];
	for(int k = 0; k < 8; k++) line[k] = room ? next[k] : 0;
	s.rc = (op & 8) ? -1 : recompsx_gpu_poly_run(ram, at, op, s.shadow, 0);
	s.at = bp_gpu_sink.next != next ? next : 0;
	for(int k = 0; k < 8; k++) { s.rec[k] = room ? next[k] : 0; if(room) next[k] = line[k]; else {} }
	bp_gpu_sink.next = next;
	*bp_gpu_sink.tris = tris;
	return 1;
}
inline void recompsx_gpu_poly_bad(const char* what, int i, int a, int b) {
	recompsx_gpu_poly_state& s = recompsx_gpu_poly_st();
	if(++s.bad <= 8) {
		char m[120];
		snprintf(m, sizeof m, \"gpu poly check: %s %d core %d, the C form %d (rc %d)\", what, i, a, b, s.rc);
		bp_log(BP_LOG_WARN, m);
	} else {}
}
inline void recompsx_gpu_poly_checked(int op) {
	recompsx_gpu_poly_state& s = recompsx_gpu_poly_st();
	(void)op;
	if(s.rc < 0) return;
	s.calls++;
	if(s.rc == 1) {
		s.declined++;
		for(int i = 0; i < 48; i++)
			if(i < 16 || i > 18) { if(s.shadow[i] != s.before[i]) { recompsx_gpu_poly_bad(\"declined, word\", i, s.shadow[i], s.before[i]); break; } else {} }
			else {}
	} else {
		int sent = 0;
		for(int i = 0; i < 36; i++) {
			if(i >= 19 && i <= 22 && recompsx_gpu[i] != s.before[i]) sent = 1;
			else {}
			if(s.shadow[i] != recompsx_gpu[i]) { recompsx_gpu_poly_bad(\"word\", i, s.shadow[i], recompsx_gpu[i]); break; }
			else {}
		}
		if(s.rc == 3) s.rejected++;
		else {
			s.drawn++;
			if((s.rc == 2) != (sent != 0)) recompsx_gpu_poly_bad(\"state sent\", 0, s.rc, sent);
			else {}
			/* The core's record against the C form's in the same place: every word, the tag only
			 * when the state stayed (answering 2, the core wrote the old one, which the backend
			 * replaces). */
			if(!s.at) recompsx_gpu_poly_bad(\"no record\", 0, s.rc, 0);
			else {
				for(int k = 0; k < 8; k++) {
					const unsigned m = (k == 7 && s.rc == 2) ? 0xFFFFu : 0xFFFFFFFFu;
					if(((s.rec[k] ^ s.at[k]) & m) != 0) { recompsx_gpu_poly_bad(\"record word\", k, (int)s.rec[k], (int)s.at[k]); break; }
					else {}
				}
			}
		}
	}
	if((s.calls & 0xFFFF) == 0) {
		char m[120];
		snprintf(m, sizeof m, \"gpu poly check: %u packets, %u drawn, %u rejected, %u declined, %u differ\", s.calls, s.drawn, s.rejected, s.declined, s.bad);
		bp_log(BP_LOG_WARN, m);
	} else {}
}
#endif
#endif
static inline __attribute__((always_inline)) int recompsx_gpu_poly_try(const unsigned char* ram, int at, int op, int second) {
#if defined(__sh__) && defined(__LITTLE_ENDIAN__) && !defined(RECOMPSX_GPU_NO_ASM)
#if RECOMPSX_GPU_POLY_CHECK
	(void)second;
	return recompsx_gpu_poly_check(ram, at, op);
#else
	return recompsx_gpu_poly_run(ram, at, op, recompsx_gpu, second);
#endif
#else
	(void)ram; (void)at; (void)op; (void)second;
	return 1;
#endif
}
static inline __attribute__((always_inline)) void recompsx_gpu_poly_after(int op) {
#if defined(__sh__) && defined(__LITTLE_ENDIAN__) && !defined(RECOMPSX_GPU_NO_ASM) && RECOMPSX_GPU_POLY_CHECK
	recompsx_gpu_poly_checked(op);
#else
	(void)op;
#endif
}
/* The core answered 2 (ADR-0051): it recorded the triangle under the state the backend has, and left
 * the new one in words 52-61, which the backend takes and moves that record into. Only the SH-4's
 * core answers so; anywhere else this is never reached, and is the state alone. */
#include \"backend_c_api.h\"
static inline __attribute__((always_inline)) void recompsx_gpu_state_after_tri(void) {
#if defined(__sh__) && defined(__LITTLE_ENDIAN__) && !defined(RECOMPSX_GPU_NO_ASM) && !RECOMPSX_GPU_POLY_CHECK
	bp_gpu_state_after_tri(recompsx_gpu + 52);
#else
	bp_gpu_state_w(recompsx_gpu + 52);
#endif
}
#endif")
// <dc-sched scripts/sh4/poly.blk> written by scripts/dc-sched.py --into: never edit by hand
@:cppFileCode("#if defined(__sh__) && defined(__LITTLE_ENDIAN__) && !defined(RECOMPSX_GPU_NO_ASM)
__asm__(R\"ASM(
	.pushsection .text.recompsx_gpu_poly,\"ax\",@progbits
	.align	5
.Lpoly_wrap0:
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	rts
	mov	#1,r0
.Lpoly_clut0:
	mov	#-128,r0
	extu.b	r0,r0
	shll8	r0
	add	#-1,r0
	and	r11,r0
	mov.l	r0,@(4,r7)
	mov	r7,r5
	add	#64,r5
	mov	r11,r0
	and	#63,r0
	shll2	r0
	shll2	r0
	mov.l	r0,@(40,r5)
	mov	r11,r0
	shlr2	r0
	shlr2	r0
	shlr2	r0
	mov	#2,r6
	shll8	r6
	add	#-1,r6
	and	r6,r0
	mov.l	r0,@(44,r5)
	tst	r8,r8
	bf	.Lpoly_page0
	bra	.Lpoly_body
	nop
.Lpoly_page0:
	mov	#2,r6
	shll8	r6
	add	#-1,r6
	and	r13,r6
	mov.l	r6,@(0,r7)
	mov	r7,r5
	add	#64,r5
	mov	r13,r0
	and	#15,r0
	shll2	r0
	shll2	r0
	shll2	r0
	mov.l	r0,@(28,r5)
	mov	r13,r0
	shlr2	r0
	shlr2	r0
	and	#1,r0
	shll8	r0
	mov.l	r0,@(32,r5)
	mov	r13,r0
	shlr2	r0
	shlr2	r0
	shlr	r0
	and	#3,r0
	mov.l	r0,@(48,r5)
	mov	r13,r0
	shlr2	r0
	shlr2	r0
	shlr2	r0
	shlr	r0
	and	#3,r0
	bra	.Lpoly_body
	mov.l	r0,@(36,r5)
	.global	_recompsx_gpu_poly2
	.type	_recompsx_gpu_poly2,@function
_recompsx_gpu_poly2:
	bra	.Lpoly_poly
	mov	#-1,r1
	.global	_recompsx_gpu_poly
	.type	_recompsx_gpu_poly,@function
_recompsx_gpu_poly:
	mov	#0,r1
.Lpoly_poly:
	mov.l	.Lpoly_k1ffffc,r0
	mov.l	.Lpoly_k1fffd0,r2
	and	r5,r0
	mov.l	r8,@-r15
	cmp/hi	r2,r0
	mov	r4,r2
	add	r0,r2
	mov	r6,r0
	and	#31,r0
	mov.l	r9,@-r15
	shll2	r0
	mov.l	.Lpoly_ksink,r3
	shll2	r0
	mov.l	r10,@-r15
	shll2	r0
	mov.l	r11,@-r15
	mov.l	@r3,r8
	mov	#-32,r10
	mov.l	@(4,r3),r9
	mov	r0,r3
	mov.l	r12,@-r15
	and	r1,r10
	mova	.Lpoly_ops,r0
	sub	r8,r9
	mov.l	r13,@-r15
	mov	r2,r13
	add	r0,r3
	mov.l	r14,@-r15
	mov.l	@r3,r14
	add	#64,r10
	mov.l	@(8,r2),r11
	bt	.Lpoly_wrap0
	add	r14,r13
	mov.w	.Lpoly_k7fff,r12
	mov.l	@(8,r13),r13
	cmp/ge	r10,r9
	shlr16	r11
	mov.l	@(4,r7),r9
	mov.w	.Lpoly_k1ff,r8
	and	r11,r12
	shlr16	r13
	mov.l	@(28,r3),r10
	mov.l	@(0,r7),r0
	xor	r9,r12
	and	r13,r8
	bf	.Lpoly_wrap0
	and	r10,r12
	xor	r0,r8
	tst	r12,r12
	and	r10,r8
	bf	.Lpoly_clut0
	tst	r8,r8
	bf	.Lpoly_page0
.Lpoly_body:
	mov	r14,r9
	mov.l	@(32,r3),r4
	and	r1,r9
	mov	r7,r5
	and	r9,r4
	mov	r7,r6
	add	r2,r9
	mov.l	@(8,r7),r10
	add	#127,r5
	mov.l	@(24,r3),r11
	add	r2,r4
	mov.w	.Lpoly_k21,r1
	add	#4,r9
	mov.w	.Lpoly_km21,r2
	add	#17,r5
	mov.l	r4,@(56,r5)
	add	#64,r6
	mov.l	r9,@(60,r5)
	mov.l	@(16,r3),r4
	mov.l	@(20,r3),r5
	mov.l	r4,@(0,r6)
	mov.l	r5,@(4,r6)
	mov.l	@(12,r3),r4
	mov.l	@(16,r7),r5
	mov.l	r11,@(8,r6)
	xor	r5,r4
	mov.l	@(0,r7),r5
	xor	r10,r5
	mov.l	@(12,r7),r10
	or	r5,r4
	mov.l	@(4,r7),r5
	xor	r10,r5
	mov.l	@(12,r6),r10
	or	r5,r4
	mov.l	@(24,r7),r5
	mov	r7,r6
	xor	r10,r5
	mov.l	@(20,r7),r10
	or	r5,r4
	mov.l	@(28,r7),r5
	add	#127,r6
	xor	r10,r5
	or	r5,r4
	tst	r4,r4
	add	#17,r6
	movt	r0
	mov.l	r3,@(48,r6)
	add	#-1,r0
	mov.w	.Lpoly_k5,r4
	and	#2,r0
	mov.l	r0,@(52,r6)
	mov.l	@r9,r0
	add	r14,r9
	mov.l	@r9,r3
	add	r14,r9
	mov.l	@r9,r5
	mov	r0,r8
	mov	r3,r10
	mov	r0,r9
	mov	r5,r13
	mov	r5,r12
	shld	r1,r10
	mov.l	@(32,r7),r6
	shld	r4,r13
	mov.l	@(36,r7),r14
	shld	r1,r8
	mov	r3,r11
	shld	r1,r12
	mov.w	.Lpoly_k1023,r3
	shad	r2,r10
	shld	r4,r9
	shad	r2,r13
	shad	r2,r8
	shad	r2,r12
	add	r6,r10
	shad	r2,r9
	mov	r10,r0
	add	r14,r13
	add	r6,r8
	add	r6,r12
	mov	r13,r6
	add	r14,r9
	shld	r4,r11
	mov	r12,r4
	sub	r8,r0
	sub	r9,r6
	cmp/gt	r3,r0
	shad	r2,r11
	bt	.Lpoly_rej1
	mul.l	r0,r6
	add	r14,r11
	mov.w	.Lpoly_km1023,r14
	mov	r11,r5
	sub	r8,r4
	sub	r9,r5
	cmp/ge	r14,r0
	sts	macl,r1
	mul.l	r5,r4
	bf	.Lpoly_rej1
	cmp/gt	r3,r4
	bt	.Lpoly_rej1
	cmp/ge	r14,r4
	sts	macl,r2
	bf	.Lpoly_rej1
	mov.l	@(52,r7),r4
	sub	r2,r1
	mov	r12,r2
	sub	r10,r2
	mov	r1,r0
	cmp/gt	r3,r2
	mov.w	.Lpoly_k511,r3
	bt	.Lpoly_rej1
	cmp/ge	r14,r2
	bf	.Lpoly_rej1
	mov.w	.Lpoly_km511,r14
	cmp/gt	r3,r5
	mov	r13,r2
	bt	.Lpoly_rej1
	cmp/ge	r14,r5
	bf	.Lpoly_rej1
	cmp/gt	r3,r6
	bt	.Lpoly_rej1
	cmp/ge	r14,r6
	sub	r11,r2
	bf	.Lpoly_rej1
	cmp/gt	r3,r2
	mov.l	@(44,r7),r3
	bt	.Lpoly_rej1
	cmp/ge	r14,r2
	bf	.Lpoly_rej1
	tst	r1,r1
	bt	.Lpoly_rej1
	shll	r0
	subc	r0,r0
	mov.l	@(60,r7),r2
	xor	r0,r1
	mov	r10,r6
	sub	r0,r1
	mov	r12,r14
	add	#1,r2
	shlr	r1
	mov.l	r2,@(60,r7)
	mov	r1,r0
	mov.l	@(40,r7),r1
	mov.l	@(48,r7),r2
	sub	r3,r4
	sub	r1,r6
	sub	r1,r2
	mov	r2,r5
	sub	r1,r14
	or	r4,r5
	cmp/pz	r5
	mov	r8,r5
	sub	r1,r5
	bf	.Lpoly_out1
	cmp/hi	r2,r5
	mov	r9,r5
	bt	.Lpoly_out1
	cmp/hi	r2,r6
	bt	.Lpoly_out1
	cmp/hi	r2,r14
	sub	r3,r5
	bt	.Lpoly_out1
	mov	r11,r6
	cmp/hi	r4,r5
	sub	r3,r6
	bt	.Lpoly_out1
	mov	r13,r14
	cmp/hi	r4,r6
	sub	r3,r14
	bt	.Lpoly_out1
	cmp/hi	r4,r14
	bt	.Lpoly_out1
	bra	.Lpoly_join
	nop
.Lpoly_rej1:
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	rts
	mov	#3,r0
.Lpoly_k1023:	.word	1023
.Lpoly_km1023:	.word	-1023
.Lpoly_k511:		.word	511
.Lpoly_km511:	.word	-511
.Lpoly_k21:		.word	21
.Lpoly_km21:		.word	-21
.Lpoly_k5:		.word	5
.Lpoly_k7fff:	.word	0x7FFF
.Lpoly_k1ff:		.word	0x1FF
.Lpoly_out1:
	mov	r8,r1
	mov	r8,r2
	cmp/gt	r10,r1
	bf	.Lpoly_o1
	mov	r10,r1
.Lpoly_o1:
	cmp/gt	r12,r1
	bf	.Lpoly_o2
	mov	r12,r1
.Lpoly_o2:
	cmp/gt	r2,r10
	bf	.Lpoly_o3
	mov	r10,r2
.Lpoly_o3:
	cmp/gt	r2,r12
	bf	.Lpoly_o4
	mov	r12,r2
.Lpoly_o4:
	mov	r9,r3
	mov	r9,r4
	cmp/gt	r11,r3
	bf	.Lpoly_o5
	mov	r11,r3
.Lpoly_o5:
	cmp/gt	r13,r3
	bf	.Lpoly_o6
	mov	r13,r3
.Lpoly_o6:
	cmp/gt	r4,r11
	bf	.Lpoly_o7
	mov	r11,r4
.Lpoly_o7:
	cmp/gt	r4,r13
	bf	.Lpoly_o8
	mov	r13,r4
.Lpoly_o8:
	mov.l	@(40,r7),r5
	mov.l	@(48,r7),r6
	cmp/gt	r6,r2
	bf	.Lpoly_o9
	mov	r6,r2
.Lpoly_o9:
	cmp/gt	r1,r5
	bf	.Lpoly_o10
	mov	r5,r1
.Lpoly_o10:
	sub	r1,r2
	add	#1,r2
	mov.l	@(44,r7),r5
	mov.l	@(52,r7),r6
	cmp/gt	r6,r4
	bf	.Lpoly_o11
	mov	r6,r4
.Lpoly_o11:
	cmp/gt	r3,r5
	bf	.Lpoly_o12
	mov	r5,r3
.Lpoly_o12:
	sub	r3,r4
	add	#1,r4
	cmp/pl	r2
	bf	.Lpoly_nobox
	cmp/pl	r4
	bf	.Lpoly_nobox
	mul.l	r2,r4
	sts	macl,r1
	cmp/gt	r1,r0
	bf	.Lpoly_join
	bra	.Lpoly_join
	mov	r1,r0
.Lpoly_nobox:
	bra	.Lpoly_join
	mov	#0,r0
.Lpoly_join:
	mov	r7,r6
	mov.l	.Lpoly_ksink,r5
	add	#127,r6
	add	#17,r6
	mov.l	@(48,r6),r3
	mov.l	@(4,r3),r1
	mov.l	@(8,r3),r2
	shld	r1,r0
	mov.l	@r5,r1
	mov	r0,r4
	shlr2	r4
	add	r4,r0
	mov	r0,r4
	shlr	r4
	and	r2,r4
	mov	r12,r2
	add	r4,r0
	mov.l	@(56,r7),r4
	add	#16,r0
	add	r0,r4
	mov	r8,r0
	shll16	r0
	mov.l	r4,@(56,r7)
	xtrct	r10,r0
	mov	r11,r4
	shll16	r2
	movca.l	r0,@r1
	xtrct	r9,r2
	mov.l	@(32,r3),r10
	shll16	r4
	mov.l	r2,@(4,r1)
	xtrct	r13,r4
	mov.l	@(56,r6),r8
	mov.l	r4,@(8,r1)
	mov	#-1,r2
	mov.l	@r3,r4
	shlr8	r2
	mov.l	@r8,r12
	and	r4,r10
	mov.l	@(60,r6),r9
	add	r10,r8
	mov.l	@(28,r3),r11
	mov.l	@r8,r13
	and	r2,r12
	mov.l	r12,@(12,r1)
	add	r10,r8
	and	r2,r13
	mov.l	@(4,r9),r12
	add	r4,r9
	mov.l	r13,@(16,r1)
	mov.l	@(4,r9),r13
	add	r4,r9
	mov.l	@r8,r0
	and	r11,r12
	mov.l	@(4,r9),r14
	and	r11,r13
	and	r2,r0
	and	r11,r14
	mov.l	r0,@(20,r1)
	extu.b	r14,r0
	shll8	r0
	extu.b	r13,r2
	or	r2,r0
	shll8	r0
	extu.b	r12,r2
	shlr8	r14
	shlr8	r12
	or	r2,r0
	mov.l	@(8,r5),r2
	shll8	r14
	shlr8	r13
	shll16	r12
	or	r13,r14
	shll8	r12
	or	r2,r14
	mov.l	@(12,r5),r2
	or	r12,r0
	mov.l	r0,@(24,r1)
	mov.w	@r2,r0
	mov.l	r14,@(28,r1)
	add	#32,r1
	add	#1,r0
	mov.l	r1,@r5
	mov.w	r0,@r2
	mov.l	@(52,r6),r0
	tst	r0,r0
	bf	.Lpoly_send1
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	rts
	mov.l	@r15+,r8
.Lpoly_send1:
	mov	r7,r13
	mov	r7,r14
	add	#64,r13
	mov.l	@(4,r7),r2
	add	#104,r14
	mov.l	@(32,r13),r9
	mov.l	@(36,r13),r10
	add	#104,r14
	mov.l	@(48,r13),r6
	mov.l	r2,@(12,r7)
	mov.l	r9,@(4,r14)
	shll8	r9
	mov.l	r10,@(8,r14)
	shll16	r10
	mov.l	r6,@(20,r14)
	shll16	r6
	mov.l	@(44,r7),r2
	shll2	r9
	mov.l	@(0,r7),r1
	shll2	r10
	mov.l	@(28,r13),r8
	shll2	r6
	mov.l	@(12,r3),r4
	shll2	r10
	mov.l	@(44,r13),r12
	or	r8,r9
	mov.l	r2,@(36,r14)
	shll8	r2
	mov.l	r1,@(8,r7)
	shll2	r6
	mov.l	r4,@(16,r7)
	shll2	r2
	mov.l	@(40,r7),r1
	or	r10,r9
	mov.l	r12,@(16,r14)
	shll8	r12
	mov.l	r4,@(24,r14)
	shll2	r6
	shll16	r4
	mov.l	@(28,r7),r5
	mov.l	@(40,r13),r11
	or	r1,r2
	mov.l	r8,@(0,r14)
	shll2	r12
	mov.l	r1,@(32,r14)
	or	r6,r9
	shll8	r4
	mov.l	@(16,r13),r1
	mov.l	@(20,r13),r8
	or	r11,r12
	mov.l	r5,@(20,r7)
	or	r4,r9
	mov.l	@(24,r7),r5
	xor	r9,r1
	mov.l	@(12,r13),r10
	xor	r12,r8
	mov.l	r11,@(12,r14)
	or	r8,r1
	mov.l	@(24,r13),r11
	xor	r5,r10
	or	r10,r1
	mov.l	r5,@(28,r14)
	xor	r2,r11
	or	r11,r1
	tst	r1,r1
	bt	.Lpoly_same
	mov.l	r9,@(16,r13)
	mov.l	r12,@(20,r13)
	mov.l	r5,@(12,r13)
	mov.l	r2,@(24,r13)
	bra	.Lpoly_sendpop
	mov	#2,r0
.Lpoly_same:
	mov	#0,r0
.Lpoly_sendpop:
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	rts
	mov.l	@r15+,r8
	.align	2
.Lpoly_k1ffffc:	.long	0x1FFFFC
.Lpoly_k1fffd0:	.long	0x1FFFD0
.Lpoly_ksink:	.long	_bp_gpu_sink
	.align	5
.Lpoly_ops:
	.long	4, -2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 20h
	.long	4, -2, 0, 4, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 21h
	.long	4, -2, -1, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 22h
	.long	4, -2, -1, 6, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 23h
	.long	8, -1, 0, 1, 1, 0, 0, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 24h
	.long	8, -1, 0, 5, 1, 1, 0, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 25h
	.long	8, -1, -1, 3, 1, 0, 1, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 26h
	.long	8, -1, -1, 7, 1, 1, 1, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 27h
	.long	4, -2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 28h
	.long	4, -2, 0, 4, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 29h
	.long	4, -2, -1, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 2Ah
	.long	4, -2, -1, 6, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0	! 2Bh
	.long	8, -1, 0, 1, 1, 0, 0, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 2Ch
	.long	8, -1, 0, 5, 1, 1, 0, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 2Dh
	.long	8, -1, -1, 3, 1, 0, 1, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 2Eh
	.long	8, -1, -1, 7, 1, 1, 1, 65535, 0, 0, 0, 0, 0, 0, 0, 0	! 2Fh
	.long	8, -2, 0, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 30h
	.long	8, -2, 0, 4, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 31h
	.long	8, -2, -1, 2, 0, 0, 1, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 32h
	.long	8, -2, -1, 6, 0, 1, 1, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 33h
	.long	12, -1, 0, 1, 1, 0, 0, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 34h
	.long	12, -1, 0, 5, 1, 1, 0, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 35h
	.long	12, -1, -1, 3, 1, 0, 1, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 36h
	.long	12, -1, -1, 7, 1, 1, 1, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 37h
	.long	8, -2, 0, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 38h
	.long	8, -2, 0, 4, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 39h
	.long	8, -2, -1, 2, 0, 0, 1, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 3Ah
	.long	8, -2, -1, 6, 0, 1, 1, 0, -1, 0, 0, 0, 0, 0, 0, 0	! 3Bh
	.long	12, -1, 0, 1, 1, 0, 0, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 3Ch
	.long	12, -1, 0, 5, 1, 1, 0, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 3Dh
	.long	12, -1, -1, 3, 1, 0, 1, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 3Eh
	.long	12, -1, -1, 7, 1, 1, 1, 65535, -1, 0, 0, 0, 0, 0, 0, 0	! 3Fh
	.size	_recompsx_gpu_poly, .-_recompsx_gpu_poly
	.popsection
)ASM\");
#endif")
// </dc-sched>
class Gpu {
	// GP0(E1h) — texture page and drawing attributes, mirrored in GPUSTAT bits 0..10.
	static var texPage = 0;

	// GP0(E6h) — mask bits, GPUSTAT 11 and 12.
	static var maskSet = false;
	static var maskCheck = false;

	// GP1(08h) — display mode, GPUSTAT 16..23 (minus display-enable).
	static var displayMode = 0;

	// GP1(03h). Note the inversion: the bit means *disabled*.
	static var displayDisabled = true;

	// GP1(04h) — DMA direction, GPUSTAT 29..30.
	static var dmaDirection = 0;

	/** GP0(1Fh) sets it, GP1(02h) clears it, and it drives I_STAT bit 1. */
	static var irqPending = false;

	// Drawing area and offset. Kept because games read them back through GP1(10h).
	static var drawAreaTopLeft(get, set):Int;
	static inline function get_drawAreaTopLeft():Int return GpuFile.get(7);
	static inline function set_drawAreaTopLeft(v:Int):Int { GpuFile.set(7, v); return v; }
	static var drawAreaBottomRight = 0;
	static var drawOffset = 0;
	static var textureWindow(get, set):Int;
	static inline function get_textureWindow():Int return GpuFile.get(6);
	static inline function set_textureWindow(v:Int):Int { GpuFile.set(6, v); return v; }

	// Display origin and ranges, which the scanout will want.
	static var displayStart = 0;
	static var displayRangeH = 0;
	static var displayRangeV = 0;

	/** What GP1(10h) left for the next read of the data port. */
	static var readLatch = 0;

	// The scanout reads these; nothing else outside this class may.
	public static inline function displayOrigin():Int return displayStart;
	public static inline function displayModeBits():Int return displayMode;
	public static inline function displayOn():Bool return !displayDisabled;

	/**
		How many GP0 words have arrived, and how many were commands rather than parameters.

		Deterministic, and the first evidence that a game is drawing at all — a title screen that
		submits nothing is a different problem from one that submits and shows nothing.
	**/
	public static var wordsReceived(get, set):Int;
	static inline function get_wordsReceived():Int return GpuFile.get(34);
	static inline function set_wordsReceived(v:Int):Int { GpuFile.set(34, v); return v; }
	public static var commandsReceived(get, set):Int;
	static inline function get_commandsReceived():Int return GpuFile.get(35);
	static inline function set_commandsReceived(v:Int):Int { GpuFile.set(35, v); return v; }

	/** How many words of the command in progress are still expected. */
	static var pending(get, set):Int;
	static inline function get_pending():Int return GpuFile.get(31);
	static inline function set_pending(v:Int):Int { GpuFile.set(31, v); return v; }

	/**
		A CPU-to-VRAM transfer in flight: GP0(A0h) is a header followed by raw pixel data, and the
		data's length is only known once the size word has arrived. So the packet machinery cannot
		size it up front the way it does a polygon — the transfer arms itself when its header is
		complete and swallows halfwords straight into the framebuffer after that.

		This is how a game gets an image onto the screen without drawing anything: fonts, logos and
		loading screens are uploads, not primitives. Counting the words and discarding them, which
		is what this did, renders a game that draws nothing as a game that shows nothing — and the
		two look identical from outside.
	**/
	static var xferLeft(get, set):Int;
	static inline function get_xferLeft():Int return GpuFile.get(32);
	static inline function set_xferLeft(v:Int):Int { GpuFile.set(32, v); return v; }
	static var xferX = 0;
	static var xferY = 0;
	static var xferW = 0;
	static var xferH = 0;
	static var xferI = 0;
	// The next texel's column and row in the rectangle, stepped rather than derived from xferI:
	// `xferI % xferW` and `xferI / xferW` were two divisions a texel, in software on the SH-4.
	static var xferCol = 0;
	static var xferRow = 0;
	// Whether any texel of this upload (or of the current copy) differed from what VRAM held. A
	// hardware backend is told of a write only when it changed something: games upload the same
	// palette or texture again and again, and each report made the Dreamcast decode a page anew.
	static var xferChanged = false;
	static var copyChanged = false;

	/**
		A VRAM-to-CPU read in flight: GP0(C0h) names a rectangle, and GPUREAD then hands it over
		two pixels a word, the first in the low halfword, left to right and top to bottom, wrapping
		within VRAM as an upload does (psx-spx, "VRAM to CPU blit"). GPUSTAT bit 27 is set while
		pixels remain, and the channel reads the port the same way (`dma.Dma`).

		This is how a game keeps a picture of what it put in VRAM. Crash Bash takes its memory card
		icon and palette from VRAM when it saves, and with GPUREAD answering only GP1(10h), its
		saves carried a black palette and an empty icon, which the Dreamcast's VMU showed blank.

		What is read is emulated VRAM: uploads and copies on every path, and drawn pixels only when
		the software rasteriser draws. A hardware backend's drawn pixels are its own, as for copies.
	**/
	static var readPixels = 0;
	static var readX = 0;
	static var readY = 0;
	static var readW = 0;
	static var readCol = 0;
	static var readRow = 0;

	/**
		A backend whose drawn pixels become texels hears of every upload, changed or not
		(bp_caps(BP_CAP_GPU_UPLOADS), set by the launcher). Its copy of VRAM holds what it drew,
		which emulated VRAM never does, so an upload that leaves emulated VRAM as it was can still
		replace what the backend drew there: Crash Bash clears nearly all of VRAM with a 511x511
		rectangle before its menu and uploads its font again, and the browser, never told, kept the
		black and drew no text. Copies are not included: the runtime copies emulated VRAM, and an
		unchanged copy reported would lay stale pixels over drawn ones.
	**/
	public static var reportUploads = false;

	/** A backend that copies what it drew itself hears of every VRAM-to-VRAM copy through
		`gpuCopy` and of none through `gpuDirty` (bp_caps(BP_CAP_GPU_COPIES), set by the launcher;
		ADR-0054). **/
	public static var reportCopies = false;

	// The texture and blend state last handed to a hardware backend, packed. The ABI latches that
	// state until the next call, so it is sent only when it differs — a quad's second triangle
	// never needs it, and runs of primitives from one page and palette do not either.
	static var sentA(get, set):Int;
	static inline function get_sentA():Int return GpuFile.get(20);
	static inline function set_sentA(v:Int):Int { GpuFile.set(20, v); return v; }
	static var sentB(get, set):Int;
	static inline function get_sentB():Int return GpuFile.get(21);
	static inline function set_sentB(v:Int):Int { GpuFile.set(21, v); return v; }
	static var sentWindow(get, set):Int;
	static inline function get_sentWindow():Int return GpuFile.get(19);
	static inline function set_sentWindow(v:Int):Int { GpuFile.set(19, v); return v; }
	static var sentArea(get, set):Int;
	static inline function get_sentArea():Int return GpuFile.get(22);
	static inline function set_sentArea(v:Int):Int { GpuFile.set(22, v); return v; }

	// What the triangle path last sent, by the raw words it came from rather than packed: a
	// triangle with the same page, palette, flags and drawing area as the last one skips packing
	// them, which it did for every triangle. `sentTp` of -2 is "nothing sent by a triangle since":
	// rectHw sends a state of its own and sets it, so the next triangle compares packed again.
	static var sentTp(get, set):Int;
	static inline function get_sentTp():Int return GpuFile.get(2);
	static inline function set_sentTp(v:Int):Int { GpuFile.set(2, v); return v; }
	static var sentClut(get, set):Int;
	static inline function get_sentClut():Int return GpuFile.get(3);
	static inline function set_sentClut(v:Int):Int { GpuFile.set(3, v); return v; }
	static var sentFlags(get, set):Int;
	static inline function get_sentFlags():Int return GpuFile.get(4);
	static inline function set_sentFlags(v:Int):Int { GpuFile.set(4, v); return v; }
	static var sentAreaWord(get, set):Int;
	static inline function get_sentAreaWord():Int return GpuFile.get(5);
	static inline function set_sentAreaWord(v:Int):Int { GpuFile.set(5, v); return v; }

	// Decoded where the words that hold them are written (GP0(E3h)-(E5h), GP1(00h)), for the
	// triangle path, which decoded them for every primitive: the drawing area's corners and the
	// drawing offset, sign-extended.
	static var areaL(get, set):Int;
	static inline function get_areaL():Int return GpuFile.get(10);
	static inline function set_areaL(v:Int):Int { GpuFile.set(10, v); return v; }
	static var areaT(get, set):Int;
	static inline function get_areaT():Int return GpuFile.get(11);
	static inline function set_areaT(v:Int):Int { GpuFile.set(11, v); return v; }
	static var areaR(get, set):Int;
	static inline function get_areaR():Int return GpuFile.get(12);
	static inline function set_areaR(v:Int):Int { GpuFile.set(12, v); return v; }
	static var areaB(get, set):Int;
	static inline function get_areaB():Int return GpuFile.get(13);
	static inline function set_areaB(v:Int):Int { GpuFile.set(13, v); return v; }
	static var offsetX(get, set):Int;
	static inline function get_offsetX():Int return GpuFile.get(8);
	static inline function set_offsetX(v:Int):Int { GpuFile.set(8, v); return v; }
	static var offsetY(get, set):Int;
	static inline function get_offsetY():Int return GpuFile.get(9);
	static inline function set_offsetY(v:Int):Int { GpuFile.set(9, v); return v; }
	// The raw attribute setTexPage and setClut decoded last (-1 after a reset): a primitive naming
	// the page and palette the last one named skips both decodes.
	static var tpKey(get, set):Int;
	static inline function get_tpKey():Int return GpuFile.get(0);
	static inline function set_tpKey(v:Int):Int { GpuFile.set(0, v); return v; }
	static var clutKey(get, set):Int;
	static inline function get_clutKey():Int return GpuFile.get(1);
	static inline function set_clutKey(v:Int):Int { GpuFile.set(1, v); return v; }

	/** Pixels delivered by upload rather than by rasterisation. */
	public static var uploaded(default, null) = 0;

	/** GP1(05h) writes — how often the game moves the displayed window. */
	public static var flips(default, null) = 0;

	/** A polygon's vertices, decoded once per packet. Allocated at boot, never per primitive. */
	static var vx:Array<Int>;
	static var vy:Array<Int>;
	static var vc:Array<Int>;
	static var vu:Array<Int>;
	static var vv:Array<Int>;

	/**
		The texture the primitive being rasterised reads from, decoded once per packet.

		Carried in statics rather than through the call, because a textured triangle needs fifteen
		numbers and the portable subset has no structs to pass them in. Set immediately before
		`triangle`, read only inside it.
	**/
	static var texEnabled(get, set):Bool;
	static inline function get_texEnabled():Bool return GpuFile.get(16) != 0;
	static inline function set_texEnabled(v:Bool):Bool { GpuFile.set(16, v ? 1 : 0); return v; }
	static var texRaw(get, set):Bool;
	static inline function get_texRaw():Bool return GpuFile.get(17) != 0;
	static inline function set_texRaw(v:Bool):Bool { GpuFile.set(17, v ? 1 : 0); return v; }
	static var texDepth(get, set):Int;        // 0 = 4bpp indexed, 1 = 8bpp indexed, 2 = 15bpp direct
	static inline function get_texDepth():Int return GpuFile.get(25);
	static inline function set_texDepth(v:Int):Int { GpuFile.set(25, v); return v; }
	static var texBaseX(get, set):Int;        // in halfwords
	static inline function get_texBaseX():Int return GpuFile.get(23);
	static inline function set_texBaseX(v:Int):Int { GpuFile.set(23, v); return v; }
	static var texBaseY(get, set):Int;
	static inline function get_texBaseY():Int return GpuFile.get(24);
	static inline function set_texBaseY(v:Int):Int { GpuFile.set(24, v); return v; }
	static var clutX(get, set):Int;
	static inline function get_clutX():Int return GpuFile.get(26);
	static inline function set_clutX(v:Int):Int { GpuFile.set(26, v); return v; }
	static var clutY(get, set):Int;
	static inline function get_clutY():Int return GpuFile.get(27);
	static inline function set_clutY(v:Int):Int { GpuFile.set(27, v); return v; }

	/**
		Whether the primitive blends with what is already there, and how.

		The mode is GPU state — GP0(E1h) bits 5-6 — which a textured polygon may override for
		itself through its own texpage word. Whether blending happens at all is the command's own
		bit 1, and for a textured pixel the texel gets the final say through its bit 15.
	**/
	static var semiMode(get, set):Int;
	static inline function get_semiMode():Int return GpuFile.get(28);
	static inline function set_semiMode(v:Int):Int { GpuFile.set(28, v); return v; }
	static var semiTransparent(get, set):Bool;
	static inline function get_semiTransparent():Bool return GpuFile.get(18) != 0;
	static inline function set_semiTransparent(v:Bool):Bool { GpuFile.set(18, v ? 1 : 0); return v; }

	/** The command word and its parameters, gathered until the packet is whole. */
	static var packet:Array<Int>;
	static var packetLen(get, set):Int;
	static inline function get_packetLen():Int return GpuFile.get(33);
	static inline function set_packetLen(v:Int):Int { GpuFile.set(33, v); return v; }

	/** Primitives actually rasterised, and pixels written. The proof a frame exists. */
	public static var primitives(get, set):Int;
	static inline function get_primitives():Int return GpuFile.get(15);
	static inline function set_primitives(v:Int):Int { GpuFile.set(15, v); return v; }
	public static var pixels(default, null) = 0;

	/**
		How long the primitives accepted since `takeWork` would have kept a PlayStation GPU busy, in
		CPU cycles — an estimate, for pacing channel 2's list walk (`dma.Dma`), which on hardware
		waits on the GPU's 16-word FIFO and so moves at the speed the GPU draws. Taken from the
		geometry every drawing path shares, after the same rejects, so it is the same whether the
		software rasteriser or a backend draws the picture. The GPU runs at 53.69 MHz to the CPU's
		33.87: a textured pixel about a GPU clock, 0.63 of a CPU cycle; an untextured one half that;
		half as much again semi-transparent; a setup cost per primitive. Only what the drawing area
		lets through is counted — a triangle's area, but no more than its bounding box clipped to
		the area: counted whole, the floor under a near camera, most of it off screen, made Crash
		Bash's walks longer than a frame and its hub ran at ten frames a second. A rectangle is its
		clipped pixels, a fill an eighth of a cycle a pixel, a VRAM copy a cycle. Not a
		cycle-accurate GPU: a walk roughly as slow as the hardware's is the whole point. Nothing else
		in the machine reads it.
	**/
	static var work(get, set):Int;
	static inline function get_work():Int return GpuFile.get(14);
	static inline function set_work(v:Int):Int { GpuFile.set(14, v); return v; }
	static inline var TRI_SETUP = 16;

	/** The GPU time owed since the last call, which starts owing afresh. */
	public static inline function takeWork():Int {
		final w = work;
		work = 0;
		return w;
	}

	/** A triangle's share, from its edge function — twice its area in pixels — and its bounding
	    box, which is clipped to the drawing area here. */
	static inline function triangleWork(twiceArea:Int, loX:Int, hiX:Int, loY:Int, hiY:Int):Void {
		final l = areaL, t = areaT, r = areaR, b = areaB;
		final w = (hiX < r ? hiX : r) - (loX > l ? loX : l) + 1;
		final h = (hiY < b ? hiY : b) - (loY > t ? loY : t) + 1;
		final box = w > 0 && h > 0 ? w * h : 0;
		final area = (twiceArea < 0 ? -twiceArea : twiceArea) >> 1;
		pixelWork(area < box ? area : box, texEnabled);
	}

	/** `px` pixels drawn: 5/8 of a cycle textured, 5/16 untextured, half again semi-transparent. */
	static inline function pixelWork(px:Int, textured:Bool):Void {
		final c = textured ? (px >> 1) + (px >> 3) : (px >> 2) + (px >> 4);
		work = (work + c + (semiTransparent ? c >> 1 : 0) + TRI_SETUP) | 0;
	}

	/**
		Whether primitives are handed to the backend instead of being rasterised here.

		**False on every path that hashes anything, and that is the point.** A backend with a
		rasteriser of its own can draw a PlayStation scene far faster than a 200 MHz console can
		draw it in software, but the pixels it produces are its own — near enough to look right,
		not near enough to be the same bytes. So this is a fork in *presentation* and never in
		state: everything the emulated machine can observe (GP0 parsing, GPUSTAT, interrupts,
		cycle costs, uploads, VRAM-to-VRAM copies) happens identically either way, and only the
		rasterised pixels go elsewhere.

		Nothing turns it on by itself. A host has to ask, with `--video-hw`, *and* its backend has
		to answer `BP_CAP_GPU_DRAW`; the JavaScript shim answers no by construction, so the
		reference target cannot take this path even by accident. Headless digest runs therefore
		never see it. See docs/decisions/ADR-0011.
	**/
	public static var hw(get, set):Bool;
	static inline function get_hw():Bool return GpuFile.get(29) != 0;
	static inline function set_hw(v:Bool):Bool { GpuFile.set(29, v ? 1 : 0); return v; }

	/**
		Hardware mode: the drawing area is VRAM no picture is made of, so what is drawn there is
		rasterised here, into emulated VRAM, rather than handed to the backend.

		A game draws into VRAM it never displays to make a texture for itself. Crash Bandicoot:
		Warped draws Crash's silhouette into 64x64 at (0, 320) every frame and lays it on the
		ground as his shadow, through a 4-bit palette. A backend's pixels never reach emulated
		VRAM, so that texture stayed whatever the level had uploaded there — on the Dreamcast, a
		dark square under Crash. Those pixels are not presentation but state that a later
		primitive reads, so they take the software path, exactly as with no backend at all, and
		the backend hears of the rectangle as it hears of an upload (`flushDrawn`).

		"No picture": the drawing area's corner lies in neither of the last two rectangles the
		scanout presented — a double-buffered game shows one and draws into the other — and the
		area is smaller than three quarters of the picture either way, which a buffer about to be
		shown for the first time is not. The Dreamcast backend's screen_origin decides the same
		from the same rectangles, so what it would decline to draw is what this draws.
	**/
	static var offscreen(get, set):Bool;
	static inline function get_offscreen():Bool return GpuFile.get(30) != 0;
	static inline function set_offscreen(v:Bool):Bool { GpuFile.set(30, v ? 1 : 0); return v; }

	// The last two distinct rectangles the scanout presented, newest first. See `shown`.
	static var shownX0 = 0;
	static var shownY0 = 0;
	static var shownW0 = 0;
	static var shownH0 = 0;
	static var shownX1 = 0;
	static var shownY1 = 0;
	static var shownW1 = 0;
	static var shownH1 = 0;

	// What primitives drawn here under hardware mode have covered since the backend last heard,
	// corners inclusive; empty while drawnX0 > drawnX1. Inside one drawing area by construction.
	static var drawnX0 = 1024;
	static var drawnY0 = 512;
	static var drawnX1 = -1;
	static var drawnY1 = -1;

	/**
		The scanout presented this rectangle of VRAM; never called for a blank screen. The last
		two distinct ones are kept, as the Dreamcast backend keeps them from the same calls.
	**/
	public static function shown(x:Int, y:Int, w:Int, h:Int):Void {
		if (x == shownX0 && y == shownY0 && w == shownW0 && h == shownH0) return;
		else {}
		shownX1 = shownX0;
		shownY1 = shownY0;
		shownW1 = shownW0;
		shownH1 = shownH0;
		shownX0 = x;
		shownY0 = y;
		shownW0 = w;
		shownH0 = h;
		classifyArea();
	}

	static inline function holds(rx:Int, ry:Int, rw:Int, rh:Int, x:Int, y:Int):Bool {
		return rw > 0 && rh > 0 && x >= rx && x < rx + rw && y >= ry && y < ry + rh;
	}

	static inline function meets(rx:Int, ry:Int, rw:Int, rh:Int, x:Int, y:Int, w:Int, h:Int):Bool {
		return rw > 0 && !(rx + rw <= x || x + w <= rx || ry + rh <= y || y + h <= ry);
	}

	/** Decides `offscreen` again: the drawing area or the rectangles shown have changed. */
	static function classifyArea():Void {
		// Whatever was drawn in the old area is complete; the backend hears of it before any
		// primitive that might sample it.
		flushDrawn();
		final x = drawAreaTopLeft & 0x3FF;
		final y = (drawAreaTopLeft >>> 10) & 0x1FF;
		final w = (drawAreaBottomRight & 0x3FF) - x + 1;
		final h = ((drawAreaBottomRight >>> 10) & 0x1FF) - y + 1;
		offscreen = hw && !holds(shownX0, shownY0, shownW0, shownH0, x, y)
			&& !holds(shownX1, shownY1, shownW1, shownH1, x, y)
			&& !(w * 4 >= shownW0 * 3 && h * 4 >= shownH0 * 3);
	}

	/** A primitive drawn here under hardware mode covered these pixels (inclusive corners). */
	static function noteDrawn(x0:Int, y0:Int, x1:Int, y1:Int):Void {
		if (x0 > x1 || y0 > y1) return;
		else {}
		if (x0 < drawnX0) drawnX0 = x0;
		else {}
		if (y0 < drawnY0) drawnY0 = y0;
		else {}
		if (x1 > drawnX1) drawnX1 = x1;
		else {}
		if (y1 > drawnY1) drawnY1 = y1;
		else {}
	}

	/**
		Reports what was drawn here under hardware mode, as an upload is reported: at the end of
		each drawing area and at every present, so a backend that samples it — or shows it —
		reads the pixels, not what they replaced.
	**/
	public static function flushDrawn():Void {
		if (drawnX0 > drawnX1) return;
		else {}
		reportDrawn();
	}

	static function reportDrawn():Void {
		final x0 = drawnX0 < 0 ? 0 : drawnX0;
		final y0 = drawnY0 < 0 ? 0 : drawnY0;
		final x1 = drawnX1 > 1023 ? 1023 : drawnX1;
		final y1 = drawnY1 > 511 ? 511 : drawnY1;
		drawnX0 = 1024;
		drawnY0 = 512;
		drawnX1 = -1;
		drawnY1 = -1;
		if (x0 <= x1 && y0 <= y1) Backend.gpuDirty(x0, y0, x1 - x0 + 1, y1 - y0 + 1);
		else {}
	}

	public static function init():Void {
		// The register file starts zeroed; these start elsewhere.
		tpKey = -1;
		clutKey = -1;
		sentTp = -2;
		sentClut = -2;
		sentFlags = -2;
		sentAreaWord = -2;
		sentWindow = -1;
		sentA = -1;
		sentB = -1;
		sentArea = -1;
		wrapped = RawMem.alloc(48);
		packet = [for (_ in 0...32) 0];
		vx = [for (_ in 0...4) 0];
		vy = [for (_ in 0...4) 0];
		vc = [for (_ in 0...4) 0];
		vu = [for (_ in 0...4) 0];
		vv = [for (_ in 0...4) 0];
		opCount = GpuTables.ops();
		wholeWords = GpuTables.whole();
		for (k in 0...0x60) {
			final op = 0x20 + k;
			MemA.set32(wholeWords, k << 2, op <= 0x3F ? polygonWords(op) : (op >= 0x60 ? rectangleWords(op) : -1));
		}
		Vram.init();
		shownX0 = 0;
		shownY0 = 0;
		shownW0 = 0;
		shownH0 = 0;
		shownX1 = 0;
		shownY1 = 0;
		shownW1 = 0;
		shownH1 = 0;
		drawnX0 = 1024;
		drawnY0 = 512;
		drawnX1 = -1;
		drawnY1 = -1;
		reset();
		wordsReceived = 0;
		commandsReceived = 0;
		primitives = 0;
		pixels = 0;
		uploaded = 0;
		xferLeft = 0;
	}

	/** GP1(00h). psx-spx: GPUSTAT becomes 14802000h, which is what these defaults produce. */
	static function reset():Void {
		texPage = 0;
		maskSet = false;
		maskCheck = false;
		displayMode = 0;
		displayDisabled = true;
		dmaDirection = 0;
		irqPending = false;
		drawAreaTopLeft = 0;
		drawAreaBottomRight = 0;
		drawOffset = 0;
		areaL = 0;
		areaT = 0;
		areaR = 0;
		areaB = 0;
		offsetX = 0;
		offsetY = 0;
		textureWindow = 0;
		semiMode = 0;
		tpKey = -1;
		clutKey = -1;
		semiTransparent = false;
		displayStart = 0;
		// The retail defaults: a 320x240 window in the middle of the visible area.
		displayRangeH = 0xC60260;
		displayRangeV = 0x3FC10;
		readLatch = 0;
		readPixels = 0;
		pending = 0;
		classifyArea();
	}

	// ---- the two ports ---------------------------------------------------------------------------

	public static function writeGp0(v:Int):Void {
		wordsReceived++;
		// One if/else chain rather than two early returns: that is the shape Haxe's inliner
		// accepts, and `Memory.ioWrite32` inlines this call so a GP0 word costs one frame less.
		if (xferLeft > 0) transferWord(v);
		else if (pending > 0) consumeParameter(v);
		else {
			commandsReceived++;
			packetLen = 0;
			push(v);
			command(v);
			if (pending == 0) draw();
			else {}
		}
	}

	/**
		An ordering-table node's words, straight from RAM: how the GPU channel feeds GP0.

		Word by word through `writeGp0` is exact, but it runs the command state machine on every
		word, and a packet's parameters each went through `consumeParameter` and `push` only to be
		copied into `packet`. A game builds its table one packet to a node, so when a polygon or
		rectangle starts at a command boundary and ends inside this node, it is copied in one pass
		and drawn, leaving every counter and field as the word path would have. Everything else —
		state commands, transfers, a packet split across nodes — takes the word path.
	**/
	public static function writeGp0Words(ram:RawBuf, addr:Int, count:Int):Void {
		// An upload a list carries goes word by word: row runs here (uploadRun, as DMA2 blocks
		// have) cost the walk they are inlined into its registers — 12 % slower on Flycast for
		// uploads no game in hand sends this way (ADR-0032).
		var i = 0;
		while (i < count) {
			final v = MemA.get32(ram, (addr + (i << 2)) & 0x1FFFFC);
			final n = (xferLeft == 0 && pending == 0) ? wholeParameters(v >>> 24) : -1;
			if (n > 0 && i + n < count) {
				wholePacket(ram, addr + (i << 2), v >>> 24, n);
				i += n + 1;
			} else if (xferLeft == 0 && pending == 0 && (v >>> 24) >= 0xE1 && (v >>> 24) <= 0xE6) {
				stateCommand(v);
				i++;
			} else {
				writeGp0(v);
				i++;
			}
		}
	}

	/**
		A state command (GP0 E1h-E6h) a list carries: what `writeGp0` does with it, but for `draw`,
		which has nothing to do for one — the packet is the command alone, it takes no parameters,
		and none of `draw`'s commands is among them. Crash Bash's ordering tables carry ~450 a frame
		(a texture page or window before nearly every object), and the call to `draw` that found
		nothing to draw cost 0.11 ms of a Dreamcast frame.
	**/
	static inline function stateCommand(v:Int):Void {
		wordsReceived++;
		commandsReceived++;
		packet[0] = v;
		packetLen = 1;
		command(v);
	}

	/**
		A node that is one whole packet and nothing more — what an ordering table carries nearly
		always — drawn as `writeGp0Words` draws it, without its loop: the same test (no transfer and
		no packet in progress, a command it takes whole, every parameter in the node) and the same
		`wholePacket`, which here ends the node. True when drawn; anything else is the loop's, and
		nothing has been done. The loop kept its index, its bounds and the node's address live
		across the polygon's call, and on the SH-4 they went to the stack and back around every
		node of the list walk (docs/perf/dreamcast-ledger.md, E-160).
	**/
	public static inline function wholeNode(ram:RawBuf, addr:Int, count:Int):Bool {
		final v = MemA.get32(ram, addr & 0x1FFFFC);
		final n = (xferLeft == 0 && pending == 0) ? wholeParameters(v >>> 24) : -1;
		final whole = n > 0 && n + 1 == count;
		if (whole) wholePacket(ram, addr, v >>> 24, n);
		else {}
		return whole;
	}

	/** Parameter words of a packet `writeGp0Words` takes whole — polygons, rectangles — or -1. */
	static inline function wholeParameters(op:Int):Int {
		return (op >= 0x20 && op <= 0x7F) ? MemA.get32(wholeWords, (op - 0x20) << 2) : -1;
	}

	/** wholeParameters for GP0 20h-7Fh, from polygonWords and rectangleWords at init: a load where
		it was the arithmetic, at every command a list walk sends. Lines (40h-5Fh) are -1. */
	static var wholeWords:RawBuf;

	/** What `writeGp0` does over a command word and its `n` parameters, in one pass. */
	static function wholePacket(ram:RawBuf, at:Int, op:Int, n:Int):Void {
		wordsReceived += n + 1;
		commandsReceived++;
		MemA.set32(opCount, op << 2, MemA.get32(opCount, op << 2) + 1);
		packetLen = n + 1;
		if (hw && !offscreen && op < 0x60) polygonHw(ram, at, op);
		else wholeToPacket(ram, at, op, n);
	}

	static function wholeToPacket(ram:RawBuf, at:Int, op:Int, n:Int):Void {
		if (op < 0x60 && (op & 0x14) == 0) flatPolygon(ram, at, op);
		else {
			for (k in 0...n + 1) packet[k] = MemA.get32(ram, (at + (k << 2)) & 0x1FFFFC);
			if (op >= 0x60) drawRect(op);
			else drawPolygon(op);
		}
	}

	/**
		A flat untextured polygon (GP0 20h-23h, a quad 28h-2Bh) the software rasteriser draws —
		under hardware mode one drawn into VRAM no picture is made of (Crash 3's shadow: ~100
		triangles a frame of four or five pixels each), everything without a backend — straight
		from its words: what `drawPolygon` and `triangle` do for it, without the packet's copy, the
		vertex arrays and the general triangle's choice of path, ~1,100 SH-4 instructions a shadow
		triangle (docs/perf/dreamcast-ledger.md, E-161). `packet` and the vertex arrays keep what
		they held: nothing reads them before the next polygon or rectangle writes them.
	**/
	static function flatPolygon(ram:RawBuf, at:Int, op:Int):Void {
		final cmd = MemA.get32(ram, at & 0x1FFFFC);
		final p1 = MemA.get32(ram, (at + 4) & 0x1FFFFC);
		final p2 = MemA.get32(ram, (at + 8) & 0x1FFFFC);
		final p3 = MemA.get32(ram, (at + 12) & 0x1FFFFC);
		texEnabled = false;
		texRaw = (op & 0x01) != 0;
		semiTransparent = (op & 0x02) != 0;
		final colour = colourOf(cmd);
		flatTriangle(sx(p1), sy(p1), sx(p2), sy(p2), sx(p3), sy(p3), colour);
		if ((op & 0x08) != 0) {
			final p4 = MemA.get32(ram, (at + 16) & 0x1FFFFC);
			flatTriangle(sx(p2), sy(p2), sx(p3), sy(p3), sx(p4), sy(p4), colour);
		} else {}
	}

	/** `triangle` for one colour and no texture, its vertices given: the same winding, rejects,
	    clipping, GPU time, count, fill rule and spans. */
	static function flatTriangle(ax:Int, ay:Int, bx:Int, by:Int, cx:Int, cy:Int, colour:Int):Void {
		// The winding normalised: vertices b and c exchanged when the triangle runs clockwise.
		final cw = edge(ax, ay, bx, by, cx, cy) < 0;
		final x0 = ax, y0 = ay;
		final x1 = cw ? cx : bx, y1 = cw ? cy : by;
		final x2 = cw ? bx : cx, y2 = cw ? by : cy;
		var minX = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
		var maxX = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
		var minY = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
		var maxY = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
		if (maxX - minX > 1023 || maxY - minY > 511) {} else {
			final clipLeft = drawAreaTopLeft & 0x3FF;
			final clipTop = (drawAreaTopLeft >>> 10) & 0x1FF;
			final clipRight = drawAreaBottomRight & 0x3FF;
			final clipBottom = (drawAreaBottomRight >>> 10) & 0x1FF;
			if (minX < clipLeft) minX = clipLeft;
			else {}
			if (minY < clipTop) minY = clipTop;
			else {}
			if (maxX > clipRight) maxX = clipRight;
			else {}
			if (maxY > clipBottom) maxY = clipBottom;
			else {}
			final area = edge(x0, y0, x1, y1, x2, y2);
			if (area != 0) flatCovered(x0, y0, x1, y1, x2, y2, minX, maxX, minY, maxY, area, colour);
			else {}
		}
	}

	/** flatTriangle past its rejects: the GPU time, the count, and the pixels. */
	static inline function flatCovered(x0:Int, y0:Int, x1:Int, y1:Int, x2:Int, y2:Int,
			minX:Int, maxX:Int, minY:Int, maxY:Int, area:Int, colour:Int):Void {
		triangleWork(area, minX, maxX, minY, maxY);
		primitives++;
		if (hw) noteDrawn(minX, minY, maxX, maxY);
		else {}
		final stepX0 = y1 - y2, stepY0 = x2 - x1;
		final stepX1 = y2 - y0, stepY1 = x0 - x2;
		final stepX2 = y0 - y1, stepY2 = x1 - x0;
		final row0 = edge(x1, y1, x2, y2, minX, minY) + (topLeft(x1, y1, x2, y2) ? 0 : -1);
		final row1 = edge(x2, y2, x0, y0, minX, minY) + (topLeft(x2, y2, x0, y0) ? 0 : -1);
		final row2 = edge(x0, y0, x1, y1, minX, minY) + (topLeft(x0, y0, x1, y1) ? 0 : -1);
		if (maxX - minX < SMALL_WIDTH) smallFlat(minX, maxX, minY, maxY, row0, row1, row2,
			stepX0, stepX1, stepX2, stepY0, stepY1, stepY2, colour);
		else flatSpans(minX, maxX, minY, maxY, row0, row1, row2,
			stepX0, stepX1, stepX2, stepY0, stepY1, stepY2, colour);
	}

	/**
		A polygon packet on the hardware path, read straight from RAM.

		drawPolygon and triangle serve the software rasteriser, whose arrays, winding and giant
		span loops a backend never needs: on the Dreamcast every hardware triangle paid the whole
		rasteriser's prologue and a packet copy on the way to two backend calls, ~535 cycles a
		triangle in Ballistix. This reads the same words and leaves the same state behind —
		palette, page, flags and the primitive count — and hands the same triangles over, with
		the texture state only when it changed (sendState). `packet` is not filled: nothing reads
		it before the next command overwrites it. An untextured vertex passes u = v = 0 where the
		software arrays held whatever the last textured one left; backends do not read them for
		an untextured primitive.

		Kept out of line on C++ (`noinline`). Left to itself the compiler inlined this, the list
		walk and the DMA register write into one function — `slowWrite32`, 9 KB — and on the SH-4
		that function ran out of registers: a third of this code's instructions were stack spills
		and reloads of the same constants, some of them two instructions just to address a frame
		too large for a displacement. Here it has its own frame, and a profile names it.
	**/
	@:specifier("__attribute__((noinline))")
	static function polygonHw(ram:RawBuf, at:Int, op:Int):Void {
		// On the SH-4 the packet's common case is a core in assembly (ADR-0047: `GpuFile.poly`,
		// scripts/sh4/poly.blk, scheduled by scripts/dc-sched.py): the texture keys, the flags, each
		// triangle's rejects, count, GPU time and state test (Gpu.triState, sendState), and the
		// backend's record of the triangle, which it writes itself (ADR-0051) — 0 drawn and recorded,
		// 2 the same with a new state for the backend in words 52-61, 3 rejected — or 1 for a packet
		// that could wrap at the end of RAM or the backend has no room for, which the C form draws.
		// Elsewhere it is 1 and that form is the whole of it. So a triangle drawn under the state the
		// backend has is done when the core returns: ~100 instructions of the backend's record had
		// been here, a fifth of the GPU path (docs/perf/dreamcast-ledger.md, E-154).
		final rc = GpuFile.poly(ram, at, op, 0);
		if (rc == 0 && (op & 0x08) == 0) {} else polygonRest(ram, at, op, rc);
	}

	/** polygonHw's other cases: a new state for the backend, a quad's second triangle, a rejected
	    one, and the packet the core declined (the C form). Out of line, so that the common case's
	    frame is the core's call alone. */
	@:specifier("__attribute__((noinline))")
	static function polygonRest(ram:RawBuf, at:Int, op:Int, rc:Int):Void {
		if (rc != 1) {
			triDone(rc);
			if ((op & 0x08) != 0) triDone(GpuFile.poly(ram, at, op, 1));
			else {}
		} else {
			polygonC(ram, at, op);
			GpuFile.polyChecked(op);
		}
	}

	/** A triangle the core answered for: recorded (0), recorded under the state the backend had,
	    which then takes the new one from the GPU file's words 52-61 and the record into it (2), or
	    rejected (3). */
	static inline function triDone(rc:Int):Void {
		if (rc == 2) Backend.gpuStateAfterTri() else {}
	}

	/**
		The C form's triangle: its colour and texture words into the GPU file beside its positions
		(words 36-47: x, y, the colour word, the texture word a vertex), as the backend takes a triangle
		in words (the SH-4 core writes the same twelve itself): the
		colour the word before a vertex's position with gouraud — vertex 0's is the command word —
		the command word's otherwise; the texture word the one after, masked to its sixteen bits, 0
		untextured. Each value is read and stored, so nothing is held across the record's own work,
		where fifteen arguments built in one frame had been spilled around it (ADR-0047).
	**/
	static inline function triWords(src:RawBuf, at0:Int, a:Int, step:Int, op:Int):Void {
		final b = a + step;
		final c = b + step;
		final gouraud = (op & 0x10) != 0;
		final tm = (op & 0x04) != 0 ? 0xFFFF : 0;
		GpuFile.set(38, MemA.get32(src, gouraud ? a - 4 : at0));
		GpuFile.set(39, MemA.get32(src, a + 4) & tm);
		GpuFile.set(42, MemA.get32(src, gouraud ? b - 4 : at0));
		GpuFile.set(43, MemA.get32(src, b + 4) & tm);
		GpuFile.set(46, MemA.get32(src, gouraud ? c - 4 : at0));
		GpuFile.set(47, MemA.get32(src, c + 4) & tm);
	}

	/** polygonHw's C form: every target's but the SH-4's, and the SH-4's for a packet its core declines. */
	@:specifier("__attribute__((noinline))")
	static function polygonC(ram:RawBuf, at:Int, op:Int):Void {
		// Every word of the packet from one base, when the packet cannot wrap at the end of RAM
		// (a polygon is at most twelve words): a load each, where the index masked for the wrap
		// was an add, a mask and a load a word. A packet that could wrap is copied out first.
		var src = ram;
		var at0 = at & 0x1FFFFC;
		if (MemA.unlikely(at0 > 0x1FFFFC - 44)) {
			for (k in 0...12) MemA.set32(wrapped, k << 2, MemA.get32(ram, (at + (k << 2)) & 0x1FFFFC));
			src = wrapped;
			at0 = 0;
		} else {}
		final textured = (op & 0x04) != 0;
		// A vertex after the first is its colour word with gouraud, its position and its texture
		// word when textured: `step` bytes on from the one before.
		final step = (1 + (textured ? 1 : 0) + ((op & 0x10) != 0 ? 1 : 0)) << 2;
		final first = at0 + 4;      // vertex 0's position word
		// The palette and the page decode only when they are not the ones decoded last: the
		// palette rides on vertex 0's texture word, the page on vertex 1's.
		if (textured) {
			final ca = MemA.get32(src, first + 4) >>> 16;
			if ((ca & 0x7FFF) != clutKey) setClut(ca);
			else {}
			final tp = MemA.get32(src, first + step + 4) >>> 16;
			if ((tp & 0x1FF) != tpKey) setTexPage(tp);
			else {}
		} else {}
		texEnabled = textured;
		texRaw = (op & 0x01) != 0;
		semiTransparent = (op & 0x02) != 0;
		// One copy per kind of vertex (gouraud, textured) was tried, to take every test of `op`
		// out of the triangle: 0.13 ms a frame slower on Crash 3, the four copies' code the cost.
		triPacket(src, at0, first, first + step, first + (step << 1), op);
		// A quad's second triangle is (1, 2, 3), as drawPolygon draws it.
		if ((op & 0x08) != 0) triPacket(src, at0, first + step, first + (step << 1), first + step * 3, op);
		else {}
	}

	/** The copy of a packet that could wrap at the end of RAM (polygonHw). */
	static var wrapped:RawBuf;

	/**
		One triangle of a polygon packet, its vertices named by the offsets of their position
		words in `src`: the same two rejects, count and calls as `triangle`.

		Only the positions are read before the rejects; each vertex's colour and texture word is
		read where the backend takes it. On the SH-4 this function's registers are the cost: the
		packet's nine or so words held from the top through the tests, the work estimate and the
		state compare, beside six coordinates and a bounding box, spilled to a stack frame too
		large for a displacement — Crash 3's triangles ran ~445 cycles each here. A vertex's
		colour is the word before its position with gouraud (vertex 0's is the command word, which
		is exactly there), the command word's otherwise; its texture word is the one after, and
		read always — for an untextured packet that is a word of the packet or the one after it,
		within the twelve polygonHw made sure of — then dropped. Reading the positions again
		there, rather than holding them through triState's call, was tried: 0.06 ms slower. So
		was the backend's half in a function of its own (noinline, the positions read again):
		0.06 ms slower too (docs/perf/dreamcast-ledger.md, E-035).
	**/
	static inline function triPacket(src:RawBuf, at0:Int, a:Int, b:Int, c:Int, op:Int):Void {
		final pa = MemA.get32(src, a), pb = MemA.get32(src, b), pc = MemA.get32(src, c);
		final x0 = sx(pa), y0 = sy(pa), x1 = sx(pb), y1 = sy(pb), x2 = sx(pc), y2 = sy(pc);
		final loX = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
		final hiX = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
		final loY = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
		final hiY = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
		final e = edge(x0, y0, x1, y1, x2, y2);
		if (MemA.likely(hiX - loX <= 1023 && hiY - loY <= 511 && e != 0)) {
			// The positions into the GPU file first, so that none is held across triState's call.
			GpuFile.set(36, x0);
			GpuFile.set(37, y0);
			GpuFile.set(40, x1);
			GpuFile.set(41, y1);
			GpuFile.set(44, x2);
			GpuFile.set(45, y2);
			primitives++;
			triangleWork(e, loX, hiX, loY, hiY);
			triState();
			triWords(src, at0, a, b - a, op);
			Backend.gpuTriWords();
		} else {}
	}

	/**
		sendState for a triangle, compared by the words its state came from: the page and palette
		attributes decoded last, the flags, the texture window and the drawing area. When they
		are the ones the last triangle sent, nothing changed; otherwise sendState compares packed
		as before, so what reaches the backend is what it always was.
	**/
	static inline function triState():Void {
		final flags = (texEnabled ? 1 : 0) | (semiTransparent ? 2 : 0) | (texRaw ? 4 : 0);
		if (tpKey != sentTp || clutKey != sentClut || flags != sentFlags
				|| textureWindow != sentWindow || drawAreaTopLeft != sentAreaWord) {
			sentTp = tpKey;
			sentClut = clutKey;
			sentFlags = flags;
			sentAreaWord = drawAreaTopLeft;
			sendState(texBaseX, texBaseY, texDepth, clutX, clutY, semiMode, flags, textureWindow,
				areaL, areaT);
		} else {}
	}

	/**
		Backend.gpuState, when the state differs from the one last sent (the ABI latches it).

		Inline because it runs for every triangle and nearly always finds nothing changed. As a
		call it was the most expensive part of that nothing: on the Dreamcast ten arguments, six
		of them through the stack, for a comparison of four words.
	**/
	static inline function sendState(tx:Int, ty:Int, depth:Int, cx:Int, cy:Int, semi:Int, flags:Int,
			window:Int, dx:Int, dy:Int):Void {
		final a = tx | (ty << 10) | (depth << 20) | (semi << 22) | (flags << 24);
		final b = cx | (cy << 10);
		final area = dx | (dy << 10);
		if (a != sentA || b != sentB || window != sentWindow || area != sentArea) {
			sentA = a;
			sentB = b;
			sentWindow = window;
			sentArea = area;
			Backend.gpuState(tx, ty, depth, cx, cy, semi, flags, window, dx, dy);
		} else {}
	}

	static function consumeParameter(v:Int):Void {
		push(v);
		pending--;
		if (pending == 0) draw();
		else {}
	}

	/**
		Two pixels a word, left to right and top to bottom, wrapping at the rectangle's edge.

		Coordinates wrap within VRAM rather than clipping: the hardware's transfer is a blit into a
		1024x512 torus and games rely on it, notably when uploading a texture page that straddles
		the right edge.
	**/
	static function transferWord(v:Int):Void {
		xferLeft--;
		putTexel(v & 0xFFFF);
		putTexel((v >>> 16) & 0xFFFF);
		// Only now has VRAM changed under the rectangle: the backend contract speaks in the
		// past tense, and a backend that copies the region on hearing of it (the browser's)
		// must hear of it after the words are in. Telling it at the header, as this used to,
		// handed it the palette that was there before the upload.
		if (xferLeft == 0 && hw && (xferChanged || reportUploads)) Backend.gpuDirty(xferX, xferY, xferW, xferH);
		else {}
	}

	/** Whether a CPU-to-VRAM upload is waiting for its words. */
	public static inline function uploading():Bool return xferLeft > 0;

	/**
		Words of the upload in progress, straight from RAM at `addr`: as many of the `count` as it
		still wants, returned. What `writeGp0` does to each — the word counted, both halfwords
		through `putTexel`, the backend told when the last one lands — done a row segment at a
		time. The words carry pixels in order, low halfword first, which is RAM's byte order and
		VRAM's, so a segment that does not wrap at the right edge is one copy. Mask bits make every
		pixel a question: they are left to the per-word path (0 returned). A run stops at the end
		of RAM; the channel's next address wraps to its first word, where the next run starts.
	**/
	public static function uploadRun(ram:RawBuf, addr:Int, count:Int):Int {
		final start = addr & 0x1FFFFC;
		var words = count < xferLeft ? count : xferLeft;
		if (start + (words << 2) > 0x200000) words = (0x200000 - start) >> 2;
		else {}
		if (maskSet || maskCheck || words <= 0) return 0;
		else {}
		var p = words << 1;
		final left = xferW * xferH - xferI;       // pixels still owed; the rest of a word pads
		if (p > left) p = left;
		else {}
		var s = start;
		while (p > 0) {
			final rowLeft = xferW - xferCol;
			final n = p < rowLeft ? p : rowLeft;
			final x = (xferX + xferCol) & 1023;
			final y = (xferY + xferRow) & 511;
			if (x + n <= Vram.WIDTH) uploadSegment(ram, s, x, y, n);
			else uploadWrapping(ram, s, x, y, n);
			xferI += n;
			uploaded = (uploaded + n) | 0;
			xferCol += n;
			if (xferCol == xferW) {
				xferCol = 0;
				xferRow++;
			} else {}
			s += n << 1;
			p -= n;
		}
		xferLeft -= words;
		wordsReceived = (wordsReceived + words) | 0;
		if (xferLeft == 0 && hw && (xferChanged || reportUploads)) Backend.gpuDirty(xferX, xferY, xferW, xferH);
		else {}
		return words;
	}

	static function uploadSegment(ram:RawBuf, s:Int, x:Int, y:Int, n:Int):Void {
		final d = (y * Vram.WIDTH + x) << 1;
		if (hw && !xferChanged && !shim.Bulk.equal(Vram.data, d, ram, s, n << 1)) xferChanged = true;
		else {}
		shim.Bulk.copy(Vram.data, d, ram, s, n << 1);
	}

	/** A segment that crosses the right edge of VRAM: pixel by pixel, wrapping as putTexel does. */
	static function uploadWrapping(ram:RawBuf, s:Int, x:Int, y:Int, n:Int):Void {
		var i = 0;
		while (i < n) {
			final v = shim.RawMem.get16(ram, s + (i << 1));
			final xx = (x + i) & 1023;
			if (hw && Vram.get(xx, y) != v) xferChanged = true;
			else {}
			Vram.set(xx, y, v);
			i++;
		}
	}

	/**
		One pixel of a CPU-to-VRAM upload, obeying the mask settings.

		A copy is affected by GP0(E6) exactly as a drawn primitive is — psx-spx, "Mask/Round" — and
		this is not a fine point for the game that needs it. Crash Bash's warning screen writes its
		text in two passes: the letters first, in white with bit 15 set, then a black pass over the
		whole cell. On hardware the second pass is a masked copy: with mask-check on, it skips every
		pixel whose bit 15 is already set, so the white letters survive and the black only fills the
		gaps around them. Ignore the check — as this did — and the black pass erases the letters,
		leaving one stray column per glyph. The text was there in VRAM the whole time, drawn and
		then overwritten, which is why it read as thin strokes rather than as nothing.
	**/
	static function putTexel(p:Int):Void {
		if (xferI >= xferW * xferH) return;
		else {}
		final x = (xferX + xferCol) & 1023;
		final y = (xferY + xferRow) & 511;
		nextTexel();
		if (maskCheck && (Vram.get(x, y) & 0x8000) != 0) return;
		else {}
		final v = maskSet ? p | 0x8000 : p;
		if (hw && Vram.get(x, y) != v) xferChanged = true;
		else {}
		Vram.set(x, y, v);
	}

	static inline function nextTexel():Void {
		xferI++;
		uploaded++;
		xferCol++;
		if (xferCol == xferW) {
			xferCol = 0;
			xferRow++;
		} else {}
	}

	/** Arms the transfer once its header words are in. */
	static function beginTransfer():Void {
		xferX = packet[1] & 0x3FF;
		xferY = (packet[1] >>> 16) & 0x1FF;
		xferW = packet[2] & 0xFFFF;
		xferH = (packet[2] >>> 16) & 0xFFFF;
		if (xferW == 0) xferW = 1024;
		else {}
		if (xferH == 0) xferH = 512;
		else {}
		xferI = 0;
		xferCol = 0;
		xferRow = 0;
		xferChanged = false;
		// Two pixels to a word, rounded up: an odd-width rectangle pads its last word.
		xferLeft = (xferW * xferH + 1) >> 1;
		// The backend is told when the last word lands (transferWord), not here: the rectangle
		// is known now, but its contents are not yet what the backend would read.
	}

	/**
		Arms a VRAM-to-CPU read. psx-spx gives the size as ((n - 1) AND 3FFh) + 1 across and
		((n - 1) AND 1FFh) + 1 down, so zero is the whole of VRAM either way.
	**/
	static function beginRead():Void {
		readX = packet[1] & 0x3FF;
		readY = (packet[1] >>> 16) & 0x1FF;
		readW = (((packet[2] & 0xFFFF) - 1) & 0x3FF) + 1;
		final h = ((((packet[2] >>> 16) & 0xFFFF) - 1) & 0x1FF) + 1;
		readCol = 0;
		readRow = 0;
		readPixels = readW * h;
	}

	/** The next word of a read: two pixels, or one and a zero when the rectangle's last is odd. */
	static function readWord():Int {
		final lo = readPixel();
		final hi = readPixels > 0 ? readPixel() : 0;
		return lo | (hi << 16);
	}

	static function readPixel():Int {
		final p = Vram.get(readX + readCol, readY + readRow);
		readPixels--;
		readCol++;
		if (readCol == readW) {
			readCol = 0;
			readRow++;
		} else {}
		return p;
	}

	static function push(v:Int):Void {
		if (packetLen < 32) packet[packetLen] = v;
		else {}
		if (packetLen < 32) packetLen++;
		else {}
	}

	/**
		Turns a completed packet into pixels.

		Polygons, rectangles (sprites) and the fill command; the VRAM transfers begin here too.
	**/
	static function draw():Void {
		final op = packet[0] >>> 24;
		if (op >= 0x20 && op <= 0x3F) drawPolygon(op);
		else if (op >= 0x60 && op <= 0x7F) drawRect(op);
		else if (op == 0x02) drawFill();
		else if (op == 0xA0) beginTransfer();
		else if (op == 0xC0) beginRead();
		else if (op == 0x80) copyWithinVram();
		else {}
	}

	/**
		GP0(80h) — a rectangle of VRAM copied somewhere else in VRAM.

		Three words: the command, the source corner, the destination corner, then the size. It is
		the cheapest thing the GPU can do, and for a game built around pre-rendered artwork it is
		most of what the GPU is asked to do at all: upload the images once, then blit pieces of them
		into the visible framebuffer every frame. Crash Bash's boot sequence is nearly nothing else
		— seven thousand of these per eight thousand frames, against a single rectangle.

		Which is why its absence looked like a working emulator. The uploads landed, the ordering
		tables were built and walked, the packets arrived and were correctly sized and skipped, and
		the screen stayed black: every part of the path worked except the one that moves pixels.

		Zero width or height means the full 1024 or 512, and the copy wraps, because VRAM is a torus
		to the GPU and games rely on it. Copied through a row buffer would be tidier, but the
		overlapping case has to behave like hardware — which copies in increasing order — and doing
		it directly is both simpler and what the hardware does.
	**/
	static function copyWithinVram():Void {
		final sx0 = packet[1] & 0x3FF;
		final sy0 = (packet[1] >>> 16) & 0x1FF;
		final dx0 = packet[2] & 0x3FF;
		final dy0 = (packet[2] >>> 16) & 0x1FF;
		final w = ((packet[3] - 1) & 0x3FF) + 1;
		final h = (((packet[3] >>> 16) - 1) & 0x1FF) + 1;
		work = (work + w * h + TRI_SETUP) | 0;
		copyChanged = false;
		// Whole rows when the mask bits ask nothing of a pixel and neither run wraps at the right
		// edge. The hardware copies in increasing order, so a row copied onto itself further
		// right repeats its first pixels — memmove would not; that one case stays per pixel.
		// Rows still go top to bottom, so an overlap across rows reads what earlier rows wrote,
		// exactly as before. (BulkPaths holds this to the per-pixel code's digest.)
		final rows = !maskSet && !maskCheck && sx0 + w <= 1024 && dx0 + w <= 1024;
		for (y in 0...h) {
			final sy = (sy0 + y) & 0x1FF;
			final dy = (dy0 + y) & 0x1FF;
			if (rows && (sy != dy || dx0 <= sx0 || dx0 >= sx0 + w)) copyRow(sx0, sy, dx0, dy, w);
			else {
				for (x in 0...w) {
					final src = Vram.get((sx0 + x) & 0x3FF, sy);
					blend(dx0, dy0, x, y, src);
				}
			}
		}
		copies++;
		// The copy lands in emulated VRAM in both modes — it is state, not presentation — but a
		// backend holding a decoded copy of that region now holds a stale one — if a pixel changed.
		// Crash Bash copies one 2x1 onto itself at every buffer flip, which changes nothing and
		// told the Dreamcast backend the picture had changed ~500 times per 1000 vblanks.
		// A backend that copies what it drew itself (bp_caps(BP_CAP_GPU_COPIES), ADR-0054) hears
		// of every copy instead, in its place among the primitives: emulated VRAM lacks what the
		// backend drew, and a copy out of a buffer on screen is a copy of that. Not of one onto
		// itself, which moves nothing — unless it sets the mask bit.
		if (hw && reportCopies) {
			if (sx0 != dx0 || sy0 != dy0 || maskSet) Backend.gpuCopy(sx0, sy0, dx0, dy0, w, h, copyChanged ? 1 : 0);
			else {}
		} else if (hw && copyChanged) Backend.gpuDirty(dx0, dy0, w, h);
		else {}
	}

	/** One row of a copy, whole: what `blend` does to each pixel with no mask bits in play. */
	static function copyRow(sx:Int, sy:Int, dx:Int, dy:Int, w:Int):Void {
		final s = (sy * Vram.WIDTH + sx) << 1;
		final d = (dy * Vram.WIDTH + dx) << 1;
		final n = w << 1;
		if (hw && !copyChanged && !shim.Bulk.equal(Vram.data, d, Vram.data, s, n)) copyChanged = true;
		else {}
		shim.Bulk.copy(Vram.data, d, Vram.data, s, n);
		pixels = (pixels + w) | 0;
	}

	/** One copied pixel, honouring the mask bits exactly as a drawn one does. */
	static function blend(dx0:Int, dy0:Int, x:Int, y:Int, src:Int):Void {
		final dx = (dx0 + x) & 0x3FF;
		final dy = (dy0 + y) & 0x1FF;
		if (maskCheck && (Vram.get(dx, dy) & 0x8000) != 0) return;
		else {}
		final v = maskSet ? src | 0x8000 : src;
		if (hw && Vram.get(dx, dy) != v) copyChanged = true;
		else {}
		Vram.set(dx, dy, v);
		pixels++;
	}

	/** VRAM-to-VRAM rectangles copied. */
	public static var copies(default, null) = 0;

	static inline function colourOf(word:Int):Int {
		// 24-bit BGR to the 15-bit word VRAM holds.
		return ((word >>> 3) & 0x1F) | (((word >>> 11) & 0x1F) << 5) | (((word >>> 19) & 0x1F) << 10);
	}

	static inline function sx(word:Int):Int {
		// 11-bit signed, plus the drawing offset (decoded when GP0(E5h) set it).
		return ((word << 21) >> 21) + offsetX;
	}

	static inline function sy(word:Int):Int {
		return ((word << 5) >> 21) + offsetY;
	}

	static function drawPolygon(op:Int):Void {
		final gouraud = (op & 0x10) != 0;
		final textured = (op & 0x04) != 0;
		final quad = (op & 0x08) != 0;

		// Vertex words sit at a fixed stride once the command word is past; with gouraud the
		// first vertex's colour was the command word itself and each later vertex is preceded by
		// its own. The three arrays are allocated once at boot — these used to be array literals,
		// which is an allocation per polygon, and this game submits three million of them.
		var i = 1;
		final n = quad ? 4 : 3;
		for (v in 0...n) {
			if (gouraud && v > 0) {
				vc[v] = packet[i] & 0xFFFFFF;
				i++;
			} else {
				vc[v] = packet[0] & 0xFFFFFF;
			}
			vx[v] = sx(packet[i]);
			vy[v] = sy(packet[i]);
			i++;
			if (textured) {
				vu[v] = packet[i] & 0xFF;
				vv[v] = (packet[i] >>> 8) & 0xFF;
				// The palette rides on the first vertex's word and the texture page on the
				// second; the rest carry nothing in their high half.
				if (v == 0) setClut(packet[i] >>> 16);
				else if (v == 1) setTexPage(packet[i] >>> 16);
				else {}
				i++;
			} else {}
		}
		texEnabled = textured;
		texRaw = (op & 0x01) != 0;
		semiTransparent = (op & 0x02) != 0;
		triangle(0, 1, 2);
		if (quad) triangle(1, 2, 3);
		else {}
	}

	/** GP0's palette attribute: X in sixteens, Y in lines. */
	static function setClut(attr:Int):Void {
		clutX = (attr & 0x3F) << 4;
		clutY = (attr >>> 6) & 0x1FF;
		clutKey = attr & 0x7FFF;
	}

	/** The texture page a primitive names for itself, in the same layout GP0(E1h) uses. */
	static function setTexPage(attr:Int):Void {
		texBaseX = (attr & 0x0F) << 6;
		texBaseY = ((attr >>> 4) & 1) << 8;
		semiMode = (attr >>> 5) & 3;
		texDepth = (attr >>> 7) & 3;
		tpKey = attr & 0x1FF;
	}

	/**
		GP0(E1h) — the page, the blend mode and the depth, for everything that does not say
		otherwise.

		An untextured primitive has no texpage word of its own, so this is where its blend mode
		comes from; a textured polygon carries its own and overrides all three.
	**/
	static function setDrawMode(v:Int):Void {
		texPage = v & 0x3FFF;
		setTexPage(v & 0x1FF);
	}

	static function drawRect(op:Int):Void {
		semiTransparent = (op & 0x02) != 0;
		texEnabled = false;
		final colour = colourOf(packet[0]);
		final textured = (op & 0x04) != 0;
		var i = 1;
		final x = sx(packet[i]);
		final y = sy(packet[i]);
		i++;
		// A sprite's texture word: the texel at its top-left corner and the palette.
		var u = 0;
		var v = 0;
		if (textured) {
			u = packet[i] & 0xFF;
			v = (packet[i] >>> 8) & 0xFF;
			setClut(packet[i] >>> 16);
			i++;
		} else {}
		var w = 1;
		var h = 1;
		final size = (op >>> 3) & 3;
		if (size == 0) { w = packet[i] & 0x3FF; h = (packet[i] >>> 16) & 0x1FF; }
		else if (size == 2) { w = 8; h = 8; }
		else if (size == 3) { w = 16; h = 16; }
		else {}
		// Clipped to the drawing area (GP0 E3h/E4h, both corners inclusive), as a polygon is;
		// only GP0(02h)'s fill ignores it (psx-spx "GPU Render Rectangle Commands"). Unclipped,
		// a double-buffered game's sprites reach past the buffer being drawn into the one on
		// screen: Crash Bandicoot: Warped's stars left of the back buffer lit up in the front
		// one until its next redraw, and blinked.
		final ax0 = drawAreaTopLeft & 0x3FF;
		final ay0 = (drawAreaTopLeft >>> 10) & 0x1FF;
		final ax1 = (drawAreaBottomRight & 0x3FF) + 1;
		final ay1 = ((drawAreaBottomRight >>> 10) & 0x1FF) + 1;
		final left = x < ax0 ? ax0 : x;
		final top = y < ay0 ? ay0 : y;
		final right = x + w > ax1 ? ax1 : x + w;
		final bottom = y + h > ay1 ? ay1 : y + h;
		if (left < right && top < bottom) {
			pixelWork((right - left) * (bottom - top), textured);
			if (textured) sprite(x, y, left, top, right, bottom, u, v, packet[0] & 0xFFFFFF, (op & 0x01) != 0);
			else fillRect(left, top, right - left, bottom - top, colour);
		} else {}
		primitives++;
	}

	/**
		A textured rectangle (GP0 64h-7Fh): `left`..`right` and `top`..`bottom` (exclusive) of the
		one at `x`, `y`, what of it is inside the drawing area. Its top-left pixel shows texel `u`,
		`v`, and each pixel right of and below it the next texel — or the one before, under
		GP0(E1h)'s X- and Y-flip (bits 12 and 13) — wrapping at 256 and through the texture window
		(psx-spx, "GPU Render Rectangle Commands"). The page is GP0(E1h)'s or the last textured
		polygon's, whose texpage attribute sets the same bits. Not dithered; the command's colour
		modulates each texel unless the texture is raw, and texels are transparent and blend as a
		polygon's do.

		psx-spx's glitch for an odd Texcoord.X (a texel drawn twice every fourth or eighth pixel)
		is not reproduced: no game is known to need it.

		They had been drawn as rectangles of the command's colour, the texture word skipped: Tekken
		3 writes every name, timer and caption as raw-textured sprites of colour 0, and each one
		was a black box.
	**/
	static function sprite(x:Int, y:Int, left:Int, top:Int, right:Int, bottom:Int, u:Int, v:Int,
			bgr:Int, raw:Bool):Void {
		final flipX = (texPage & 0x1000) != 0;
		final flipY = (texPage & 0x2000) != 0;
		// The texel at the clipped corner.
		final u0 = flipX ? u - (left - x) : u + (left - x);
		final v0 = flipY ? v - (top - y) : v + (top - y);
		if (hw && !offscreen) {
			texEnabled = true;
			texRaw = raw;
			triState();
			Backend.gpuSprite(left, top, right - left, bottom - top, u0 & 0xFF, v0 & 0xFF, bgr,
				(flipX ? 1 : 0) | (flipY ? 2 : 0));
			return;
		} else {}
		if (hw) noteDrawn(left, top, right - 1, bottom - 1);
		else {}
		// The window as texturedSpans applies it, the wrap at 256 folded into the AND.
		final window = textureWindow;
		final mx = window & 0x1F, my = (window >>> 5) & 0x1F;
		final uAnd = ~(mx << 3) & 0xFF, uOr = ((window >>> 10) & 0x1F & mx) << 3;
		final vAnd = ~(my << 3) & 0xFF, vOr = ((window >>> 15) & 0x1F & my) << 3;
		final depth = texDepth, pageX = texBaseX, pageY = texBaseY;
		final clutRow = (clutY & 511) << 10, clutCol = clutX;
		final r = bgr & 0xFF, g = (bgr >>> 8) & 0xFF, b = (bgr >>> 16) & 0xFF;
		final blendable = semiTransparent, mode = semiMode;
		final check = maskCheck, set = maskSet;
		final du = flipX ? -1 : 1;
		final dv = flipY ? -1 : 1;
		final count = right - left;
		var written = 0;
		var tv = v0;
		var j = top;
		while (j < bottom) {
			final texRow = ((pageY + ((tv & vAnd) | vOr)) & 511) << 10;
			var pixel = Vram.rowStart(j) + left;
			var tu = u0;
			var k = 0;
			while (k < count) {
				final cu = (tu & uAnd) | uOr;
				// Depth 3 is read as 4-bit, as texturedSpans reads it.
				var t = 0;
				if (depth == 2) t = texel15(texRow, pageX, cu);
				else if (depth == 1) t = texel8(texRow, pageX, cu, clutRow, clutCol);
				else t = texel4(texRow, pageX, cu, clutRow, clutCol);
				if (t != 0) {
					final c = raw ? t & 0x7FFF : modulate(t, r, g, b);
					final stp = (t & 0x8000) != 0;
					written += plotPixel(pixel, c, blendable && stp, mode, check, set || stp);
				} else {}
				tu = (tu + du) | 0;
				pixel++;
				k++;
			}
			tv = (tv + dv) | 0;
			j++;
		}
		pixels = (pixels + written) | 0;
	}

	static function drawFill():Void {
		semiTransparent = false;
		texEnabled = false;
		final colour = colourOf(packet[0]);
		final x = packet[1] & 0x3F0;
		final y = (packet[1] >>> 16) & 0x1FF;
		final w = ((packet[2] & 0x3FF) + 0xF) & ~0xF;
		final h = (packet[2] >>> 16) & 0x1FF;
		work = (work + ((w * h) >> 3) + TRI_SETUP) | 0;
		fillVram(x, y, w, h, colour);
		primitives++;
	}

	/**
		GP0(02h): a rectangle of VRAM set to one colour — a VRAM operation, not a primitive.
		psx-spx, "Fill Rectangle in VRAM": the drawing area does not clip it, it is "not affected
		by the GP0(E6h) mask setting, acting as if GP0(E6h).0 and GP0(E6h).1 are both zero", and
		it writes bit 15 as zero.

		It used to share the sprite's path and obey both mask bits. The hardware path then left
		the mask bit of every pixel it filled as it was, and a mask bit is bit 15 of the halfword:
		Crash Bandicoot: Warped clears its shadow texture with a fill every frame, over a corner
		whose uploaded words have bit 15 set, and read back through a 4-bit palette every fourth
		texel of the cleared half was index 8 or more, not transparent — a hatched rectangle
		across half of Crash's shadow.

		Under hardware mode a fill that meets no picture shown is VRAM a later primitive reads, as
		an off-screen drawing area is (see `offscreen`), so it is done here and reported.
	**/
	static function fillVram(x:Int, y:Int, w:Int, h:Int, colour:Int):Void {
		if (hw && (meets(shownX0, shownY0, shownW0, shownH0, x, y, w, h)
				|| meets(shownX1, shownY1, shownW1, shownH1, x, y, w, h))) {
			fillHw(x, y, w, h, colour);
			return;
		} else {}
		final left = x < 0 ? 0 : x;
		final top = y < 0 ? 0 : y;
		final right0 = x + w;
		final bottom0 = y + h;
		final right = right0 > 1024 ? 1024 : right0;
		final bottom = bottom0 > 512 ? 512 : bottom0;
		if (left >= right || top >= bottom) return;
		else {}
		final count = right - left;
		var row = Vram.rowStart(top) + left;
		var j = top;
		while (j < bottom) {
			Vram.fillLinear(row, count, colour & 0x7FFF);
			row += Vram.WIDTH;
			j++;
		}
		pixels = (pixels + count * (bottom - top)) | 0;
		if (hw) reportFill(left, top, right - 1, bottom - 1);
		else {}
	}

	/** A fill the backend draws: under mask bits of zero, whatever GP0(E6h) says. */
	static function fillHw(x:Int, y:Int, w:Int, h:Int, colour:Int):Void {
		final masked = maskSet || maskCheck;
		if (masked) Backend.gpuMask(0, 0);
		else {}
		rectHw(x, y, w, h, colour);
		if (masked) Backend.gpuMask(maskSet ? 1 : 0, maskCheck ? 1 : 0);
		else {}
	}

	/** A fill done here under hardware mode: reported on its own, after what came before it. */
	static function reportFill(x0:Int, y0:Int, x1:Int, y1:Int):Void {
		flushDrawn();
		noteDrawn(x0, y0, x1, y1);
		reportDrawn();
	}

	/**
		A triangle, by three edge functions over its bounding box.

		The edge functions decide coverage and the fill rule; `rowSpan` solves each row's covered
		columns from them in closed form, so the span walks below visit only pixels inside the
		triangle. Degenerate and oversized triangles are dropped exactly as the hardware drops
		them: anything wider than 1023 or taller than 511 is not drawn at all.
	**/
	static function triangle(ia:Int, ib0:Int, ic0:Int):Void {
		// The hardware fork. Taken before the winding is normalised, because that is a rasteriser's
		// business and a backend with culling disabled does not care which way round the vertices
		// arrive. Both rejects below are kept so the primitive counter means the same thing in
		// either mode — a heartbeat that counted differently would make the two incomparable.
		// An off-screen drawing area is the exception, rasterised here (see `offscreen`).
		if (hw && !offscreen) {
			final hx0 = vx[ia], hy0 = vy[ia];
			final hx1 = vx[ib0], hy1 = vy[ib0];
			final hx2 = vx[ic0], hy2 = vy[ic0];
			final loX = hx0 < hx1 ? (hx0 < hx2 ? hx0 : hx2) : (hx1 < hx2 ? hx1 : hx2);
			final hiX = hx0 > hx1 ? (hx0 > hx2 ? hx0 : hx2) : (hx1 > hx2 ? hx1 : hx2);
			final loY = hy0 < hy1 ? (hy0 < hy2 ? hy0 : hy2) : (hy1 < hy2 ? hy1 : hy2);
			final hiY = hy0 > hy1 ? (hy0 > hy2 ? hy0 : hy2) : (hy1 > hy2 ? hy1 : hy2);
			if (hiX - loX > 1023 || hiY - loY > 511) return;
			else {}
			final he = edge(hx0, hy0, hx1, hy1, hx2, hy2);
			if (he == 0) return;
			else {}
			primitives++;
			triangleWork(he, loX, hiX, loY, hiY);
			sendState(texBaseX, texBaseY, texDepth, clutX, clutY, semiMode,
				(texEnabled ? 1 : 0) | (semiTransparent ? 2 : 0) | (texRaw ? 4 : 0),
				textureWindow, drawAreaTopLeft & 0x3FF, (drawAreaTopLeft >>> 10) & 0x1FF);
			Backend.gpuTri(hx0, hy0, vc[ia], vu[ia], vv[ia],
				hx1, hy1, vc[ib0], vu[ib0], vv[ib0],
				hx2, hy2, vc[ic0], vu[ic0], vv[ic0]);
			return;
		} else {}

		// One winding, decided here, so that everything downstream has a single case to handle.
		// A clockwise triangle is the same triangle with two vertices exchanged, and exchanging
		// them carries the colour and the texture coordinate along, so nothing else notices.
		var ib = ib0, ic = ic0;
		if (edge(vx[ia], vy[ia], vx[ib], vy[ib], vx[ic], vy[ic]) < 0) {
			ib = ic0;
			ic = ib0;
		} else {}
		final a = ia, b = ib, c = ic;
		final x0 = vx[a], y0 = vy[a], c0 = vc[a];
		final x1 = vx[b], y1 = vy[b], c1 = vc[b];
		final x2 = vx[c], y2 = vy[c], c2 = vc[c];
		var minX = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
		var maxX = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);
		var minY = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
		var maxY = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
		if (maxX - minX > 1023 || maxY - minY > 511) return;
		else {}

		// Read once into locals rather than through the four ignored-argument accessors that used
		// to stand here. Those made JavaScript and reflaxe.CPP disagree about the *lower* two
		// clamps — same vertices, same area, same clip values, different bounding box — which is
		// 0.3% of every pixel this rasteriser writes. See PROGRESS.md, upstream defect 10.
		final clipLeft = drawAreaTopLeft & 0x3FF;
		final clipTop = (drawAreaTopLeft >>> 10) & 0x1FF;
		final clipRight = drawAreaBottomRight & 0x3FF;
		final clipBottom = (drawAreaBottomRight >>> 10) & 0x1FF;
		if (minX < clipLeft) minX = clipLeft;
		else {}
		if (minY < clipTop) minY = clipTop;
		else {}
		if (maxX > clipRight) maxX = clipRight;
		else {}
		if (maxY > clipBottom) maxY = clipBottom;
		else {}

		final area = edge(x0, y0, x1, y1, x2, y2);
		if (area == 0) return;
		else {}
		triangleWork(area, minX, maxX, minY, maxY);
		primitives++;
		if (hw) noteDrawn(minX, minY, maxX, maxY);
		else {}

		// The edge function is linear in x and y, so stepping it costs an add where evaluating it
		// costs two multiplies. Six multiplies a pixel over a bounding box is what a scene of three
		// million triangles spends most of its time on, and none of them are necessary: one
		// evaluation per edge at the top-left corner, then `stepX` along a row and `stepY` down.
		//
		// Identical integers, not an approximation — the same values the three calls produced,
		// arrived at by addition. The digest is the proof and it does not move.
		final stepX0 = y1 - y2, stepY0 = x2 - x1;
		final stepX1 = y2 - y0, stepY1 = x0 - x2;
		final stepX2 = y0 - y1, stepY2 = x1 - x0;
		// The fill rule. A pixel lying exactly on a shared edge is claimed by one of the two
		// triangles that meet there, never both and never neither: the edge belongs to whichever
		// of them has it as a top or a left edge, and the two traverse it in opposite directions,
		// so exactly one qualifies. Without this, every seam is drawn twice — invisible on an
		// opaque surface, because the second write puts back what the first did, and a bright line
		// along every polygon diagonal the moment the surface blends with what is behind it.
		var row0 = edge(x1, y1, x2, y2, minX, minY) + (topLeft(x1, y1, x2, y2) ? 0 : -1);
		var row1 = edge(x2, y2, x0, y0, minX, minY) + (topLeft(x2, y2, x0, y0) ? 0 : -1);
		var row2 = edge(x0, y0, x1, y1, minX, minY) + (topLeft(x0, y0, x1, y1) ? 0 : -1);

		if (texEnabled) {
			texturedSpans(a, b, c, x0, y0, c0, x1, y1, c1, x2, y2, c2,
				minX, maxX, minY, maxY, row0, row1, row2,
				stepX0, stepX1, stepX2, stepY0, stepY1, stepY2);
		} else if (c0 == c1 && c1 == c2 && maxX - minX < SMALL_WIDTH) {
			smallFlat(minX, maxX, minY, maxY, row0, row1, row2,
				stepX0, stepX1, stepX2, stepY0, stepY1, stepY2, colourOf(c0));
		} else if (c0 == c1 && c1 == c2) {
			flatSpans(minX, maxX, minY, maxY, row0, row1, row2,
				stepX0, stepX1, stepX2, stepY0, stepY1, stepY2, colourOf(c0));
		} else {
			shadedSpans(x0, y0, c0, x1, y1, c1, x2, y2, c2, minX, maxX, minY, maxY,
				row0, row1, row2, stepX0, stepX1, stepX2, stepY0, stepY1, stepY2);
		}
	}

	/**
		The columns of one row a triangle covers, as a closed interval of offsets from `minX`.

		Each edge function is linear along a row, so the columns where all three are non-negative
		form one run whose ends can be solved for: `w + s*k >= 0` bounds `k` from below when `s`
		is positive and from above when it is negative, and decides the whole row when it is zero.
		These are the same integers the per-pixel test used to accept, arrived at in closed form —
		the bounding-box reject keeps every edge value inside 32 bits, so no wrap can separate the
		two, and the Raster fixture and the game digest hold it to that.

		Why it matters: half of a triangle's bounding box lies outside the triangle, so the scan
		this replaces spent as many iterations rejecting pixels as drawing them, and paid three
		compares for each one it kept. Three divisions a row buy all of that back.

		Packed as `lo | (hi << 16)`, both inclusive; -1 when the row has no pixel.
	**/
	static function rowSpan(w0:Int, w1:Int, w2:Int, s0:Int, s1:Int, s2:Int, last:Int):Int {
		var lo = 0;
		var hi = last;
		if (s0 > 0) lo = maxInt(lo, -floorDiv(w0, s0));
		else if (s0 < 0) hi = minInt(hi, floorDiv(w0, -s0));
		else if (w0 < 0) return -1;
		else {}
		if (s1 > 0) lo = maxInt(lo, -floorDiv(w1, s1));
		else if (s1 < 0) hi = minInt(hi, floorDiv(w1, -s1));
		else if (w1 < 0) return -1;
		else {}
		if (s2 > 0) lo = maxInt(lo, -floorDiv(w2, s2));
		else if (s2 < 0) hi = minInt(hi, floorDiv(w2, -s2));
		else if (w2 < 0) return -1;
		else {}
		return lo > hi ? -1 : lo | (hi << 16);
	}

	/** `floor(a / b)` for a positive `b`: the truncating division, corrected where it rounded up. */
	static inline function floorDiv(a:Int, b:Int):Int {
		final q = shim.IntMath.div(a, b);
		return shim.IntMath.mul(q, b) > a ? q - 1 : q;
	}

	static inline function maxInt(a:Int, b:Int):Int return a > b ? a : b;
	static inline function minInt(a:Int, b:Int):Int return a < b ? a : b;

	/**
		One colour over the whole triangle: no interpolation to do, so none is paid for.

		A row's columns are rowSpan's, but carried down the rows rather than divided for: each
		edge's bound is a floor quotient of its value by its step, and the value grows by the same
		amount a row, so the quotient grows by that amount's quotient and by one more where the
		remainders carry — the integer the division gives, without dividing (two divisions an edge
		a triangle where rowSpan took one an edge a row). Inline, with nothing passed: E-078 carried
		them through calls of seven and nine arguments and spent in the calls what the divisions
		had cost. Crash 3 draws its shadow into VRAM this way, ~460 rows a frame.
	**/
	@:specifier("__attribute__((noinline))")
	static function flatSpans(minX:Int, maxX:Int, minY:Int, maxY:Int,
			row0:Int, row1:Int, row2:Int, stepX0:Int, stepX1:Int, stepX2:Int,
			stepY0:Int, stepY1:Int, stepY2:Int, colour:Int):Void {
		// The per-primitive state, read once. Inside the loops these are locals a compiler can
		// keep in registers; as static fields they were a load per pixel each.
		final blend = semiTransparent, mode = semiMode;
		final check = maskCheck, set = maskSet;
		final value = set ? colour | 0x8000 : colour;
		final last = maxX - minX;
		var written = 0;
		// Each edge: w + s*k >= 0 for the row's value w and column offset k bounds k from below by
		// -floor(w / s) when s > 0 and from above by floor(w / -s) when s < 0 (rowSpan). d is |s|
		// (1 for an edge level with the rows, whose quotient is not read: such an edge keeps or
		// drops the whole row by w's sign), q and m the quotient and remainder of w by d, qt and mt
		// those of the row step. A negated quotient is `| 0`'d: -0 is a double on JavaScript.
		final d0 = stepX0 > 0 ? stepX0 : (stepX0 < 0 ? -stepX0 : 1);
		final d1 = stepX1 > 0 ? stepX1 : (stepX1 < 0 ? -stepX1 : 1);
		final d2 = stepX2 > 0 ? stepX2 : (stepX2 < 0 ? -stepX2 : 1);
		var q0 = floorDiv(row0, d0), q1 = floorDiv(row1, d1), q2 = floorDiv(row2, d2);
		var m0 = (row0 - shim.IntMath.mul(q0, d0)) | 0;
		var m1 = (row1 - shim.IntMath.mul(q1, d1)) | 0;
		var m2 = (row2 - shim.IntMath.mul(q2, d2)) | 0;
		final qt0 = floorDiv(stepY0, d0), qt1 = floorDiv(stepY1, d1), qt2 = floorDiv(stepY2, d2);
		final mt0 = (stepY0 - shim.IntMath.mul(qt0, d0)) | 0;
		final mt1 = (stepY1 - shim.IntMath.mul(qt1, d1)) | 0;
		final mt2 = (stepY2 - shim.IntMath.mul(qt2, d2)) | 0;
		var r0 = row0, r1 = row1, r2 = row2;
		var y = minY;
		while (y <= maxY) {
			var lo = 0;
			var hi = last;
			var empty = false;
			if (stepX0 > 0) lo = maxInt(lo, (-q0) | 0);
			else if (stepX0 < 0) hi = minInt(hi, q0);
			else if (r0 < 0) empty = true;
			else {}
			if (stepX1 > 0) lo = maxInt(lo, (-q1) | 0);
			else if (stepX1 < 0) hi = minInt(hi, q1);
			else if (r1 < 0) empty = true;
			else {}
			if (stepX2 > 0) lo = maxInt(lo, (-q2) | 0);
			else if (stepX2 < 0) hi = minInt(hi, q2);
			else if (r2 < 0) empty = true;
			else {}
			if (!empty && lo <= hi) {
				final count = hi - lo + 1;
				final first = Vram.rowStart(y) + minX + lo;
				if (!blend && !check) {
					Vram.fillLinear(first, count, value);
					written += count;
				} else {
					var pixel = first;
					final end = first + count;
					while (pixel < end) {
						written += plotPixel(pixel, colour, blend, mode, check, set);
						pixel++;
					}
				}
			} else {}
			r0 = (r0 + stepY0) | 0; r1 = (r1 + stepY1) | 0; r2 = (r2 + stepY2) | 0;
			// w + t = (q + qt) d + (m + mt), with 0 <= m + mt < 2d: one more where it reaches d.
			q0 = (q0 + qt0) | 0; m0 = (m0 + mt0) | 0;
			if (m0 >= d0) { m0 = (m0 - d0) | 0; q0 = (q0 + 1) | 0; } else {}
			q1 = (q1 + qt1) | 0; m1 = (m1 + mt1) | 0;
			if (m1 >= d1) { m1 = (m1 - d1) | 0; q1 = (q1 + 1) | 0; } else {}
			q2 = (q2 + qt2) | 0; m2 = (m2 + mt2) | 0;
			if (m2 >= d2) { m2 = (m2 - d2) | 0; q2 = (q2 + 1) | 0; } else {}
			y++;
		}
		pixels = (pixels + written) | 0;
	}

	/** A bounding box narrower than this (after clipping) is drawn pixel by pixel (`smallFlat`). */
	static inline var SMALL_WIDTH = 16;

	/**
		flatSpans for a narrow bounding box: each of its pixels tested against the three edge
		functions, stepped by adds along the row and down the rows.

		The same pixels: along a row each edge function is linear in the column, so the columns
		where all three are non-negative are one run, the run flatSpans solves for in closed form
		(rowSpan), and the writes and the count are the same — a pixel each, none written twice.
		What it does without is that solving: six divisions a triangle and a quotient carried for
		each edge a row, ~1,100 SH-4 instructions for each of the ~100 4x4 triangles of Crash 3's
		shadow a game frame, where a 4x4 box is sixteen tests. Below SMALL_WIDTH a row of tests
		costs less than a row of flatSpans' carries, the divisions aside.
	**/
	@:specifier("__attribute__((noinline))")
	static function smallFlat(minX:Int, maxX:Int, minY:Int, maxY:Int,
			row0:Int, row1:Int, row2:Int, stepX0:Int, stepX1:Int, stepX2:Int,
			stepY0:Int, stepY1:Int, stepY2:Int, colour:Int):Void {
		final blend = semiTransparent, mode = semiMode;
		final check = maskCheck, set = maskSet;
		final value = set ? colour | 0x8000 : colour;
		final opaque = !blend && !check;
		final last = maxX - minX;
		final px = Vram.buffer();
		var written = 0;
		var r0 = row0, r1 = row1, r2 = row2;
		var first = Vram.rowStart(minY) + minX;
		var y = minY;
		while (y <= maxY) {
			var w0 = r0, w1 = r1, w2 = r2;
			var k = 0;
			while (k <= last) {
				// All three non-negative: no sign bit in any of them.
				if ((w0 | w1 | w2) >= 0) {
					if (opaque) {
						MemA.set16(px, (first + k) << 1, value);
						written++;
					} else written += plotPixel(first + k, colour, blend, mode, check, set);
				} else {}
				w0 = (w0 + stepX0) | 0; w1 = (w1 + stepX1) | 0; w2 = (w2 + stepX2) | 0;
				k++;
			}
			r0 = (r0 + stepY0) | 0; r1 = (r1 + stepY1) | 0; r2 = (r2 + stepY2) | 0;
			first += Vram.WIDTH;
			y++;
		}
		pixels = (pixels + written) | 0;
	}

	/**
		Gouraud shading: each channel a plane through the three vertex colours.

		Colour varies linearly across a triangle, so each channel is stepped exactly as the edge
		functions are — one division per channel per triangle to find the two gradients, then an
		add per pixel. Ten fractional bits, which is enough that the rounding error accumulated
		across a full-width span stays under one level of the 255, and few enough that every
		intermediate stays inside 32 bits: the bounding-box reject above caps coordinate
		differences at 1023 by 511, so a gradient numerator cannot exceed about half a million.

		Gradients are clamped to one full colour range per pixel. Anything steeper is a sliver
		whose colour saturates within a pixel anyway, and the clamp is what keeps a degenerate
		triangle from producing an intermediate that wraps. `IntMath.mul` throughout so that if one
		ever does wrap, it wraps the same way on both targets.

		A row starts at its span's first column with the channel value that stepping there would
		have produced — a multiply, since the plane is linear and nothing wraps — so the columns
		outside the triangle are never visited at all.

		Without this the whole scene is faceted: every polygon Crash Bash draws but one in a
		thousand asks for shading, and painting all three vertices in the first one's colour turns
		a smooth surface into flat plates.
	**/
	static function shadedSpans(x0:Int, y0:Int, c0:Int, x1:Int, y1:Int, c1:Int,
			x2:Int, y2:Int, c2:Int, minX:Int, maxX:Int, minY:Int, maxY:Int,
			row0:Int, row1:Int, row2:Int, stepX0:Int, stepX1:Int, stepX2:Int,
			stepY0:Int, stepY1:Int, stepY2:Int):Void {
		final ax = x1 - x0, ay = y1 - y0;
		final bx = x2 - x0, by = y2 - y0;

		final r0 = c0 & 0xFF, g0 = (c0 >>> 8) & 0xFF, b0 = (c0 >>> 16) & 0xFF;
		final dr1 = (c1 & 0xFF) - r0, dg1 = ((c1 >>> 8) & 0xFF) - g0, db1 = ((c1 >>> 16) & 0xFF) - b0;
		final dr2 = (c2 & 0xFF) - r0, dg2 = ((c2 >>> 8) & 0xFF) - g0, db2 = ((c2 >>> 16) & 0xFF) - b0;

		final area = edge(x0, y0, x1, y1, x2, y2);
		final drdx = gradient(shim.IntMath.mul(dr1, by) - shim.IntMath.mul(dr2, ay), area);
		final drdy = gradient(shim.IntMath.mul(dr2, ax) - shim.IntMath.mul(dr1, bx), area);
		final dgdx = gradient(shim.IntMath.mul(dg1, by) - shim.IntMath.mul(dg2, ay), area);
		final dgdy = gradient(shim.IntMath.mul(dg2, ax) - shim.IntMath.mul(dg1, bx), area);
		final dbdx = gradient(shim.IntMath.mul(db1, by) - shim.IntMath.mul(db2, ay), area);
		final dbdy = gradient(shim.IntMath.mul(db2, ax) - shim.IntMath.mul(db1, bx), area);

		final blend = semiTransparent, mode = semiMode;
		final check = maskCheck, set = maskSet;
		final last = maxX - minX;
		var written = 0;

		final ox = minX - x0, oy = minY - y0;
		var rRow = start(r0, drdx, ox, drdy, oy);
		var gRow = start(g0, dgdx, ox, dgdy, oy);
		var bRow = start(b0, dbdx, ox, dbdy, oy);

		var e0 = row0, e1 = row1, e2 = row2;
		var y = minY;
		while (y <= maxY) {
			final span = rowSpan(e0, e1, e2, stepX0, stepX1, stepX2, last);
			if (span >= 0) {
				final lo = span & 0xFFFF;
				final count = (span >> 16) - lo + 1;
				var r = (rRow + shim.IntMath.mul(drdx, lo)) | 0;
				var g = (gRow + shim.IntMath.mul(dgdx, lo)) | 0;
				var b = (bRow + shim.IntMath.mul(dbdx, lo)) | 0;
				var pixel = Vram.rowStart(y) + minX + lo;
				final end = pixel + count;
				while (pixel < end) {
					written += plotPixel(pixel, pack555(r >> CFRAC, g >> CFRAC, b >> CFRAC),
						blend, mode, check, set);
					r = (r + drdx) | 0; g = (g + dgdx) | 0; b = (b + dbdx) | 0;
					pixel++;
				}
			} else {}
			e0 = (e0 + stepY0) | 0; e1 = (e1 + stepY1) | 0; e2 = (e2 + stepY2) | 0;
			rRow = (rRow + drdy) | 0; gRow = (gRow + dgdy) | 0; bRow = (bRow + dbdy) | 0;
			y++;
		}
		pixels = (pixels + written) | 0;
	}

	/**
		Textured spans: the shaded walk, with a texel fetched and modulated at every pixel.

		Everything the fetch depends on is decided once per triangle and lives in locals: the
		texture window as an AND and an OR per axis, the page and palette origins as row indices,
		the depth, and the four mode flags. The fetch itself is then two loads for an indexed
		texel and one for a direct one, straight from the linear framebuffer index. It used to be
		three calls a pixel — the texel, the page read and the palette read — each redoing the
		window and coordinate arithmetic, and that was the single most expensive thing this
		emulator did.

		The masks that are provably identities are kept anyway: the page origin plus a windowed
		coordinate can exceed the row for the wider formats, and one AND is cheaper than an
		argument about which formats it applies to.
	**/
	static function texturedSpans(ia:Int, ib:Int, ic:Int,
			x0:Int, y0:Int, c0:Int, x1:Int, y1:Int, c1:Int, x2:Int, y2:Int, c2:Int,
			minX:Int, maxX:Int, minY:Int, maxY:Int,
			row0:Int, row1:Int, row2:Int, stepX0:Int, stepX1:Int, stepX2:Int,
			stepY0:Int, stepY1:Int, stepY2:Int):Void {
		final ax = x1 - x0, ay = y1 - y0;
		final bx = x2 - x0, by = y2 - y0;

		final r0 = c0 & 0xFF, g0 = (c0 >>> 8) & 0xFF, b0 = (c0 >>> 16) & 0xFF;
		final dr1 = (c1 & 0xFF) - r0, dg1 = ((c1 >>> 8) & 0xFF) - g0, db1 = ((c1 >>> 16) & 0xFF) - b0;
		final dr2 = (c2 & 0xFF) - r0, dg2 = ((c2 >>> 8) & 0xFF) - g0, db2 = ((c2 >>> 16) & 0xFF) - b0;
		final u0 = vu[ia], v0 = vv[ia];
		final du1 = vu[ib] - u0, dv1 = vv[ib] - v0;
		final du2 = vu[ic] - u0, dv2 = vv[ic] - v0;

		final area = edge(x0, y0, x1, y1, x2, y2);
		final drdx = gradient(shim.IntMath.mul(dr1, by) - shim.IntMath.mul(dr2, ay), area);
		final drdy = gradient(shim.IntMath.mul(dr2, ax) - shim.IntMath.mul(dr1, bx), area);
		final dgdx = gradient(shim.IntMath.mul(dg1, by) - shim.IntMath.mul(dg2, ay), area);
		final dgdy = gradient(shim.IntMath.mul(dg2, ax) - shim.IntMath.mul(dg1, bx), area);
		final dbdx = gradient(shim.IntMath.mul(db1, by) - shim.IntMath.mul(db2, ay), area);
		final dbdy = gradient(shim.IntMath.mul(db2, ax) - shim.IntMath.mul(db1, bx), area);
		final dudx = gradient(shim.IntMath.mul(du1, by) - shim.IntMath.mul(du2, ay), area);
		final dudy = gradient(shim.IntMath.mul(du2, ax) - shim.IntMath.mul(du1, bx), area);
		final dvdx = gradient(shim.IntMath.mul(dv1, by) - shim.IntMath.mul(dv2, ay), area);
		final dvdy = gradient(shim.IntMath.mul(dv2, ax) - shim.IntMath.mul(dv1, bx), area);

		// The window, as psx-spx gives it: `(coord AND NOT(mask*8)) OR ((offset AND mask)*8)`.
		// The final `& 0xFF` of the old per-pixel form is folded into the AND: the OR term is
		// below 256, so masking before it and after it are the same operation.
		final window = textureWindow;
		final mx = window & 0x1F, my = (window >>> 5) & 0x1F;
		final uAnd = ~(mx << 3) & 0xFF, uOr = ((window >>> 10) & 0x1F & mx) << 3;
		final vAnd = ~(my << 3) & 0xFF, vOr = ((window >>> 15) & 0x1F & my) << 3;
		final depth = texDepth, pageX = texBaseX, pageY = texBaseY;
		final clutRow = (clutY & 511) << 10, clutCol = clutX;
		final raw = texRaw, blendable = semiTransparent, mode = semiMode;
		final check = maskCheck, set = maskSet;
		final last = maxX - minX;
		var written = 0;

		final ox = minX - x0, oy = minY - y0;
		var rRow = start(r0, drdx, ox, drdy, oy);
		var gRow = start(g0, dgdx, ox, dgdy, oy);
		var bRow = start(b0, dbdx, ox, dbdy, oy);
		var uRow = start(u0, dudx, ox, dudy, oy);
		var vRow = start(v0, dvdx, ox, dvdy, oy);

		var e0 = row0, e1 = row1, e2 = row2;
		var y = minY;
		while (y <= maxY) {
			final span = rowSpan(e0, e1, e2, stepX0, stepX1, stepX2, last);
			if (span >= 0) {
				final lo = span & 0xFFFF;
				final count = (span >> 16) - lo + 1;
				var r = (rRow + shim.IntMath.mul(drdx, lo)) | 0;
				var g = (gRow + shim.IntMath.mul(dgdx, lo)) | 0;
				var b = (bRow + shim.IntMath.mul(dbdx, lo)) | 0;
				var u = (uRow + shim.IntMath.mul(dudx, lo)) | 0;
				var v = (vRow + shim.IntMath.mul(dvdx, lo)) | 0;
				var pixel = Vram.rowStart(y) + minX + lo;
				final end = pixel + count;
				while (pixel < end) {
					final tu = ((u >> CFRAC) & uAnd) | uOr;
					final tv = ((v >> CFRAC) & vAnd) | vOr;
					final texRow = ((pageY + tv) & 511) << 10;
					// Depth 3 is reserved; it has always been read as 4-bit here and stays so.
					var t = 0;
					if (depth == 2) t = texel15(texRow, pageX, tu);
					else if (depth == 1) t = texel8(texRow, pageX, tu, clutRow, clutCol);
					else t = texel4(texRow, pageX, tu, clutRow, clutCol);
					// A zero texel is transparent. Bit 15 means "blend me" — but only for a
					// command that asked to blend at all; for an opaque command the same bit
					// means nothing and the texel is drawn as it is. Either way the pixel
					// written keeps it: "the upper bit of the data written to the framebuffer
					// is equal to bit15 of the texture color" while GP0(E6h).0 is off
					// (psx-spx, "GPU Rendering Attributes"). Crash Bandicoot: Warped's
					// transition draws the frame back over itself as a semi-transparent
					// texture, so only the pixels its textures marked blend; with the bit
					// dropped every pixel read as opaque, and the effect lost its colours.
					if (t != 0) {
						final c = raw ? t & 0x7FFF : modulate(t, r >> CFRAC, g >> CFRAC, b >> CFRAC);
						final stp = (t & 0x8000) != 0;
						written += plotPixel(pixel, c, blendable && stp, mode, check, set || stp);
					} else {}
					r = (r + drdx) | 0; g = (g + dgdx) | 0; b = (b + dbdx) | 0;
					u = (u + dudx) | 0; v = (v + dvdx) | 0;
					pixel++;
				}
			} else {}
			e0 = (e0 + stepY0) | 0; e1 = (e1 + stepY1) | 0; e2 = (e2 + stepY2) | 0;
			rRow = (rRow + drdy) | 0; gRow = (gRow + dgdy) | 0; bRow = (bRow + dbdy) | 0;
			uRow = (uRow + dudy) | 0; vRow = (vRow + dvdy) | 0;
			y++;
		}
		pixels = (pixels + written) | 0;
	}

	/**
		One texel of each storage format, from a windowed coordinate and precomputed origins.

		Indexed formats pack several pixels into one halfword — four nibbles or two bytes, lowest
		bits leftmost — so the coordinate selects both the halfword and the field within it, and
		the field is then a palette index into the CLUT row. Fifteen-bit texels are the colour.
	**/
	static inline function texel4(texRow:Int, pageX:Int, tu:Int, clutRow:Int, clutCol:Int):Int {
		final w = Vram.getLinear(texRow + ((pageX + (tu >> 2)) & 1023));
		return Vram.getLinear(clutRow + ((clutCol + ((w >>> ((tu & 3) << 2)) & 0x0F)) & 1023));
	}

	static inline function texel8(texRow:Int, pageX:Int, tu:Int, clutRow:Int, clutCol:Int):Int {
		final w = Vram.getLinear(texRow + ((pageX + (tu >> 1)) & 1023));
		return Vram.getLinear(clutRow + ((clutCol + ((w >>> ((tu & 1) << 3)) & 0xFF)) & 1023));
	}

	static inline function texel15(texRow:Int, pageX:Int, tu:Int):Int
		return Vram.getLinear(texRow + ((pageX + tu) & 1023));

	/**
		`texel * colour / 128`, per channel, back into a 15-bit word.

		The texel's five bits are widened to eight before the multiply and narrowed after, so the
		rounding happens once rather than twice.
	**/
	static inline function modulate(t:Int, r:Int, g:Int, b:Int):Int {
		final tr = (t & 0x1F) << 3, tg = ((t >>> 5) & 0x1F) << 3, tb = ((t >>> 10) & 0x1F) << 3;
		return pack555(shim.IntMath.mul(tr, r) >> 7, shim.IntMath.mul(tg, g) >> 7,
			shim.IntMath.mul(tb, b) >> 7);
	}

	/** Ten fractional bits: fine enough to hide banding, coarse enough to stay inside an Int. */
	static inline var CFRAC = 10;
	static inline var CGRAD_MAX = 255 << CFRAC;

	static inline function gradient(numerator:Int, area:Int):Int {
		final g = shim.IntMath.div(shim.IntMath.mul(numerator, 1 << CFRAC), area);
		return g > CGRAD_MAX ? CGRAD_MAX : (g < -CGRAD_MAX ? -CGRAD_MAX : g);
	}

	static inline function start(base:Int, dx:Int, ox:Int, dy:Int, oy:Int):Int {
		return ((base << CFRAC) + shim.IntMath.mul(dx, ox) + shim.IntMath.mul(dy, oy)) | 0;
	}

	/** Three 8-bit channels, clamped, into the 15-bit word VRAM holds. */
	static inline function pack555(r:Int, g:Int, b:Int):Int {
		final rc = r < 0 ? 0 : (r > 255 ? 255 : r);
		final gc = g < 0 ? 0 : (g > 255 ? 255 : g);
		final bc = b < 0 ? 0 : (b > 255 ? 255 : b);
		return (rc >> 3) | ((gc >> 3) << 5) | ((bc >> 3) << 10);
	}

	/**
		Whether a directed edge is a top or a left edge of the triangle on its inside.

		With screen coordinates running down the page and the winding normalised so that the
		interior lies where all three edge functions are non-negative: a horizontal edge travelling
		right has the interior below it, which makes it the top; any edge travelling upwards has
		the interior to its right, which makes it a left edge.
	**/
	static inline function topLeft(ax:Int, ay:Int, bx:Int, by:Int):Bool {
		final dy = by - ay;
		return dy < 0 || (dy == 0 && bx > ax);
	}

	static inline function edge(ax:Int, ay:Int, bx:Int, by:Int, cx:Int, cy:Int):Int {
		return shim.IntMath.mul(bx - ax, cy - ay) - shim.IntMath.mul(by - ay, cx - ax);
	}

	static function rectHw(x:Int, y:Int, w:Int, h:Int, colour:Int):Void {
		sendState(0, 0, 0, 0, 0, semiMode, semiTransparent ? 2 : 0, 0,
			drawAreaTopLeft & 0x3FF, (drawAreaTopLeft >>> 10) & 0x1FF);
		sentTp = -2;        // the next triangle compares packed again (triState)
		// The ABI's colour is 24-bit BGR, as a triangle's is; `colour` is the 15-bit word VRAM
		// holds. Widened, not taken from the command: a rectangle is not dithered, so the five
		// bits per channel VRAM keeps are exactly what the hardware shows. Handing the 15-bit
		// word over as BGR painted Crash Bandicoot: Warped's grey stars orange and green.
		Backend.gpuRect(x, y, w, h, ((colour & 0x1F) << 3) | (((colour >> 5) & 0x1F) << 11)
			| (((colour >> 10) & 0x1F) << 19), semiTransparent ? 1 : 0, semiMode);
	}

	/** An untextured rectangle, already clipped to the drawing area by drawRect. */
	static function fillRect(x:Int, y:Int, w:Int, h:Int, colour:Int):Void {
		// No `primitives++` here in either mode: the caller counts for itself.
		if (hw && !offscreen) {
			rectHw(x, y, w, h, colour);
			return;
		} else {}
		// Drawing clips at the viewport edge; it does not wrap like a VRAM transfer. Clip once
		// here so the inner loop can use a linear VRAM index without repeating coordinate checks.
		final left = x < 0 ? 0 : x;
		final top = y < 0 ? 0 : y;
		final right0 = x + w;
		final bottom0 = y + h;
		final right = right0 > 1024 ? 1024 : right0;
		final bottom = bottom0 > 512 ? 512 : bottom0;
		if (left >= right || top >= bottom) return;
		else {}
		if (hw) noteDrawn(left, top, right - 1, bottom - 1);
		else {}
		final count = right - left;
		if (!semiTransparent && !maskCheck) {
			final value = maskSet ? colour | 0x8000 : colour;
			var row = Vram.rowStart(top) + left;
			var j = top;
			while (j < bottom) {
				Vram.fillLinear(row, count, value);
				row += Vram.WIDTH;
				j++;
			}
			pixels = (pixels + count * (bottom - top)) | 0;
		} else {
			final blend = semiTransparent, mode = semiMode;
			final check = maskCheck, set = maskSet;
			var written = 0;
			var row = Vram.rowStart(top) + left;
			var j = top;
			while (j < bottom) {
				var i = 0;
				while (i < count) {
					written += plotPixel(row + i, colour, blend, mode, check, set);
					i++;
				}
				row += Vram.WIDTH;
				j++;
			}
			pixels = (pixels + written) | 0;
		}
	}

	/**
		One pixel of a clipped span, obeying the mask settings and blending when asked to.

		A polygon, rectangle or line respects GP0(E6) the same way an upload does — bit-15-check
		skips a pixel the game has protected, bit-15-set marks each written pixel. Crash Bash's
		warning screen is where it shows: it draws the text first, with the mask bit set on every
		letter, and then draws the red "no" circle straight over it with mask-check on. On hardware
		the circle skips the letters and passes behind them; without the check the circle painted
		over the text, cutting each word where it crossed. Same rule as `putTexel` and `blend`.

		The pixel underneath is read once and used for both the test and the blend source: it is
		both what decides whether we may write and what we are blending with. An opaque write with
		no check reads nothing. Returns how many pixels were written, 0 or 1, so a span counts once
		at its end instead of touching the counter for every pixel.
	**/
	static inline function plotPixel(index:Int, colour:Int, blend:Bool, mode:Int,
			check:Bool, set:Bool):Int {
		final back = (blend || check) ? Vram.getLinear(index) : 0;
		if (check && (back & 0x8000) != 0) return 0;
		else {
			final c = blend ? blendMode(mode, back, colour) : colour;
			Vram.setLinear(index, set ? c | 0x8000 : c);
			return 1;
		}
	}

	/**
		A pixel blended into what is already in the framebuffer.

		The four modes are the whole of PlayStation transparency, and each is one line of
		arithmetic on five-bit channels (psx-spx, "Semi Transparency"): half and half, additive,
		subtractive, and a quarter added. Additive is the common one — every spark, flame, glow and
		lens flare on the machine is a dark texture added to the background, which is why a build
		without blending draws them as **black squares over the picture** rather than as light.
	**/
	static inline function blendMode(mode:Int, back:Int, front:Int):Int {
		final br = back & 0x1F, bg = (back >>> 5) & 0x1F, bb = (back >>> 10) & 0x1F;
		final fr = front & 0x1F, fg = (front >>> 5) & 0x1F, fb = (front >>> 10) & 0x1F;
		return mode == 0 ? sat555((br + fr) >> 1, (bg + fg) >> 1, (bb + fb) >> 1)
			: mode == 1 ? sat555(br + fr, bg + fg, bb + fb)
			: mode == 2 ? sat555(br - fr, bg - fg, bb - fb)
			: sat555(br + (fr >> 2), bg + (fg >> 2), bb + (fb >> 2));
	}

	/** The current blend mode, for the VRAM-copy path that has no per-primitive locals. */
	static function blendWith(back:Int, front:Int):Int return blendMode(semiMode, back, front);

	/** Three five-bit channels, clamped to 0..31, packed. */
	static inline function sat555(r:Int, g:Int, b:Int):Int {
		final rc = r < 0 ? 0 : (r > 31 ? 31 : r);
		final gc = g < 0 ? 0 : (g > 31 ? 31 : g);
		final bc = b < 0 ? 0 : (b > 31 ? 31 : b);
		return rc | (gc << 5) | (bc << 10);
	}


	/**
		A GP0 command word.

		The state-setting commands are implemented because they are what a game's setup depends on.
		Drawing commands are counted and their parameters swallowed, so the port stays in step —
		mis-counting a packet's length would leave the next command word read as a parameter and
		desynchronise everything after it, which is far worse than not drawing.
	**/
	/** How many of each GP0 opcode arrived. A drawable command that never becomes a primitive is
		a rasteriser dropping work, which looks exactly like a game that draws nothing. */
	public static var opCount:RawBuf;

	static function command(v:Int):Void {
		final op = v >>> 24;
		MemA.set32(opCount, op << 2, MemA.get32(opCount, op << 2) + 1);
		if (op == 0xE1) setDrawMode(v);
		else if (op == 0xE2) textureWindow = v & 0xFFFFF;
		else if (op == 0xE3) setDrawArea(v, drawAreaBottomRight);
		else if (op == 0xE4) setDrawArea(drawAreaTopLeft, v);
		else if (op == 0xE5) setDrawOffset(v);
		else if (op == 0xE6) setMaskBits(v);
		else if (op == 0x1F) raiseIrq();
		else if (op == 0x00 || op == 0x01 || (op >= 0x03 && op <= 0x1E)) {}   // NOPs
		else pending = parameterCount(op);
	}

	/**
		GP0(E3h)/(E4h). A hardware backend is told the corners so it can clip triangles where
		the software rasteriser does; without that, a double-buffered game's geometry reaches
		past its drawing buffer into the buffer on screen.
	**/
	/** GP0(E5h): X in bits 0-10 and Y in 11-21, both signed. */
	static function setDrawOffset(v:Int):Void {
		drawOffset = v & 0x3FFFFF;
		offsetX = (drawOffset << 21) >> 21;
		offsetY = (drawOffset << 10) >> 21;
	}

	static function setDrawArea(topLeft:Int, bottomRight:Int):Void {
		drawAreaTopLeft = topLeft & 0xFFFFF;
		drawAreaBottomRight = bottomRight & 0xFFFFF;
		areaL = drawAreaTopLeft & 0x3FF;
		areaT = (drawAreaTopLeft >>> 10) & 0x1FF;
		areaR = drawAreaBottomRight & 0x3FF;
		areaB = (drawAreaBottomRight >>> 10) & 0x1FF;
		if (hw) Backend.gpuClip(drawAreaTopLeft & 0x3FF, (drawAreaTopLeft >>> 10) & 0x1FF,
			drawAreaBottomRight & 0x3FF, (drawAreaBottomRight >>> 10) & 0x1FF);
		else {}
		classifyArea();
	}

	static function setMaskBits(v:Int):Void {
		maskSet = (v & 1) != 0;
		maskCheck = (v & 2) != 0;
		// A hardware backend applies these to its own primitives; uploads and copies have them
		// applied here, in VRAM, before it hears of the rectangle.
		if (hw) Backend.gpuMask(maskSet ? 1 : 0, maskCheck ? 1 : 0);
		else {}
	}

	static function raiseIrq():Void {
		irqPending = true;
		Irq.raiseLine(Irq.GPU);
	}

	/**
		How many words follow a drawing command.

		From the command's own bits, which is how the hardware knows: bit 27 makes a polygon a
		quad, 28 makes it gouraud, 26 textures it. Line strips are the exception — they run until a
		terminator rather than a count — and are reported rather than guessed at, because guessing
		a length here desynchronises the port.
	**/
	static function parameterCount(op:Int):Int {
		if (op >= 0x20 && op <= 0x3F) return polygonWords(op);
		else if (op >= 0x40 && op <= 0x5F) return lineWords(op);
		else if (op >= 0x60 && op <= 0x7F) return rectangleWords(op);
		else if (op == 0x02) return 2;                       // fill: colour, then two corners
		else if (op == 0x80) return 3;                       // VRAM to VRAM
		else if (op == 0xA0 || op == 0xC0) return 2;         // transfers: the data follows
		else return unknownCommand(op);
	}

	static function polygonWords(op:Int):Int {
		final vertices = (op & 0x08) != 0 ? 4 : 3;
		var perVertex = 1;                                    // the position
		if ((op & 0x04) != 0) perVertex++;                    // texture coordinate
		if ((op & 0x10) != 0) perVertex++;                    // its own colour
		// The first vertex's colour came in the command word itself when gouraud is off.
		return vertices * perVertex - ((op & 0x10) != 0 ? 1 : 0);
	}

	static function lineWords(op:Int):Int {
		if ((op & 0x08) != 0) return polylineIsOpen(op);
		else return (op & 0x10) != 0 ? 3 : 2;
	}

	static function polylineIsOpen(op:Int):Int {
		Runtime.reportOnce(0x60000000 | op, "GP0 polyline, which runs until its terminator");
		return 0;
	}

	static function rectangleWords(op:Int):Int {
		var n = 1;                                            // position
		if ((op & 0x04) != 0) n++;                            // texture coordinate
		if ((op & 0x18) == 0) n++;                            // variable size
		return n;
	}

	static function unknownCommand(op:Int):Int {
		Runtime.reportOnce(0x61000000 | op, "GP0 command that is not in the table");
		return 0;
	}

	// ---- GP1 -----------------------------------------------------------------------------------

	public static function writeGp1(v:Int):Void {
		final op = (v >>> 24) & 0x3F;
		final arg = v & 0xFFFFFF;
		if (op == 0x00) reset();
		else if (op == 0x01) pending = 0;                     // reset the command buffer
		else if (op == 0x02) irqPending = false;
		else if (op == 0x03) displayDisabled = (arg & 1) != 0;
		else if (op == 0x04) dmaDirection = arg & 3;
		else if (op == 0x05) { displayStart = arg & 0x7FFFF; flips++; }
		else if (op == 0x06) displayRangeH = arg;
		else if (op == 0x07) displayRangeV = arg;
		else if (op == 0x08) displayMode = arg & 0xFF;
		else if (op == 0x09) {}                               // VRAM size, v2 only
		else if (op == 0x10) readLatch = internalRegister(arg);
		else Runtime.reportOnce(0x62000000 | op, "GP1 command that is not in the table");
	}

	/** GP1(10h) — the handful of internal registers a game may read back. */
	static function internalRegister(index:Int):Int {
		final which = index & 0x0F;
		if (which == 2) return textureWindow;
		else if (which == 3) return drawAreaTopLeft;
		else if (which == 4) return drawAreaBottomRight;
		else if (which == 5) return drawOffset;
		else if (which == 7) return 2;                        // GPU version
		else return readLatch;                                // unchanged, as the hardware leaves it
	}

	// ---- reads ------------------------------------------------------------------------------------

	/**
		GPUREAD: the next word of a VRAM read while one lasts, and after it the last word read,
		or what GP1(10h) put there.
	**/
	public static function readData():Int {
		if (readPixels > 0) readLatch = readWord();
		else {}
		return readLatch;
	}

	/**
		GPUSTAT, assembled on every read.

		Nothing here is stored as a status word: it is a view over the state the commands set, plus
		the beam position. That is why a game polling it in a loop sees something that changes
		without any event having to fire.
	**/
	public static function readStatus(cycles:Int):Int {
		var s = texPage & 0x7FF;
		if (maskSet) s |= 1 << 11;
		else {}
		if (maskCheck) s |= 1 << 12;
		else {}
		// Bit 13 is the interlace field, and psx-spx notes it reads 1 whenever interlace is off.
		if ((displayMode & 0x20) == 0) s |= 1 << 13;
		else {}
		s |= (displayMode & 0xFF) << 16;
		if (displayDisabled) s |= 1 << 23;
		else {}
		if (irqPending) s |= 1 << 24;
		else {}
		s |= dmaRequestBit();
		// Never busy: drawing is instant in this model, so readiness is the truthful answer. Bit
		// 27 is the one that waits on the game: VRAM has words for it while a read lasts.
		s |= (1 << 26) | (1 << 28);
		if (readPixels > 0) s |= 1 << 27;
		else {}
		s |= dmaDirection << 29;
		s |= oddLineBit(cycles);
		return s;
	}

	/** Bit 25 means different things per DMA direction; with DMA off it is simply clear. */
	static function dmaRequestBit():Int {
		if (dmaDirection == 0) return 0;
		else if (dmaDirection == 1) return 1 << 25;
		else return 1 << 25;
	}

	/**
		Bit 31 — the beam's parity, or zero during vblank.

		Computed rather than stored. Games use it to find the field, and a game that spins on it is
		waiting for the beam to move, so the answer has to come from the clock.
	**/
	static function oddLineBit(cycles:Int):Int {
		final line = TimeBase.line(cycles);
		if (line >= TimeBase.DEFAULT_VBLANK_LINE) return 0;
		else return (line & 1) << 31;
	}
}
