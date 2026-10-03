# ADR-0045: Hand-overs instead of copies where functions share code
Status: accepted as an option (`gen --cut-shared`, off by default)   Date: 2026-10-02

## Context

The multi-entry policy (docs/specs/tool.md, Discovery) keeps every entry and gives each function
every block it can reach, so code that several entries reach by branches is emitted once per
entry. Compiled code rarely does that. Hand-written code does it on purpose: Crash Bandicoot:
Warped's renderer hops between routines through `jr $t9`, and each routine branches back into a
shared loop. Five functions carried a copy of that loop — `f_80041d28` was 529 guest instructions,
44 of them its own — and the game's emitted guest code was 1.54 times the code it has. In the
Dreamcast's gameplay window those routines were 5 ms of the conflict-free frame, half of it
instruction-cache fills that no placement can remove (ledger E-077): the copies take turns in an
8 KB cache.

## Decision

**With `gen --cut-shared`, after discovery every function is traced again, stopping at other
functions' entries, and hands over to them there; it keeps its copy only where the hand-over would
not be the same program to the machine. Off by default: on the Dreamcast it is slower (below).**

- **Where:** a branch's arm (taken or not) or running on into another function's entry. Never a
  call's continuation (it must stay a block of the caller, where a cooperative slice suspended in
  the callee resumes), a switch arm, or an entry whose occupant is decided at run time (the
  executable's code in an overlay window; `Discovery.cutTarget`), and not in relocatable code.
- **Emitted:** a direct tail call, `Cls.f_X(ctx, -2)`: the target maps the entry to its first
  block and skips its checkpoint and pump, as the inline copy ran on into that block without
  them; `-3` enters through them where the copy pumped at that block (`Func.pumpedHops`: an edge
  back to it). `Runtime.hopRa` passes the entry `$ra` on, so the target's return checks
  (ADR-0027) compare with what the copy compared with; where `$ra` may be foreign at the
  hand-over the caller checks the return after it (`Func.checkedHops`). A token the target leaves
  is the caller's caller's to act on, as before. Mod hooks never run for a hand-over.
- **Kept whole:** a function on a cycle of hand-overs and direct tail calls (each is a host
  call); one whose `jr $ra` jumped to an address it built (`raJumps`) in code it would hand over;
  and one whose code would pump somewhere else — every pump point (FunctionIR: a block an edge
  reaches from at or above) of the copy must be one of the functions that now run that code, and
  the reverse, along every chain of hand-overs (`Discovery.samePumps`).
- **Summaries:** a hand-over is a tail call (`FunctionSummary`), so callers see its effects.

## Alternatives

- **Keep the copies** (the policy as it was): correct, and 26-43 % of Crash 3's emitted guest
  code, measured as instruction-cache capacity misses in gameplay.
- **Hand over through the dispatcher** (a `TAIL` token, ADR-0026): bounded stack whatever the
  graph, but a lookup per hand-over where the target is known statically.
- **Pump points by guest address, program-wide:** would make any function boundary exact by
  construction, but moves where every game takes its events today.
- **The renderer's `jr $t9` targets as a jump table in Crash 3's config:** one function, no
  hand-overs at all, but per game; the goal here is global.

## Consequences

- The program is the same to the machine: Crash 3's headless digests at frames 600, 4523, 4700,
  4850 and 5000 and Crash Bash's at 20300 are unchanged, and a trace of every pump over Crash 3's
  frames 4521-4523 is identical, call for call. `HandOver` (TestHandOver) runs a program with each
  case traced both ways on every target and compares the machine state, the instruction count,
  where an event due at each cycle offset is taken and where cooperative slices yield.
- `Runtime.blocks` (a statistic) counts a hand-over's two halves as two blocks.
- Crash 3: emitted guest instructions 118,177 → 109,150 (1.54 → 1.43 times the unique code); the
  renderer's fragments hand over (f_80041d28 529 → 44 instructions, f_80041c64 737 → 35,
  f_80041dd8 112 → 17, f_80041cf0 630 → 14). Images: Crash 3 −376 KB, Crash Bash −194 KB.
- **Slower, measured (ledger E-077):** gameplay's conflict-free frame +0.65 ms, the title and Crash
  Bash unchanged. Each copy had carried only the paths its own entry takes, so the renderer's
  executed lines fell only 618 → 581, while the hand-overs' entries added 3 % of its instructions
  and their spread added instruction fills. Duplication was not what filled the cache. Hence off
  by default; the option is for a game that needs the memory.
- Entries for shared code that no entry starts (a block more functions carry than the block that
  enters it) were tried on top and dropped: they changed Crash 3's picture by frame 2522 though
  every subset of the 114 heads tried alone kept it — an interaction not yet understood.
