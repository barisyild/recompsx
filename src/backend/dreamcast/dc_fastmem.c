/* dc_fastmem.c — the fastmem feasibility test (`--dc-fastmem-test`). */

#include "dc_internal.h"

#if RECOMPSX_DC_PROFILE
/* ---- fastmem feasibility (`--dc-fastmem-test`) --------------------------------------------------
 * A measurement, not a feature. "Fastmem" would map the emulated RAM with the SH-4's MMU at the
 * PlayStation's own addresses, so a guest access becomes one masked load, and let the MMU's miss
 * exception catch the rare access that is a hardware register. On a real Dreamcast the MMU costs
 * nothing; under an emulator it may cost everything — Flycast can run MMU-enabled code on a slower
 * path — and the exception is the price of every register access. So before anything is built,
 * this measures, at boot, what each of those costs where the numbers are read:
 *
 *   base  a load from ordinary memory, MMU off
 *   on    the same load with the MMU on (it only translates P0; this is the emulator's tax)
 *   p0    a load through a static 64 KB P0 mapping of that memory (what fastmem would do)
 *   chk   the check-then-load the generated code does today, RAM case
 *   flt   one TLB-miss exception, handled by emulating the faulting `mov.l`
 *
 * in nanoseconds per access, plus whether the mapping read back what was written (`ok`/`BAD`:
 * an emulator without MMU translation reads whatever is at the physical address). The MMU is off
 * again before the game starts. */
#include <arch/mmu.h>
char g_fm_line[48];
static volatile uint32_t g_fm_faults;

static void fm_miss_read(irq_t code, irq_context_t* cx, void* data) {
    (void)code; (void)data;
    const uint16_t op = *(const uint16_t*)cx->pc;     /* mov.l @Rm,Rn: 0110nnnnmmmm0010 */
    cx->r[(op >> 8) & 15] = 0x5A5A5A5Au;
    cx->pc += 2;
    g_fm_faults++;
}

/* Today's fast path, as the generated code has it inline: RAM, else scratchpad, else a call. */
static uint32_t g_fm_ram_base;
__attribute__((noinline)) static uint32_t fm_slow(uint32_t a) { return a; }
static inline uint32_t fm_checked(uint32_t a) {
    const uint32_t p = a & 0x1FFFFFFFu;
    if((p & 0x1F9FFFFFu) < 0x200000u) return *(volatile uint32_t*)(g_fm_ram_base + (p & 0x1FFFFCu));
    else if((p & 0x1FFFFC00u) == 0x1F800000u) return *(volatile uint32_t*)(g_fm_ram_base + (p & 0x3FCu));
    else return fm_slow(p);
}

void fastmem_test(void) {
    enum { N = 1 << 18, FAULTS = 4096 };
    uint32_t* buf = (uint32_t*)memalign(65536, 65536);
    if(!buf) { snprintf(g_fm_line, sizeof(g_fm_line), "fm: no aligned 64K"); return; }
    for(int i = 0; i < 16384; i++) buf[i] = 0x1000u + (uint32_t)i;
    g_fm_ram_base = (uint32_t)(uintptr_t)buf;
    uint32_t sink = 0;
    uint64_t t0, t[5];

#define FM_LOOP(expr) do { t0 = bp_time_us(); \
        for(int i = 0; i < N; i++) { const uint32_t o = (uint32_t)(i * 4) & 0xFFFCu; sink += (expr); } } while(0)

    FM_LOOP(*(volatile uint32_t*)((uintptr_t)buf + o));
    t[0] = bp_time_us() - t0;

    mmu_init_basic();
    const uintptr_t virt = 0x00100000u;
    const int mapped = mmu_page_map_static(virt, (uintptr_t)buf & 0x1FFFFFFFu, PAGE_SIZE_64K,
                                           MMU_ALL_RDWR, true);
    FM_LOOP(*(volatile uint32_t*)((uintptr_t)buf + o));
    t[1] = bp_time_us() - t0;
    FM_LOOP(*(volatile uint32_t*)(virt + o));
    t[2] = bp_time_us() - t0;
    int ok = mapped == 0;
    for(int i = 0; i < 16384 && ok; i += 97) ok = ((volatile uint32_t*)virt)[i] == 0x1000u + (uint32_t)i;
    FM_LOOP(fm_checked(0x80000000u + o));
    t[3] = bp_time_us() - t0;

    irq_set_handler(EXC_DTLB_MISS_READ, fm_miss_read, NULL);
    g_fm_faults = 0;
    t0 = bp_time_us();
    for(int i = 0; i < FAULTS; i++) {
        uint32_t v;
        __asm__ __volatile__("mov.l @%1,%0" : "=r"(v) : "r"(0x00800000u) : "memory");
        sink += v;
    }
    t[4] = bp_time_us() - t0;
    /* What the first misses gave: the handler's 5A5A5A5A each time, or something else after the
     * first (the address read untranslated, as an emulator that stopped trapping would). */
    uint32_t seen[8];
    const uint32_t f0 = g_fm_faults;
    for(int i = 0; i < 8; i++) {
        uint32_t v;
        __asm__ __volatile__("mov.l @%1,%0" : "=r"(v) : "r"(0x00800000u + (uint32_t)i * 4096u) : "memory");
        seen[i] = v;
    }
    const uint32_t f1 = g_fm_faults;
    irq_set_handler(EXC_DTLB_MISS_READ, NULL, NULL);
    mmu_shutdown_basic();
