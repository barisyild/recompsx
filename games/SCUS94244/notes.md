# Crash Bandicoot: Warped (NTSC-U, SCUS-94244) — third bring-up target

Naughty Dog's engine, nothing shared with Crash Bash (Eurocom). Its value to the project is the
parts of the machine Crash Bash never leaned on: a 1 kHz root counter, hand-written assembly that
borrows `$sp` as a general register, computed jumps into unrolled loops, and an interpreter
(GOOL) whose opcode table lives in the scratchpad.

## 2026-10-06: What faces the screen, and the world's polygon list, read for widescreen's 2D

Read with a scratch probe mod (a copy of this directory with an extra mod, generated into out/, so
nothing here changed) and the disassembly; the facts the widescreen mod stands on.

- **The objects' draw loop**, `f_8003f3ac(first record, frame, state)`, walks a list of draw records
  with `$sp` (+0 the next, +4 a setup routine, +8 and +0Ch two more, +10h the object, put in `$gp`,
  +14h five words of a matrix, loaded into the GTE first by 80041FBCh); the primitive pointer lives
  at 1F800014h meanwhile and is written back to the frame's +8 at the end. Setup routines seen:
  8003D054h for a model (80041EF0h, the camera's matrix with the object's), 8003D078h and 8003D0C0h
  for the world's billboards (wumpa fruit: 80041FD8h, then 80042058h for its place through the
  camera), 8003E67Ch for the screen's own objects (kinds 6 and 7: the HUD's icons, the pause
  screen's panels) — 80041FD8h, then TRX = x >> 8 (>> 4 with a flag), TRY = -y >> 8, TRZ = H.
- **80041FD8h** makes the GTE's matrix from five words in t0..t4 (row 0 in t0 and t1's low half,
  left as it is; row 1 times 5/8, as 160/256, and negated; row 2 negated): the matrix of everything
  that faces the screen, none of it through the camera's. Callers: 8003D034h, 8003D07Ch, 8003D0C4h,
  8003D460h, 8003E680h, 8003F860h. A sprite (8003D524h) is four corners at ±200 << n through RTPT
  and RTPS, a POLY_FT4 of 40 bytes at the scratchpad's primitive pointer.
