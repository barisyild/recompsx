/* The definitions. Zero-initialised by the C runtime, which golden rule 3 requires of every piece
 * of emulated state — host garbage reaching an emulated machine ends determinism before the first
 * instruction runs. Being in .bss rather than on the heap changes nothing about the bytes. */
#include "recompsx_arena.h"

unsigned char recompsx_ram[RECOMPSX_RAM_BYTES];
unsigned char recompsx_scratch[RECOMPSX_SCRATCH_BYTES];
