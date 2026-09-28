# ADR-0038: The host's mouse as a pointer over the picture — an HLE kernel service
Status: accepted; its kernel service and mod API superseded-by-0040   Date: 2026-09-28
Direction set by the project owner: menus chosen with the mouse, the mouse a kernel service beside
the keyboard's (ADR-0036), backends wherever the platform has one.

**Since ADR-0040** a mod reads the machine's own mouse — a Sony Mouse (SCPH-1030) on a controller
port of the mod's, the motion since its last read and two buttons — and `ModHost.enableMouse`,
`mouseOver`/`X`/`Y`/`Held`/`Clicks`/`Moves` and `pictureWidth`/`Height` are gone: the machine's
pointer shows while that mouse is polled, not once a mod enables it. The backend ABI, the
pointer's three states, the pad rule, the backends and Crash Bash's menus stay as below.

## Context

The PS1 had a mouse of its own (SCPH-1030): a controller-port device that reports motion to the
few games written for it. Crash Bash is not one of them, and neither are most games. What a
recompiled game needs is different: a pointer over the picture it draws, so that a mod can make
its menus answer to it the way a PC port's would — point at a line to select it, click to choose,
the side button to go back.

Three facts shaped the design. The picture ends up in very different places — a letterboxed SDL
window (at two pixels to a point on a high-DPI display), a CSS box in a page, a 640 x 480 PVR
screen — and none of those is the emulated display's size. Readers run at the game's rate, often
every other vblank, and a click can begin and end inside one. And more than one mod may watch the
same mouse.

## Decision

