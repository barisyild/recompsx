/* recompsx_arena.h — the emulated machine's memories, placed by the linker.
 *
 * These exist for one reason, and it is measured. When emulated RAM is a POINTER, every access
 * the recompiler emits costs two loads before the real one — the address of the pointer, then
 * the pointer itself — and the second depends on the first, so the SH-4 interlocks between them.
 * Worse, the generated code is compiled with -fno-strict-aliasing (it must be: emulated memory is
 * untyped bytes read as bytes, halfwords and words), which means every store in a basic block
 * might alias that pointer, so the compiler reloads it after each one. A block with five memory
 * accesses paid for the base five times over.
 *
 * As an ARRAY the base is a link-time constant. One literal load, no dereference, no interlock,
 * and — the part that actually matters — the compiler may keep it in a register for the whole
 * function because a constant cannot be aliased by anything.
 *
 * A dedicated header rather than a shim trick because every C-linking target links this one
 * translation unit, and the JavaScript shim keeps its own typed arrays with the same API. */
#ifndef RECOMPSX_ARENA_H
#define RECOMPSX_ARENA_H

#define RECOMPSX_RAM_BYTES     0x200000   /* 2 MB, the PlayStation's main RAM   */
#define RECOMPSX_SCRATCH_BYTES 0x400      /* 1 KB, the scratchpad at 1F800000h  */
#define RECOMPSX_GTE_WORDS     656        /* the GTE's registers, one word each, then its division
                                             tables (shim.GteFile, gte.Gte.UNR and CLZ) */
#define RECOMPSX_GPU_WORDS     64         /* the GPU's hot state, one word each (shim.GpuFile) */
#define RECOMPSX_SPU_WORDS     1176       /* the SPU's per-voice tables (shim.SpuFile, spu.Spu.SpuArray) */
#define RECOMPSX_TIMER_WORDS   40         /* the root counters' state (shim.TimerFile, timers.Timers.TimerArray) */
#define RECOMPSX_SCHED_WORDS   16         /* the scheduler's deadlines and bookkeeping (shim.SchedFile,
                                             core.Scheduler): two 32-byte lines */

/* RAM and the scratchpad are one array, so that one index addresses either: a run of guest
 * accesses through one base register is checked once and then indexed (mem.Memory.span, the
 * recompiler's spans). The scratchpad starts 160 bytes after RAM ends — five 32-byte lines past a
 * 16 KB boundary from RAM's start — so the two keep the colours in the operand cache the data
 * placement gave them apart (src/backend/dreamcast/dc-data-placement.txt: 82 and 87). The same
 * number is shim.Arena.SCRATCH_OFFSET on every target. */
#if RECOMPSX_FASTMEM
/* Fastmem (ADR-0049): the SH-4's MMU maps guest RAM at its own bus addresses in 1 MB pages, so the
 * RAM starts on a 1 MB boundary; and the scratchpad's 1 KB page sits 16 KB-aligned, so that its P0
 * address (0x1F800000) and its P1 one index the same operand-cache lines — a 1 KB page's address
 * bits 10-13 are translated, and two aliases of one line in different sets would not see each
 * other's writes. RAM's 1 MB pages have no such alias. */
#define RECOMPSX_SCRATCH_OFFSET (RECOMPSX_RAM_BYTES + 0x4000)
#define RECOMPSX_ARENA_ALIGN    (1 << 20)
#else
#define RECOMPSX_SCRATCH_OFFSET (RECOMPSX_RAM_BYTES + 160)
#define RECOMPSX_ARENA_ALIGN    32
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned char ram[RECOMPSX_RAM_BYTES];
    unsigned char gap[RECOMPSX_SCRATCH_OFFSET - RECOMPSX_RAM_BYTES];
    unsigned char scratch[RECOMPSX_SCRATCH_BYTES];
} __attribute__((aligned(RECOMPSX_ARENA_ALIGN))) recompsx_mem_t;

