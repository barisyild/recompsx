# ADR-0037: Memory cards — a card per game, kept only as large as its saves
Status: accepted   Date: 2026-09-28

## Context

Nothing could be saved. SIO0 answered FFh at the card address, and the kernel's `_card_info`
answered every query with a timeout, so Crash Bash's Load Game said "there is no memory card in
memory card slot 1" and its save screens never ran.

The user set the terms. Memory cards are implemented per backend, each target keeping them in a
format of its own. A game should not cost 128 KB of storage for a card holding one 8 KB save:
the space follows what the game actually uses, growing when it saves more and shrinking when it
deletes, with no per-game configuration. And a card is identified by the game's title ID, not by
some id of recompsx's. While a save is being written, the speed limit should come off, so modern
hardware gets through it at once. A card's files must survive being deleted and created in any
order without corruption.

The kernel is HLE and the one source it may translate is OpenBIOS (MIT, per file). Its card
driver (`sio0/driver.c`, `sio0/card.c`), its backup unit (`card/backupunit.c`) and its `bu`
device (`card/device.c`) describe the retail behaviour games were written against, bugs and all.

## Decision

**The card the game sees is a whole PlayStation card.** `sio.MemoryCard` holds slot 1's 128 KB
image: sixteen blocks, block 0 the directory, and the FLAG byte with its "new card" latch that
only a write clears. Slot 2 is empty. When a game has no card kept, it gets a freshly formatted
one: every file block free, formatted exactly as the BIOS formats a card, including the FFFFh
the BIOS leaves at 08h of the broken-sector frames. A game therefore never asks to format a
card, and its save screens see fifteen free blocks. Two paths reach the image:

- **HLE.** `kernel.KCard` is a translation of OpenBIOS's driver and backup unit: InitCARD2,
  StartCARD2, StopCARD2, `_card_read`, `_card_write`, `_card_info` and its subfunction,
  `_new_card`, `_card_status`, `_card_wait`, `_card_chan`, `_bu_init`, `_card_load`,
  `_card_auto` and the `bufs_cb` callbacks. It keeps the BIOS's pace: a queued sector moves at
  the vblank, and each slot gets its turn every second vblank. HwCARD and SwCARD events are
  delivered as the BIOS delivers them, and an empty slot is found out a vblank later as a
  timeout. `kernel.KBu` is the `bu` device: open (create is first-fit, and the directory is
  written back middle entries first), read, write, close, lseek, erase, rename, format,
  firstfile and nextfile. Synchronous calls spin through vblanks as `WaitEvent` does.
- **LLE.** `sio.Sio0` answers at 81h with a Sony card's read, write and ID commands, byte by
  byte, including the late acknowledge of a read's 5Ch. A game that bypasses the BIOS sees the
  same card.

**The kernel's control blocks are in RAM.** The FCBs are at [140h] and the device table at
[150h] (tty, cdrom, bu). A device's function pointers are stubs in the BIOS window, which the
runtime routes back to `kernel.KDevices`. firstfile and nextfile are called through the device
table. This is required by Psy-Q's libcard, which swaps its own function into bu's firstfile
slot to mark the search FCB as taken. Without the table, Crash Bash waited forever for a card
event that only that detour produces.

**What is kept is recompsx's card format, one per game, under its product code.** The runtime
builds it (`MemoryCard.toFormat`) and reads it back (`fromFormat`):

    00h  "RXMC"          04h  version 1        05h  N, the blocks kept
    06h  mask: bit b set for each block b kept (1..15), little-endian
    08h  FNV-1a (core.Hash) of bytes 04h..07h, then of every byte after the header
    0Ch  zero
    10h  N records in block order: the block's directory frame (frame b of block 0, 128 bytes,
         its checksum included), then the block (8192 bytes)

A block is kept while its directory entry says it is in use (51h, 52h, 53h). Everything else
(frame 0, the free and deleted entries, the broken-sector list, the unused frames, frame 63) is
what a freshly formatted card holds, and is rebuilt that way when the card goes in. So a card
costs 16 bytes plus 8320 per block in use: 8336 for Crash Bash's one-block save, and nothing at
all when the game has saved nothing, because a card with no blocks removes the backend's copy.

**Blocks keep their places.** Each record carries its block number (the mask), so a card whose
saves were created in the holes others left (a file in blocks 1, 4 and 5) comes back with
every block where it was and every chain intact. Nothing is ever moved, so nothing needs
defragmenting: moving blocks would mean rewriting the chains a game wrote. The storage is
compact whatever the layout, because it holds only the blocks in use.