#undef FM_LOOP

    free(buf);
    /* Nanoseconds per access; the fault in whole nanoseconds. */
    unsigned long ns[4];
    for(int i = 0; i < 4; i++) ns[i] = (unsigned long)(t[i] * 1000u * 10u / N);   /* tenths */
    snprintf(g_fm_line, sizeof(g_fm_line), "fm %lu.%lu %lu.%lu %lu.%lu %lu.%lu f%lu %s%s",
             ns[0] / 10, ns[0] % 10, ns[1] / 10, ns[1] % 10, ns[2] / 10, ns[2] % 10,
             ns[3] / 10, ns[3] % 10, (unsigned long)(t[4] * 1000u / FAULTS),
             ok ? "ok" : "BAD", g_fm_faults == FAULTS ? "" : "!");
    char msg[128];
    snprintf(msg, sizeof(msg), "fastmem test (ns/access: base on p0 chk, fault): %s (sink %lu, %lu of %d faults taken)",
             g_fm_line, (unsigned long)sink, (unsigned long)f0, FAULTS);
    bp_log(BP_LOG_WARN, msg);
    snprintf(msg, sizeof(msg), "fastmem test: 8 misses on 8 pages, %lu trapped: %08lx %08lx %08lx %08lx %08lx %08lx %08lx %08lx",
             (unsigned long)(f1 - f0), (unsigned long)seen[0], (unsigned long)seen[1], (unsigned long)seen[2],
             (unsigned long)seen[3], (unsigned long)seen[4], (unsigned long)seen[5], (unsigned long)seen[6],
             (unsigned long)seen[7]);
    bp_log(BP_LOG_WARN, msg);
}
#endif

#if RECOMPSX_FASTMEM
/* ---- fastmem (ADR-0049): guest RAM and the scratchpad through the MMU ----------------------------
 * The generated code reaches guest memory at the guest's own bus addresses in P0 (shim.P0,
 * recompsx_p0_*): RAM and its three mirrors are eight 1 MB pages onto the arena's RAM, the
 * scratchpad one 1 KB page onto its copy; nothing else is mapped. An access anywhere else — a port,
 * the BIOS, an address the PlayStation has nothing at — misses the TLB, and is emulated:
 *
 *   rx_fm_vbr     the vector table while fastmem is on: KallistiOS's for every exception and
 *                 interrupt, except a TLB miss on a P0 address by code in P1 — a guest access, the
 *                 only P0 accesses there are — which it records (TEA and the pc) and resumes at the
 *                 trampoline, in fourteen instructions (KallistiOS's own path saves the whole
 *                 context, both FPU banks, and dispatches in C: several hundred a trap);
 *   fm_tlb_miss   KallistiOS's path, for a miss the vector passes on: not a guest access, an error;
 *   rx_fm_trampoline (the faulting code's context: its stack, interrupts as they were) keeps what a
 *                 C call may change, reads the record and decodes the access before it calls out
 *                 (so an access the slow path makes cannot change it), takes the bus address
 *                 from TEA (wrapped, for an offset that carried a base past 0x1FFFFFFF), calls the runtime's
 *                 slow path (rx_fm_read / rx_fm_write, mem.Fastmem), puts a load's value where its
 *                 destination register is restored from, and goes back to the instruction after
 *                 the access.
 *
 * The slow path runs where it always did, in ordinary context, since a port write can run as much
 * of the machine as today's decode lets it; and with the clock the access named (shim.P0). */
