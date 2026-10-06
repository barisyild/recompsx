# ADR-0057: The MDEC — decoded when output is wanted, in exact integers
Status: accepted   Date: 2026-10-05
Asked for by the project owner while bringing up Tekken 3 (SLUS00402): "mdec desteği ekle,
tekken'in düzgün çalıştığından emin ol", with psx-spx's "Macroblock Decoder (MDEC)" as the spec.

## Context

The MDEC turns run-length coded DCT blocks into pixels: a game's movie player decodes each frame's
bitstream into that form on the CPU, sends it in through DMA0, takes the pixels out through DMA1
and uploads them to VRAM; some games decode their stills the same way. Neither Crash game uses it.
Tekken 3 does, for its opening movie and its character portraits, and without it: DMA channels 0
and 1 had no device, the MDEC's registers were unimplemented I/O, and its library printed
"MDEC_in_sync timeout:" after every frame of the movie.

psx-spx gives the decoder as pseudo-code (rl_decode_block, real_idct_core, yuv_to_rgb,
y_to_mono) and says that the hardware rounds "about like that". Golden rule 3 wants the pixels the
same on every target; the pixels go to RAM, so they are emulated state.

## Decision

- **One device, `mdec.Mdec`, in the portable runtime**: the command and data port (1F801820h), the
  status and control register (1F801824h), MDEC(1) decode, MDEC(2) quant tables, MDEC(3) scale
  table, the reset and the two DMA requests. `Dma` runs channel 0 into it and channel 1 out of it.
- **Decoded when output is wanted.** MDEC(1)'s parameter words wait as received. A DMA1 transfer
  (or a read of the data port) decodes whole macroblocks until it has what it asked for; a transfer
  the input cannot fill yet stays busy and takes the rest when DMA0 or the port brings more
  (`Dma.mdecMore`). That is the hardware's FIFOs pacing the two channels, without modelling them: a
  game may start DMA1 before DMA0 or after, and nothing holds more than one macroblock of pixels.
- **The output is in the order DMA1 leaves it in RAM**: a colour macroblock as 16x16 pixels, row
  by row, the four 8x8 luminance blocks in JPEG's order (top-left, top-right, bottom-left,
  bottom-right); a monochrome one as 8x8. psx-spx's pseudo-code calls yuv_to_rgb(0,8) for the block
  its comment calls upper-right; the comment, JPEG and Tekken 3's movie agree on the order taken.
- **Exact integer arithmetic.** The inverse DCT is psx-spx's two passes with the scale table's top
  13 bits, each sum rounded as `(sum + 0FFFh) >> 13`; colour uses psx-spx's factors (1.402, 0.3437,
  0.7143, 1.772) in twelve fractional bits, rounded, then the 9-bit wrap and the saturation to
  8 bits. Where the scale table has the standard one's symmetry (every game's), a row is taken as
  its even and odd frequencies apart — the same products, regrouped, so the same sums with half
  the multiplications; any other table takes the full sum.
- **Cheap on a console, the same everywhere.** The tables and the blocks are words of one buffer
  at fixed offsets, never `Array<Int>` (on reflaxe.CPP a vector behind a shared pointer: the
  Dreamcast spent a third of a movie frame in the IDCT through them, and passing one bumped an
  atomic count). A block's coefficients are mostly zero and a zero's products add nothing, so the
  first pass leaves columns that are all zero as zero rows and both passes take only the terms
  that can be non-zero (the rows and columns the run-length decode filled, `rowMask`/`colMask`):
  the DC alone, the low four, or all eight. Each Cr/Cb sample's colour terms are worked out once a
  macroblock, not once a pixel. Every shortcut sums the full product's terms; the conformance test
  holds each path to psx-spx's decoder.
- **Busy is "parameters to come, or input left to decode"** — and FE00h padding is not input. A
  movie frame's data is padded with FE00h to whole DMA blocks; the hardware passes over padding
  before a block, so once only padding is left it is idle. Tekken 3's player waits on the busy bit
  after every frame: with the padding counted as input, it timed out on each one.

## Alternatives

- **Decode at DMA0, buffer the pixels.** A frame of 24-bit pixels is 3 bytes a pixel against the
  input's ~0.3; the buffer would be the largest allocation in the runtime for one device, and a
  console has none to spare. Decoding at DMA1 keeps one macroblock.
- **Model the FIFOs and their timing.** No game observed needs it; the pacing above gives every
  order of channel starts the result the hardware gives.
- **Floats for the IDCT** (SH-4's FIPR is the obvious tool on the Dreamcast). Not exact, and not
  the same on every target; the pixels are emulated state.
- **psx-spx's fast_idct_core.** It is the same transform with different rounding; real_idct_core is
  the one psx-spx describes as what the hardware does.

## Consequences

- Tekken 3's opening movie and portraits decode (verified on JavaScript: the movie's captions and
  scenes, the character select and VS screens).
- `tests/conformance/MdecDecode.hx`: every depth and sign, symmetric and asymmetric tables, dense
  and sparse blocks (the DC alone, the first 5, 9 or 20 coefficients), against psx-spx's decoder
  written out as plain loops in the test; the padding and partial-macroblock status. JS = C++.
- Not modelled: the odd timing of status bit 30 (data-in FIFO full), DMA0's request bit while a
  transfer runs, and decode speed: a macroblock is ready the moment it is wanted. A game timing
  itself against the MDEC would see it as infinitely fast.
- The Dreamcast takes the same code through reflaxe.CPP. Tekken 3's opening movie under the cache
  model (presents 300-600, one video frame in three presents): 61.2 ms a present with the tables in
  `Array<Int>`, 49.3 in one buffer, 35.7 with the shortcuts and the per-macroblock colour terms —
  a decoded frame 158 → 123 → 81 ms, the IDCT 6.3 → 2.0 s of the window. The movie plays at about
  half speed there; what is left is the IDCT's multiply chains, the colour conversion, the 24-bit
  picture uploaded at every present, the XA interpolation and the game's own polling.
