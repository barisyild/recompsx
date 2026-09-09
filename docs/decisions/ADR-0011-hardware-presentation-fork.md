# ADR-0011 — Hardware drawing as a presentation fork, never a state fork

Status: **accepted**, 2026-08-11
Extends the backend ABI (docs/specs/backend.md §1) with five functions and one capability.
Does not amend ADR-0003: JavaScript remains the reference, and by construction cannot take this
path.

## Context

Crash Bash runs on a Dreamcast at 17.5 emulated vblanks a second against the 60 it owes. The
backend's own profiler settled where the time goes — `emu 461 | upload 110 | disc 0 | pvr-wait 0`
per ten frames — and two rounds of mechanical work on the host code (removing per-block hint
stores, replacing byte-composed memory access with direct loads; together 25% of `.text`)
measured *nothing* on the console. The arithmetic explains why: a desktop frame costs 1.13 ms,
the SH-4 gives up roughly fifty times in clock and IPC, and 50 × 1.13 ≈ the 57 ms measured. There
is no fat left to trim. What remains is the volume of emulated work.

Menus are the cheap case — one primitive a frame — and gameplay is not. A software rasteriser
that keeps up with a menu on this machine will drown in a race track, whatever the CPU side
achieves. The Dreamcast has a rasteriser sitting idle: the PowerVR, which drew this console's own
games. Handing PlayStation primitives to it is what made PS1 emulation viable on this hardware
once before, and it is the only lever whose ceiling is high enough to matter.

The problem is that this project's central promise is bit-identical output across targets, and a
different rasteriser does not produce identical pixels. Ever. Not with the same texture filter,
not with the same blend arithmetic, not with the same fill rule.

## Decision

**Hardware drawing is a fork in presentation and never in state, and nothing takes it by
accident.**

Everything the emulated machine can observe happens identically in both modes: GP0 parsing,
GPUSTAT, interrupts, DMA, cycle costs, and — this is the load-bearing part — **VRAM uploads and
VRAM-to-VRAM copies still land in emulated VRAM**. They are state: a game reads them back, blits
them, and builds its world out of them. The only thing that goes elsewhere is *rasterised*
pixels, which nothing but a display was ever going to look at.

Three gates stand between a build and this path:

1. `gpu.Gpu.hw` is `false` in the source. Nothing in the runtime sets it.
2. A host must ask, with `--video-hw`.
3. Its backend must answer `BP_CAP_GPU_DRAW`. The JavaScript shim's `caps()` returns zero for
   everything but pad count — deliberately, and documented there — so the reference target cannot
   take this path even if a page asks. The null and SDL backends answer zero too.

Therefore every digest-producing run is in software mode by construction, and `--headless-hash`
output cannot move. That is not a convention to be careful about; it is the arrangement of the
code.

## What hardware mode gives up, stated plainly

These are consequences, not defects, and a bug report against them is a request for the software
path:

- **Rendered pixels are not in emulated VRAM.** Anything reading them back sees what was there
  before: feedback effects, the `vram.bin` diagnostic dump, and GP0(C0h) if it is ever
  implemented.
- **Blend mode 2 (B − F) is approximated** as half-and-half. The PowerVR's eight blend factors
  do not include inverse-source-colour; the hardware cannot express subtraction. Logged once.
- **Modulation clamps.** The PlayStation multiplies texel by colour and divides by 128, so a
  colour above 0x80 *brightens*; the PVR multiplies in 0..1 and cannot. Colours are doubled and
  clamped, so bright modulation is dimmer than the software path.
- **Mask bits and dithering are not emulated** in this path.
- **Transparency is texel-zero only.** The texel's bit 15 (the semi-transparency flag) is not yet
  carried into the decoded texture.
- **Palettes above the hardware's ceiling are approximated.** This is the one place where the
  Dreamcast has *less* than the PlayStation, and it is worth stating precisely because it is
  permanent. A PS1 CLUT is ordinary data in the same one megabyte of VRAM, so a scene may use a
  thousand of them; the PowerVR reads a fixed 1024-entry palette table (register base 0x1000) at
  render time, which at 4bpp is 64 banks of 16. A Crash Bash arena wants about a hundred. Two
  mitigations carry nearly all of it — banks are addressed by content, and the overflow is drawn
  from texels with the CLUT baked in, sized to the patch a primitive actually samples — and what
  neither can carry (a primitive sampling wider than one 64x64 patch) falls back to the nearest
  banked palette by channel distance. That fallback is counted and reported, never silent.

Frames that produce no primitives — movies, and any screen a game builds entirely out of VRAM
blits, which is most of Crash Bash's boot — fall back to the existing framebuffer path
automatically, because there is nothing to draw and the VRAM window is still the truth.

## The ordering problem — amended 2026-08-11: Z does NOT solve it; submission order does

**The scheme this section originally described is dead, and the section is kept as the record of
why.** In practice the three-list depth ramp lost surfaces of the character model — the mouth,
a leg, moving as other fixes landed — and survived every unrelated repair. The user suspected
the depth buffer twice; twice it was argued away with reasoning that each cross-list case
resolves correctly, and the argument was never faulted — the *system* was. Which interaction
broke was never isolated, and no claim is made here about which it was: the decisive move was
not winning the argument but deleting the machinery it was about.

The replacement is the PlayStation's own semantics, natively: **one translucent list with
autosorting disabled renders in submission order per tile** — later submission wins, no depth
compare, no depth write, nothing to reconstruct. Opacity is a blend mode (ONE/ZERO untextured;
textured surfaces carry texel alpha through SRCALPHA/INVSRCALPHA, which also gives "texel zero
draws nothing" without a punch-through list or an alpha threshold). The model completed the
moment this shipped.

The lesson worth the ink: when a target machine has a native expression of the emulated
machine's semantics, use it — rebuilding those semantics on top of a different mechanism is a
standing invitation to exactly this class of unfalsifiable bug.

## The original ordering design (superseded, kept for the record)

A PlayStation draws strictly in submission order: the last primitive wins. A PowerVR sorts
geometry into three lists and renders opaque, then punch-through, then translucent — an order
that has nothing to do with when the game submitted anything.

The bridge is depth. Every primitive in a frame is given `z = 1.0 + n × 0.25`, one step nearer
than the one before it, with the depth test set to greater-or-equal and depth writes on. A later
primitive then wins against an earlier one whatever list either landed in, because it is nearer.
Autosorting is disabled for the same reason: the order is already decided and is not the
hardware's to improve on. Quarter steps keep every value exact in a float across the buffer's
twelve thousand entries.

## Consequences

The ABI grows five functions and one capability, all flat ints, so the boundary keeps its shape
(no structs cross it). Backends that do not want them return zero from `bp_caps` and stub them;
`check.sh` enforces that every backend still answers the whole header, which is what caught the
stubs being missing while this was written.

Every other console this project targets has a GPU too, and they all have this same problem —
their own rasteriser, their own pixels, their own ordering model. This ADR is the shape of the
answer for all of them, and the Dreamcast is its first instance rather than a special case.

The software rasteriser stays exactly where it is, keeps being the thing every digest is measured
against, and remains the only path on the reference target. Two rasterisers is a cost; being able
to say which one is *right* is what pays for it.

Historical decision restored from `6819782` on `dreamcast-hardware-rendering`.
The September main reconciliation and current verification are recorded in PROGRESS.md.