extern recompsx_mem_t recompsx_mem;
#define recompsx_ram (recompsx_mem.ram)
#define recompsx_scratch (recompsx_mem.scratch)
extern int recompsx_gte[RECOMPSX_GTE_WORDS];
extern int recompsx_gpu[RECOMPSX_GPU_WORDS];
extern int recompsx_spu[RECOMPSX_SPU_WORDS];
extern int recompsx_timers[RECOMPSX_TIMER_WORDS];
extern int recompsx_sched[RECOMPSX_SCHED_WORDS];

#if RECOMPSX_FASTMEM && defined(__sh__)
/* A guest access through the MMU (ADR-0049): `a` is the bus address (the guest address & 0x1FFFFFFF),
 * a P0 address whose page is RAM, the scratchpad, or nothing — and nothing traps, the backend's
 * TLB-miss handler emulating the access through the runtime's slow path with the clock the access
 * names as a memory input (`clk`, the CpuState's cycles): so the compiler has stored it before the
 * access, where the slow path reads it, with no store at an access whose clock is already there and
 * no memory clobber. Volatile, so the accesses keep their order. One instruction each, register
 * indirect — the forms the handler decodes.
 *
 * What GCC is not told: that an access may write memory. A port's slow path can schedule an event
 * (Scheduler.scheduleAt moves the CpuState's nextEvent), which the code after it must see at its
 * next pump test, as it does after the C++ form's call; the pump tests read it volatile instead
 * (recompsx_p0_deadline, through Runtime.deadline). A memory operand would have said so, and cost
 * far more: GCC takes any asm with a memory output for one that may write all memory (each
 * access then stored and reloaded every guest register cached around it — +20 % mov.l in a shard,
 * measured). Nothing else a slow path changes is read by the code around an access: it never
 * pumps, never runs guest code, and leaves the clock alone. */
/* The slow paths (mem.Fastmem) the trap reaches, and what an address the compiler knows can go to
 * without one: an address it can prove is not RAM (or a mirror: bits 23-28 clear) nor the
 * scratchpad's page — `lui $at, 0x1F80` and a register offset, a port — calls them directly. */
int rx_fm_read(int size, int addr);
void rx_fm_write(int size, int addr, int v);
#define RECOMPSX_P0_MAPPED(a) ((((a) & 0x1F800000u) == 0) || (((a) & 0x1FFFFC00u) == 0x1F800000u))
#define RECOMPSX_P0_PORT(a) (__builtin_constant_p(a) && !RECOMPSX_P0_MAPPED(a))

static inline __attribute__((always_inline)) int recompsx_p0_ld32(unsigned int a, const int* clk) {
    if(RECOMPSX_P0_PORT(a)) return rx_fm_read(2, (int)a);
    int v; __asm__ __volatile__("mov.l @%1,%0" : "=r"(v) : "r"(a), "m"(*clk)); return v;
}
static inline __attribute__((always_inline)) int recompsx_p0_ld16(unsigned int a, const int* clk) {
    if(RECOMPSX_P0_PORT(a)) return rx_fm_read(1, (int)a);
    int v; __asm__ __volatile__("mov.w @%1,%0" : "=r"(v) : "r"(a), "m"(*clk)); return v;
}
static inline __attribute__((always_inline)) int recompsx_p0_ld8(unsigned int a, const int* clk) {
    if(RECOMPSX_P0_PORT(a)) return rx_fm_read(0, (int)a);
    int v; __asm__ __volatile__("mov.b @%1,%0" : "=r"(v) : "r"(a), "m"(*clk)); return v;
}
static inline __attribute__((always_inline)) void recompsx_p0_st32(unsigned int a, int v, const int* clk) {
    if(RECOMPSX_P0_PORT(a)) { rx_fm_write(2, (int)a, v); return; }
    __asm__ __volatile__("mov.l %1,@%0" : : "r"(a), "r"(v), "m"(*clk));
}
static inline __attribute__((always_inline)) void recompsx_p0_st16(unsigned int a, int v, const int* clk) {
    if(RECOMPSX_P0_PORT(a)) { rx_fm_write(1, (int)a, v); return; }
    __asm__ __volatile__("mov.w %1,@%0" : : "r"(a), "r"(v), "m"(*clk));
}
static inline __attribute__((always_inline)) void recompsx_p0_st8(unsigned int a, int v, const int* clk) {
    if(RECOMPSX_P0_PORT(a)) { rx_fm_write(0, (int)a, v); return; }
    __asm__ __volatile__("mov.b %1,@%0" : : "r"(a), "r"(v), "m"(*clk));
}
/* The CpuState's next deadline, read from memory at every pump test (see above). */
#define recompsx_p0_deadline(next) (*(volatile const int*)(next))

