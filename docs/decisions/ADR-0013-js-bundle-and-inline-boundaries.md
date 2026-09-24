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