- **Texts**: `f_8001c824` places its text object with `f_8003c3d0` — whose screen path (a2 = 1) takes
  TRX and TRY from the object's x and y and builds the matrix from its angles, the 80065CB0h it is
  handed only used on the world path — then `f_8001c3f8` writes the glyphs (80019090h, 800192F8h:
  RTPT of each glyph's corners) as POLY_GT4s, 12 words a glyph, into the frame's buffer (*80061A84h
  + 8). The pause screen's panels are POLY_GT3s; nothing of the 2D seen is a sprite primitive.
- **The display flags the game asks for** (80068F08h) and the shrink (8006901Ch): gameplay 0C01FFFFh
  (the Toad Village demo 0C01FEFFh), the title 2C01FFFEh (objects but no world), the pause screen
  opening with the shrink 1 to 8 (a step every second vblank), then 0401DFFEh — neither the world
  nor the objects — with the shrink back at 0, and closing with the shrink 8 to 0 and the flags as
  in gameplay. Pausing at vblank 15400 in the warp room: shrink 1 at 15406, settled at 15428.
- **The world's polygon list.** `f_80040ed8(list, frame, state, a3)` (from 80011C04h, the list from
  *80060AA4h) draws a count and then halfwords, walked from the last: world (bits 13-15), a type
  (11-12: 0 a triangle from the world's table at slot +8, else a quad from +0Ch), index (0-10). The
  world slots are 32 bytes from 1F800280h (filled by the main loop before the call: +0 and +4 the
  world's place, +8 and +0Ch the polygon tables, +10h the vertices — xy words downward, z halfwords
  upward from it). Each polygon is RTPT'd, AVSZ3/4'd, rejected when all corners are off one side of
  the bounds at 1F80021Ch, and linked into OT slot 770h − z; there is no NCLIP — the list holds the
  front faces the 4:3 view saw, kept up as the camera moves along its path (list buffers of 0BE4h
  bytes, 8002A97Ch). The warp room lists 251 of world 0's 607 or more and 344 of world 1's 1,914 or
  more; at 16:9 its platform's edge at the bottom left is missing, which no polygon in the list
  covers.

## 2026-10-06: The camera's aspect, read for the widescreen mod

The world and the objects are projected through one matrix the camera's update makes every frame.
Found by probing the world renderer's entry (`f_80040ed8`, called at 80011C04h) for the GTE's
registers and searching RAM for its rotation matrix, then watching which code wrote it (a scratch
build wrapping every generated function and comparing those bytes after each).

- **The camera's update**, `f_80018a54`, from the main loop (`f_8001166c`) at 80011A4Ch every frame
  whose flags in effect (+84h of the state at 80068E98h) lack 40000000h — paused or not. Its state
  is at 80065CF0h (+0Ch, +10h, +14h the angles about x, y and z; its sines and cosines from
  `f_8003c2f0` and `f_8003c364`). It builds the rotation at **80065C90h** (a MATRIX: nine
  halfwords, 4.12; +14h..+1Ch the translation) — z, then x, then y, through `f_8004f404` (MulMatrix)
  — and the translation with `f_8004f514` (TransMatrix: the camera's place in the world, position
  >> 8, not rotated: the renderers subtract it before rotating).
- **The aspect routine**, `f_80018988(to, from)`, called only from there (80018B9Ch) with to =
  80065CB0h, from = 80065C90h: row 0 copied, row 1 times -5/8 (`-(5x) >> 3`), row 2 negated, the
  translation copied. 5/8 is the game's aspect correction: at 512x240 shown 4:3 a pixel is 0.625 as
  wide as it is tall. The update copies the result to 80065CD0h; the main loop loads 80065CB0h into
  the GTE (`f_8004f674`, at 80011AD8h) before drawing the world, then clears the low two bits of its
  nine halfwords. In the warp room: rotation rows of length 4096, 2560 and 4096; H 491, OFX 256,
  OFY 108.
- **Widescreen** (`mods/widescreen`): row 0 times 3/4 in that routine squeezes every view-space x,
  so every projected one; drawn for a 16:9 screen, a third more of the world shows on each side,
  Crash and Coco in proportion. The world renderer rejects a triangle only when all three corners
  are off one side of the screen (80041700h, against the bounds at +21Ch of its scratchpad block),
  which follows the squeeze. What is missing at the sides is a level's own — in the warp room the
  floor's edge at both bottom corners — which parts of a level are drawn at all comes with the
  camera's place on its path, made for 4:3.

## 2026-10-05: The pause menu, read for the resolution mod

START in the warp room (or a level) opens the status screen: the game view top left, the menu panel
under it, the progress panel on the right. The menu is GOOL, not native code, and its pieces are
GOOL objects (processes): the menu object, and one **text object** per line, which the menu
reuses from screen to screen — the pause menu's title (WARP ROOM) becomes OPTIONS' first line.
Found by hooking the text routine and dumping the objects it is handed, frame by frame, with a
scripted pad (`--pad-script 3400:START,3410:-,15400:START,15410:-,15500:DOWN,15510:-,15560:CROSS,
15570:-` reaches OPTIONS in the warp room); the run is the JS build of the mod (`gen --mods`).

- **Drawing.** The main loop (`f_8001166c`) ends each frame by walking a list of text objects
  (`*(*(s4+12) + 209Ch)`, nodes {next, object}) and calling `f_8001c824(object, strings,
  object[ECh] >> 8, *(s4+12) + 20h)` with the alignment on the stack (0 centred: flags 400h at
  +ACh). It picks string number a2 from the table a1 (strings from a1 + 12, NUL-separated), runs it
  through `sprintf` (80048120h) with arguments from the object's GOOL stack (+BCh minus 8..20), and
  draws it with `f_8001c3f8`, whose `~` codes set scale (`~sx800~`), offsets and colour. The menus'
  strings are the pause GOOL entry's: RESUME 30h, OPTIONS 31h, QUIT 32h, `# OPTIONS` 34h (`#` is the
  note glyph), `VIBRATION~x200~ON` 35h, `~sx800~<~sx400~CTR: %d~sx800~>` 36h, DONE 37h,
  `VIBRATION~x200~OFF` 38h; the table is in an NSF page, so its address moves with the level.
