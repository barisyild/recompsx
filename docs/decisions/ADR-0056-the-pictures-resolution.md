# ADR-0056: The picture's resolution — a console setting, a scale for the backends, a line in Crash 3's OPTIONS
Status: accepted   Date: 2026-10-05
Asked for by the project owner: a resolution option in Crash Bandicoot: Warped's OPTIONS menu, its
values multipliers — 1 the PlayStation's own, 2 and 3 higher ("1,2,3 gibi değerler olacak bunlar
çarpan 1 native olacak"); a lower one came and went — 0.5, then 0.8, then none ("192p olmayacak").
The line says the resolution, not the multiplier ("1x değilde direkt çözünürlük yazsın ... 240p
yazsın"), while what is kept stays a multiplier ("veri çarpan olacak yine ama text pixel tarzında
olacak"). Pointed at Crash Bash's
onlinemenu mod as the model. How a program reaches it is ADR-0060: a PS1 Pro system call.

## Context

Two backends draw the PlayStation's primitives themselves (BP_CAP_GPU_DRAW): the browser's WebGL2
renderer and the Dreamcast's PVR. Both drew at one fixed resolution: the browser at the
PlayStation's (fbTex is VRAM's 1024x512), the Dreamcast at its screen's 640x480 (ADR-0055). Nothing
asked a backend to draw at another, and nothing in the runtime knew a resolution beyond VRAM's.

A resolution is not the machine's: the PlayStation never had one to choose, and a game cannot see
it — VRAM, the digest and everything a game reads are the same at any scale. It is the console's,
as the network address is (ADR-0034): one choice for every game, kept across sessions, and the HLE
kernel's ("PS1 Pro").

Crash 3's menus are GOOL, not code: the pause screen's menu is a GOOL object with one text object
per line, so there is no list of records to lengthen as there was for Crash Bash (ADR-0033's first
mod). How the menu works is in games/SCUS94244/notes.md, "The pause menu".

## Decision

- **A console setting**, `video.scale` in `system.cfg`, kept as a multiplier: "1", "2", "3"
  (`kernel.KVideo`, in percent of the PlayStation's resolution: 100, 200, 300; it reads 0.25 to 4,
  and a program may set any of that — the menu's choices are the program's). The launcher boots it once it knows how the picture is drawn (`KVideo.boot`): the kept scale,
  or the backend's own. A program reads and changes it through the PS1 Pro system calls (ADR-0060:
  GetVideoScale, SetVideoScale, GetVideoLines); the kernel keeps it and hands it to the backend.
- **ABI**: `bp_gpu_scale(percent)` — draw from the next primitive on at that scale, keeping the
  picture so far; `BP_CAP_GPU_SCALE` (8) — the scale a backend draws at until told, in percent, 0 if
  it cannot scale; `BP_CAP_GPU_LINES` (9) — the most lines it draws a picture at, 0 for no limit. A
  backend draws at what it is told or at the most it can. SDL2 and null answer 0 (SDL2 is handed
  the finished picture); JVM likewise.
- **What a resolution is called is its lines**: the display's own (240, or 480 interlaced) times the
  scale, held to BP_CAP_GPU_LINES — GetVideoLines. A menu names a choice by them ("RES: 240P") and
  offers a scale only where it draws lines no other offered scale draws.
- **The browser** draws at any of them: fbTex, its depth and the copy's scratch become VRAM's size
  times the scale, rounded (819x410 at 0.8, 3072x1536 at 3), made anew with their contents carried
  over, and the canvas is the display's pixels times the scale. Coordinates stay VRAM's (the vertex
  shader maps VRAM onto the target whatever its size); only the viewport, the scissor and a copy's
  texels count target pixels, at each axis's own rounded scale. A drawn tile read back into vramTex
  takes the target pixel at the VRAM pixel's centre: what a game draws and then samples is sampled at
  the PlayStation's resolution. No limit of lines of its own.
- **The Dreamcast** draws a picture at the screen's 640x480 from 2 up — exactly ADR-0055's picture,
  for every buffer size, and its own scale (BP_CAP_GPU_SCALE 200), so nothing changes until a scale
  is set — and below 2 at its buffer's size times the scale, rounded: 1 512x240, 0.8 410x192 for
  Crash 3's 512x240 buffers. Its limit is the screen's 480 lines (BP_CAP_GPU_LINES), so 3 is 480
  lines as 2 is. A smaller picture is rendered into the same memory, its rows still 640 apart, and
  the screen shows it stretched through RECOMPSX_DC_FILTER (bilinear); at the screen's size it is
  shown 1:1 as before. Each picture is declared at the next powers of two of its own size (512x256;
  1024x512 at the screen's): that is the texture Flycast keeps a render to texture as, and it
  matches a read by size — declared 1024x512, a 512x240 render was read as whatever the memory held
  before (the old 640x480 picture, magnified). On a console the declared size only scales the
  coordinates. A new scale takes effect at the next present: the picture on screen is drawn at the
  new size into the other picture's memory and back (two renders, never one in place, which would
  read tiles already written when it grows), so what a frame does not redraw — the pause's frozen
  game — survives it; the headers kept for a picture's memory are forgotten when its declared size
  changes (`hdr_forget`).
