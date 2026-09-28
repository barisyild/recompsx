# ADR-0038: The host's mouse as a pointer over the picture — an HLE kernel service
Status: accepted   Date: 2026-09-28
Direction set by the project owner: menus chosen with the mouse, the mouse a kernel service beside
the keyboard's (ADR-0036), backends wherever the platform has one.

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
began and ended between two polls is reported held for the second. A backend whose host draws no
pointer (a console) draws one; one whose host would act on a button (a browser's context menu,
its Back and Forward) keeps it from the host.

**Kernel** (`kernel.KMouse`): sampled once per vblank after the pads, like the keyboard; the
fractions become pixels of the display the game has set up (`gpu.Scanout`), so readers work in
the pixels the game draws in. Moves and presses are **counted from boot**: a reader keeps the
counts it last saw, and a different count is a move or a click since then — nothing is taken from
another reader and nothing is missed between a reader's frames. A headless digest run has no
mouse, as it has no controllers.

**Mods** reach it through `ModHost.mouseOver`/`mouseX`/`mouseY`/`pictureWidth`/`pictureHeight`/
`mouseHeld`/`mouseClicks`/`mouseMoves`, and `isModMemory` to tell a mod's screen from the game's.

**Backends:** SDL2 — the letterbox rectangle kept from `bp_present`, window points scaled to
renderer pixels, X1/X2 as the side buttons. Browser — pointer events over the page's picture
element (`recompsxHost.screen`), fractions worked out in plain JavaScript so no float reaches
Haxe, the context menu and the history buttons suppressed over it. Dreamcast — a maple mouse
integrated on the 640 x 480 screen the picture fills, and an arrow drawn as the last thing in
each scene. Null, JVM and Node have none.

**Crash Bash** (the first reader): `mods/onlinemenu` drives its own screens directly (the main
menu with ONLINE, the address keyboard); `mods/mouse` drives the game's own screens by **writing
the index each keeps** — the line of a list, CHARACTER SELECT's portrait, CHOOSE LEVEL's level —
playing the move sound, and adding cross for a click after the game's pad reader, so each
screen's handler draws and takes it as its own (games/SCUS94570/notes.md, "The mouse in the
menus"). A first version pressed its way there a step a frame; the owner found it slow — a
character at the far end of the ring took several slides — and a choice is an index, so stepping
is now only the fallback for lists not yet reverse engineered.

## Alternatives

- **The PS1 mouse on SIO0.** Helps only games written for it, which Crash Bash is not. It stays
  possible — the kernel's counts and pixels are what a controller-port mouse would report — for
  the games that are.
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
- Verified: conformance `Mouse` `adc65922` on JS and reflaxe.CPP; a scripted headless walk with
  both mods (main menu, OPTIONS in slot 4 and back, the Adventure submenu, the side button), and
  one through CHARACTER SELECT (portrait 7 to 2, click) and CHOOSE LEVEL (level 0 to 2, click,
  the match starts); the
  main menu and the address keyboard with a real mouse in the browser; the SDL2 and Dreamcast code
  compile clean; with only this change applied, Crash Bash's digests are unchanged (3000
  `654669df`, 9000 `fda4764f`).
