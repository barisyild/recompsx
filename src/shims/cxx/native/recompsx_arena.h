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

/* RAM and the scratchpad are one array, so that one index addresses either: a run of guest
 * accesses through one base register is checked once and then indexed (mem.Memory.span, the
 * recompiler's spans). The scratchpad starts 160 bytes after RAM ends — five 32-byte lines past a
 * 16 KB boundary from RAM's start — so the two keep the colours in the operand cache the data
 * placement gave them apart (src/backend/dreamcast/dc-data-placement.txt: 82 and 87). The same
 * number is shim.Arena.SCRATCH_OFFSET on every target. */
#define RECOMPSX_SCRATCH_OFFSET (RECOMPSX_RAM_BYTES + 160)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned char ram[RECOMPSX_RAM_BYTES];
    unsigned char gap[RECOMPSX_SCRATCH_OFFSET - RECOMPSX_RAM_BYTES];
    unsigned char scratch[RECOMPSX_SCRATCH_BYTES];
} __attribute__((aligned(32))) recompsx_mem_t;

extern recompsx_mem_t recompsx_mem;
#define recompsx_ram (recompsx_mem.ram)
#define recompsx_scratch (recompsx_mem.scratch)
extern int recompsx_gte[RECOMPSX_GTE_WORDS];
extern int recompsx_gpu[RECOMPSX_GPU_WORDS];
extern int recompsx_spu[RECOMPSX_SPU_WORDS];
extern int recompsx_timers[RECOMPSX_TIMER_WORDS];

#ifdef __cplusplus
}
#endif

#endif
