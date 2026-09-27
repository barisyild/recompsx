# ADR-0030: Under hardware drawing, off-screen drawing stays in emulated VRAM
Status: accepted   Date: 2026-09-27
Amends ADR-0011 ("rendered pixels are not in emulated VRAM").

## Context

Crash Bandicoot: Warped draws Crash's silhouette every frame into a 64x64 corner of VRAM that
is never displayed, (0, 320), and then lays that corner on the ground as his shadow: a
subtractive quad sampling it as a 4-bit texture through a palette whose index 0 is transparent.
Under ADR-0011 a backend's pixels never reach emulated VRAM, so the Dreamcast sampled whatever
the level had uploaded there (the words 1111h..FFFFh, every texel non-zero) and drew a dark
square under Crash. The Dreamcast backend already declined to draw such primitives
(`screen_origin`: a drawing area in neither of the last two displayed rectangles and smaller
than three quarters of the picture), and the PVR has no way to make them VRAM.

The browser's renderer turns drawn tiles back into VRAM words itself, and there the same shadow
came out hatched: the game clears the corner with a GP0(02h) fill, which the hardware does
without regard to the mask bits and with bit 15 written as zero (psx-spx, "Fill Rectangle in
VRAM"); the renderer kept each pixel's old mask bit, bit 15 of the words it converted, and the
cleared half of the texture read back as index 8 or more in every fourth texel.

## Decision

Pixels drawn where no picture comes from are state, not presentation, and stay with the
runtime. Under hardware drawing, `gpu.Gpu` rasterises into emulated VRAM itself — exactly as
with no backend — every primitive whose drawing area is off screen by the Dreamcast's own rule,
computed from the same rectangles (`Scanout.present` hands each one to `Gpu.shown`), and every
fill that meets neither displayed rectangle. The backend hears of the drawn rectangle through
`bp_gpu_dirty`, as it hears of an upload: at the end of each drawing area and at every present,
so a primitive that samples it reads the pixels. A fill obeys psx-spx on every path: no mask
check, no mask set, bit 15 zero; a fill the backend draws is sent under mask bits of zero. The
browser's renderer stores the mask bit a write would: 1 under "set", 0 otherwise (the texel's
bit 15 where a pass knows it).

## Alternatives

- Render-to-texture on the PVR, copied back into a texture the scene samples. Rejected: it
  needs VRAM-exact output (palette indices packed four to a halfword), which a filtered,
  blended, 16-bit PVR target does not produce, and every backend would need its own.
- Draw everything in software and present with the backend. Rejected: that is the software
  path; ADR-0011 exists because the Dreamcast cannot afford it.
- Leave the browser renderer's tile conversion to handle it. It does, once the mask bit is
  right — but the Dreamcast and every console backend after it would still need their own.

## Consequences

Off-screen drawing costs CPU under hardware drawing again: in Crash 3's attract demo, about a
hundred 4x4 triangles and one 64x64 fill a game frame, 1495.0 -> 1536.3 M cycles (+2.8 %) over
the Flycast bench window; Crash Bash draws nothing off screen in 30000 frames. Hardware-mode
VRAM is now closer to the software path's: a copy or a readback of an off-screen buffer sees
what was drawn. What still cannot work is drawing on screen and sampling it later (feedback
effects) — that remains ADR-0011's stated limit. The rule depends on the last two displayed
rectangles; a game that renders a texture larger than three quarters of its picture off screen
would still be handed to the backend.