#include <arch/mmu.h>
#include <arch/irq.h>
#include "recompsx_arena.h"

extern int rx_fm_read(int size, int addr);
extern void rx_fm_write(int size, int addr, int v);
extern void rx_fm_trampoline(void);

/* The access the trampoline finishes: TEA and the access's pc. */
__attribute__((used)) volatile uint32_t g_fm_fault[2];
__attribute__((used)) uint32_t g_fm_traps;

/* An instruction the trampoline does not decode as a guest access (`op`, at `pc`, missing at `tea`):
 * a stray pointer in the runtime or the backend, or an access in a delay slot (SPC at its branch),
 * where the accessors are never put. */
__attribute__((used, noreturn)) void fm_bad(uint32_t op, uint32_t pc, uint32_t tea) {
    char msg[96];
    snprintf(msg, sizeof(msg), "fastmem: TLB miss at %08lx by %04lx at pc %08lx — not a guest access",
             (unsigned long)tea, (unsigned long)(op & 0xFFFFu), (unsigned long)pc);
    bp_log(BP_LOG_ERROR, msg);
    arch_abort();
    for(;;) {}
}

#if RECOMPSX_FM_HIST
/* A diagnostic build's count of the traps by bus address over the bench window (-DRECOMPSX_FM_HIST=1):
 * which ports a game reaches through computed addresses, and from where. Not for measuring: the note
 * is a call in every trap. */
#define FM_HIST 128
static uint32_t g_fm_hist_addr[FM_HIST], g_fm_hist_pc[FM_HIST], g_fm_hist_n[FM_HIST], g_fm_hist_lost;
__attribute__((used)) void fm_hist_note(uint32_t addr, uint32_t pc) {
    const uint32_t h = (addr * 2654435761u) >> 25;
    for(uint32_t k = 0; k < FM_HIST; k++) {
        const uint32_t i = (h + k) & (FM_HIST - 1);
        if(g_fm_hist_n[i] == 0) { g_fm_hist_addr[i] = addr; g_fm_hist_pc[i] = pc; g_fm_hist_n[i] = 1; return; }
        else {}
        if(g_fm_hist_addr[i] == addr) { g_fm_hist_n[i]++; return; }
        else {}
    }
    g_fm_hist_lost++;
}
void fm_hist_reset(void) {
    for(uint32_t i = 0; i < FM_HIST; i++) g_fm_hist_n[i] = 0;
    g_fm_hist_lost = 0;
}
/* The 24 most trapped addresses: address, traps a frame (tenths), and the pc of the first. */
void fm_hist_report(uint32_t frames) {
    char line[160];
    for(int r = 0; r < 24; r++) {
        int best = -1;
        for(int i = 0; i < FM_HIST; i++) if(g_fm_hist_n[i] != 0 && (best < 0 || g_fm_hist_n[i] > g_fm_hist_n[best])) best = i;
        if(best < 0) break;
        else {}
        const uint32_t t = g_fm_hist_n[best] * 10u / (frames ? frames : 1u);
        snprintf(line, sizeof(line), "fastmem trap %08lx: %lu.%lu a frame, pc %08lx",
                 (unsigned long)g_fm_hist_addr[best], (unsigned long)(t / 10), (unsigned long)(t % 10),
                 (unsigned long)g_fm_hist_pc[best]);
        bp_log(BP_LOG_WARN, line);
        g_fm_hist_n[best] = 0;
    }
    snprintf(line, sizeof(line), "fastmem traps not counted (table full): %lu", (unsigned long)g_fm_hist_lost);
    bp_log(BP_LOG_WARN, line);
}
#endif

/* KallistiOS's TLB-miss path: what the vector passes on — a miss on P3, or by code in P0. */
static void fm_tlb_miss(irq_t code, irq_context_t* cx, void* data) {
    (void)code; (void)data;
    fm_bad(*(const uint16_t*)cx->pc, cx->pc, *(volatile uint32_t*)0xFF00000Cu);
}

