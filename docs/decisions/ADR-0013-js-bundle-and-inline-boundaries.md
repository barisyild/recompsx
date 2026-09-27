# ADR-0013: Keep large runtime accessors out of generated JS bodies
Status: accepted   Date: 2026-09-21

## Context

The generic generator emits more than half a million lines of Haxe for a real PS1 executable.
Inlining the complete `Memory.read/write` address classification into every guest load and store
made the raw browser bundle 27.4 MB and gave downstream ES6 compilation multi-minute, multi-GB
working sets. The same decision also affected VRAM coordinate access in raster loops, where the
coordinate masks and address multiplication were repeated for every clipped pixel.

## Decision

Keep public `Memory` address accessors and wrapped `Vram.get/set` as ordinary static methods, and
keep only small raw-buffer, arithmetic and already-clipped linear accessors inline. Raster spans
must calculate a valid linear VRAM index once per row and use `getLinear`/`setLinear`; upload and
VRAM-copy paths retain the wrapping coordinate API. Browser builds preserve the Haxe output as a
raw bundle and run the served bundle through the pinned Closure Compiler package with
`SIMPLE_OPTIMIZATIONS`, `ECMASCRIPT_2020` input and `ECMASCRIPT_2015` output. Do not use
`ADVANCED` because the page host communicates with generated code through dynamic JS names.

## Alternatives

- Keep all accessors inline: rejected because generated body size and ES6 compiler memory became
  the dominant build problem.
- Use Closure `ADVANCED`: rejected because it can rename or remove names used by the page host and
  generated dynamic dispatch ABI.
- Make every runtime helper non-inline: rejected because small RawMem, arithmetic and linear
  raster accessors are measurable hot paths on both JavaScript and reflaxe.CPP.

## Consequences

The browser raw bundle is 10,564,124 bytes and the Closure ES6 bundle is 4,930,496 bytes in the
Crash Bash build `b97768f188a6`. Both the raw and Closure bundles report `frames=3000
digest=0e180c28`; the Raster conformance fixture agrees on JavaScript and C++ (`b66077e7`). The
unoptimized raw bundle measured 6.91 seconds for that bounded Node run, while the Closure bundle
measured 7.14 seconds, so Closure is currently a size/parse optimization rather than a guaranteed
steady-state emulator speedup.

## Revision 2026-09-27: on C++, RAM and the scratchpad inline at the call site (`mem.Access`)

The decision stands for JavaScript: the accessors are still ordinary functions there, one call per
guest access, and the bundle does not grow — call sites name `Access` instead of `Memory`, whose
public accessors are now inline one-liners forwarding to it. On reflaxe.CPP the hot half of every
access runs inline: `mem.Access` is a header-only class (`@:headerOnly`, which is where
reflaxe.CPP puts a function body another translation unit can inline) with `@:cppInline` and
`always_inline`, holding the RAM path and the scratchpad path. The ports stay out of line in
`Memory.slowRead*`/`slowWrite*`, now `noinline`.

Measured on the Dreamcast (Flycast, M cycles, Crash 3 vblanks 4700-5000): 1741.8 as calls; 1811.5
with only RAM inline, because GCC inlined the port handlers into the out-of-line half and every
scratchpad access paid their prologue; 1749.9 with the slow paths `noinline`; **1645.0** with the
scratchpad inline too. Counted on JS, Crash 3 makes 7.1 M of its 17.1 M accesses in that window
to the scratchpad (a base register holding 1F800000h), Crash Bash 13.3 M of 64 M in 18800-20300
(its stack), so the scratchpad is not one game's habit. Crash Bash itself is neutral (6233.1 ->
6227.7): what memory time it has left is I/O polling. The cost is size, about 30 bytes a site:
the Dreamcast images grow from 10.10 to 11.60 MB (Crash 3) and 8.44 to 9.46 MB (Crash Bash).
