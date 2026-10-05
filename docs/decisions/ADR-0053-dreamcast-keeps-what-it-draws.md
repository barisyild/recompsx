# ADR-0053: The Dreamcast keeps what it draws — a picture per display buffer
Status: accepted   Date: 2026-10-04
Direction set by the project owner: Crash 3's pause screen must look as it does on the console.
Amends ADR-0011's consequences (hardware drawing). Keeps ADR-0039's hold, for a different reason.
Amended by ADR-0055: pictures are the screen's size, 640x480, shown 1:1, and a render draws into the
picture it starts from (two memories, after g_txr's slot 0). The size and memories below are the first
form's.

## Context

On a PlayStation every primitive is drawn into VRAM and stays there until something draws over it.
The Dreamcast backend draws the primitives itself (ADR-0011), and so emulated VRAM never receives
them: it holds only uploads, VRAM copies and the off-screen drawing the runtime does for it
(ADR-0030). The backend keeps nothing either. Each present is built from the records since the
frame began, over emulated VRAM's display rectangle as a background, and is gone at the next.
The browser keeps a framebuffer texture (`fbTex`) and so has no such problem.

Two reports from the owner come from this (analysis: out/_work/agent-dc-issues/, a JS model of
the backend fed the runtime's `bp_gpu_*` stream; checked on a Dreamcast build in Flycast):

- **Crash 3's pause** stops drawing the game and draws only the menu panels, into buffers it no
  longer clears; the PlayStation shows the frozen game behind them. The Dreamcast shows the
  panels over emulated VRAM's display rectangle, which Crash 3 never uploads to: black.
- **Crash Bash's legal screen** is an upload into both display buffers. Every clear after it is a
  primitive, so emulated VRAM keeps the legal screen for the whole session. Whenever a frame
  shows the background — no records yet (a loading pause), or no fill covering the picture (the
  first frame of a demo's fade-in, everything drawn black) — the Dreamcast shows the legal screen
  where the PlayStation shows the last picture. Flycast, attract loop, present 1500: the
  Dreamcast shows the legal screen, while VRAM in the JavaScript reference (the software
  rasteriser) holds the Eurocom logo.

## Decision

**Each display buffer has a picture**, a PVR texture that holds what the PlayStation's VRAM holds
in that rectangle, rendered by the PVR into texture memory (`pvr_scene_begin_rtt`).

- **Records go into the buffer they draw into.** At each present, the records since the last one
  are rendered into their buffer's picture. The buffer is the one `screen_origin` finds, for each
  state a triangle or a fill was recorded under. A state with neither draws nothing, and the
  frame's first state is one: it is the last frame's last, carried over, and in a double-buffered
  game it names the other buffer. Counted, it had every present render the picture on screen
  again, over itself. Each
  render starts from that picture as it was, drawn 1:1 with point sampling into a scratch texture,
  and the two are then swapped. A frame that opens with a fill covering the buffer skips the copy.
  A record is drawn once: at the next present only newer records are added, which is how the
  PlayStation's VRAM keeps them. A VRAM mark recorded after a present, an upload between frames,
  moves to the front of the next frame's records rather than being dropped with the old ones.
- **The screen shows the displayed buffer's picture**, then the overlay and the pointer. A present
  with nothing new keeps the screen as it is. A texture upload alone changes no picture.
- **A present during a list still being walked is held (ADR-0039)**, as on the old path, and for
  at most as many presents in a row. The reason is not the old one: the half-drawn buffer would
  not be seen, because the buffer being drawn is not the one shown. Rendered, though, the frame
  would be two scenes, each with a scene's fixed cost (the palette ranking, the scene's setup, a
  render), and the second would start from a copy of the first. A held present that finds the
  display flipped shows the buffer flipped to. Its picture is complete, and records held back
  are not rendered then.
- **Uploads reach the picture where they happen.** A VRAM mark (an upload or copy into a buffer,
  `mark_vram`) is drawn into that buffer's picture at its place in the order, from the VRAM upload
  slot as today. A buffer without a picture yet starts from emulated VRAM.
- **Pictures are the buffer at its own resolution** (512x240 for Crash 3 and Crash Bash), in
  textures of 512x256 RGB565. Their three memories are slots 1-3 of the background's megabyte
  (g_txr); slot 0 is the background slot while the pictures are in use. They cost the texture
  pools nothing. The screen pass scales the picture to 640x480, bilinear. A mode wider than 512 or
  taller than 256 lines, 24-bit video and a blank display keep today's path, and when one comes
  the pictures are dropped and g_txr's four slots are the background's again.
- **The PVR writes 16-bit pixels.** Dithering is off, so a picture copied every frame does not
  drift.

## Alternatives

- **One screen-sized picture, ping-ponged** (no buffer identity). Simpler, but it merges the two
  buffers' histories, so translucent layers build up twice as fast in a double-buffered game.
- **Pictures 640 wide** (the screen's width, as sharp as the direct render). Built first: three of
  them at 640x256 took ~960 KB from the texture pools, the bake pool fell from 128 patches to 10,
  and Crash 3's warp room showed texture-slot conflicts under the model (none without pictures).
  At 1x, inside g_txr, the pools are as before (128 patches) and the picture is the PlayStation's,
  softer than the direct 640 render once scaled.
- **Redraw the last frame's records as the background.** The textures can change underneath them
  (Crash 3's menu replaces what the game drew with); the old records are not the old picture.
- **Write primitives into emulated VRAM as well (software).** That doubles the rasterising the
  hardware path exists to avoid, on a CPU already short of a frame.
- **Black instead of the VRAM picture for a buffer drawn over (a stopgap).** It fixes the legal
  screen but not the pause.

## Consequences

- Each built present costs one render to texture and one screen pass, a quad. The render covers
  the records at the buffer's resolution: for 512x240, two fifths of the 640x480 the direct render
  filled. Unless a fill covers the buffer, the render also draws a copy of the picture first, a
  quad over the whole buffer. Measured under the cache model, against the same build without
  pictures (ledger E-164):
  - Crash 3's demo (presents 4700-5000): 20.40 → 20.63 ms a frame, conflict-free 17.52 → 17.60.
  - Crash Bash's scene after the disc load (B210): 17.38 → 17.40, work 11.40 → 11.47.
  - Both games render once and show once every second vblank (they run at 30 fps). Every render
    went over a copy: neither window has a fill covering the buffer.
  - The model times the SH-4 only; what the PVR takes for the renders is the console's to say.
- The picture on screen is the PlayStation's own resolution, scaled: softer than the direct 640x480
  render it replaces, as the browser's (which also draws at 1x).
- The TA-hash baseline changes once: the scenes are different scenes. The DC digests do not change,
  because this is presentation only (a headless run draws in software and never presents here).
- Verified with Flycast screenshots (out/_sh_c3pic3, out/_sh_cbpic3; the fastmem build of the
  model's Flycast, no cache model):
  - Crash 3's pause (warp room, START at present 15150) shows the frozen game behind the panels.
  - Crash Bash's attract loop shows the Eurocom logo at present 1500 and black at 6300, 15150,
    18000, 19950 and 22200. Emulated VRAM in the JavaScript reference shows the same there: the
    Eurocom logo, then black. Before, the Dreamcast showed the legal screen at all six, at one of
    them under the characters' black silhouettes.
  - A spread of both runs (every 150th present) shows nothing else changed.
