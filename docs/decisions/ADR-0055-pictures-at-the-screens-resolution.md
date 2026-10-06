# ADR-0055: Pictures at the screen's resolution, rendered in place
Status: accepted   Date: 2026-10-05
Reported by a Dreamcast tester and the project owner: since ADR-0053 Crash Bandicoot: Warped looks
lower in resolution on the Dreamcast, and blurred. Direction set by the owner: draw at the
console's own resolution, as the Dreamcast draws a scene. Amends ADR-0053 (the pictures' size, their
memories, the screen pass) and ADR-0054 (how a picture is read).

## Context

ADR-0053 gave each display buffer a picture, a PVR texture holding what the PlayStation's VRAM holds
there, so that what a game drew stays drawn (Crash 3's pause, Crash Bash's legal screen). The
pictures were the buffer at its own resolution, 512x240 in a 512x256 texture, and the screen pass
scaled the displayed one to 640x480 with bilinear filtering. ADR-0053 knew it: "softer than the direct
640x480 render it replaces". The direct render had drawn the primitives at 640x480 — vertical
resolution doubled, horizontal 1.25 times — and the scaled picture lost both, and blurred the rest.

640-wide pictures were tried for ADR-0053 and set aside: three memories (two buffers' pictures and
the one the next render goes into, swapped after it) took ~1 MB from the texture pools, the bake pool
fell from 128 patches to 10, and Crash 3's warp room showed texture-slot conflicts. At 640x480 three
memories are 1.8 MB.

The owner asked why the Dreamcast does not simply draw what is on screen at that moment, as a
Dreamcast game sets up its scene — DuckStation's free camera re-renders a PlayStation scene, after
all. It does, for the frames that draw everything: a free camera works in gameplay because the game
sends the whole scene every frame. It does not in the frames ADR-0053 exists for — a pause that stops
drawing the game and draws its panels over the frozen frame, a transition that turns the frame on
screen into the next — where what is on screen was drawn in earlier frames and kept in VRAM.
Neither game's frames begin with a fill covering the buffer (ADR-0053), so a frame that redraws
everything cannot be told cheaply from one that does not, and a frame drawn only to the screen leaves
nothing for the next one to start from: the Dreamcast's framebuffer is in the 32-bit address space,
which the texture unit cannot read.

## Decision

- **A picture is the screen's size, 640x480**, whatever its buffer's (up to 512x256, as before): the
  buffer's records are built at the screen's scale, 640/w by 480/h, exactly as the direct render built
  them, into the picture (`pvr_scene_begin_rtt`, 640 a row). The PVR draws it tile by tile, as it
  draws a scene.
- **The screen pass shows it 1:1**, point sampled: a pixel a texel, no filtering.
- **A picture is a stride texture**, 640 pixels a row, declared 1024x512 (`PVR_TXRFMT_X32_STRIDE`,
  `pvr_txr_set_stride(640)` once; nothing else uses the stride). Flycast keeps a render to texture as
  a texture of the next powers of two (1024x512 here) and matches it by address, size and format,
  not by the stride bit, so the same header reads it in Flycast and on a console.
- **A render draws into the picture it starts from** (in place): the copy it starts from is the
  picture itself, 1:1 and point sampled, so each tile reads only its own pixels before it writes them.
  Two memories, one a picture, after slot 0 of g_txr (the background slot while the pictures are in
  use): g_txr grows from 1 MB to 1.42 MB.
- **Reading a picture back takes its scale** (ADR-0054): a 15-bit page bound to picture i has `dim`
  PIC_TEXDIM + i, so its texel coordinates, in the buffer's pixels, are multiplied by that picture's
  screen pixels per buffer pixel over the texture's size (`g_pic_ru`, `g_pic_rv`, set when the
  picture is taken for a buffer). A copy out of a buffer is drawn at the destination's scale from the
  source's.
- **The 432 KB come from the 4bpp mirror's unsampled pages.** The mirror is the whole of PlayStation
  VRAM as 32 pages of 32 KB, but a game never samples as 4bpp textures the pages its display buffers
  cover: Crash 3 samples 16 of them (the lower row, `ffff0000`), Crash Bash 20. Each page's memory
  carries four bake patches until the page is first sampled (`page_reclaim`): then the patches leave
  the pool at once, so that nothing binds them again, and if the PVR may still read one the page waits
  a frame or two while its primitives take a page slot. (The first form left them in the pool until
  they were idle, which a scene binding them every frame could have put off for good.) A page once
  sampled keeps its memory. Without this the pictures' memory came out of the bake pool
  alone — 128 patches to 92, and to 76 with the profile overlay's texture — and Crash 3's attract demo
  wants more in a frame: 772 misses by present 5000, bake_slot re-baking (the demo window 20.87 →
  21.57 ms a frame under the model), and the owner saw the DEMO text drawn wrong for a frame each time
  it appeared (a patch missed: the page drawn through the nearest bank, or a page slot evicted in
  flight — "page conflicts" on the serial log, none before).

