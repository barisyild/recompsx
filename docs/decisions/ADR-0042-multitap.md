# ADR-0042: The multitap, in port 1 by default
Status: accepted   Date: 2026-09-29
Direction set by the project owner: the multitap is on by default, and Crash Bash is to be played
four at a time on the Dreamcast.

## Context

The backend ABI has had four pads from the start ("because the multitap is not optional for the
games this project targets", backend_c_api.h), and the Dreamcast, desktop and browser backends
report up to four. The machine used two of them: SIO0 had a digital pad on each port and nothing
else. A game played by more than two needs the Multitap (SCPH-1070). This is an adaptor with four
controller slots and four card slots, on one controller port. Crash Bash reads eight controller
records (two ports of four slots) and allows as many players as it finds pads.

The tap's protocol is in psx-spx, "Controller and Memory Card Multitap Adaptor":

- A read of 01h, 42h answers for slot A. A game that knows nothing of the tap sees an ordinary
  controller.
- The third byte of a read, 01h, asks that the *next* read be the long one: ID 5A80h, then four
  halfwords per slot. A digital pad is its 5A41h and buttons, padded with FFFFh; an empty slot is
  all FFFFh.
- Asked again during a long read, the following read is four bytes of garbage, and then the long
  one comes again.
- An empty slot A leaves the address unacknowledged.
- 02h-04h address slots B-D directly, and 81h-84h the four card slots.
- The BIOS's own pad driver always sends 00h as the third byte (OpenBIOS sio0/driver.c), so the
  kernel path only ever sees slot A.

Two things are not the hardware's to decide: where the tap is, and where the host's pads are.
With the tap in port 1 and pads 0-3 in its slots, a two-player game that has no tap support looks
for player 2 in port 2. Put pad 1 there as well, and a game that does know the tap sees it twice.

## Decision

**A multitap is plugged into port 1** (`sio.Multitap`), and the host's pads 0-3 are in its slots
A-D. `sio.Sio0` routes port 1's addresses to it. The tap follows psx-spx's table: slot A,
long, garbage, and the request taken from a slot-A read's third byte. It answers 02h-04h as each
slot's pad on its own, and 81h with the machine's one card (82h-84h hold none). A long read
latches all four slots at its address byte, as a pad read latches one.

**Pad 1 is in one place at a time.** Until the game uses the tap beyond slot A, pad 1 is also the
pad in port 2 (`Pads.padOnPort`). The tap counts as used after a long read, or when slots B-D are
addressed and answer. After that, pad 1 is in slot B only and port 2 is empty. This lasts until
the machine resets, because a game that has found the tap goes on using it. The kernel's pad path
(`kernel.KPads`) reads each port through the same rule: port 1 is pad 0, and port 2 is pad 1 while
the tap is unused.

A headless run has no pads, and a tap with slot A empty answers exactly as an empty port does, so
no digest moves. `Multitap.plugged = false` gives the old machine, with a pad in each port.

## Alternatives

- **Off by default, an option to turn it on.** Rejected by the owner. A game played by four has
  no other way to see four pads, and a tap that nobody asks for is invisible, since a plain read of
  port 1 is slot A.
- **Pad 1 in slot B and in port 2 at once.** A game with tap support that also reads port 2 would
  count one controller twice. Crash Bash reads all eight records, and who plays which player would
  depend on its order of reading them.
- **Pad 1 in port 2 only, pads 2-3 in slots B-C.** Four-player games would lose a player, and
  players would be out of order.
- **Handing pad 1 back to port 2 after some time without a long read.** A game that pauses its
  polling, a loading screen say, would see a controller come and go.
- **A tap in port 2, or two taps (eight pads).** Some games want the tap in port 2 (Bomberman,
  S.C.A.R.S., psx-spx's list). That is a per-game fact for game.json when a game needs it. The ABI
  has four pads, and nothing here needs more.

## Consequences

- Crash Bash, headless with four scripted pads, counts four pads (80051600h = 4). Its controller
  records 0-3 are filled, and 4-7 (port 2) are empty. Each pad's own button reaches its own
  record. With two pads it counts two, in slots A and B.
- On the Dreamcast (the Flycast fork, four Sega controllers in maple A-D) it counts four as well.
  The fork's `RXPAD` held A, B, X and Y on ports A-D together, and cross, circle, square and
  triangle reached records 0-3 (98 of 2400 presents showed a press). Record 4 stayed empty.
- Digests are unchanged: conformance `PadSio`, `PadBios`, `CardSio`, `CardBios`, `CardChains`;
  Crash Bash 3000 `db892c4b`. `MultitapSio` is new: the table, the long and garbage reads, direct
  slots, cards, port 2 before and after, the tap unplugged, and headless.
- The browser reads four gamepads (pad 0 is also the keyboard), as SDL2 and the Dreamcast's maple
  ports A-D already did.
- Not modelled: analog pads in a slot (the machine has only digital pads), rumble through the tap,
  and anything a game sends in the long read's data bytes.