/* By base register and offset (Memory.read32bt and the rest): for an offset that is not negative,
 * the base's bus address plus the offset, `(base & 0x1FFFFFFF) + off` — the first part the
 * compiler's to share among every access through one base value (a span with no test), the
 * offset the instruction's displacement where it fits (mov.l @(0..60,Rn); mov.w and mov.b through
 * R0, @(0..30) and @(0..15)) and in R0 where it does not (mov.x @(R0,Rn)); for a negative one the
 * bus address `(base + off) & 0x1FFFFFFF`, as before. The first is that bus address too, but where
 * the offset carries it past 0x1FFFFFFF: then it lands on no page (0x20000000 up) and traps, and
 * the trap takes the guest address as TEA & 0x1FFFFFFF — the bus address again. (A negative offset
 * could carry it below 0, into P4, so it never takes that form.) Every form here is one the trap
 * decodes. */
#define RECOMPSX_P0_BPORT(p) (__builtin_constant_p(p) && !RECOMPSX_P0_MAPPED((p) & 0x1FFFFFFFu))
#define RECOMPSX_P0_DISP(off, step, max) ((off) >= 0 && (off) <= (max) && ((off) & ((step) - 1)) == 0)
#define RECOMPSX_P0_UP(off) (__builtin_constant_p(off) && (off) >= 0)