## Alternatives

- **Draw to the screen only, no pictures** (ADR-0053's predecessor). What a frame does not redraw is
  lost: the pause over black, the legal screen through every loading pause.
- **Draw to the screen when a frame covers its buffer, a picture otherwise.** A covering fill is the
  only cheap proof, and neither game has one. And the frame after one drawn only to the screen has
  nothing to start from.
- **Three memories, copy and swap, as ADR-0053.** 1.8 MB: the pools would lose about 1 MB, ADR-0053's
  conflicts and worse.
- **640x240 pictures, each line shown twice.** Sharp across, but the PlayStation's 240 lines down:
  half of what the direct render had.
- **Smaller vertex buffers to pay for the memory.** 768 KB (twice, KOS double-buffers it) is sized for
  a heavy frame of any game, and an overrun silently loses the frame's last polygons.
- **The screen drawn at 640x480 straight into the framebuffer, and a picture at the PlayStation's
  resolution kept beside it for what reads the buffer back** (the owner's question). The PVR draws a
  scene list at one resolution, the vertices being screen coordinates, so every frame would be built
  and sent twice — Crash 3's scene building is ~5 ms of a 21 ms frame. And the screen's framebuffer
  cannot be read as a texture (it is in the 32-bit address space; a render to texture writes the
  64-bit one, bit 24 of FB_W_SOF1), so neither can a 640x480 frame drawn there be shrunk into the
  smaller picture afterwards: anything read later must be rendered as a texture first. Kept as a
  texture, one 640x480 work picture and two at 512x240 are 1.37 MB against two at 640x480's 1.46, and
  what a frame does not redraw (the pause's frozen game) would come back at the low resolution. The
  readback it would make exact — a copy or a page at the PlayStation's own pixels — is within one
  screen pixel here.
- **Taking the memory from the bake pool alone.** See the decision: the DEMO text.

## Consequences

- **What a read of the buffer being rendered sees** (a copy inside one buffer, a page in the buffer
  drawn into): in an emulator, the picture as the render started — Flycast keeps a render apart from
  the texture it read (by default), or reads it back after (when copying renders to VRAM). On a
  console, a tile already rendered holds the new pixels. ADR-0053's three memories gave the start of
  the render everywhere.
- **The PVR draws two and a half times the pixels** of a 512x240 picture, plus the copy the render
  starts from and the screen pass: two quads the size of the screen for each rendered frame. That is
  the console's to measure; the model times the SH-4 only.
- **VRAM:** g_txr 1 MB → 1.42 MB (`TXR_BYTES`). The bake pool's own patches 128 → 92 (76 with the
  profile overlay's texture), and four more in each mirror page not sampled yet: Crash 3's attract
  demo, overlay on, 144 patches with 15 of 32 pages sampled, at most 92 bound in a frame and no miss
  (the pool before the lending: 76, every one bound, 772 misses by present 5000); its pause run 156,
  at most 109 bound in a frame; Crash Bash's B210 20 pages sampled, at most 48 bound. A game sampling
  all 32 pages keeps 92 (76) patches, against ADR-0053's 128 — the one game for which this costs
  what it did before the lending. The serial line `bench vram` says, for a game, what its pool and
  mirror came to.
- **Cost** (the model; ledger E-166): before the lending, Crash 3's demo window 20.87 → 21.57 ms a
  frame (conflict-free 17.73 → 18.50: bake_slot re-baking for the 76-patch pool) and Crash Bash's B210
  17.39 → 17.43 (work 11.50 → 11.51). With it, against ADR-0054's build: Crash 3 20.87 → 20.70 (cf
  17.73 → 17.66), Crash Bash 17.39 → 17.38 (work 11.50 either way). The pictures add no SH-4 work of
  their own: the same records, the same quads.
- **Verified** — Flycast's fork, the dynarec, pictures by present (`--dc-shots`):
  - Sharpness: the attract demo and the warp room's pause, zoomed, against the 512x240 pictures.
  - Persistence: the pause keeps the frozen game behind its panels.
  - The attract loop's second transition (X at 4700 and 8000) as before, frame for frame.
  - The DEMO text over the attract demo: drawn through the wrong palette at 4756, the frame it
    reappears, before the lending; right at every appearance after it.
  - The owner, on Flycast: Crash 3 ("DEMO düzelmiş") and Crash Bash ("sorun yok").
