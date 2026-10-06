# ADR-0061: A texture page's CLUTs as VQ codebooks on the Dreamcast
Status: proposed — measured, not adopted (ledger E-180)   Date: 2026-10-05

## Context

A PlayStation texture through a CLUT is a page of indices and a palette; the PVR can sample an
index texture only through its palette RAM, 1024 entries in all. The backend gives that RAM to 4bpp
pages as 64 banks of 16 (src/backend/dreamcast/dc_textures.c, `g_pal4`), and everything that does
not fit is **baked**: the CLUT applied to a 64x64 patch of the page at decode time (`bake_slot`,
1 MB of 8 KB patches) —
- every unwindowed **8bpp** page (an 8bpp CLUT is 256 entries: four would fill the RAM);
- a 4bpp page whose CLUT found **no bank** (Crash 3 binds sixty-odd CLUTs a frame against 64);
- the two **variants** of a semi-transparent 4bpp primitive whose CLUT holds solid and STP texels
  (`AM_SOLID`, `AM_STP`; semi_prim).

A patch binds one record, so each baked record is a run of its own through build_scene's slow path.
Crash 3's demo bakes ~110 records a present; bake_slot and its search are 0.25 ms a present of the
model (ledger E-179's profile), with the palette work around them ~0.2 more. Tekken 3's first fight
misses the pool 908 times by present 2100 (PROGRESS.md, 2026-10-05 midday): the bake decodes are
most of its 8 ms scene build. The owner's rule is that a game's speed must not depend on work done
for that game (2026-10-05: "oyun başına optimizasyon ... doğru yol değil").

Bloom, a PlayStation emulator for the Dreamcast (github.com/pcercuei/bloom, GPL-2.0 — studied for
the technique only, nothing taken), keeps a page's indices once and each CLUT as a **VQ codebook**:
a VQ texture is a 2 KB codebook of 256 four-texel entries followed by one index byte per four
texels — a 2x2 block twiddled, a row of four in scan order (Flycast's `ConvertPlanar`, xpp 4,
core/rend/texconv.cpp `texture_PLVQ`) — so an entry whose four texels are the CLUT colour turns
each index byte into one PlayStation texel four texels wide, and a CLUT is 16 entries (128 bytes)
or 256 (2 KB) of codebook. Many codebooks share one page's indices: the hardware reads the indices
2 KB after the address in the header, so codebook k placed k index rows lower than the first, read
with V moved down k rows, lands on the same indices.

## Decision

Draw every texture that is baked today through **VQ page slots**: a pool of 80 KB slots, each one
PlayStation page's 256x256 indices as bytes in scan order (64 KB; 4bpp nibbles widened) after a
16 KB codebook area — 56 codebooks of 16 entries 256 bytes apart for a 4bpp page, 8 of 256 entries
2 KB apart for an 8bpp one. A binding is (slot, codebook k): the header's texture is the codebook's
address, VQ, ARGB1555, scan order, 1024 x 512 (256 index bytes a row, a row a texel high); a
vertex's U is the texel's as at 256, its V the texel's plus k rows (4bpp) or 8k (8bpp) over 512. A codebook holds one CLUT in one variant
(AM_VIS, AM_SOLID, AM_STP), its entries `texel_argb`'s four times over; it is kept across builds
while its CLUT's VRAM rows are what they were (the generations of E-171), and like every texture
here it is never rewritten while a scene in flight may read it. A page's indices are written when
the slot is first bound and again where emulated VRAM was written since (`textures_stale`). A slot
binds per state, not per record, so the records it draws are runs again. 4bpp pages with a bank
(PAL4BPP mirrors), windowed pages and 15-bit pages stay as they are. The bake pool goes.

## Alternatives

- **More palette RAM**: there is none; 1024 entries is the PVR's.
- **Bake bigger or keep more patches**: moves the misses, never ends them; the pool is already the
  megabyte the mirror pages lend it, and a game with more CLUTs than Crash 3 thrashes it.
- **Every 4bpp page as VQ too** (drop the banks): one form for every CLUT, but 32 pages of 64 KB
  indices is 2 MB beside the pictures' 1.4 — over the PVR's budget; the banks are already free for
  the common case. Revisit if the slots prove cheap on the console.
- **Twiddled VQ**: the hardware's fast order, but codebooks could not share indices — a byte offset
  is a row only in scan order.

## Consequences

- The TA stream changes (texture words, V coordinates): exactness is checked by pictures, as for
  E-179; the bake's patch-origin bookkeeping (one_patch, BAKE_STEP) goes with it.
- The PVR loads a codebook at each change of VQ texture; its cost is the PVR's, measured on the
  console (Flycast does not time it). A 4bpp codebook uses 128 of the 2 KB the PVR may fetch.
- Memory: 12 slots (960 KB) where the bake pool's own patches were 1 MB; the mirror pages stop
  lending memory.
- Verify: Crash 3 and Crash Bash pictures against the current form (present-numbered shots), the
  demo's model time, Tekken 3's fight (its bake misses).

## Measured (2026-10-05, ledger E-180)

Built behind RECOMPSX_VQ (0: the bake pool, the default; 1: VQ where the bake pool was, banks kept;
2: every plain 4bpp and 8bpp page, no mirror and no banks). Exact on Flycast (Crash 3's pictures as
before but for scattered single pixels). Neither form pays on the games it was measured on:
- **2** takes 0.19 ms off Crash 3's demo (conflict-free) once vq_bind remembers its answers, but a
  page's 57 codebooks are too few for Crash Bash's ~100 CLUTs a page: codebooks are rewritten
  thousands of times and Ballistix's work rises 11.74 → 12.74 ms.
- **1** leaves both games where they were, and its 17 slots (all that fit beside the mirror) leave
  some binds with none, which then take the nearest palette.
- The first try of 1 had seven slots and fell back to whole-page slots, whose evictions inside a
  scene drew foreign texels: VQ's fallback must never be a page slot.

What remains for it: **8bpp pages only**, where the bake pool thrashes (Tekken 3's fight, 908
misses by present 2100) and a page's CLUTs are few (Crash 3: at most 3 an 8bpp page over two
presents) — VQ slots for those pages, the bake pool kept for the rest.

**8bpp pages only (ledger E-183, RECOMPSX_VQ8, off):** 0.29 ms off Crash 3's demo with eight slots in
half the big pool, whose intro then ran out of big slots and rewrote them in flight; with the big
pool kept only six slots fit, for the demo's 9-11 8bpp pages a frame, and nothing was gained. Its
pictures are not the bake pool's either: the 8bpp walls of Toad Village came out scrambled — a bug in
this form's binding, to find before the form is tried again.
