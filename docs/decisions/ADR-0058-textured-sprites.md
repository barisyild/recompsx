# ADR-0058: Textured rectangles — drawn by the runtime, and `bp_gpu_sprite` for the backends
Status: accepted   Date: 2026-10-05
Found bringing up Tekken 3 (SLUS00402): every name, timer and caption on its screens was a black
box, and the owner's screenshot asked for it to be fixed ("bunu çöz").

## Context

GP0(64h-7Fh), the textured rectangles, were drawn as rectangles of the command's colour: `drawRect`
skipped the texture word and filled. Neither Crash game draws one, so nothing showed it. Tekken 3
writes all of its text as raw-textured sprites whose colour word is 0 — a raw texture ignores it —
and each became a black rectangle.

psx-spx, "GPU Render Rectangle Commands": the pixel at the rectangle's corner shows the texel of
its texture word, each pixel right and down the next texel — the one before under GP0(E1h)'s
X-flip and Y-flip (bits 12, 13) — wrapping at 256 and through the texture window. The page is
GP0(E1h)'s, which a textured polygon's texpage attribute also sets (bits 0-8 and 11). Clipped to
the drawing area; not dithered; texels transparent and blending as a polygon's do.

A backend that draws (the browser's WebGL2, the Dreamcast's PVR) gets triangles whose texture
coordinates are bytes (bp_gpu_tri, its texture word). A sprite's far edge is u + w, very often 256
(a glyph at the end of a font row), which a byte cannot hold; and a flipped sprite's goes below 0.

## Decision

- **The runtime draws them** in its software rasteriser (`Gpu.sprite`): texel by texel, through the
  window, flips from GP0(E1h), the colour modulating unless raw, `plotPixel` as polygons use it.
  psx-spx's glitch for an odd Texcoord.X is not reproduced.
- **A backend that draws gets `bp_gpu_sprite(x, y, w, h, u, v, bgr, flip)`**, under the state
  bp_gpu_state latched (BP_GPU_TEXTURED, BP_GPU_RAW), the rectangle already clipped to the drawing
  area and `u`, `v` the texel at its corner. It is the 54th ABI function. Each backend splits it as
  its own coordinates allow:
  - **Browser:** two triangles whose texture coordinates are signed halfwords (the vertex format's
    UV is now `SHORT`), running past 255 or below 0, which the shader takes modulo 256 through the
    window's AND. Their corners are not shifted half a pixel as a triangle's are: a texel's edges
    are the VRAM pixel's, so a target pixel takes the right texel at any scale (ADR-0056).
  - **Dreamcast:** the quads of the runs a byte can carry (`sprite_spans`): up to the texel before
    the edge, the edge texel (255 counting up, 0 counting down) as a column of its own with that
    texel at both ends, and what comes after the wrap. Each is drawn as the game's own polygons are
    — the binding, the texel centres, the passes — through bp_gpu_tri. Almost every sprite is one
    quad.
  - **PC (SDL2), null:** nothing to do; they show what the runtime drew.

## Alternatives

- **Two triangles at the ABI** (no new function): exact only for sprites whose UVs stay inside a
  byte, wrong by the whole page for the common one that ends at 256.
- **A 9-bit texture word for triangles**: every backend's triangle record changes for what only
  sprites need, and the Dreamcast's record has no bits to spare (32 bytes, ADR-0051).
- **The runtime splitting sprites into byte-safe triangles for every backend**: the browser can
  draw any sprite as two triangles; splitting it there would be up to nine quads for nothing.

## Consequences

- Tekken 3's screens have their text (verified: JS software and WebGL, every screen of the attract
  loop and a played path).
- `tests/conformance/GpuSprite.hx`: 4-, 8- and 15-bit pages, flips, the window, the wrap, the
  clip, raw and modulated colour, transparent and blending texels, the fixed sizes, a polygon's
  page carried over — JS = C++.
- Crash 3 and Crash Bash draw no textured rectangle: their digests are unchanged (52875c77 at 5000,
  37eefb07 at 20300).
- Not verified on the hardware: the Dreamcast's split at the edge texel follows its polygons'
  convention (texel centres at the vertices); a sprite flipped there is as exact as a game's own
  flipped polygon is.
