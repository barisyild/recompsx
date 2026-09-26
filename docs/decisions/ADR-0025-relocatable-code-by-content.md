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
