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

#ifdef __cplusplus
extern "C" {
#endif

extern unsigned char recompsx_ram[RECOMPSX_RAM_BYTES];
extern unsigned char recompsx_scratch[RECOMPSX_SCRATCH_BYTES];

#ifdef __cplusplus
}
#endif

#endif
