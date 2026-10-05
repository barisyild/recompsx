# ADR-0054: Reading back what was drawn — a texel's bit 15, VRAM copies and buffers as textures
Status: accepted   Date: 2026-10-05
Reported by the project owner: Crash Bandicoot: Warped's level transitions are wrong on every target
— in the browser the effect's colours, on the Dreamcast the effect itself, with a triangle in the
middle of the screen.

## Context

The transition (the attract loop's demo left with a button, a level entered or left) draws the frame
on screen back into the other buffer, turned and scaled, every second vblank, until it is black. Its
GPU commands each time (a JavaScript trace at vblank 4761):

- GP1(05h): the buffer just finished is shown (512,0 or 0,0, 512x240).
- GP0(80h): that buffer is copied into the other, 512x240.
- A textured quad in mode 2 (B − F), colour 080808h, its one texel FFFFh at (0,256): a diamond in the
  middle that darkens a little every frame.
- Four textured quads in mode 0 (B/2 + F/2), colour 808080h, 15-bit, each a quarter of the buffer on
  screen as its texture (pages at x 512 and 768, or 0 and 256), turned about the centre.

Three faults made it what the owner saw:

1. **The software rasteriser dropped a texel's bit 15** (JavaScript, C++, every target, and the
   reference). psx-spx, "GPU Rendering Attributes": while GP0(E6h).0 is off, "the upper bit of the
   data written to the framebuffer is equal to bit15 of the texture color". The written pixel kept bit
   15 only under "set". A semi-transparent textured primitive blends only the texels whose bit 15 is
   set, and 83 % of the frame's pixels carry it (Crash 3's palettes mark their colours). With the bit
   dropped no texel of the frame blended: the quarters were drawn opaque, sharp, and the colours went
   flat and wrong.
2. **A copy out of a buffer on screen copied emulated VRAM**, which a hardware backend never draws
   into: stale pictures, or, when stale and unchanged, nothing reported at all (bp_gpu_dirty). The
   browser's renderer and the Dreamcast both had only that.
3. **A texture page inside a buffer was read from emulated VRAM** on both hardware backends, for the
   same reason. On the Dreamcast the quarters sampled stale words, and the darkening diamond was all
   that showed of the effect.
4. **The browser's colours were eight-bit** (found after 1-3, when the owner still saw the browser's
   transition wrong). The PlayStation cuts a primitive's colour to five bits before it blends and
   blends five-bit channels (psx-spx, "Semi Transparency"; gpu.Gpu `modulate`, `pack555`,
   `blendMode`), and the effect lives on what those cuts lose: the diamond subtracts 1/31 a frame
   (its colour 15/255 cut to one step), and every (B + F) >> 1 drops half a step when B + F is odd,
   which is what turns the turning frame black. The renderer subtracted 15.5/255 — the middle went
   black twice as fast — and lost nothing elsewhere, where the frame never darkened. Measured
   against the reference over the first transition (fbTex read back at 15 vblanks, 4744-4800): the
   mean difference grew to 2.1 five-bit steps a channel, 7 % of pixels exact.

## Decision

- **Runtime:** a textured pixel keeps its texel's bit 15 — `plotPixel(..., set || stp)`.
- **ABI:** `bp_gpu_copy(sx, sy, dx, dy, w, h, changed)` and `BP_CAP_GPU_COPIES` (7). A backend that
  copies what it drew answers it nonzero and then hears of every VRAM-to-VRAM copy in its place
  among the primitives, and of none through `bp_gpu_dirty`. A copy onto itself is reported only
  when it sets the mask bit, since otherwise it moves nothing. `changed` says whether emulated
  VRAM's destination changed, which is all a copy out of what emulated VRAM holds amounts to — the
  Dreamcast keeps `bp_gpu_dirty`'s rule for those. Emulated VRAM has every copy as before (state,
  not presentation).
- **Browser (WebGL):**
  - The mask bit is the depth buffer. Every fragment writes the bit the PlayStation stores as
    `gl_FragDepth`: 1 under "set", otherwise the texel's bit 15, and 0 for an untextured primitive.
    Depth is not blended and each fragment writes its own, so a texel's bit reaches VRAM inside one
    draw, and submission order stays exact.
  - The stencil serves "check" alone. It is rebuilt from the depth buffer before a batch that checks.
  - A copy goes from fbTex and its depth through a scratch target, drawn both ways: the shader that
    writes the mask bits reads them from the depth texture. (A first version blitted colour and
    depth into the scratch; it drew both transitions the same, frame for frame.)
  - Colour is five bits a channel. The shader cuts the primitive's colour as the software
    rasteriser does, and fbTex stores a channel's k as (k + 1/2) / 32, read back (screen, toWord)
    as the floor of 32 times it. Modes 1-3 then move in whole steps. Mode 0's floor, which a
    fixed-function blend cannot compute, comes from F given half a step less: (B + F) / 2 lands a
    quarter step under the floor for an even sum and a quarter over for an odd one, inside the
    step either way, and the half step above k keeps that F non-negative for a black texel (a
    blend clamps a negative colour). After a chain of such blends a value can drift towards the
    step's edge; one step off is then possible, never a drift.
