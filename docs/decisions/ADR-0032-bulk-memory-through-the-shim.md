# ADR-0032: Bulk memory operations go through the shim
Status: accepted   Date: 2026-09-28

## Context

The runtime moved memory an element at a time in the places where it moves the most: a
VRAM-to-VRAM copy called `blend` per pixel; a CPU-to-VRAM upload went through `writeGp0`,
`transferWord` and `putTexel` per halfword, also when a DMA2 block carried it straight from RAM;
DMA3 popped a sector out of the CD FIFO a byte at a time into `Memory.write32`; DMA4 pushed wave
data a halfword at a time; DMA6 built each ordering table through the memory map word by word;
and the C++ shim's `fill16Index` — every fill and every opaque span — was a loop of byte stores
the SH-4 cannot widen. On the Dreamcast the rule of ADR-0031 wants sh4zam's copies and fills
under exactly these, and the portable runtime cannot name sh4zam.

## Decision

Add `shim.Bulk` — `copy` (memmove), `equal`, `fill16`, `prefetch`, offsets in bytes — with an
implementation per target: C++ through `native/recompsx_bulk.h`, which chooses sh4zam on the
Dreamcast (`_arch_dreamcast`) and the C library or the compiler builtin elsewhere; JavaScript
through `copyWithin`, typed-array loops and `fill` (no view allocated per call); the JVM through
byte loops. The runtime uses it where each run is provably equivalent to the per-element code,
and falls back to that code everywhere else:

- VRAM-to-VRAM copies by rows when no mask bit is set or checked and neither run wraps at the
  right edge — except a row copied onto itself further right, which the hardware's in-order copy
  repeats and memmove would not.
- Uploads from RAM (`Gpu.uploadRun`, used by DMA2 blocks and lists) by row segments, with the
  word count, the padding halfword, `uploaded`, `wordsReceived` and the backend's dirty rectangle
  exactly as the per-word path leaves them; mask bits fall back, and a run stops at the end of
  RAM, where the channel's address wraps. A list node asks for a run only where one can be under
  way — at its start and after a word the command path took — not before every packet.
- DMA3 forwards inside RAM (`Cdrom.dmaCopy`: the FIFO's bytes, then zeroes), DMA4 inside RAM
  (`Spu.dmaCopy`: runs up to the end of sound RAM, counted and marked dirty the same), DMA6 inside
  RAM stored directly, and `Vram.fillLinear` on `Bulk.fill16`.
- Under hardware drawing, a copy or upload still tells the backend only when a pixel changed:
  `equal` before the run is the per-pixel comparison, since nothing is read after it is written.
- The DMA2 list walk takes untouched stretches of an ordering table a cache line at a time. Such
  an entry links to its neighbour — the word below in a table ClearOTagR or DMA6 built (Crash
  Bash), the word above in one ClearOTag built (Crash 3) — so from a line's first word in the
  walk's direction, a line is eight independent loads compared against their addresses, and one
  `prefetch` two lines ahead, instead of eight loads each waiting on the last. The walk lands where
  its single steps would have, with their header and guard, and never passes the guard's limit
  inside a line. Measured on JavaScript: 86 % of Crash 3's empty-node steps and 70 % of Crash
  Bash's go this way, in runs of 155 and 166 nodes on average.

The BulkPaths conformance test covers the copies, uploads, fills and DMA3/4/6; OtWalk covers the
list walk — tables in both directions at every alignment, fills at a line's ends and middle, a
skipping link, a link through the RAM mirror, tables at either end of RAM, the guard met exactly
and passed, tables looped on themselves — and uploads carried across list nodes and past the
end of RAM. Both digests were taken from the per-element code before this existed, and both
targets reproduce them.

## Alternatives

- sh4zam called from the runtime behind `#if`: the runtime is portable Haxe (golden rule 1);
  what differs per machine belongs to the shim.
- Bulk paths without the fallbacks: the mask bits, the wraps and the in-order overlap are all
  observable, and a digest would move for the rare game that uses them.
- A prefetch alone in the node-at-a-time walk, asked for at each line boundary: tried first.
  The test on every node, and the register it cost (GCC moved the guard to the stack), made
  the walk 16 % slower on Flycast's count (Crash 3, 164.5 -> 191.0 ms of 7,525) — more than the
  hint can win back on a console. Taking the line whole pays for its prefetch.

## Consequences

The C++ shim grows a native header and a header-only class, shaped as `mem.Access` is (an
`@:include` on an extern does not follow its `@:nativeFunctionCode` calls into the files that
make them); the Hatchet shim, set aside but kept compiling, calls the same header. Game digests
do not move: Crash 3 9,000/20,000 and Crash Bash 3,000/9,000/30,000 on JavaScript, conformance
on both targets.
