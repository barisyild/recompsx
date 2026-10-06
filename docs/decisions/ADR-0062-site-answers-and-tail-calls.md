# ADR-0062: Each dynamic call and jump site keeps its own answer; a jump's is a tail call on C++
Status: accepted   Date: 2026-10-06
Direction set by the project owner: study the JIT recompilers and bring their approach, done better,
into the static recompiler, with the optimisations already in place ("JIT recompiler'i bir incele onun
yaklaşımının daha iyisini static recompiler'e taşımak gerek mevcut optimizasyonlarla birlikte"), and
make every gain global — a game's speed must not depend on work done for that game. Amends ADR-0026
on C++; ADR-0028's tables stay behind the sites.

## Context

Everything the analysis leaves dynamic reaches its code by address: a JALR, a call into an overlay
window or the kernel, a computed jump (`jr` through anything but `$ra`, ADR-0026's tail request), a
jump table's default arm. ADR-0028 gave the program one kept answer (the CpuState's last target) in
front of FAST, its direct-mapped table, and the long way behind both. A JIT links blocks: a call or
jump site that went somewhere once goes there directly next time, behind one compare (an inline
cache). Over Crash 3's demo (vblanks 4700-5000, JavaScript replays):

- 279,561 dynamic calls; the program's one last answer missed 150,202, one answer per site 31,135.
- 294,918 computed jumps — the renderer hands over from routine to routine through registers
  (`lw $t9, 112($v1); jr $t9`), 983 a present — each a TAIL token returned to the caller, which ran
  it through `Runtime.unwinding`, `Runtime.call`, the bound runner and FnTable.run; the last answer
  missed 279,863 of them, one answer per site 323. Every site went to one function.
- 10,802 calls into relocatable code (ADR-0025), 9,220 to an address `RelocTable` had a memo for, each
  ~800 cycles of the long way (dispatcher, overlays, the executable's table) before the memo.

## Decision

**Give every call and jump site the program leaves dynamic an answer of its own, and on C++ take a
jump's answer as a tail call.** The generator numbers the sites (Emitter.SITE_TOKEN, numbered
program-wide after deduplication by Program.numberSites, deterministic) and emits `FnTable.runAt(ctx,
target, site)` for a JALR and a call by address, `FnTable.tailAt(ctx, target, site)` for a jump the
caller runs. On C++ a site's answer is its address and the function's own pointer
(`recompsx_fnsite`, `RecompsxSite`, declared in FnTable's header): a call site compares and calls it
inline; a jump site compares and leaves by `[[gnu::musttail]] return site.fn(ctx, 0)`, so the frame is
replaced and a chain of jumps runs at one host depth, which is what ADR-0026 asked of the caller. A
miss falls back to the old way (FAST, the long way; a jump's TAIL token to the caller, whose `run`
fills the site's answer from FAST); answers are kept for a function's entry only and forgotten with
FAST (`clearFast`). The after-call check is the program's own `FnTable.unwound`, which runs a pending
tail through `run` without the runtime's runner. A call FAST misses asks `RelocTable.quick` — the memo
with its words compared — before the long way; `clearFast` forgets the memo too. JavaScript, every
other target and the cooperative build keep `run` and ADR-0026's requests unchanged.

## Alternatives

- **Static devirtualisation from the program's tables.** Finds the targets of some sites, not of a
  register a routine computes; and a guess is a compare a site already makes.
- **A per-site cache with several entries.** One entry missed 0.1 % of the jumps and 11 % of the
  calls; more entries cost every hit more code.
- **Direct calls at jump sites without musttail.** Grows the host stack per hop in threaded code —
  ADR-0026's reason — unless the compiler happens to make a sibling call; musttail is a guarantee or
  a build error.
- **One more home for the target than the CpuState.** A field added to CpuState moves every field
  after it out of the displacement's reach (E-057); the jump's site is a static of FnTable.

## Consequences

- Exact: the guest's semantics are unchanged; JavaScript digests unchanged (Crash 3 52875c77 at
  5000, Crash Bash 37eefb07 at 20300); the Dreamcast digest is checked by `scripts/dc-digest.sh`.
- Requires GCC 15's `[[gnu::musttail]]` on C++ targets (the Dreamcast's sh-elf-gcc 15.2): a call that
  cannot be a tail call is a compile error, not a deeper stack.
- Measured in docs/perf/dreamcast-ledger.md, E-181 and E-184.
