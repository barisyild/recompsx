# ADR-0063: The hot code laid out at run time
Status: accepted   Date: 2026-10-06

## Context
The Dreamcast's 8 KB direct-mapped instruction cache decides much of a frame: on Crash 3's gameplay
demo the same code reads 18.76 ms a present on round r144's placement (games/SCUS94244/dc-placement.txt,
made from a trace of that game) and 21.61 on the shared runtime/backend placement every other game gets
(instruction-cache conflicts 0.88 against 3.37 ms; ledger E-185). The owner's rule (2026-10-05): **a
game's speed must not depend on work done for that game** — no placement rounds per game, and no data
from a run of the game in its build (no PGO). So the layout had to come from something every game has.

A static, trace-free layout was built and judged first (ledger E-186, judged against the demo's trace
only, never made from it): the game's functions in the guest program's own address order, which keeps
together what the PS1 program kept together. Over 64 builds' worth of sizes and start offsets it averaged
4.21 M misses on the trace, against 4.4-4.7 M for the link's order and 2.75 M for r144; told the demo's
hot set exactly (an oracle), guest order still averaged 3.90 M. The frame is decided by a handful of hot
pairs — `f_80041550`/`f_80041d28`, `f_80040ab8`/the RTPS core — landing on each other or not, and nothing
in the code says which functions those are: a hand-written renderer reached through tables, routines
whose heat no loop or call count predicts (static heat ranked the demo's hottest 128 KB at 43 % of its
time, against 94 % for the truth).

A JIT does not have this problem: its code cache fills in the order the program first runs. What the
console can observe at run time — its own PC, sampled — is enough to do better than that. Judged on the
trace: the demo's PC sampled for its first quarter (~23,000 samples), a temporal relationship graph of
the samples and a greedy colouring of the 133 hottest functions (256 KB) gave 2.16 M misses on the last
three quarters, where r144 gave 2.08 M and the shared placement 3.56 M; learnt from the first three
quarters at a 20 kHz-equivalent rate, the last quarter's 1.146 M as linked fell to 0.648 M.

## Decision
Lay the hot code out on the console, for whatever runs. The backend (dc_hotcode.c, `RECOMPSX_HOTCODE`)
samples the emulation thread's PC at 20 kHz over a window of presents, takes the sections holding most of
the samples while an arena's budget lasts (192 KB), gives each — hottest first — the colour where its
sampled lines meet the least line heat of what the samples put beside it (Gloy and Smith's TRG, a window
of 4 samples), copies them into a 16 KB-aligned arena — largest first, each into the first hole where its
colour (and its operand-cache half, below) fits, so none gives anything up for the arena's memory — and
rewrites every word that pointed at a moved function to point at its copy. The originals stay as they were but for
those words, so a frame live in one goes on there. What may move and which words point at it comes from
the link: build-dc.sh keeps the relocations (`-Wl,-q`; the loaded image is unchanged) and
scripts/dc-hotcode.py writes HOTCODE.BIN (sections none of whose PC-relative references leave them — all
of ours; every R_SH_DIR32 target inside one), which the backend refuses from another build. The site
answers of ADR-0062 (`recompsx_fnsite`) are rewritten too.

The copies' literal pools are read through the 16 KB operand cache, and where they land there is the
other half of the problem (Crash 3: operand conflicts 1.15 → 1.67 ms with the copies placed for the
instruction cache alone). So each sample also decodes the interrupted instruction's operand address from
its registers — a statistical operand trace — and each moved section goes in the half of the operand cache
(its instruction colour kept) where its sampled pool lines meet less of the sampled data; judged on an
operand trace of the moved run, that choice from a subsample removed 13.5 % of the misses and 17 % of the
write-backs, against 23 % for the best flips the trace itself could find. Packed in order with a limit on
padding, a section gave its half up when nothing else fitted near: Crash 3's f_8003fc50 put a pool on the
line of the CPU state's hottest word, 9 % of every operand access, at 25 times the cost of its other half.

The work after a window — the samples, the graph, the colours, the copies (a section at a time), the
words — is done in the time the game spends waiting for its vblank (the pacer hands it its spare time), and
in 3 ms slices of presents only when it has had none for four presents (Crash 3's demo: 22-52 presents, where
at once it was a 175-354 ms hitch; Crash Bash's 30 Hz match waits ~13 ms at every other vblank, and a slice
added to the late ones made them later). That is safe because every word points at good code at every
moment: an original, an older copy or a new one, the same instructions. When the code moves again, the
words inside the older copies are rewritten as well: a frame that never leaves an older copy (a minigame's
loop) calls through its own copy's words, and would otherwise keep its callees in that arena's copies for
good (Crash Bash: 58 % of a match's samples in layout 8's copies after layout 9). An older arena is given
back once no thread's stack or saved registers point into it (a conservative scan, after each layout and
every 120 presents; the scan keeps the range it looks for negated, or its own registers would hold every
arena); a function found under such a live frame at eight looks — a loop that never returns, which would hold
every arena it is copied into — is pinned, and unpinned when that arena goes. The scan is conservative, so a
stale word in a live frame holds an arena too: pinned at three looks, such words kept hot functions out of
every later layout (Crash 3: 20.02 a present in auto mode against 19.00-19.53 for the same binary with one
explicit window). A pinned section that is hot takes part in the colouring where it runs, so the copies go
around it. A new arena is made only with 512 KB of heap to spare, four at most held.

