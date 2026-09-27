# Crash Bandicoot: Warped (NTSC-U, SCUS-94244) — third bring-up target

Naughty Dog's engine, nothing shared with Crash Bash (Eurocom). Its value to the project is the
parts of the machine Crash Bash never leaned on: a 1 kHz root counter, hand-written assembly that
borrows `$sp` as a general register, computed jumps into unrolled loops, and an interpreter
(GOOL) whose opcode table lives in the scratchpad.

## Disc and executable, verified 2026-09-26

| Field | Value |
|---|---|
| SYSTEM.CNF | `BOOT = cdrom:\SCUS_942.44;1`, TCB 4, EVENT 16, STACK 801FFFF0 |
| exe | `\SCUS_942.44;1`, LBA 24, 333,824 bytes, sha256 `1b93cc56…6d71d1` |
| initialPc / gp | `0x800489F8` / 0 |
| load | `0x80010000`..`0x80060FFF` (0x51000 bytes) |

Levels are `S0`..`S3/S00000xx.NSD/.NSF` pairs. `S0/WARPSCUS.BIN` (LBA 1505, 14,336 bytes) is
native code read whole at boot to `0x8006EA78` — the `warp` overlay. The disc also carries the
Spyro: Year of the Dragon demo (`DRAGON/SPYRO.EXE`, `WAD.WAD`, `CDEMO.STR`), a fourth target.

## What game.json says, and why

- **The GOOL interpreter** is `f_80038e28`. It dispatches with `jr $a3` through a table whose base
  it reads from the scratchpad (`lw $a0, 0x5C($fp)`, `$fp = 0x1F800000`): the game copies the 82
  handlers at `0x8005D120` to `0x1F800060` for speed. A `jumpTableHint` names the ROM copy; the
  targets are the same. Its native-call stub (`0x80038DD8`) sits *below* its entry, which is what
  exposed the block-0 bug in the emitter (fixed: the entry is block 0 whatever its address).
- **Hand-written copies and a register machine.** `f_80039e3c`/`f_8003a928` jump into unrolled
  halfword-copy loops (`target = label - n*stride`), and `f_8003af78` into runs of 8-byte branch
  slots indexed by a counter or an opcode byte (`ra >> 24`); the latter also uses `$sp`, `$gp`,
  `$k0`, `$k1` as data. Their targets are listed outright (`targets`) — see each `_at` note.
- **Entry points nothing calls statically**: the NSF entry-type handler table at `0x8005BD40`
  (records of a four-character tag and five slots), libgpu's table at `0x8005F3C0`, the VSync
  callback `0x80017AD0` (increments the frame counter at `gp+0x70`), the RCnt2 callback
  `0x8003AE70`, the renderer's per-primitive routines (table at `0x8005C1B8`) and the renderer's
  continuation points, which it builds with `lui/addiu`, stores, and later reaches with `jr`.

## Runtime facts this game established

- **Root counter 2 at ~1 kHz drives it**; after boot it masks vblank (`I_MASK 0x0CC`). Timer IRQs
  were unimplemented; without them it sat on a black screen forever.
- **A line raised during a handler is not the kernel's to take.** With 1 kHz interrupts, a CD INT1
  arriving at a pump inside the handler was acknowledged by the kernel's fallback before libcd
  read the sector; libcd printed `CdRead: retry...` and the level loader eventually `exit(-1)`.
  (Crash Bash had six of these retries too; one remains there, and it is authentic: its SCEx check
  polls the drive directly with `Setmode 01`, so libcd's first read after it runs in the wrong
  sector size and reports `sector error` — the same on hardware.)
- **Kernel handlers run on the kernel's stack** (OpenBIOS `kernel/vectors.s`), and device-event
  callbacks from the pump preserve the interrupted registers.
- **Rectangles clip to the drawing area.** Stars left of the back buffer were landing in the
  front one and blinking. The hardware path also received the rectangle colour as 15-bit.
- **A return can skip a frame.** Objects are drawn from linked draw lists (`f_8003f3ac`, one node
  per object: `$sp` walks the list). A node's visibility routine is either a no-op (Crash:
  `0x8003e034`) or the bounding-box test `0x8003def4`: eight corners projected with RTPT, each
  checked by `0x8003e000`, which on an on-screen corner reloads the test's saved `$ra` from
  `100($v1)` and jumps straight to the test's caller with `$t8 = 0`. ADR-0027. Until then every
  box, enemy and animal was culled while Crash was drawn.
- **Drawn pixels are textures.** Crash's shadow is his silhouette, rendered each frame into VRAM
  (0..63, 320..383) and laid on the ground as a 4-bit texture (tpage 0x0250, CLUT (64,256)).
  The WebGL renderer converts drawn tiles back into its VRAM texture before a primitive samples
  them (ADR-0020 revision).

## Status (2026-09-27)

The attract loop's second demo, in the diving level, runs too: 20000 frames headless through both
demos with nothing missing (digest `f05fb3ea`; 9000 frames unchanged at `2c8bc61d`). It froze at
~10150 because the fish's GOOL native routine (FshOC, seven words) was keyed on eight — the eighth
an entry reference the game resolves to a pointer when the page loads (ADR-0025 revision).

## Status (2026-09-26, later)

The DEMO draws boxes, the ? box, enemies, animals, butterflies and fruit, with Crash's shadow in
both renderers. Checked against DuckStation through its GDB stub: Crash's position and the camera
match frame for frame from the level start to the end of the demo (931 samples; ours runs 114
frames ahead because it loads faster). Headless 9000 frames: digest `2c8bc61d`.

## Status (2026-09-26)

JS: the whole attract loop runs — Sony and Universal screens, the intro, the title (NEW GAME /
LOAD GAME), a DEMO in the medieval level, and back to the title — through 9000 frames with no
missing code (headless 9000 frames: digest `7f7d8a93`). Software and WebGL render alike.

What it took, in order: the `jr $at` return (GOOL's operand helpers), **native code inside GOOL**
compiled from the NSF files and recognised by content (`relocatable` stanza, ADR-0025: 12,834
entries, 1,313 distinct functions), `jr $ra` after the function set `$ra` itself being a jump (the
run-merge routine `f_80039e3c` uses `$ra` as its loop head and `$sp`/`$gp`/`$fp` as data), and
computed tail jumps run by the caller instead of nesting (ADR-0026; the renderer hops between
routines through pointers once per primitive).

Not yet looked at: input (start a game), the Dreamcast image, performance with the relocatable
code in (JS 9000 frames ~16 s headless).

Run it: `out/_c3web` (browser, `web-crash3` launch config) or
`node out/_c3/game.js <SCUS_942.44> <disc.bin> --headless-hash N`.
