/* The definitions. Zero-initialised by the C runtime, which golden rule 3 requires of every piece
 * of emulated state — host garbage reaching an emulated machine ends determinism before the first
 * instruction runs. Being in .bss rather than on the heap changes nothing about the bytes. */
#include "recompsx_arena.h"

recompsx_mem_t recompsx_mem;
int recompsx_gte[RECOMPSX_GTE_WORDS];
int recompsx_gpu[RECOMPSX_GPU_WORDS];
int recompsx_spu[RECOMPSX_SPU_WORDS];
int recompsx_timers[RECOMPSX_TIMER_WORDS];
/* On a line of its own, so its second line holds every word a stretch of the list walk touches. */
int recompsx_sched[RECOMPSX_SCHED_WORDS] __attribute__((aligned(32)));