**Backend ABI** (`bp_mouse(field)`, latched by `bp_input_poll` with the pads):
`BP_MOUSE_OVER` (a mouse exists and the pointer is over the picture), `BP_MOUSE_X`/`_Y` as
fractions of the picture, 0..65535 — a backend knows where it put the picture and nothing about
the emulated display — and `BP_MOUSE_BUTTONS` (left, right, middle, back, forward). A press that
began and ended between two polls is reported held for the second. The pointer the machine shows
comes and goes by `bp_mouse_pointer` (below); a backend whose host would act on a button (a
browser's context menu, its Back and Forward) keeps it from the host while there is one.

**The machine has a pointer only once a mod turns the mouse on** (the owner's call, the same
day): `ModHost.enableMouse`, which a mod calls when it installs. The pointer then shows in any
game a mod drives with the mouse — what the mouse does is the mod's — and in none that nothing
does; until then readers see no pointer, though the mouse is read all along. `bp_mouse_pointer`
carries three states: off (the start — a host with a cursor of its own shows that, as over any
window; a console nothing), shown (the machine's pointer: the art of
`src/backend/api/pointer_art.h`), and hidden.

**The pointer hides while a pad is in use** (the owner's call): a pad button pressed hides it
and the mouse moving or clicking shows it again. The rule is the kernel's, one for every target
(`KMouse.showOrHide`, from the pads it has just latched); the backends only carry out the hidden
state — the Dreamcast stops drawing its arrow, SDL2 shows no cursor, the page sets `cursor: none`
over the picture. While hidden, readers see no pointer.

**Kernel** (`kernel.KMouse`): sampled once per vblank after the pads, like the keyboard; the
fractions become pixels of the display the game has set up (`gpu.Scanout`), so readers work in
the pixels the game draws in. Moves and presses are **counted from boot**: a reader keeps the
counts it last saw, and a different count is a move or a click since then — nothing is taken from
another reader and nothing is missed between a reader's frames. A headless digest run has no
mouse, as it has no controllers.

**Mods** turn it on with `ModHost.enableMouse` and read it through `ModHost.mouseOver`/`mouseX`/
`mouseY`/`pictureWidth`/`pictureHeight`/`mouseHeld`/`mouseClicks`/`mouseMoves`, and
`isModMemory` to tell a mod's screen from the game's.

**Backends:** SDL2 — the letterbox rectangle kept from `bp_present`, window points scaled to
renderer pixels, X1/X2 as the side buttons; the pointer is the host's cursor, the art as a colour
cursor while shown and the system's own while off. Browser — pointer events over the page's
picture element (`recompsxHost.screen`), fractions worked out in plain JavaScript so no float
reaches Haxe, the context menu and the history buttons suppressed over it while the machine has a
pointer, which is the class `pointer` whose CSS cursor is the art (1x and 2x PNGs). Dreamcast — a
maple mouse integrated on the 640 x 480 screen the picture fills, and the pointer drawn as the
last thing in each scene: a 16 x 24 pixel-art arrow the owner chose, kept as a letter grid in
`pointer_art.h`, uploaded once as an ARGB1555 texture and drawn a texel to a pixel at the
console's own 640 x 480, so it stays sharp at any game resolution. KallistiOS keeps only the last bus frame's motion while the emulator polls below 60
frames a second, so a vblank handler adds every frame's motion up (and zeroes what it took); and a
maple keyboard is pad 0 too, with the desktop's map, as it is on the other targets. Null, JVM and
Node have none.

In Flycast a Dreamcast mouse or keyboard hears the host's only when the host device is assigned
to the same maple port as the Dreamcast device (Controls: the physical Mouse or Keyboard's port
must be the Mouse or Keyboard port's letter): the host mouse writes its motion into its own
port's state and the Dreamcast mouse reads its port's, so a mismatch shows the arrow but never
moves it.

**Crash Bash** (the first reader): `mods/onlinemenu` drives its own screens directly (the main
menu with ONLINE, the address keyboard); `mods/mouse` drives the game's own screens by **writing
the index each keeps** — the line of a list, CHARACTER SELECT's portrait, CHOOSE LEVEL's level —
playing the move sound, and adding cross for a click after the game's pad reader, so each
screen's handler draws and takes it as its own (games/SCUS94570/notes.md, "The mouse in the
menus"). A first version pressed its way there a step a frame; the owner found it slow — a
character at the far end of the ring took several slides — and a choice is an index, so stepping
is now only the fallback for lists not yet reverse engineered. The menus in play — PAUSED, its
OPTIONS, the questions with YES and NO on one row — are the boot overlay's own: it draws the
current one every frame from a definition, so `mods/mouse` measures it there, each line's letters
where the drawer puts them, writes the line chosen, and clicks with the cross of the player whose
pad drives the menu; back is triangle, or start on PAUSED, which resumes.

## Alternatives

- **The PS1 mouse on SIO0.** Helps only games written for it, which Crash Bash is not. It stays
  possible — the kernel's counts and pixels are what a controller-port mouse would report — for
  the games that are. The owner asked whether the PS1's own mouse and keyboard could replace the
  HLE services: the kernel has no mouse or keyboard function (OpenBIOS's pad driver reads whatever
  is in a controller port and hands its bytes to the game); the Sony Mouse (SCPH-1030, psx-spx
  "Controllers - Mouse") is such a device, 5A12h — two buttons and each poll's motion, which some
  fifty games read through the ordinary pad calls and draw their own cursor for; there is no
  official keyboard (psx-spx "Controllers - Keyboards"), and the only text input the kernel has
  is the development board's TTY. Neither gives a mod a pointer over the picture or text by the
  host's layout, so the services stay; the Sony Mouse, fed by the same host mouse, would be an
  addition for the games written for it.
- **Pixels from the backend.** Every backend would have to know the emulated display's size and
  follow its mode changes; a fraction needs neither.
- **A click queue.** One reader takes an event from another; counters let any number watch.
- **A guest-callable BIOS function** (a new B0 entry). Nothing in a game calls it and mods are
  Haxe; one can be added when MIPS code — a patch, homebrew — needs the pointer.

## Consequences

- The ABI grows by one function; `scripts/check.sh` holds every backend to it.
- On the Dreamcast a bus frame of motion the emulator did not poll for is not seen, so the pointer
  slows when the game runs below 60 frames a second.
- A mod turns display pixels into its game's units itself (Crash Bash's menus: 640 x 480 centred
  on the screen).
- A game no mod turns the mouse on for shows no pointer and reads none; "off" leaves a host's own
  cursor as it is over any window.
- Verified: conformance `Mouse` `adc65922` on JS and reflaxe.CPP, `b0789b91` with the enable rule
  and the pointer's states; a scripted headless walk with
  both mods (main menu, OPTIONS in slot 4 and back, the Adventure submenu, the side button), one
  through CHARACTER SELECT (portrait 7 to 2, click) and CHOOSE LEVEL (level 0 to 2, click, the
  match starts), and one through a battle's PAUSED (QUIT GAME, the question's YES and NO, OPTIONS
  and back with the right button, CONTINUE; the right button on PAUSED resumes); the
  main menu and the address keyboard with a real mouse in the browser; the SDL2 and Dreamcast code
  compile clean; with only this change applied, Crash Bash's digests are unchanged (3000
  `654669df`, 9000 `fda4764f`).
