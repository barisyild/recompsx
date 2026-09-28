# ADR-0041: QUIT — back to the host's own menu
Status: accepted   Date: 2026-09-28
Direction set by the project owner: a QUIT line at the bottom of Crash Bash's main menu, added the
way ONLINE was, that leaves the game for the Dreamcast's BIOS menu (`syscall_system_bios_menu()`).

## Context

A console game ends by the player switching the console off; a recompiled one runs on hosts that
have a menu of their own — the Dreamcast's BIOS menu, a desktop, a page — and nothing in the
program could go back to it. The PS1's own `exit()` (A0 06h) cannot serve: the kernel reports it
and runs on, because during bring-up a game that calls it has usually gone wrong, and a headless
digest run must never stop early. The memory card has to reach the backend before the program
goes (ADR-0037 writes it back thirty vblanks after a write, or at exit — and there was no exit).

## Decision

**Backend ABI:** `bp_exit_to_menu()` leaves the program for the host's own menu. The Dreamcast
stops its hardware where it stands, as KallistiOS's `arch_abort` does — interrupts off, the PVR
reset, maple DMA stopped, the SPU off, nothing freed — puts the BIOS's own SR and VBR back
(`irq_shutdown`) and calls `syscall_system_bios_menu()`; the BIOS starts the hardware again
itself. SDL2 and the null backend exit the process; the page goes back to its start screen
(`recompsxHost.exitToMenu`, a reload); Node and the JVM end the program. A host that cannot leave
at once (the page) may return.

**Kernel:** `kernel.Kernel.exitToMenu()` writes the memory card back (`MemoryCard.flush`), then
calls the backend; in a headless run it notes the request and runs on. **Mods** reach it as
`ModHost.exitToMenu()`. It is the host's service, not a PS1 function: `exit()` is unchanged.

**Crash Bash** (`mods/onlinemenu`): QUIT is a record added to Select Game Type's list the way ONLINE
is, a line below OPTIONS, the panel a line taller and the description a line lower. The game keeps
OPTIONS selected under it and hears none of its keys: down from OPTIONS and cross on QUIT are the
mod's, up from QUIT is the game's own down from TOURNAMENT to OPTIONS (its sound, its
description). Its description is "exit to the system menu"; the pointer selects and clicks it.

## Alternatives

- **The PS1's `exit()` leaves the program** — bring-up runs and headless digests would stop at
  any game's error path; the game's own exit stays a report.
- **KallistiOS's own exit to the menu** (`arch_set_exit_path(ARCH_EXIT_MENU); arch_exit()`: the
  destructors, every subsystem shut down, then `arch_menu()`) — the first version. The owner's
  Crash Bash rebooted its disc instead of reaching the menu. Under Flycast with a real BIOS, a
  small KallistiOS program reached the menu this way while idle, but one doing what the backend
  does — a vblank handler reading maple, a thread reading the disc — hung on the way out: the
  shutdown takes maple and the CD away under them. The same busy program reached the menu by
  stopping the hardware and calling the BIOS directly.
- **A QUIT only on the Dreamcast** — every target has a menu to go back to; one mod line serves all.

## Consequences

- The ABI has 47 functions; `scripts/check.sh` holds every backend to them.
- A save made just before QUIT is kept: the card goes to the backend before the program leaves.
- Verified on the Dreamcast path: test programs under the Flycast fork with a real BIOS (serial
  console, a picture every emulated second) — idle + KallistiOS's exit: the menu; busy + that
  exit: hung, black; busy + stop and the BIOS call: the menu. Then Crash Bash itself, built with
  a temporary mod that quit at vblank 1200: the Universal logo, a black frame, the BIOS menu — and
  still the menu twenty emulated minutes later, the disc never booted again.
- Verified: headless with a scripted pad — five downs reach QUIT ("EXIT TO THE SYSTEM MENU"), up
  gives OPTIONS with the game's "CHANGE THE OPTIONS", down QUIT again, cross logs the request and
  the run goes on; check.sh (47), test.sh (JS) with the demo at `329de455`; in the browser
  (build 26cac2d99317) the pointer over QUIT showed its description and a click brought the page
  back to its start screen.