/* The vector table. In an exception r0..r7 are bank 1, free; SR.BL is set, so nothing here may miss
 * the TLB: TEA is P4, the record P1. VBR+0x400 is the TLB misses' alone (instruction, data read, data
 * write); a miss on P3, or an instruction's (its SPC in P0), goes to KallistiOS. */
__asm__(
"   .pushsection .text.rx_fm_vbr,\"ax\",@progbits\n"
"   .balign 32\n"
"   .global _rx_fm_vbr\n"
"_rx_fm_vbr:\n"
"   .org    0x100\n"                  /* general exceptions */
"   mov.l   .Lv_k100,r0\n"
"   jmp     @r0\n"
"   nop\n"
"   .balign 4\n"
".Lv_k100:   .long _irq_vma_table + 0x100\n"
"   .org    0x400\n"                  /* TLB misses */
"   mov.l   .Lv_tea,r0\n"
"   mov.l   @r0,r1\n"
"   cmp/pz  r1\n"
"   bf      .Lv_kos\n"                /* not P0 */
"   stc     spc,r2\n"
"   cmp/pz  r2\n"
"   bt      .Lv_kos\n"                /* code in P0: an instruction miss */
"   mov.l   .Lv_fault,r0\n"
"   mov.l   r1,@r0\n"
"   mov.l   r2,@(4,r0)\n"
"   mov.l   .Lv_tramp,r3\n"
"   ldc     r3,spc\n"
"   rte\n"
"   nop\n"
".Lv_kos:\n"
"   mov.l   .Lv_k400,r0\n"
"   jmp     @r0\n"
"   nop\n"
"   .balign 4\n"
".Lv_tea:    .long 0xff00000c\n"
".Lv_fault:  .long _g_fm_fault\n"
".Lv_tramp:  .long _rx_fm_trampoline\n"
".Lv_k400:   .long _irq_vma_table + 0x400\n"
"   .org    0x600\n"                  /* interrupts */
"   mov.l   .Lv_k600,r0\n"
"   jmp     @r0\n"
"   nop\n"
"   .balign 4\n"
".Lv_k600:   .long _irq_vma_table + 0x600\n"
"   .popsection\n"
);
extern char rx_fm_vbr[];

/* The trampoline keeps what a C call may change and the access's code may hold: r0..r7, PR, MACH,
 * MACL and T (r8..r14 the slow path keeps by the ABI). Not the FPU's: the generated code and the
 * runtime have no floating point (scripts/check.sh), so no FP value is live at an access; the
 * division helper they call (__sdivsi3_i4) uses the FPU inside the call only, and every C callee
 * leaves FPSCR's modes as it found them. The accesses it decodes are the accessors' (shim.P0):
 * mov.{b,w,l} @Rm,Rn and Rm,@Rn, mov.{b,w,l} @(R0,Rm),Rn and Rm,@(R0,Rn), mov.l @(disp,Rm),Rn and
 * Rm,@(disp,Rn), and mov.{b,w} through R0 with a displacement. Stack after the saves: the instruction (a load's n once decoded) 0, the
 * resume address 4, T 8, MACL 12, MACH 16, PR 20, then r7..r0 — r(n), n < 8, at 52 - 4n. */
