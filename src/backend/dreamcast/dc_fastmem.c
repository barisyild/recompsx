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
    snprintf(msg, sizeof(msg), "fastmem test (ns/access: base on p0 chk, fault): %s (sink %lu)",
             g_fm_line, (unsigned long)sink);
    bp_log(BP_LOG_WARN, msg);
}
#endif
