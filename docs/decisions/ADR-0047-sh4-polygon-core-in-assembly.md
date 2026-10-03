# ADR-0047: The GPU's polygon packet in scheduled SH-4 assembly
Status: accepted   Date: 2026-10-02

## Context

On the Dreamcast every PlayStation polygon passes `Gpu.polygonHw` on its way to the backend: the
packet's texture keys and flags, then each triangle's decode, size and line rejects, count, GPU time
(`triangleWork`), state test (`triState`) and record (`Backend.gpuTri`). It was the most expensive
runtime function in every bench window: ~2 ms a present, 382 cycles a triangle conflict-free on
Crash 3's title (1,036 a present), 448 on Crash Bash's. Three C restructurings measured nothing
(E-059: what the source saved GCC spent on the SH-4's sixteen registers — of its 460 instructions a
triangle, 78 were stack traffic and 86 register moves), and the cause is structural: the triangle's
nine positions, bounding box and edge are live across the state test's possible call, and the
record's fifteen arguments are built in the same frame.

## Decision

**On the SH-4, `Gpu.polygonHw` first runs a core in assembly for each triangle of the packet; the
core answers 0 (drawn, the backend's triangle in GPU words 36-47), 2 (drawn, and a state the
backend must hear of first, in words 52-61), 3 (rejected) or 1 (a packet that could wrap at the end
of RAM, nothing changed but the flags the C form writes too); the backend reads the state and the
triangle from those words.** As ADR-0046, the
core is generated:

- **Source:** scripts/sh4/poly.blk — two blocks scheduled by scripts/dc-sched.py under the cache
  model's issue rules, written into Gpu.hx's `@:cppFileCode` (`--guard RECOMPSX_GPU_NO_ASM`). It
  reads the command's row of a 32-entry table (the step between vertices, the GPU time's shift and
  blend mask, the flags triState compares, texEnabled, texRaw, semiTransparent, the texture and
  colour-step masks), tests the packet's palette and page against the keys decoded last — a new one
  is decoded in a cold path (`Gpu.setClut`, `setTexPage`) and the packet starts again — writes the
  flags, ORs triState's five differences into one test — and when one differs does triState's and
  sendState's work itself (the sent words, the packed page, palette, area and window compared with
  what the backend has, the ten state words when they differ: a scheduled block of its own, cold
  for a game that keeps its state, half the triangles for Crash Bash's) — decodes the three positions, rejects a box
  wider than 1023 or taller than 511 and a line, counts the primitive, adds its GPU time (the area
  when every vertex is inside the drawing area, where the box can only be larger; the clipped box
  otherwise), and leaves x, y, the colour word and the texture word (masked) of each vertex.
- **The state and the triangle in words** (`bp_gpu_state_w`, `bp_gpu_tri_w`, backend ABI entries
  beside `bp_gpu_state` and `bp_gpu_tri`): the ten state words are `bp_gpu_state`'s arguments; the
  Dreamcast compares a state with the last one recorded as seven packed words in one test and
  writes it as eight, where fourteen fields were compared and written one by one. The twelve
  words are exactly `bp_gpu_tri`'s fifteen arguments, and the backend reads them after its own
  record work began — on the Dreamcast as its record line's eight words (positions in halfword
  pairs, the tag in one store) where fifteen arguments built in one frame had been spilled around
  that work and the fields written through r0 one by one. The C form (`triPacket`) hands its
  triangles over the same way, on every target.
- **The C++ around it** (`polygonHw`): a triangle drawn is the backend's state when there is one
  and its record; a quad's second triangle (the same core a vertex on, `_recompsx_gpu_poly2`), a
  rejected one and a declined packet go out of line (`polygonRest`). Every other target, and the SH-4 with `RECOMPSX_GPU_NO_ASM`, answers 1 and runs
  the C form (`polygonC`, the old body) — the definition.

Verified twice: scripts/dc-polyrun.py runs the assembled core with the C++'s part in an SH-4
interpreter over generated packets — every command 20h-3Fh, positions on and off the drawing area,
too wide, lines, stray high bits, palettes and pages new and kept, states sent and not, packets
that could wrap — and compares GPU words 0-35 and the backend's calls with a transcription of the C
form; and a console build with `-DRECOMPSX_GPU_POLY_CHECK=1` runs the core on a copy of the GPU file
before the C form draws each packet and compares the words, the answer and the triangle's
positions (ledger E-085).

## Alternatives

- **The C form restructured** (E-059's three ways, E-035's record out of line): no gain.
- **The record written by the core**: the record's format is the backend's; the runtime hands it
  triangles through the ABI and nothing else. Words are as close as the ABI comes.
- **The core with the C++ building the record** (the first form, measured: E-085): the core's
  ~170 cycles were about what GCC's code for the same work had cost, and the record's C++ — fifteen
  values live across `begin_frame`'s possible call — another ~200.
- **The scene straight to the PVR** (PROGRESS Next up 000): the backend's half, a larger change;
  this one stands without it.

## Consequences

- The runtime carries a second piece of SH-4 machine code. A change to the GPU file's layout, to the
  triangle's rejects, count, GPU time or state test, or to `setClut`/`setTexPage`, must regenerate
  the core (`scripts/dc-sched.py --into src/runtime/gpu/Gpu.hx --guard RECOMPSX_GPU_NO_ASM
  scripts/sh4/poly.blk`) and run scripts/dc-polyrun.py and the check build again.
- The common triangle (keys and state kept, inside the drawing area): ~190 cycles in the core by
  the replay, its record's eight words on top, where GCC's whole path took ~382 (ledger E-085,
  E-086). The GPU-stream hash of the backend's calls is unchanged (Crash 3 4050, JavaScript
  `--video-hw --gpu-hash`: 5f877994a1335867 over 3,098,753 calls).
