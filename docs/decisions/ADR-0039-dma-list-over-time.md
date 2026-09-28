# ADR-0039: Channel 2's ordering table walked over time, at the speed the GPU draws
Status: accepted   Date: 2026-09-28

## Context

Crash Bash's pause menu drew its two boxes but none of its text. The owner reported it as a
well-known failure of many emulators. Research into public behavioural sources (no emulator code
was read) points to PCSX-ReARMed: it failed the same way, and fixed it with "slow linked list
walking" (notaz/pcsx_rearmed 8c84ba5f), an option its game database turns on for SCUS94570.
Spot Goes to Hollywood's menu text failed in another PS1 recompiler for the same reason.

On hardware, DMA channel 2 does not read an ordering table at the moment it starts. It walks the
table a node at a time, feeding the GPU's 16-word FIFO, so it moves at the speed the GPU draws,
and a node is read only when the walk reaches it. A game can therefore write packets into a
table it has already handed to the channel, and they are drawn if the walk has not passed them.
Crash Bash does exactly that with the pause text. recompsx walked the whole table synchronously
inside the CHCR store (`dma.Dma.walkList`), which drew the boxes that were already in the table
and missed everything written after.

Two measurements on the way settled the model:

- At the channel's own rate alone, a cycle a word and a cycle a node, the walk reached the text
  while the game was still writing it. PAUSED, CONTINUE and OPTIONS were drawn but QUIT GAME was
  not. In a battle's pause menu "SHOW RUL" and "SHOW RU" alternated from frame to frame, the cut
  moving with the race.
- With the GPU's time added from each primitive's unclipped area, at a cycle a textured pixel,
  the text was whole. But walks in play averaged about 13 ms and reached 48 ms, longer than a
  frame, so the Adventure hub dropped to about 10 frames a second. Near-camera floor polygons are
  mostly off screen, and the GPU draws only what is on it.

## Decision

Channel 2 in linked-list mode walks the table over emulated time. The first stretch runs when
CHCR starts the channel; the rest run on the scheduler slot `DMA_STEP`, which replaces the
unused `DMA_IRQ`. A stretch covers about 256 cycles, and each is due when the previous one would
have finished on the channel's own clock. So a late pump catches up rather than stretching the
walk, and a stretch is never longer than its nodes. Every node is read from RAM when the walk
gets to it. The channel stays busy (CHCR bit 24) until the terminator, and completion then sets
DICR and raises the interrupt as before. If the game clears the start bit, the walk stops there.

A node costs one cycle per word plus one cycle for its header, and in addition the GPU time of
what it carries. `gpu.Gpu` accumulates that time from each primitive's geometry: the same
vertices, after the same rejects, on the software rasteriser and on every hardware path. The
estimate is the same whichever path draws the picture, and a digest is unaffected by the choice.
The estimate, in CPU cycles:

- **Triangle.** Its area, but no more than its bounding box clipped to the drawing area.
  Textured pixels cost 5/8 of a cycle and untextured pixels 5/16 (the GPU runs at 53.69 MHz
  against the CPU's 33.87). Semi-transparency costs half as much again. Each triangle adds 16
  cycles of setup.
- **Rectangle.** Its clipped pixels, at the same rates.
- **VRAM fill.** An eighth of a cycle per pixel.
- **VRAM-to-VRAM copy.** One cycle per pixel.

Work the GPU received through its port before a walk starts is discarded when the walk starts.
The estimate is presentation-independent state that nothing but the walk reads.

A table that neither ends nor repeats is still given up after 65536 links, at the same node as
before. MADR is left as it was and becomes FFFFFFh at a normal end, so that a finished walk
leaves every register and every drawn pixel exactly as the instant walk did.

## Alternatives

- **A per-game switch (the ReARMed way: an option, and a database that turns it on).** Rejected
  for three reasons: hardware walks every game's tables this way, a switch per game is config for
  a machine fact, and AGENTS.md keeps `src/runtime` free of per-game behaviour.
- **The channel's rate alone.** This is not slow enough for Crash Bash (see Context), and on
  hardware the FIFO makes the GPU the bottleneck.
- **Counting the GPU's pixels as the software rasteriser writes them.** Those pixels exist only
  on the software path, and a backend that draws would pace differently. The walk must be the
  same on every target and every rendering choice.
- **Walking the table at completion instead of at the start.** This would pick up writes the
  hardware would already have passed. Node by node is what the hardware does, and it costs a few
  hundred scheduler events a frame.
- **A cycle-accurate GPU timing model.** Out of scale for the problem. The walk only has to be
  roughly as slow as the hardware's, and the estimate is documented as an estimate.

## Consequences

- Crash Bash's pause menus draw all their text: confirmed by the owner in the browser with the
  unclipped estimate. The clipped estimate, which keeps the hub at full speed, is still to be
  confirmed on the pause menu.
- Walks in Crash Bash's play average about 85,000 cycles (2.5 ms) and peak around 190,000. The
  game renders the same number of frames in its first 3000 as with the instant walk (1078 flips).
- Every game's digest moves, because interrupt and event timing changed. The drawing itself is
  unchanged: GPU words and commands are identical over 3000 frames of Crash Bash. The
  conformance digests, `OtWalk` among them, did not move. `OtWalk` now waits for each walk to
  finish.
- The scheduler fires a few hundred more events a frame. The Dreamcast should be judged on
  hardware.
- A game that depends on the GPU's real speed more finely than this, for example one that polls
  GPUSTAT's ready bits mid-list (always ready here), is not served by it. GPUSTAT is unchanged.
