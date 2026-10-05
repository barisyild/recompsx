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

## Amendment (2026-10-05): a long read answers the one before it

The owner, on the Dreamcast: Crash Bash's Adventure hub paused with "CONTROLLER 1-A IS UNPLUGGED!
PLEASE INSERT A CONTROLLER", and the browser did not. A Dreamcast controller has a stick, so it is a
DualShock (ADR-0052), and the browser's keyboard a digital pad. Headless with `--pad-dualshock` the
hub paused the same way: the shared runtime, not the backend.

libpad configures a DualShock in a slot through the long reads (the trace from boot: 43h 01h, 45h,
4Ch, 47h through slot A directly, then 43h, 45h, 43h 00h through slot A's window of long reads). The
tap answered each window at once, as a transfer of its own. A real SCPH-1070 does not: it takes the
host's bytes for the four slots while sending what it has, and talks to the controllers after the
transfer, so a long read returns the controllers' answers to what the *previous* long read sent
them — BlueRetro's logic-analyser logs of the adaptor: "a 0x43 config mode request sent in TX3
produces its response visible in the RX4 data"
(https://hackaday.io/project/170365-blueretro/log/186471-playstation-playstation-2-spi-interface).
Answered at once, libpad read each answer as the one to its command before: it left configuration
mode early and went on asking 45h of a pad in normal mode, which refuses it (41h, then FFh),
forever; the hub took that for a pad pulled out.

Now `Multitap` keeps each slot's eight bytes of the last long read and sends them to the controllers
when that read ends (`finished`); the next long read answers with the result. The first long read
answers a read made at its start. A garbage read and a slot-A read send the controllers nothing this
way (slot A read directly answers at once, as without a tap).

- Crash Bash, headless, a scripted DualShock: libpad enters configuration mode, reads 45h's answer
  (01 02 00 02 01 00), leaves it, and reads the pad in digital mode; the hub plays on, 4800-7200
  without a pause (it paused from the first frame before).
- `MultitapSio` 644b488d unchanged (digital pads answer every command as a read, and its buttons do
  not change between long reads). `DualShockSio` 6081cd6f (was a1fdfeea): its long reads now expect
  the answers to the read before, and the motors running once the read that drives them has ended.
  JS = C++. Digests of both games unchanged (no controller in a headless run).
- What a game sends in the long read's data bytes is modelled now (the "not modelled" above).