- **Dreamcast:**
  - A copy out of a buffer on screen (through the pictures, ADR-0053) is a record, `GCMD_COPY`. It is
    drawn where it falls among the primitives, 1:1, from the source buffer's picture. Anything else is
    a write as before.
  - (ADR-0055 makes pictures 640x480 stride textures, declared 1024x512, and scales a page's and a
    copy's coordinates by the picture's own scale; what follows is the first form.)
  - A 15-bit texture page whose corner lies in a buffer with a picture binds that picture. It is
    sampled at the size it was rendered, 512x256: an emulator matches a texture it rendered by address
    and size, and Flycast keeps a 512x240 render as 512x256. V is therefore scaled apart from U
    (`dim_v`, put_tri's `rv`).
  - A picture keeps no bit 15, so a semi-transparent primitive reading one blends every texel. That is
    what 83 % of Crash 3's frame does.

## Alternatives

- **A fifth texture format for pictures with an alpha bit (ARGB1555), the mask bit in it.** The PVR
  writes alpha from what it blended, not from the texel's bit, and the screen pass and the copies
  would need it decoded again. Kept for when a game needs the exact split.
- **Read the PVR's picture back into emulated VRAM before a copy or a texture reads it.** That puts
  what the PVR drew into emulated state, which then depends on the target, against golden rule 3.
- **The browser's mask bit in the stencil, written per texel in two passes.** The passes of one batch
  reorder overlapping primitives. As separate batches, it is a draw call per primitive.

## Consequences

- **Digests change: the reference.** JavaScript (and C++, conformance):
  - Crash 3 at 5000: 47853ef7 → **52875c77**.
  - Crash Bash with its mods at 20300: 95e17b07 → **37eefb07**.
  - `Raster`: a749a71a → **1bdad19d** (JS = C++). A third of its texels carry bit 15.
  - Every Dreamcast digest check from here on compares with the new values: the Dreamcast build
    with all of this prints 52875c77 for Crash 3 and 37eefb07 for Crash Bash with its mods
    (`scripts/dc-digest.sh`).
- **The TA hash** (builds without placement, before and after): Crash 3's title and demo windows
  are unchanged (1,891 and 2,168 scenes). Crash Bash renders one picture more at about present 1700
  — a copy out of a buffer, now drawn into its picture — and from there 1,766 of its 7,944 scenes
  differ, every one only above bit 14 of the hash: the texture address of one picture memory
  against another, 256 KB apart, since that render shifted the three memories' rotation. No hash
  differs below bit 15, as a changed vertex, colour or header bit would almost surely make it.
- **Cost** (the model, Crash 3's demo window, which holds the first transition): 20.63 → 20.87 ms a
  frame, conflict-free 17.60 → 17.73 — the transition's copies and textures drawn (ledger E-165).
- **The Dreamcast's approximations:**
  - Every texel of a picture blends; a black one is not transparent.
  - A copy out of a buffer into VRAM no picture is made of stays stale there (said once on the
    serial log).
  - A buffer read while it is being rendered is the picture that render started from.
  - Colour: the PVR blends eight-bit channels within a scene, and a picture's five bits are widened
    back with their high bits when it is read, so the losses of fault 4 are not had there either:
    the transition turns, and stays brighter than the reference for longer before it is black (the
    owner, on Flycast: "bu özellik şu an çalışıyor").
- **Verified**, the attract loop's first demo and its second (the diving level), a button pressed in
  each (`--pad-script 4700:CROSS,4710:-,8000:CROSS,8010:-`):
  - JavaScript, software (the reference): the frame turns into black in ~50 vblanks.
  - The browser, WebGL, fbTex read back at the same vblanks as the reference's VRAM (`?arg=`, a
    present wrapper from the first frame, web/AGENTS.md): the first transition within 0.06-0.33 of
    a five-bit step a channel on average, 50-86 % of pixels exact (eight-bit colour: up to 2.1,
    7 %); the second within 0.08-0.17, 73-85 %; title screen and demo gameplay 0.04-0.06, 87-89 %
    — the rest is interpolation at edges.
  - The Dreamcast (Flycast's fork, `--dc-shots=8040:8140:4`): both transitions as the reference,
    the swirl a little brighter and a few vblanks longer — the PVR blends at 8 bits too, and every
    texel of a picture blends.
  - The owner's report that the browser drew "the second one" wrong was the attract loop's own
    transition at the end of its second demo (no button pressed; ~12200): there the picture halved
    to black at once. ANGLE on Metal (Chrome 152, Apple M3) had given vramTex fresh storage at a
    palette upload 40 frames before, and `wordFbo`, still attached to the old storage, took every
    converted word: the effect sampled stale black texels. A word written there read back
    unchanged until the attachment was renewed, and right after it was. `syncDrawn` now detaches
    and attaches vramTex each time; the transition then follows the reference (0.15 of a step at
    most, black at 12290 on both). The transitions a button starts (the owner's 4811/8100 and
    4600/7900/11100) matched it before the fix, which changes only the attachment.
    The conversion also reads the mask bit from fbDepth as a texture in one pass, so `wordFbo` has
    no depth attachment of its own any more.
