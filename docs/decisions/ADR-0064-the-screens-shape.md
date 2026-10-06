# ADR-0064: The screen's shape — 16:9 and STRETCH as the console's, a program's wide pictures, Crash 3's WIDE line
Status: accepted   Date: 2026-10-06
Asked for by the project owner: a 16:9 option in the HLE BIOS, offered in Crash Bandicoot: Warped's
OPTIONS too, through an API games use to turn widescreen on and off ("HLE Bios'a 16:9 seçeneği ekle
ve onuda crash 3 seçeneği olacak ekle. Oyunlar bu API'yi kullanarak widescreen kapatıp
açabilecek"); Crash 3's mods made three packages — a menu manager, the resolution, the widescreen
("bir menü yönetici modu, çözünürlük modu, widescreen modu olacak şekilde 3 paket"); the Dreamcast
showing it as its own widescreen games did ("dreamcast backend içinde widescreen desteği ekle
sanırım bazı oyunlar destekliyormuş resmi olarak"); and a stretch beside 16:9 ("Stretch mümkün mü
16:9'un yanında ayrıca").

## Context

The PlayStation's picture is 4:3 at every resolution (256 to 640 pixels across the same width).
Widescreen on its successors was the game's: a 16:9 option in its menu, the picture drawn
anamorphic — the horizontal squeezed by 3/4 — and a 16:9 television stretching it back. The
Dreamcast's few widescreen games (Rayman 2 has a 16:9 option) are the same: the console sends a
640x480 frame whatever the game draws, and a 16:9 set stretches it. A game that knew nothing of it
was shown stretched too, unless the set was switched back.

Two backends present the picture on a screen of their own choosing: the browser (an element of any
shape) and SDL2 (a window); the Dreamcast's screen is a television's frame. ADR-0056 made the
picture's resolution the console's (`kernel.KVideo`), and ADR-0060 its programs' way in (PS1 Pro
system calls). The shape belongs beside them.

Crash 3's projection: each frame the camera's update (`f_80018a54`) builds the camera's rotation
from its angles (80065C90h) and hands it to `f_80018988`, which makes the matrix the world and the
objects are projected with (80065CB0h): row 0 copied, row 1 times -5/8 — the game's own aspect
correction for its 512-wide pixels — row 2 negated, the translation (the camera's place in the
world, which the renderers subtract before rotating) copied. One routine, called from one place,
whose rows are every view-space coordinate (games/SCUS94244/notes.md, "The camera's aspect").

## Decision

- **The screen's shape is the console's**, `video.wide` in `system.cfg`: 0 4:3, 1 16:9, 2 STRETCH (a
  16:9 screen with every picture stretched over it), kept across sessions and shared by every
  program like the scale (`kernel.KVideo.shape`). A backend that can show a 16:9 screen says so
  (`BP_CAP_WIDESCREEN`, 10); elsewhere the shape stays 4:3 and nothing is kept.
- **A program says what it draws for.** Every program's pictures are drawn for 4:3 until it says
  otherwise (`KVideo.widePicture`, reset at launch). On 16:9 a picture drawn for 4:3 is shown at 4:3
  in the middle of the screen, between black bars — a game that knows nothing of widescreen is never
  stretched — and one drawn for 16:9 fills it. On STRETCH every picture fills the screen, which is
  what a player who asked for it wants of a 4:3 game; a program draws for 16:9 only on 16:9.
- **PS1 Pro calls** (ADR-0060), the video family: GetWidescreen (50524F14h, the shape), SetWidescreen
  (50524F15h, `$a1` the shape, kept; `$v0` the shape now, 0 where 16:9 cannot be shown) — what a menu
  offers — and SetWidePicture (50524F16h, `$a1` 1 or 0; `$v0` 1 when its wide pictures are shown on a
  16:9 screen). A program that supports it: `if (GetWidescreen() == 1) { squeeze; SetWidePicture(1); }`.
- **ABI**: the scanout passes the shape with every present — `BP_PRESENT_WIDE` (64), the screen is
  16:9, and `BP_PRESENT_WIDE_FILL` (128), the picture fills it (drawn for it, or STRETCH). The
  browser makes its element 16:9 and keeps a 4:3 picture's canvas to the middle three quarters (the
  pointer is read over that canvas); SDL2 letterboxes a filling picture at 16:9 in its window; the
  Dreamcast fills the 640x480 frame, as its own widescreen games did — a 16:9 television stretches
  it — and draws a 4:3 picture into the middle 480 pixels (the pictures' screen scene and a film's
  background quad; the pointer moves over that band). Null and JVM answer 0. A held picture
  (HoldPicture) keeps its shape until the next one is shown.