- **Crash 3** (`games/SCUS94244/mods/resolution`; since ADR-0064 a line of the `menu` mod, which
  draws, steers and redraws for it — the words and the change are all that stayed here): RES, a line before DONE in OPTIONS on the pause
  screen — `<RES: 240P>` in the game's own font and arrows (capitals: the font has no others),
  chosen with left and right among 1, 2 and 3 as the console draws them (the browser 240P, 480P,
  720P; a console that cannot scale 240P alone) — since ADR-0064 a button, RESOLUTION, whose cross
  opens them as a panel — nothing below the PlayStation's own, which a 0.8
  (192P) offered for a while and the owner took out. The list is fixed by the build ("compile if
  ile", the owner): a Dreamcast tree is transpiled with `-D dreamcast` and lists 1 and 2 — 240P and
  480P, the most its screen shows — and every other build 1, 2, 3 (ADR-0033: the console's name is a
  mod's, never the runtime's). The line starts at the console's own: 240P in the browser, the
  Dreamcast's 480P ("dreamcast'te default çözünürlük konsolun çözünürlüğü"), until a choice is kept. It makes
  the calls a game would (ADR-0060). It draws RES as a copy of DONE's text object with a string
  table of its own, then DONE a line lower; it steers the pressed buttons the menu reads (pad 0's
  +24h, after the pad routine) so that the game's choice stays on DONE while RES is the player's;
  and it draws RES in the colours the game gave DONE (the blinking highlight) and DONE plain. No
  GOOL bytecode is touched.
- **The pause screen's picture is drawn anew** at the new scale, by the game (the owner: "pause
  tetikleyen yeri bulursan aslında tekrar yaratman kolay olur"). The frozen view is the last two
  pictures Crash 3 drew of its world while the view shrank into the corner; after a change the mod
  asks for the world and the settled shrink again for four frames, two pictures of each buffer
  (the display flags at 80068F08h, the shrink at 8006901Ch), and then for what it found. The texts
  and screen objects the game never draws under the shrink are moved back for those frames, and the
  routine that applies the shrink (bars into one frame, offset and projection into the next) is split
  at the first and last. The last two frames are the pause screen's last two to the pixel — the view
  inside its black bars, which the owner saw as the menu going black for a frame — so the mod holds
  the picture on screen meanwhile (HoldPicture, ADR-0060): the old picture stays up until the menu is
  drawn over both new ones. Two pictures a buffer, not one: on the Dreamcast the first frame of the
  world after the menu's drew Crash without his shadow, so one buffer had it and one did not, a
  30 Hz flicker behind the menu; the second follows a frame of the world, as the pause screen's own
  last frames did. It is the mod's, so every backend that scales gets it; the Dreamcast's own part is
  the hold (a held present renders its records into the pictures and builds no screen scene). A
  generic alternative — a renderer that keeps each buffer's last full frame and replays it at the
  new scale — was weighed and not built: exact for any game, but per backend, and on the Dreamcast
  a frame's records copied every frame or ~1.5 MB more RAM.

## Alternatives

- **The scale in the game's own options, as a game setting.** A game's save is its own format;
  and the scale is the console's, the same for every game — the next game's menu (or a BIOS menu)
  shows the same value.
- **Patching the GOOL menu's bytecode** (a fifth line the game itself knows). GOOL is data, so it
  could be done, but the menu's code would have to be decompiled and written back per NSF page
  (42 copies, one per level), for a line the native hooks give without it.
- **The multiplier on the line ("1X").** The owner's call: the line says the resolution. The
  multiplier is what is kept, since it means the same in every display mode.
- **Halves of the PlayStation's resolution as the unit** (the first cut). 0.8 is not one; percent
  holds every multiplier a menu is likely to offer.
- **A resolution as a width and height.** The games change modes (320, 368, 512 wide; 240 or 480
  high); a multiplier of the PlayStation's own means the same in every mode.
- **Rescaling a Dreamcast picture in place.** Shrinking reads only tiles not yet written (KOS's tile
  order runs down columns), but growing reads ones already written; two renders through the other
  picture's memory are safe either way and cost nothing outside a change.

## Consequences

- The digest is untouched: a headless run draws in software, reads no settings and never calls
  `bp_gpu_scale`; the mod is transparent until OPTIONS is opened (Crash 3 at 5000 52875c77, with and
  without the mod).
- What a frame does not redraw keeps the resolution it was drawn at (the browser carries it over
  nearest-texel, the Dreamcast through its renders) until the game draws it again. Crash 3's pause
  screen is drawn again by its mod (above); another game's frozen picture keeps the old scale.
- The redraw changes what the game runs while it is paused (four frames of its world, as its own
  pause opening ran them), only after a change of scale — a digest run never makes one, and
  Crash 3 at 5000 is unchanged. The screen stands still for sixteen vblanks (a quarter of a second)
  after the change, then shows the new picture whole: the redraw's four frames, the menu's over
  both buffers, and a game frame in hand — a hold that ended just as the first whole picture came
  up let one frame of the bars through when a frame ran a vblank late (the owner saw it).
- Memory: the browser's targets at 3 are ~75 MB of GPU memory (four 3072x1536 textures); the
  Dreamcast's pictures keep ADR-0055's memories (a smaller picture uses part of its 640-pixel rows).
- The Dreamcast at 1 draws less: two-fifths of 640x480's pixels for 512x240 buffers. What that buys
  on a console is the console's to measure (`pvr-wait`).
- Verified: conformance `VideoScale` (the setting's format, the lines) and `ProCalls` JS = C++; the
  mod headless on JavaScript (where nothing scales: one value, RES: 240P; both pad kinds; the sound
  options show none); the browser in the pane (`?arg=--pad-script`, the line going 240P, 480P, 720P,
  480P, 240P and stopping there, with fbTex read back at each); the Dreamcast in
  Flycast's fork (`--dc-shots`; a long `--pad-script` split over several lines, since a RECOMPSX.CFG
  line holds 127 characters) with the halves version: 2, 1 and the lower scale from the menu with the
  frozen game kept and rescaled, gameplay after resuming, the value kept on the second visit.
