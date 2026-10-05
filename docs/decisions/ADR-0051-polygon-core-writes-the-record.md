# ADR-0051: The SH-4's polygon core writes the backend's triangle record itself
Status: accepted   Date: 2026-10-04

## Context

Crash Bandicoot: Warped's gameplay demo is the one bench window not at full speed under the cache
model (20.02 ms a present on round r139's placement, docs/perf/dreamcast-ledger.md E-151). The
graphics path is ~37 % of its instructions: the list walk, the polygon core (ADR-0047) and the scene
build, ~1,550 SH-4 instructions a triangle. ~770 triangles a present are recorded, and each record
was made twice over: the core wrote the triangle into twelve words of the GPU file (x, y, the colour
word and the texture word a vertex, the form bp_gpu_tri_w takes), and `Gpu.polygonHw` handed those
to the backend, whose `bp_gpu_tri_w`, forced inline there, read them back, packed them into the
backend's 32-byte record — positions as halfword pairs, colours masked, the texture coordinates a
byte each beside the state's tag — found the frame and the buffer's end, counted the triangle on its
state, and stored eight words: ~100 instructions a triangle in `polygonHw` and `polygonRest`, whose
code the game's evicted between list steps (their instruction fills 0.21 ms a present).

## Decision

**The backend lends the SH-4's polygon core its record buffer — a sink, `bp_gpu_sink` in
backend_c_api.h: the next record, the buffer's end, the current state's tag, the address of its
count of triangles — and the core writes each triangle's record there itself, in the layout the ABI
now states, then moves `next` on and counts one.** The core declines a packet the sink has no room
for (two records, one for a quad's second triangle), which the C form then draws and records through
`bp_gpu_tri_w` as before; the backend closes the sink (end = next) while a frame is shown, so the
first record after a present comes that way and begins the next frame. When the core finds a new
state to send it has already recorded the triangle under the old one, and answers 2: the runtime
hands the state's words to `bp_gpu_state_after_tri`, which records the state and, when it is
another, moves that record into it — its tag, and one count from the old state to the new. A
triangle drawn under the state the backend has is then done when the core returns; `polygonHw` is
the core's call alone. Every other target, and the SH-4 for what the core declines, is unchanged.

## Alternatives

- **The core writes the eight packed words into the GPU file and the backend copies them:** half
  the saving — the packing moves, the call, the frame's checks and the copy stay.
- **The core leaves a new state's triangle to the C side** (answering 2, the twelve words as before):
  simpler, but half of Crash 3's triangles arrive under a new state (169 of 356 a present outside
  quads), and they would keep the cost.
- **The core records the state too:** the backend names states by content through a hash of seven
  words (state_enter); in assembly that is a second copy of it, for the few hundred a frame.

## Consequences

- The record's layout is part of the ABI (backend_c_api.h) for a backend that offers a sink; only
  the Dreamcast's does, and only the SH-4's core reads it. `g_cmd_count` is gone from the backend:
  the frame's count is the sink's `next` (`cmd_count`), where the core and `cmd_line` both append.
- The core grows by ~45 instructions a record and the room test (+36 cycles a triangle by
  scripts/dc-polyrun.py, which now runs it against the C form with a sink, too small ones included:
  20,000 packets, 0 mismatches); `polygonHw` loses the record's ~100.
- The check build (`RECOMPSX_GPU_POLY_CHECK`) keeps the core's record aside, puts the sink back, and
  compares it with the C form's in the same place.
- Exactness is the TA hash's: the scene is built from the same records.