- **Crash 3's mods are three packages**, the two lines each needing the third — a mod may now name
  the mods it builds on (`needs` in mod.json, ADR-0033; `gen --mods` brings them along, each before
  the mods that need it):
  - `menu` — the pause screen's menu for every mod: a mod says what it offers and what a choice
    does, and the menu mod draws and steers it, so every mod's lines look and move alike (the
    owner's direction: "yeni paneller ekleme, yeni seçenekler ekleme gibi şeyleri de menü moduna
    taşı oradan genel yönetelim"). `Menu.option(panel, title, choices, current, choose)` is a button,
    as the game's own ♫ OPTIONS is: a line with the option's title that cross opens — its choices,
    offered by its mod once a boot, as a panel under that title on the one in effect, where cross
    picks one (the owner: "res'e tıklayınca menü açılsa ve çözünürlük seçsek olmaz mı?", then
    "Resolution Options gibi buton olsun basınca seçelim widescreen'de aynı şekilde"; an earlier
    cut drew it `< RES: 240P >` with left and right stepping, which the button replaced).
    `Menu.panel(title)` is a screen of a mod's own and `Menu.link(panel, name, to)` a line that
    opens one: panels are laid out as the pause menu lays out its own — the title where the level's
    name stands, in its colours, the lines on the panel's last ones where RESUME, OPTIONS and QUIT
    stand, DONE below a mod's, five at a time of more, moving with the choice — and shown in place
    of OPTIONS' lines; up and down move, cross picks, opens or goes back on DONE, triangle goes back,
    and the game hears none of it. `Menu.OPTIONS` is the game's own: the mods' lines go before its
    DONE, drawn as copies of DONE's text object and steered through the pressed buttons the menu
    reads. `Menu.redraw()` has the game draw the pause screen's frozen picture anew (ADR-0056's
    redraw, moved here whole); `menu.Pro` makes the PS1 Pro calls as the game's `syscall` would.
    With a DualShock's VIBRATION, OPTIONS has six lines where the panel holds five at the game's
    spacing: they are drawn closer together.
  - `resolution` — RESOLUTION (ADR-0056), an option: its choices (240P, 480P, 720P — one per number
    of lines the console draws), the one in effect and what a choice sets.
  - `widescreen` — WIDESCREEN, an option: `4:3`, `16:9`, `STRETCH`. On 16:9 the game draws for it:
    its aspect routine scales row 0 by 3/4 as well, so every view-space x — every projected one,
    and what the game culls against its view — is three quarters as far from the centre, and the
    game shows a third more of its world on each side. What faces the screen is squeezed where it
    is drawn, since none of it goes through the camera's matrix: sprites, the world's billboards
    (wumpa fruit) and the screen's own objects (the HUD's icons) through one matrix of their own
    (80041FD8h), whose row 0 times 3/4 narrows each about its own place; the screen's objects are
    placed from their x (8003E67Ch), times 3/4 toward the middle; texts are glyphs the text routine
    projects itself (8001C3F8h), and the polygons it writes are narrowed toward the middle after it.
    The HUD keeps its 4:3 places, in the middle three quarters of the screen, at its proportions.
    The pause screen is 4:3: its view is the world shrunk into a corner with its panels laid out
    around it, so while it is up — the shrink running (8006901Ch), or settled with neither the world
    nor the objects drawn (the title screen draws objects) — nothing is squeezed and its pictures
    are said to be 4:3, shown in the middle of the screen; a change of shape draws nothing anew.
    The pictures are said to be 16:9 while the camera's update runs (its main loop) and the pause
    screen is not up, and 4:3 otherwise: loading screens and films are kept to the middle.

## Alternatives

- **The shape as the program's alone** (SetWidescreen turning the presentation on for the program
  that asked). Every game would ask again at every boot, and a game that knows nothing of it could
  not be shown on a 16:9 screen at all — the console's setting and the pillarbox give both.
- **The console's 16:9 stretching every program** (the setting alone, as a television's). A game
  that knows nothing of it would be stretched; that is STRETCH, offered as a choice, not imposed.
