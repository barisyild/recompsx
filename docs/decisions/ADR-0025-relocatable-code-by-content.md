# ADR-0025: Relocatable code is compiled ahead of time and recognised by content
Status: accepted   Date: 2026-09-26

## Context

ADR-0006 models loaded code as overlays: bytes from the disc at a fixed address, identified by
(bytes, window). Crash Bandicoot: Warped (games/crash3) also runs code that has no fixed address.
Its object scripts (GOOL) are bytecode, and op `49BE0BE0h` runs the native MIPS that follows it in
the bytecode (`jalr $s5` in the interpreter at 0x800398e8); that code comes back with
`jalr $s5, $ra`, handing the interpreter the address of the next bytecode word. The bytecode lives
in the level files (`S?/S*.NSF`), which the game loads 64 KB page by page to wherever its heap has
room — byte for byte as on the disc (measured: an 18 KB region of RAM equal to the file). The
native code is position independent: relative branches, calls to the executable at fixed
addresses, returns through `$ra`. On the disc: 12,834 entries in 42 files, 1,313 distinct functions,
about 46,000 instructions — two thirds of the executable again.

The user ruled out an interpreter: everything is to be statically recompiled.

## Decision

**Relocatable code is compiled ahead of time from the disc and recognised by its content.**
A `relocatable` stanza in game.json names the files (patterns allowed), a marker word that
precedes every entry, the aligned unit the files are loaded in (code never crosses one), and how
many words the runtime hashes. The tool reads every file, takes the word after each aligned marker
as an entry, and traces it in its unit mapped at a nominal base no real code occupies (below the
top of RAM, checked against the executable and every overlay window). The tracer rejects data that
happened to contain the marker. Surviving functions are deduplicated by a signature over
(offset from the entry, word) of everything they cover, and emitted once, into `Rel_<id>_…` shards,
in a position-independent mode: the entry address arrives in `core.Reloc.base`, the function's first
statement copies it into `rbase`, and the only values code computes from its own address — link
registers, and the pc published for a trap or kernel call — are `rbase + offset`. A cooperative
frame records the base so a suspended relocatable function resumes with it.

The runtime recognises code at an address the fixed tables do not know by FNV-1a over the first
`hashWords` words there (`RelocTable.call`, reached from `FnTable.call` after the executable's
table misses). Where several functions on the disc share a key, the tool picks the fewest word
positions that tell them apart and emits one row per distinct reading; the runtime reads those
words and takes the row that matches. No cache: a key is a hash and a binary search.

Two tool rules came with it, both generic: a jump through `$ra` returns whatever it links
(`jalr rd, $ra`), and an entry is plausible up to such a jump.

## Alternatives

- **A fallback interpreter for unknown code.** General and simple, rejected by the user: the
  project is static recompilation.
- **Overlay stanzas per load address.** The address is the heap's choice and differs per level and
  per moment; there is no finite set of windows.
- **Recognising by address after watching loads.** The loader copies pages with DMA and with the
  CPU; nothing reliable says which bytes are code or where an entry begins, while the bytes
  themselves do.
- **A fixed-length prefix as the whole key.** Measured: even 16 words leave 44 keys shared by
  different functions (identical prologues, different tails). Separating positions per key cost
  nothing at run time for the unshared ones.

## Consequences

- The universe of relocatable code is closed: it is what the disc holds. Code the game builds or
  patches in RAM would not be recognised — it misses and says so, like any unknown address.
- A unique key is trusted without verifying the rest of the function (the closed world above).
  Keys shared on the disc are verified at their separating positions.
- Program size grows by the relocatable functions (Crash 3: +200k generated lines, 1,313
  functions). The Dreamcast budget has not been measured with them.
- The marker is game knowledge and lives in config; the mechanism is generic.
- `tools/recomp/src/recomp/codegen/Relocatable.hx`, `Program.relocTableSource`,
  `src/runtime/core/Reloc.hx`, `Cooperative.suspendAt/afterCallAt`.

## Revision (2026-09-27): a key covers the function's own instructions

The first key hashed a fixed `hashWords` words at the entry. 204 of the 1,313 functions end, or
jump away, before that, so their keys reached into what follows code in a level file: bytecode
and data, some of which the game rewrites once a page is loaded — an entry reference (EID)
becomes a pointer. The fish's seven-word routine in the diving level (FshOC) is followed by one:
its key matched the disc and missed in RAM, GOOL's call went nowhere, and the second demo froze
at frame ~10150. A key now hashes only the instructions the function runs from its entry without
a gap, up to `hashWords`, with that length folded in as one more byte; the runtime keeps the
hash state after each word and tries the lengths in use, longest first (`LENGTHS`). The words
that tell functions sharing a key apart are compared only where the row's function has an
instruction (`ROW_MASKS`); where two functions differ only in words one of them lacks, the row
that has them is tried first. Positions can be negative — code a function reaches before its
entry. Crash 3: 1,173 keys, 83 shared; the attract loop runs 20000 frames through both demos
with nothing missing. `tools/recomp/test/TestRelocatable.hx`.


## Revision (2026-10-03): answers kept by address, checked against their words

"No cache" above cost ~1,500 cycles a call on the Dreamcast — eight words hashed byte by byte and
the keys searched once for every length in use — and Crash 3's play makes ~36 such calls a frame,
most to a handful of addresses. `RelocTable` now keeps the answers it finds: 64 slots by the
address's low bits, each holding the address (with bit 0 set, so a slot never written matches
nothing), the handle and the `hashWords` words the answer was decided by. A call whose words are
still those takes the handle after reading them; any other finds it the long way and keeps it.
Only answers `resolve` took no part in are kept, since those depend on nothing but the hashed words;
a key shared by several functions reads further words, and is always found the long way. The answer
is the one the full lookup gives for the same memory, so nothing a game can observe changes (the
digests do not move). JavaScript: 86 % of gameplay's calls take the kept answer, ~5 % need
`resolve`. Measured on the Dreamcast model: `FnTable.call` 0.314 → 0.204 ms a frame of Crash 3's
gameplay demo (docs/perf/dreamcast-ledger.md E-099).
