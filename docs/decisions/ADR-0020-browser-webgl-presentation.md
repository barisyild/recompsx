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
same stretch of the attract mode. The mask bits are modelled through a second ABI addition,
`bp_gpu_mask` (GP0(E6h)): the framebuffer texture carries a stencil, a dirty rectangle's copy
writes it from bit 15, a primitive drawn with "set" increments it under every pixel it writes,
and one drawn with "check" passes only where it is zero. Uploads and copies keep applying the
bits in emulated VRAM before the backend hears of them. Verified in the page with the renderer
driven directly (a "check" rectangle leaves a "set" rectangle and an uploaded bit-15 region
untouched); Crash Bash's attract loop never sets or checks the bit, so the game itself does
not exercise it. The C backends gained stubs for both additions, unverified while the C++ path
is paused (ADR-0015); the Dreamcast one records the values for its user clip later, and has no
stencil to give the mask.

## Revision (2026-09-25): state per vertex, one blend state

A batch per texture-state change cost a draw call and a dozen state calls, and a game changes
texture page, CLUT or blend flags between almost every pair of primitives: about 190 batches
and 2350 GL calls per vblank of Crash Bash's gameplay. Every vertex now carries its primitive's
page, depth, CLUT, window, flags and blend mode (three `uint` words, unpacked into flat
varyings), and the three adding blend equations share one GL blend state — source factor ONE,
destination factor the fragment's alpha, colour pre-scaled by the shader: (F, 0) opaque,
(F/2, 1/2) mode 0, (F, 1) mode 1, (F/4, 1) mode 3. Opaque and blending primitives therefore
share a batch, and inside a textured primitive each texel picks its equation by bit 15. Mode 2
subtracts and keeps a GL state of its own; a textured mode-2 primitive is still its own batch,
drawn twice. A vblank of gameplay is now one to three draw calls and about 40 GL calls.

The blend state keeps the destination's alpha, and the blit writes alpha 1. The first version
stored the shader's alpha weight, and a subtraction left dst − src = 0 there; the canvas is
unpremultiplied, so the page showed every pixel a mode-2 primitive had touched as black, and
kept it black, since no later draw wrote alpha any more. The old renderer had the same zero,
transiently: an opaque draw with blending off put the 1 back the next frame.

Proof, by a replay harness (the renderer calls of a stretch of frames recorded under Node from
the real bundle, uploads included, and replayed in the browser into two renderers in lockstep):
RGB of the framebuffer texture and of the presented canvas identical, byte for byte, over six
300-frame stretches of the attract loop (menus, gameplay, the Select Game Type scene) and a
synthetic trace of every depth, raw and modulated texels, all four modes textured and flat,
mask set/check, clip changes and wrapping uploads; framebuffer alpha now 255 everywhere.
Main-thread time of the renderer, Chromium on the development Mac, harness cost subtracted,
minimum of ten interleaved runs of 300 vblanks: 26.1 → 6.0 ms (menu), 28.1 → 6.2 ms
(gameplay), 79.3 → 10.3 ms (Select Game Type). Safari, which carries every GL call to another
process, is where the call count should matter most, and is not yet measured.