__asm__(
"   .text\n"
"   .align  2\n"
"   .global _rx_fm_trampoline\n"
"_rx_fm_trampoline:\n"
"   mov.l   r0,@-r15\n"
"   mov.l   r1,@-r15\n"
"   mov.l   r2,@-r15\n"
"   mov.l   r3,@-r15\n"
"   mov.l   r4,@-r15\n"
"   mov.l   r5,@-r15\n"
"   mov.l   r6,@-r15\n"
"   mov.l   r7,@-r15\n"
"   sts.l   pr,@-r15\n"
"   sts.l   mach,@-r15\n"
"   sts.l   macl,@-r15\n"
"   movt    r0\n"
"   mov.l   r0,@-r15\n"
"   mov.l   .Lfm_fault,r1\n"
"   mov.l   @r1,r5\n"                 /* TEA */
"   mov.l   @(4,r1),r2\n"             /* the access's pc */
"   mov.w   @r2,r3\n"                 /* its instruction */
"   add     #2,r2\n"
"   mov.l   r2,@-r15\n"               /* where to resume */
"   mov.l   r3,@-r15\n"               /* the instruction; a load's n, once decoded */
"   mov.l   .Lfm_traps,r1\n"
"   mov.l   @r1,r0\n"
"   add     #1,r0\n"
"   mov.l   r0,@r1\n"
#if RECOMPSX_FM_HIST
"   mov     r5,r4\n"                  /* fm_hist_note(TEA, the access's pc) */
"   mov.l   @(4,r15),r5\n"
"   mov.l   .Lfm_note,r0\n"
"   jsr     @r0\n"
"   add     #-2,r5\n"
"   mov.l   .Lfm_fault,r1\n"
"   mov.l   @r1,r5\n"
"   mov.l   @r15,r3\n"
#endif
"   mov.l   .Lfm_mask,r0\n"           /* the bus address: an offset that carried the base's */
"   and     r0,r5\n"                  /* bus address past 0x1FFFFFFF wraps, as the bus does */
"   mov     r3,r0\n"
"   shlr8   r0\n"
"   shlr2   r0\n"
"   shlr2   r0\n"
"   and     #15,r0\n"                 /* the instruction's top nibble */
"   cmp/eq  #6,r0\n"                  /* mov.{b,w,l} @Rm,Rn */
"   bt      .Lfm_t6\n"
"   cmp/eq  #5,r0\n"                  /* mov.l @(disp,Rm),Rn */
"   bt      .Lfm_t5\n"
"   cmp/eq  #2,r0\n"                  /* mov.{b,w,l} Rm,@Rn */
"   bt      .Lfm_t2\n"
"   cmp/eq  #1,r0\n"                  /* mov.l Rm,@(disp,Rn) */
"   bt      .Lfm_t1\n"
"   cmp/eq  #0,r0\n"                  /* mov.{b,w,l} through @(R0,Rn) */
"   bt      .Lfm_t0\n"
"   cmp/eq  #8,r0\n"
"   bf      .Lfm_bad\n"
"   mov     r3,r0\n"                  /* 0x8x..: the R0 forms */
"   shlr8   r0\n"
"   and     #15,r0\n"
"   cmp/eq  #4,r0\n"                  /* mov.b @(disp,Rm),R0 */
"   bt      .Lfm_t84\n"
"   cmp/eq  #5,r0\n"                  /* mov.w @(disp,Rm),R0 */
"   bt      .Lfm_t85\n"
"   cmp/eq  #0,r0\n"                  /* mov.b R0,@(disp,Rn) */
"   bt      .Lfm_t80\n"
"   cmp/eq  #1,r0\n"                  /* mov.w R0,@(disp,Rn) */
"   bt      .Lfm_t81\n"
".Lfm_bad:\n"
"   mov     r3,r4\n"
"   mov.l   @(4,r15),r5\n"
"   add     #-2,r5\n"
"   mov.l   .Lfm_fault,r1\n"
"   mov.l   .Lfm_badf,r0\n"
"   jmp     @r0\n"
"   mov.l   @r1,r6\n"
".Lfm_t6:\n"
"   mov     #3,r4\n"
"   and     r3,r4\n"                  /* the size: 0 byte, 1 halfword, 2 word */
"   mov     #3,r0\n"
"   cmp/eq  r0,r4\n"                  /* 0x6nm3, mov Rm,Rn: no access */
"   bt      .Lfm_bad\n"
".Lfm_tn:\n"
"   mov     r3,r7\n"
"   bra     .Lfm_load\n"
"   shlr8   r7\n"                     /* n */
".Lfm_t5:\n"
"   bra     .Lfm_tn\n"
"   mov     #2,r4\n"
".Lfm_t84:\n"
"   mov     #0,r4\n"
"   bra     .Lfm_load\n"
"   mov     #0,r7\n"
".Lfm_t85:\n"
"   mov     #1,r4\n"
"   bra     .Lfm_load\n"
"   mov     #0,r7\n"
".Lfm_t0:\n"
"   mov     r3,r0\n"
"   and     #15,r0\n"                 /* the low nibble */
"   cmp/eq  #12,r0\n"                 /* mov.b @(R0,Rm),Rn */
"   bt      .Lfm_t0c\n"
"   cmp/eq  #13,r0\n"                 /* mov.w @(R0,Rm),Rn */
"   bt      .Lfm_t0d\n"
"   cmp/eq  #14,r0\n"                 /* mov.l @(R0,Rm),Rn */
"   bt      .Lfm_t0e\n"
"   cmp/eq  #4,r0\n"                  /* mov.b Rm,@(R0,Rn) */
"   bt      .Lfm_t04\n"
"   cmp/eq  #5,r0\n"                  /* mov.w Rm,@(R0,Rn) */
"   bt      .Lfm_t05\n"
"   cmp/eq  #6,r0\n"                  /* mov.l Rm,@(R0,Rn) */
"   bt      .Lfm_t06\n"
"   bra     .Lfm_bad\n"
"   nop\n"
".Lfm_t0c:\n"
"   bra     .Lfm_tn\n"
"   mov     #0,r4\n"
".Lfm_t0d:\n"
"   bra     .Lfm_tn\n"
"   mov     #1,r4\n"
".Lfm_t0e:\n"
"   bra     .Lfm_tn\n"
"   mov     #2,r4\n"
".Lfm_t04:\n"
"   bra     .Lfm_tm\n"
"   mov     #0,r4\n"
".Lfm_t05:\n"
"   bra     .Lfm_tm\n"
"   mov     #1,r4\n"
".Lfm_t06:\n"
"   bra     .Lfm_tm\n"
"   mov     #2,r4\n"
".Lfm_t2:\n"
"   mov     #3,r4\n"
"   and     r3,r4\n"
"   mov     #3,r0\n"
"   cmp/eq  r0,r4\n"
"   bt      .Lfm_bad\n"
".Lfm_tm:\n"
"   mov     r3,r7\n"
"   shlr2   r7\n"
"   bra     .Lfm_store\n"
"   shlr2   r7\n"                     /* m */
".Lfm_t1:\n"
"   bra     .Lfm_tm\n"
"   mov     #2,r4\n"
".Lfm_t80:\n"
"   mov     #0,r4\n"
"   bra     .Lfm_store\n"
"   mov     #0,r7\n"
".Lfm_t81:\n"
"   mov     #1,r4\n"
"   bra     .Lfm_store\n"
"   mov     #0,r7\n"
".Lfm_load:\n"                        /* r4 the size, r5 the bus address, r7's low nibble n */
"   mov     #15,r0\n"
"   and     r0,r7\n"
"   mov.l   r7,@r15\n"
"   mov.l   .Lfm_read,r0\n"
"   jsr     @r0\n"
"   nop\n"
"   mov.l   @r15,r3\n"
"   mov     #8,r1\n"
"   cmp/hs  r1,r3\n"
"   bt      .Lfm_loadhi\n"
"   shll2   r3\n"
"   mov     r15,r1\n"
"   add     #52,r1\n"
"   sub     r3,r1\n"
"   bra     .Lfm_back\n"
"   mov.l   r0,@r1\n"                 /* r(n)'s slot */
".Lfm_loadhi:\n"                      /* r8..r14 themselves: the slow path kept them */
"   add     #-8,r3\n"
"   shll2   r3\n"
"   mov     r0,r2\n"
"   mova    .Lfm_ltab,r0\n"
"   add     r3,r0\n"
"   jmp     @r0\n"
"   nop\n"
"   .align  2\n"
".Lfm_ltab:\n"
"   bra     .Lfm_back\n"
"   mov     r2,r8\n"
"   bra     .Lfm_back\n"
"   mov     r2,r9\n"
"   bra     .Lfm_back\n"
"   mov     r2,r10\n"
"   bra     .Lfm_back\n"
"   mov     r2,r11\n"
"   bra     .Lfm_back\n"
"   mov     r2,r12\n"
"   bra     .Lfm_back\n"
"   mov     r2,r13\n"
"   bra     .Lfm_back\n"
"   mov     r2,r14\n"
".Lfm_store:\n"                       /* r4 the size, r5 the bus address, r7's low nibble m */
"   mov     #15,r0\n"
"   and     r7,r0\n"
"   mov     #8,r1\n"
"   cmp/hs  r1,r0\n"
"   bt      .Lfm_storehi\n"
"   shll2   r0\n"
"   mov     r15,r1\n"
"   add     #52,r1\n"
"   sub     r0,r1\n"
"   bra     .Lfm_write_\n"
"   mov.l   @r1,r6\n"                 /* the value: r(m) as the store found it */
".Lfm_storehi:\n"
"   add     #-8,r0\n"
"   shll2   r0\n"
"   mov     r0,r1\n"
"   mova    .Lfm_stab,r0\n"
"   add     r1,r0\n"
"   jmp     @r0\n"
"   nop\n"
"   .align  2\n"
".Lfm_stab:\n"
"   bra     .Lfm_write_\n"
"   mov     r8,r6\n"
"   bra     .Lfm_write_\n"
"   mov     r9,r6\n"
"   bra     .Lfm_write_\n"
"   mov     r10,r6\n"
"   bra     .Lfm_write_\n"
"   mov     r11,r6\n"
"   bra     .Lfm_write_\n"
"   mov     r12,r6\n"
"   bra     .Lfm_write_\n"
"   mov     r13,r6\n"
"   bra     .Lfm_write_\n"
"   mov     r14,r6\n"
".Lfm_write_:\n"
"   mov.l   .Lfm_write,r0\n"
"   jsr     @r0\n"
"   nop\n"
".Lfm_back:\n"
"   mov.l   @(8,r15),r0\n"
"   shlr    r0\n"                     /* T as it was: nothing below changes it */
"   mov.l   @(12,r15),r1\n"
"   lds     r1,macl\n"
"   mov.l   @(16,r15),r1\n"
"   lds     r1,mach\n"
"   mov.l   @(20,r15),r1\n"
"   lds     r1,pr\n"
"   mov.l   @(4,r15),r0\n"            /* where to resume */
"   mov.l   @(24,r15),r7\n"
"   mov.l   @(28,r15),r6\n"
"   mov.l   @(32,r15),r5\n"
"   mov.l   @(36,r15),r4\n"
"   mov.l   @(40,r15),r3\n"
"   mov.l   @(44,r15),r2\n"
"   mov.l   @(48,r15),r1\n"
"   add     #52,r15\n"                /* at the saved r0 */
"   jmp     @r0\n"
"   mov.l   @r15+,r0\n"
"   .align  2\n"
".Lfm_fault: .long _g_fm_fault\n"
".Lfm_traps: .long _g_fm_traps\n"
".Lfm_read:  .long _rx_fm_read\n"
".Lfm_write: .long _rx_fm_write\n"
".Lfm_badf:  .long _fm_bad\n"
".Lfm_mask:  .long 0x1FFFFFFF\n"
#if RECOMPSX_FM_HIST
".Lfm_note:  .long _fm_hist_note\n"
#endif
);