**The ABI carries bytes, not images.** `bp_card_load(game, buf, cap)` returns the length, or -1
when no card is kept. `bp_card_save(game, title, buf, len)` returns 0 or -1, and must be atomic
or else detectably damaged, which the checksum catches. The backend decides where the bytes go:

- **PC:** `<SERIAL>.card` beside the other saves, written to a temporary file and renamed.
- **Browser:** `localStorage["recompsx:card:<SERIAL>"]`, base64.
- **Node shim:** `<SERIAL>.card` beside the program.
- **Dreamcast:** where saves go as files (/pc, /sd), `<SERIAL>.card` as on the PC. On a VMU, a
  package named by the product code, carrying the game's own save icon (the first save's
  16×16 frames, doubled to 32×32, with the palette converted to ARGB4444), and protected by the
  package CRC. A VMU's 200 blocks hold a card of up to twelve PlayStation blocks.
- **Null:** keeps nothing.

`GameInfo.SERIAL` and `GameInfo.TITLE` come from game.json's `id` and `title`. Without a config
they come from the disc's SYSTEM.CNF, or from the executable's own name.

**When the card is written back.** After thirty vblanks without a write, and at exit, the card
goes back to the backend. If it is unchanged from the copy the backend already has, it is not
written again, because the BIOS writes frame 63 every time it opens a card and flash wears. A
headless run gets a blank card that goes nowhere, so a digest stays a function of the disc and
the frame count.

**While sectors move, frames are not held.** The runtime marks such a frame with
`BP_PRESENT_FAST`. That covers three cases: a game waiting in a card call, a sector read or
write queued, and one of the backup unit's transfers under way. A probe alone does not count,
since games make one every few frames. The Dreamcast skips its pacing for these frames, and so
does the browser loop. The PC build does not pace game frames today. Emulated time is
unchanged; only the host stops waiting.

## Alternatives

- **The raw 128 KB image (.mcr), the first version of this.** It is what other emulators read,
  but every game would cost 128 KB whatever it saved, and a whole image does not fit on a
  100 KB VMU at all.
- **A block budget per game in game.json, with the rest of the card filled by a reserved dummy
  file.** This was built first and rejected. It needs configuration for every game, and a game
  with more saves than its budget would find the card full.
- **Keeping files rather than blocks, and packing them together on load.** This would lose
  where the blocks were, which games do not need but the chains encode, and it would rewrite a
  game's directory behind its back. Keeping block positions costs nothing in storage.
- **An unformatted card, so that the game offers to format it.** This is faithful to a
  third-party card fresh from the shop, but it adds a question on every first run of every
  game, for no benefit.
- **Completing card operations instantly inside the call.** Simpler, but it changes the event
  timing games wait on, and the pace is what they were written against. The speed-up comes from
  presentation instead.

## Consequences

- Game digests change, because games now find a card. Crash Bash at 3000 frames is `6bd7b329`
  on JS and reflaxe.CPP (it was `0e180c28`).
- A game's save paths run for the first time, and code the analysis never saw runs with them.
  Crash Bash's boot overlay calls three functions in the executable from its save screens, and
  those are now function hints in its game.json.
- The directory scan of `_bu_init` takes about 75 frames, as on hardware, and a one-block save
  takes about 130. With `BP_PRESENT_FAST`, neither is held to the video rate.
- Open: the retail BIOS's I_MASK for SIO0 after `_bu_init`. The kernel has unmasked it there
  since e468132, and OpenBIOS leaves it masked after a transfer; this was kept as it was.
- Not done:
  - multitap cards (82h..84h answer nothing);
  - `undelete` (B46h reports and returns 0, as OpenBIOS has none);
  - broken-sector reallocation on a failed write (this card's writes never fail);
  - device-table slots other than firstfile and nextfile being called through RAM.
- Verified:
  - Conformance tests `CardFormat`, `CardSio`, `CardBios` and `CardChains` digest identically
    on JS and reflaxe.CPP.
  - In the browser, Crash Bash saved to slot 1, the page kept 8336 bytes, and after a reload
    the card came back with one block in use.
  - The save carries the game's own icon, two frames and a palette. Crash Bash reads them back
    from VRAM with libgpu's StoreImage (GP0 C0h). Until the GPU answered that read, saves had a
    black palette and an empty icon, and the VMU showed a blank one.