- **A text object:** +44h its menu, +60h/+64h/+68h its position (x, y, z; a line is 4096 below the
  one before: OPTIONS' lines at y -5120, -9216, ...), +28h..+3Ch six words of colours — four
  corners' RGB as halfwords, 1FFh full. A plain line is 008B00A0 00A00060 0060008B 006000A0
  00A00006 00060060 (beige); the chosen line alternates white (01FF01FF ...) and orange-red
  (019001FF 01FF0000 00000190 000001FF 01FF0000 00000000) every game frame: the menu writes them.
- **The menu object:** +E4h the chosen line times 256. OPTIONS is `# OPTIONS`, VIBRATION (only
  with a DualShock), CTR, DONE: DONE is line 2, or 3 with a DualShock. The mods' lines (`menu`:
  RESOLUTION, WIDESCREEN) go before DONE; the panel has room for a fifth line (the pause menu's QUIT stands at
  -21504), so with a DualShock's six the menu mod draws them closer together. The sound options
  behind `#` (STEREO, MUSIC VOL, FX VOL, DONE) end in the same DONE string, without a `# OPTIONS`
  line.
- **The panel's layout.** The pause menu's title (the level's name: WARP ROOM) stands a line above
  the first, at y -1024, orange over red — the colour words 019001FF 01FF0000 00000190 000001FF
  01FF0000 00000000, the chosen line's red frames — and RESUME, OPTIONS, QUIT are lines 2-4, the
  panel's last. The sound options use the line above too: STEREO at -1024, MUSIC VOL and its slider,
  FX VOL and its slider, DONE at -21504. The menu mod's panels (`Menu.panel`, and an option's
  choices: cross on RESOLUTION or WIDESCREEN) are laid out as the pause menu: the title at -1024 in those colours,
  the lines ending on line 4.
- **The font** has capitals only: a lower-case `p` in a line cut it short after the digits before
  it ("240p 240P" drew "24"). The panel holds about nine capitals between the arrows: "RES: 240P"
  fits, "RES 480P 192P 720P" ran off both sides.
- **The pad.** `f_80015798` reads the pads once a game frame (the game runs at 30 Hz: every second
  vblank; called from 8001D698h). Pad 0's record is at 80065BCCh: +28h the buttons held, +2Ch the
  frame before's, +24h the buttons **pressed** this frame (held and not before), which is what the
  menu reads — clearing a bit there after the routine and the menu never sees the press. The word's
  layout: the d-pad in the high byte (UP 1000h, RIGHT 2000h, DOWN 4000h, LEFT 8000h, START 800h,
  SELECT 100h), the shapes in the low one (TRIANGLE 10h, CIRCLE 20h, CROSS 40h, SQUARE 80h, L2 1,
  R2 2, L1 4, R1 8). +3Ch/+40h are the d-pad made a stick (a length 100h, a direction).
- **Sound.** None: the SPU's main volume is zero while the game is paused (the music sequencer
  goes on keying voices), so the menus move silently and the mods' lines need no sound of their own.