When: `--dc-hotcode=FROM:TO[,...]` for a bench; otherwise (`--dc-hotcode=auto`) every 20 presents from
present 300 it looks at two things: the share of the profiler's own 250 Hz samples in movable code that fall
in the copies, and how long the game waited for its vblanks (the pacer). When the share has stayed under 70 %
at three looks in a row (a new phase of the game: a level, a menu; a disc load or a cut is shorter than
that) or there are no copies yet: if the game has been behind its rate at the same three looks — it waited
less than 1 ms a vblank — a window of 45 presents opens, at least 300 presents after the last layout; if it
has kept its rate at all three, the layout is given back (every word at its original again) and the game
runs as linked. Behind at fewer looks is a moment between two scenes, and a layout made there is one for
neither: Crash Bash, laying out a transition it was behind in for two looks, ran the match after it with
2.75 ms of instruction-cache conflicts a present, and 0.75 with the transition given back instead. A game that keeps its rate
gains nothing it can show from a layout, and one made for another of its phases can cost it more than the
link's: Crash Bash's Ballistix, at full speed as linked, ran 17.1 a present on a layout made for the screens
before it. There is no window on a timer as well: one every 3600 presents whatever the share (for the same
code run in another order, which the share does not see) opened where it fell, and in Crash Bash that was a
transition it was behind in for three looks — 3.34 ms of instruction-cache conflicts a present in the match
after it, against 0.8 laid out for the match. A window in
which the game spent most of its time elsewhere — under 40 % of the samples a whole window would hold fell
in movable code: it waited for the vblank, or for the disc — lays nothing out, and the next looks may open
another (Crash Bash laid its menu out from a disc load's window, at 3.6 % of the time, before this).

A profiling run's lines (the layouts, their maps of copies for dc-prof.py, the looks) are kept in RAM and
printed after the bench stops: the serial port takes ~4 ms a line, and a layout's map printed as it was made
was a quarter-second stall wherever it fell, a bench window included.

## Alternatives
- **Per-game placement rounds** (ADR-0043's games/<SERIAL>/dc-placement.txt): the best layout for the
  game and the build they were made from, stale after any code change, and work done for one game.
- **A static layout from the code** (guest order, static heat, GTE users kept off the GTE cores, reserved
  colours for the runtime): measured at 3.9-4.2 M on average against 2.75 M, with a spread of ±0.4 M from
  one build to the next. Its order of the game's functions is kept as the link's starting point.
- **PGO or a layout from a run, in the build**: rejected by the owner (a game run per build; a mod
  changes the code).
- **A trampoline at each moved function's entry** instead of rewriting references: every call pays a jump
  and the original's line stays hot.

## Consequences
- The originals' words are rewritten in place at run time (the code itself never changes); an arena is
  never reused while a frame could be live in it.
- A moved function's address taken at run time into memory the scan does not read — a callback stored
  while a copy is current — would outlive its arena. None is: the generated code keeps handles (FnTable's
  FAST, RelocTable's memo), its pointer caches are the site answers, which are rewritten, and the
  backend's callbacks are bound at init or are interrupt handlers, which a sample never lands in (the
  interrupts do not nest). A new pointer cache must be added to HOTCODE.BIN's words or kept as handles.
- The overlay's function names and the model's profile see copies: dc-prof.py names them by their
  originals from the run's `@@hc` lines.
- On in every Dreamcast build (`RECOMPSX_HOTCODE`, `--dc-hotcode=off` to turn it off), and every game is
  linked with the shared placement: the per-game placements (games/<SERIAL>/dc-placement.txt) are no longer
  picked by build-dc.sh. Measured (ledger E-187): Crash 3's demo 23.07 as linked, 19.2-20.0 in auto mode
  (19.48 for the final policy; the spread is a window's samples), 19.71 with its own r144 placement under
  the layout — a placement made from the demo's own trace, without the layout, is still ~0.5-0.8 better
  (18.76): what 45 presents of samples cost against a trace. Crash Bash's Ballistix at full speed either
  way (busy 13.77 as linked, 13.5-13.6). Exact on both: the digests are the same with the code moved.
- A bench window now holds whatever the policy did before and inside it; an A/B of something else keeps the
  setting the same on both sides (or `--dc-hotcode=off`, or an explicit window ahead of the bench).