static inline __attribute__((always_inline)) int recompsx_p0_ld32b(unsigned int base, int off, const int* clk) {
    int v;
    if(RECOMPSX_P0_UP(off)) {
        const unsigned int b = base & 0x1FFFFFFFu;
        if(RECOMPSX_P0_BPORT(b + (unsigned int)off)) return rx_fm_read(2, (int)((b + (unsigned int)off) & 0x1FFFFFFFu));
        else if(RECOMPSX_P0_DISP(off, 4, 60)) __asm__ __volatile__("mov.l @(%O2,%1),%0" : "=r"(v) : "r"(b), "n"(off), "m"(*clk));
        else __asm__ __volatile__("mov.l @(%2,%1),%0" : "=r"(v) : "r"(b), "z"(off), "m"(*clk));
        return v;
    }
    return recompsx_p0_ld32((base + (unsigned int)off) & 0x1FFFFFFFu, clk);
}
static inline __attribute__((always_inline)) int recompsx_p0_ld16b(unsigned int base, int off, const int* clk) {
    int v;
    if(RECOMPSX_P0_UP(off)) {
        const unsigned int b = base & 0x1FFFFFFFu;
        if(RECOMPSX_P0_BPORT(b + (unsigned int)off)) return rx_fm_read(1, (int)((b + (unsigned int)off) & 0x1FFFFFFFu));
        else if(RECOMPSX_P0_DISP(off, 2, 30)) __asm__ __volatile__("mov.w @(%O2,%1),%0" : "=z"(v) : "r"(b), "n"(off), "m"(*clk));
        else __asm__ __volatile__("mov.w @(%2,%1),%0" : "=r"(v) : "r"(b), "z"(off), "m"(*clk));
        return v;
    }
    return recompsx_p0_ld16((base + (unsigned int)off) & 0x1FFFFFFFu, clk);
}
static inline __attribute__((always_inline)) int recompsx_p0_ld8b(unsigned int base, int off, const int* clk) {
    int v;
    if(RECOMPSX_P0_UP(off)) {
        const unsigned int b = base & 0x1FFFFFFFu;
        if(RECOMPSX_P0_BPORT(b + (unsigned int)off)) return rx_fm_read(0, (int)((b + (unsigned int)off) & 0x1FFFFFFFu));
        else if(RECOMPSX_P0_DISP(off, 1, 15)) __asm__ __volatile__("mov.b @(%O2,%1),%0" : "=z"(v) : "r"(b), "n"(off), "m"(*clk));
        else __asm__ __volatile__("mov.b @(%2,%1),%0" : "=r"(v) : "r"(b), "z"(off), "m"(*clk));
        return v;
    }
    return recompsx_p0_ld8((base + (unsigned int)off) & 0x1FFFFFFFu, clk);
}
static inline __attribute__((always_inline)) void recompsx_p0_st32b(unsigned int base, int off, int v, const int* clk) {
    if(RECOMPSX_P0_UP(off)) {
        const unsigned int b = base & 0x1FFFFFFFu;
        if(RECOMPSX_P0_BPORT(b + (unsigned int)off)) rx_fm_write(2, (int)((b + (unsigned int)off) & 0x1FFFFFFFu), v);
        else if(RECOMPSX_P0_DISP(off, 4, 60)) __asm__ __volatile__("mov.l %2,@(%O1,%0)" : : "r"(b), "n"(off), "r"(v), "m"(*clk));
        else __asm__ __volatile__("mov.l %2,@(%1,%0)" : : "r"(b), "z"(off), "r"(v), "m"(*clk));
        return;
    }
    recompsx_p0_st32((base + (unsigned int)off) & 0x1FFFFFFFu, v, clk);
}
static inline __attribute__((always_inline)) void recompsx_p0_st16b(unsigned int base, int off, int v, const int* clk) {
    if(RECOMPSX_P0_UP(off)) {
        const unsigned int b = base & 0x1FFFFFFFu;
        if(RECOMPSX_P0_BPORT(b + (unsigned int)off)) rx_fm_write(1, (int)((b + (unsigned int)off) & 0x1FFFFFFFu), v);
        else if(RECOMPSX_P0_DISP(off, 2, 30)) __asm__ __volatile__("mov.w %2,@(%O1,%0)" : : "r"(b), "n"(off), "z"(v), "m"(*clk));
        else __asm__ __volatile__("mov.w %2,@(%1,%0)" : : "r"(b), "z"(off), "r"(v), "m"(*clk));
        return;
    }
    recompsx_p0_st16((base + (unsigned int)off) & 0x1FFFFFFFu, v, clk);
}
static inline __attribute__((always_inline)) void recompsx_p0_st8b(unsigned int base, int off, int v, const int* clk) {
    if(RECOMPSX_P0_UP(off)) {
        const unsigned int b = base & 0x1FFFFFFFu;
        if(RECOMPSX_P0_BPORT(b + (unsigned int)off)) rx_fm_write(0, (int)((b + (unsigned int)off) & 0x1FFFFFFFu), v);
        else if(RECOMPSX_P0_DISP(off, 1, 15)) __asm__ __volatile__("mov.b %2,@(%O1,%0)" : : "r"(b), "n"(off), "z"(v), "m"(*clk));
        else __asm__ __volatile__("mov.b %2,@(%1,%0)" : : "r"(b), "z"(off), "r"(v), "m"(*clk));
        return;
    }
    recompsx_p0_st8((base + (unsigned int)off) & 0x1FFFFFFFu, v, clk);
}
#endif

#ifdef __cplusplus
}
#endif

#endif