- **The frozen game.** Pausing, the game goes on drawing its world for ~10 game frames while the
  view slides and shrinks into the corner (the drawing offset walks from 512,12 to 412,-48; a fill
  of the 512x216 buffer, ~1,300-1,600 triangles and black bars a frame), then stops: from there each
  frame draws only the panels and text (234 triangles; 334 in OPTIONS) without a clear, over the
  last two pictures, one in each buffer. What decides it, in the game's state at 80068E98h (s3 in the
  main loop `f_8001166c`; s4 = 80061A78h, s5 = 800676B0h):
  - **Display flags.** The game asks for them at +70h; the end of every frame (`f_80016634`, at
    80016CACh) copies them to +84h, the ones in effect. Bit 0 has the main loop draw the world
    (`f_80040ed8` at 80011C04h, tested at 80011A88h with the zone list and 80065DD4h); 2000h and
    08000000h bring the fill and the objects with it. The pause screen's GOOL object asks for
    0C01FFFFh -> 0401DFFEh once, when the shrink ends (seen at 80038E28h, the interpreter, under the
    object pass `f_8001d16c`). Writing +84h does nothing: the end of the frame overwrites it.
  - **The shrink**, +184h, 0 to 8 (one step a game frame, then 0 when it ends). The end of every
    frame calls `f_80017834(shrink, the one before)` (the one before is gp+88h, gp = 80060878h): it
    puts the black bars around the view into the frame being finished (POLY_F4s added to the OT word
    at +201Ch of the frame being built, *80061A84h), writes the next frame's drawing offset into
    *80061A80h + 203Ch/203Eh (100 x shrink / 8 left, 60 x shrink / 8 up) and sets the projection
    for it (`f_8004f724`, base - base/24 x shrink, base from `f_80025c0c`; 491 -> 331 at 8).
  - **Objects** (GOOL) are a pool of 96 of 23Ch bytes allocated at boot, its address at 80068E9Ch
    (800204BCh), +0 1 for a live one, +44h the parent, +60h/+64h/+68h the position, +120h the
    kind. Kinds 6 and 7 are placed on the screen at x / 256 and -y / 256 (the text routine projects
    them through 8003C3D0h's 2D path); they do not follow the shrink. `f_8003f3ac` draws the
    frame's objects; the pause screen's panel glass is one of them.
  The menu mod draws the picture anew after a change of scale or shape by asking for both again for
  four frames, two pictures of each buffer (`Menu.redrawWorld`): with the texts and screen
  objects moved back by the shrink's offset and `f_80017834` split at the first and last call, the
  last two frames are the same VRAM as the pause screen's last two (0 pixels differ in each buffer,
  software); in the browser the view after 240P -> 480P is the same picture as a pause opened at
  480P. One picture a buffer was not enough on the Dreamcast: the first frame of the world after the
  menu's drew Crash without his shadow (its 4-bit page, unsampled through the menu's frames), and
  the buffers flickered between the two. The pad routine is called at
  8001D698h, from a routine handed an object (its flags at +100h), not from the main loop itself.

## 2026-09-28: The memory card was "not inserted" — libcard stubs only the warp overlay calls

LOAD GAME answered "MEMORY CARD IS NOT INSERTED IN MEMORY CARD SLOT 1." on every target. The game
drives its pad on SIO0 itself, but its cards through the BIOS (libcard): InitCARD2 and StartCARD2
at boot, then from the warp overlay's save screens `_bu_init`, `_card_info` (A0 ABh), `_new_card`,
`_card_write`, `_card_read` and `_card_load` (A0 ACh). The wrappers for `_card_info` and
`_card_load` are three-instruction BIOS stubs in the executable at 0x8005B618 and 0x8005B628
(`addiu $t2, $zero, 0xA0; jr $t2; addiu $t1, $zero, 0xAB`), after padding and with no prologue,
and nothing in the executable calls them: only the overlay does. The base pass never traced them,
so the overlay's `jal` found no function ("no function at 0x8005b618, ra=0x8006fb0c") and the game
took the missing answer for an empty slot. Fixed in the tool, for every game: an overlay's `jal`
targets in the executable that the base pass left unclaimed are fed back to it as seeds
(`Main.calledFromOverlays`; tools/recomp test "an executable function only an overlay calls").
Crash 3 gains 16 functions (1025 -> 1041) and Crash Bash 8 (1026 -> 1034). Measured headless with a
scripted pad (DOWN, CROSS on the title menu at frame ~3650): READING MEMORY CARD DIRECTORY, then
LOAD GAME with four EMPTY slots. Digests without input are unchanged (Crash 3 9000 `4de78425`,
Crash Bash 3000 `db892c4b`): nothing reaches those calls until a card screen opens.

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
