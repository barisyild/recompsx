# ADR-0020: The browser draws primitives with WebGL2
Status: accepted   Date: 2026-09-25

## Context

After the rasteriser rewrite the software GPU was still 22 % of JavaScript time, the largest
runtime bucket after the GTE, and in the browser it ran on the main thread beside the game.
The Dreamcast backend already takes ADR-0008's presentation fork — primitives go to the PVR,
emulated state never forks — and the JS backend answered "no" to the same capability.

## Decision

Give the browser page a WebGL2 renderer (`web/gpu-webgl.js`) behind the same seam: the page
puts a `gpu` object on the host and passes `--video-hw`; `shim.Backend.caps(4)` answers from
the host's presence, and the GPU calls forward to it. A 16-bit integer texture holds VRAM as
the runtime writes it; texels are decoded in the fragment shader (4-bit and 8-bit indices
through their CLUT, 15-bit direct, the texture window folded in), so there is no page cache and
a palette repainted mid-frame is read as it stands. A 1024x512 framebuffer texture stands for
the rendered VRAM: dirty rectangles are copied into it, primitives are drawn on it in
submission order with no depth buffer, and the display window is blitted from it per vblank,
with 24-bit rows decoded straight from VRAM. Semi-transparency is the four PlayStation blend
equations; a textured blending primitive draws twice, opaque texels then blending ones, and is
its own batch so overlap order holds. Add `bp_gpu_clip` to the backend ABI: the drawing area's
corners, so triangles are scissored where the software rasteriser clips them — without it a
double-buffered game's geometry spills from the buffer it draws into onto the one on screen,
which is exactly what the first build showed. Headless runs have no host and keep the software
path, so digests are untouched.

## Alternatives

- A Haxe renderer inside the shim. Rejected: the shim is portable-subset code with no `Float`,
  and a WebGL renderer is nothing but floats; the page is the right owner of the canvas.
- Decoded texture pages cached CPU-side, as the Dreamcast does. Rejected: the PVR needs its own
  formats; a shader can read VRAM directly and has no cache coherence to get wrong.

## Consequences

Measured in the page with `requestAnimationFrame`/`setTimeout` callbacks timed: main-thread CPU
per emulated frame 3.85 ms with the software rasteriser, 2.43 ms with WebGL (−37 %) over the
same stretch of the attract mode. The mask bits are still not modelled on the hardware path
(the ABI does not carry them). The C backends gained a stub `bp_gpu_clip`, unverified while the
C++ path is paused (ADR-0015); the Dreamcast one records the corners for its user clip later.