void fastmem_init(void) {
    const uintptr_t ram = (uintptr_t)recompsx_mem.ram & 0x1FFFFFFFu;
    const uintptr_t scr = (uintptr_t)recompsx_mem.scratch & 0x1FFFFFFFu;
    char msg[128];
    if((ram & 0xFFFFFu) != 0 || (scr & 0x3FFFu) != 0) {
        snprintf(msg, sizeof(msg), "fastmem: the arena is not where its pages need it (RAM %08lx, scratchpad %08lx)",
                 (unsigned long)ram, (unsigned long)scr);
        bp_log(BP_LOG_ERROR, msg);
        arch_abort();
    }
    mmu_init_basic();                       /* the store queues' two pages, and the MMU on */
    for(uint32_t m = 0; m < 4; m++)         /* RAM at 0 and its mirrors at 2, 4 and 6 MB */
        for(uint32_t h = 0; h < 2; h++)
            mmu_page_map_static(m * 0x200000u + h * 0x100000u, ram + h * 0x100000u, PAGE_SIZE_1M, MMU_KERNEL_RDWR, true);
    mmu_page_map_static(0x1F800000u, scr, PAGE_SIZE_1K, MMU_KERNEL_RDWR, true);
    irq_set_handler(EXC_DTLB_MISS_READ, fm_tlb_miss, NULL);
    irq_set_handler(EXC_DTLB_MISS_WRITE, fm_tlb_miss, NULL);
    /* KallistiOS never reloads VBR (entry.s: "don't play with VBR"), and puts its own back at
     * irq_shutdown. */
    __asm__ __volatile__("ldc %0,vbr" : : "r"(rx_fm_vbr) : "memory");
    snprintf(msg, sizeof(msg), "fastmem: guest RAM at P0 0 (physical %08lx) and its mirrors, the scratchpad at 1F800000 (%08lx)",
             (unsigned long)ram, (unsigned long)scr);
    bp_log(BP_LOG_INFO, msg);
}
#endif
