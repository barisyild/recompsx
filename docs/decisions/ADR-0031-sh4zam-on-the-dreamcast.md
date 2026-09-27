# ADR-0031: sh4zam first on the Dreamcast
Status: accepted   Date: 2026-09-27

## Context

The Dreamcast backend is plain C over KallistiOS and newlib: `memcpy`, `memset`, compiler struct
copies (`__movstr_i4_*`), headers handed to the TA one `pvr_prim` call at a time. sh4zam
(github.com/gyrovorbis/sh4zam, MIT, part of kos-ports) is a hand-optimised SH-4 library: memory
routines built on paired 64-bit FPU moves, `movca.l` and the store queues, the SH-4's cache and
prefetch intrinsics, and fast replacements for `<math.h>`. What it buys is mostly invisible to
the profiler we have: Flycast counts guest cycles but not cache misses, store-queue bursts,
`movca.l` or bus timing, so its numbers understate a change made for the hardware. libfastmem,
the other candidate, is LGPL-2.1 — not for an MIT repository or its statically linked binaries.

## Decision

Vendor sh4zam as a pinned submodule (`vendor/sh4zam`) and build it into Dreamcast builds only:
its headers, and `source/sh4/shz_mem_sh4.s`, whose routines its inline copies call.
**On the Dreamcast, a std function with an sh4zam counterpart is not used: the sh4zam one is**
(the table in `src/backend/dreamcast/AGENTS.md`), and the backend uses sh4zam's intrinsics
where the hardware rewards them. First uses: every `memcpy`/`memset` in the backend; headers,
restated headers and background-mark quads go to the TA through the direct-rendering store queue
with `shz_sq_memcpy32_1` instead of `pvr_prim`; kept headers are copied with `shz_memcpy32_1`;
the command record shrinks from 36 to 32 bytes and is 32-aligned, so recording one allocates its
line with `shz_dcache_alloc_line` (`movca.l`, no read of a line about to be overwritten) and
`build_scene` walks the buffer with `SHZ_PREFETCH` four records ahead. Changes like these are
judged on hardware; Flycast remains the gate for correctness and for CPU-work regressions.

## Alternatives

- libfastmem: LGPL-2.1; and sh4zam's memory routines cover the same ground under MIT.
- kos-ports' sh4zam: not pinned (it builds upstream master), so a build would change under us.
- sh4zam in the runtime or in generated code: they are portable integer code with bit-exact
  semantics shared with JavaScript (golden rules 1 and 3); sh4zam's float routines cannot keep
  the GTE exact, and the runtime has no std calls to replace.

## Consequences

The backend's C code now needs `vendor/sh4zam` (setup.sh checks it; CMake fails clearly without
it). sh4zam's contracts become ours: alignment for its sized copies (asserts vanish under
`NDEBUG`), whole-line writes after `movca.l` (Flycast treats it as a store, so only a console
shows a mistake), `fr0`-`fr7` clobbered by the `fschg` routines. A wrong record layout would
show up as `_Static_assert` failures in `dc_internal.h`, not at run time.
