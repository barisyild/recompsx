# ADR-0034: Console settings in the HLE kernel — the first of "PS1 Pro"
Status: accepted   Date: 2026-09-28

## Context

The user's direction for online play is to build it into the HLE kernel as advanced BIOS
features — a "PS1 Pro" — with networking a per-target backend service, so that it reaches the
consoles as well as the browser. The first thing it needs is memory: Crash Bash's ONLINE keyboard
(ADR-0033's first mod) should open on the last address that was accepted, after the page is
reloaded or the console switched off. The request was framed next to the game's own saves ("the
game saves unlocked characters; can the last address be saved too?").

Two facts shaped the answer. Memory cards are not emulated yet (SIO0's card address answers FFh),
so the game saves nothing today. And a game's save is the game's: adding a field to it would
change a format the game checksums and other emulators read.

The backend ABI already reserves storage for this — `bp_storage_read`/`_write`, "memory card
images and configuration" — implemented by the PC backend as atomic files and by the Dreamcast
backend on its storage root; the browser's side read nothing and wrote only to the log.

## Decision

The HLE kernel keeps console settings: `kernel.KSettings`, named values in one small text file,
`system.cfg` (`key=value` lines, 4 KB), read on first use and written on every change through
`bp_storage_*`. It belongs to the console, not to a game — shared by every game and mod, the way
a console's network settings are — and it never touches a game's save data. Keys are
`<area>.<name>`; the first is `net.last_address`.

Mods reach it through `ModHost.setting`/`setSetting`. A headless digest run neither reads nor
writes it (`Kernel.haltAt`), as controllers are not sampled there: a digest stays a function of the
disc and the frame count.

The browser's host keeps storage in `localStorage` under the page's origin (`recompsx:<name>`,
base64), blobs up to 256 KB — room for a 128 KB memory card later — and only reports larger ones
(the VRAM dump); under Node the shim reads the files it already wrote beside the program. The dev
server now sends `Cache-Control: no-cache` for the page and build.json: an edited page had gone on
serving its heuristically cached self beside a new bundle, which is how the first test of this
missed the new host.

## Alternatives

- **In the game's save (the memory card).** Not emulated yet, a format that is the game's, and a
  per-game home for what is a console setting.
- **A mod-private file.** Every mod would invent its own; the console's settings are one place a
  future BIOS menu can show and edit.
- **IndexedDB in the browser.** Asynchronous, while `bp_storage_read` is synchronous; the page
  would have to preload. `localStorage` is enough for settings and for memory cards.

## Consequences

- A build with mods that reads a setting behaves differently per machine, as it does with the
  player's controllers; digest runs are unaffected by construction.
- Settings are per browser origin (localhost:8000 and a LAN https address are different stores),
  per storage root on PC and Dreamcast.
- The same storage path is the one memory card emulation will use.
- Verified: conformance `Settings` (the file format) digests identically on JS and reflaxe.CPP;
  in the browser an address accepted on the keyboard was in `recompsx:system.cfg` and came back
  after a reload and a fresh boot.
