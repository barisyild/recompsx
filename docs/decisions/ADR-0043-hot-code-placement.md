# ADR-0043: The hot code placed for the Dreamcast's instruction cache
Status: accepted   Date: 2026-09-29

## Context

The SH-4's instruction cache is 8 KB, direct-mapped, 32-byte lines. Which functions evict each
other is decided by where the linker puts them, and it puts them by chance. The cache model
(scripts/dc-flycast-model.sh) measured this on Crash 3's title screen (presents 3300..4050, the
console-calibrated window). It also counts what fully associative LRU caches of the same sizes
would miss:
- 68 % of the instruction fills were conflicts: 6.9 of 10.1 ms a frame, in a 35.1 ms frame.
- Two links of the same sources read 35.1 and 39.4 ms, and the whole difference was conflicts.
- The link keeps one input section per function after LTO (-ffunction-sections, 3,253 of them),
  and binutils 2.45's `--section-ordering-file` puts named sections first in .text, in order.

A first placement balanced the profile's samples over the 256 colours. It won 0.3 ms of
instruction fills and lost 0.7 ms of operand fills. The code a function reads its constants from
moves with it, and that is read through the operand cache. Samples say how often a line runs, not
which lines take turns in the cache, and only the second decides a miss.

## Decision

**Each game keeps a placement, and every Dreamcast link applies it.**

- **The file:** `games/<SERIAL>/dc-placement.txt` holds, hottest first, a colour per section:
  its first line, mod 256.
- **The build:** `scripts/build-dc.sh` finds the file by the product code in the generated
  `GameInfo`, links once (for the map, which gives each section's size), writes an ordering file
  and padding with `scripts/dc-layout.py place`, and links again. The second link is skipped when
  the first already had the order. Then it checks every placed section's address against the plan.
- **Kept as it was:** KallistiOS's startup stays first, since its entry is the load address. A
  section keeps its offset into its first line, so any alignment up to 32 holds. The growth of
  .text is rounded up to 16 KB, so the data keeps its colours in the 16 KB operand cache.

**A placement is made from a trace, and judged on one.** The model with `RXTRACE=<n>` records the
address of every instruction that enters a new line. `scripts/dc-icache-sim.c` replays that
against a candidate placement: a direct-mapped cache misses exactly where the replay says, so
this is the model's own count, in a second rather than twenty minutes. Its `opt` mode gives the
most fetched sections, one at a time, the colour that misses least with the others where they
are, over several rounds.

Crash 3's placement came from 48 M entries of the title screen. `opt` was run on the first 12 M:
120 sections, two rounds, two minutes on ten threads. On the other 36 M, which it had not seen,
direct-mapped misses fell 59 % and conflicts 87 %. Linked and run under the model, the frame went
from 35.1 to 29.5 ms: emu 18.0 to 13.6, gte 4.6 to 4.1, build 5.4 to 4.8. Instruction fills fell
from 10.1 to 4.1 ms a frame, and operand fills rose 0.5 ms (constants moving with their code).

## Alternatives

- **Balancing sample heat over the colours.** Measured above: the wrong quantity.
- **GCC's hot/cold attributes, `-freorder-functions`, profile feedback.** These group code, but
  none chooses colours. Nothing runs gcov on the SH-4 either; the model's trace is the profile.
- **A linker script with a fixed address per function.** It would replace KallistiOS's script. The
  ordering file only adds to it.
- **A temporal relationship graph (Gloy and Smith).** The usual way to place code for a
  direct-mapped cache when replaying is too slow. Here replaying is exact and fast enough.
- **One pass, each hot function in its own 8 KB window.** It would need no plan from sizes, but
  would grow .text by 8 KB a function instead of the padding the colours need.

## Consequences

- A placed Dreamcast build links twice: about three more minutes with `--max`. `--no-placement`
  gives the linker's own layout; `--placement <file>` tries another.
- .text grows about 500 KB (Crash 3: 507,904 bytes, all padding). The loaded image is checked
  against the budget as before.
- A placement names sections, so it survives most changes to the code. A section that disappears
  is left unplaced, and a function that changes its size moves everything placed after it off
  plan. The build warns when the check fails. When a game's hot code changes much, the placement
  is made again: src/backend/dreamcast/AGENTS.md, Measuring.
- A placement comes from one window of one game. Crash 3's is the title screen, which runs the
  same runtime and object interpreter as play. Other windows and other games need their own
  traces. Crash Bash has none yet.
- The operand side is not placed. Constant pools moving with their code cost 0.5 ms here. The hot
  data (`recompsx_ram`'s busiest lines, the runtime's state, the scene buffers) is placed by
  nobody.
- The model has been within a percent of the console on this window's total. A placed build still
  has to be confirmed on hardware.