- **Squeezing in the GTE** (a PS1 Pro GTE projecting at 3/4 for every program, as some emulators'
  widescreen hacks do). One switch for every game, but RTPS/RTPT are the hottest code there is on
  the Dreamcast, a game's own uses of the projection (sizes from depth, picking) would be squeezed
  behind its back, and its 2D not at all. A game's mod knows where its projection is — Crash 3's is
  one routine, already its aspect correction.
- **Letterboxing on the Dreamcast** (a 16:9 picture shown at 640x360 for a 4:3 television). Not
  what its own widescreen games did; the 16:9 screen is a 16:9 television's.
- **Hor- widescreen** (the vertical cut instead: row 1 times 4/3, the picture's top and bottom
  cropped). Nothing at the sides would be missing, but it shows less, not more, and draws a quarter
  of its lines for nothing.

## Consequences

- Digests are untouched: a headless run has no backend that shows 16:9 (null, Node), reads no
  setting and never squeezes; Crash 3 at 5000 is 52875c77 with the three mods.
- What Crash 3 draws at 16:9 that it never drew at 4:3: which of a level's polygons are drawn at all
  comes with the camera's place on its path. The world renderer (`f_80040ed8`) draws a list of
  polygons the game keeps for that place (*80060AA4h: a count, then halfwords of world, type and
  index), each sorted into the OT by its depth, with no backface test of its own: the list is what
  the 4:3 view saw, front faces only. So at the sides a polygon the 4:3 view never had can be
  missing — in the warp room the platform's edge at the bottom left (595 of its two worlds' 2,500 or
  more polygons are listed); none showed in Toad Village's demo. Adding polygons to the list is
  possible, but which: each needs a test for facing, place and cover that the list made unnecessary,
  every frame on the console that has the least time for it. It is the game's data, not the
  console's.
- A 16:9 picture is shown at the PlayStation's resolution stretched: no pixels are added across,
  as on a 16:9 television; RES adds them both ways.
- The Dreamcast's direct path (primitives drawn straight onto the screen, for a picture the
  pictures cannot hold) fills the screen whatever the shape: pillarboxing it would move the
  primitives' transform, the hottest of its code, for a fallback.
- Verified: conformance `ProCalls` (the calls where nothing shows 16:9) JS = C++, the 69 tests on
  JavaScript; tool test "a mod brings the mods it needs"; Crash 3 headless on JavaScript with the
  capability forced on — WIDE from 4:3 to 16:9, STRETCH and back in OPTIONS, the frozen picture drawn
  anew each time (squeezed, then not, then squeezed), the scanout's flags (16:9 filling while the
  camera runs), gameplay after resuming at 16:9, six lines with a DualShock drawn closer in the
  panel. The choices' panels, the same way with the scale forced on as well: RES's and WIDE's opened
  on the choice in effect, a pick of 480P (200 %) and of 16:9 kept and the picture drawn anew,
  triangle going back as it was, a DualShock's six lines, START from an open panel resuming the game
  and OPTIONS coming back without it — the same VRAM, frame for frame, before and after the menu mod
  became the framework; the options as buttons (RESOLUTION, WIDESCREEN; right on one does nothing,
  cross opens it, a pick of 480P and of STRETCH); and, with a scratch mod in that build only,
  a link in OPTIONS to a panel of options and a link to a deeper one (a link to a panel with nothing
  to show left out), left and right in a panel, a choice of seven shown five at a time, DONE and
  triangle back to where each was opened. What faces the screen, on JavaScript with 16:9 kept from
  the boot: the title's NEW GAME and LOAD GAME, the demo's HUD (the fruit's icon and count, Crash's
  head and lives), DEMO and the wumpa fruit in the air at their proportions, the HUD in the middle
  three quarters, the fades whole; the pause screen 4:3 from its first shrinking frame to the last
  of its growing back (vblanks 15405-15737), its view and panels as at 4:3. The browser: a boot on a kept 16:9
  screen kept to its middle (the element 16:9, the canvas
  three quarters of it) until the game's camera, then filled; STRETCH in OPTIONS. The Dreamcast
  (Flycast's fork): the same changes in OPTIONS, a second boot on the 16:9 kept in the VMU — every
  logo of Crash 3's (Universal's globe, Naughty Dog's crate, the title) is drawn through its camera
  and fills the frame; Crash Bash, which knows nothing of it, given that VMU: its logos in the middle
  480 pixels between black bars.
