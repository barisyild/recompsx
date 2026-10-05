# Crash Bash (NTSC-U, SCUS-94570) — bring-up notes

Clean-room observations recorded by this project. No game code or data lives in this repository;
everything below is a measurement taken from the user's own dump, or a plan for taking one.

## 2026-10-05: "CONTROLLER 1-A IS UNPLUGGED" in the Adventure hub with a DualShock

Reported by the owner on the Dreamcast (a maple controller with a stick is a DualShock to the
machine, ADR-0052); the browser with the keyboard (a digital pad) was fine. Headless with
`--pad-dualshock` and the walk below the hub paused the same way, from its first frame, and the
menus before it tolerated what caused it. The walk: `0:-`, START every 120 frames from 1800 to 2880,
then CROSS every 90 from 3000 to 6600 (ADVENTURE MODE, NEW GAME, 1 PLAYER, the character, the
intro) — the hub from about 4800.

libpad configures a DualShock in slot A through the multitap's long reads, where a real adaptor
answers a read late: the tap answered at once, libpad fell out of step, left configuration mode
early and asked 45h of a pad in normal mode, forever. The tap now answers the previous long read's
commands (ADR-0042 amended); the hub plays on. Slot A's traffic from vblank 90 is the thing to
trace (a hook on `sio_Sio0.answer` in a copy of the bundle).

## 2026-09-28: Circle in the warp room froze the character — three entries the analysis never had

Reported by the owner (the keyboard's A is circle). Reproduced headless with a scripted pad —
main menu, ADVENTURE, 1 PLAYER, CHARACTER SELECT, the intro skipped with cross, the hub — and
circle there: the runtime reported three misses in the frame circle was pressed, and nothing
before it (walking right and left was clean). `boot` had no code at 8008671Ch (called from
8008713Ch), and the resident `adventure` overlay none at 800C2F60h and 800C013Ch (called from
boot's 80086908h and 80084538h): reached through pointers only, so no pass found them. They are
entry hints now; with them, circle twice and cross in the hub reach nothing unimplemented.

The runtime's own advice for the two adventure addresses was wrong — "the disc has since been read
over this part of its window", with a stanza identical to `adventure` itself. `OverlayMgr.reportMiss`
compared the covering load's exclusive end with the window's end plus one, but the window's end is
exclusive too (`define` keeps start plus length), so an overlay's own load always looked foreign.
Fixed: both ends exclusive; such a miss now says "add it to its entryHints".

**The boss pad said nothing.** On Papu Pummel's pad (the hub's boss) the message at the top — "YOU
NEED 4 TROPHIES TO FACE PAPU PAPU" — never came, where every level's pad shows "PRESS X BUTTON TO
START". Headless, walking the hub's ring and up each branch: the level pads reach nothing missing;
the boss pad calls boot's 80090248h from the adventure overlay (800B67F4h), a function only a
pointer reaches. An entry hint; with it the message is there. Not an overlay missing — the overlay
was resident, one function of it had never been compiled.

## 2026-09-28: The mouse in the menus (mods/mouse, mods/onlinemenu; ADR-0038, ADR-0040)

Measured headless (a scripted pad, then a scripted mouse through `kernel.KMouse.update`).

**The mouse is the PS1's own** (ADR-0040): each mod plugs a Sony Mouse into a controller port of
its own and reads it every frame (01h 42h; 12h, 5Ah, the buttons, the motion), keeping its cursor
in display pixels, from the middle of the display, as a PS1 mouse program does; the kernel's
mouse moves that cursor to wherever the host's pointer is. Reading it is what shows the pointer.

**Units.** Menu records and widgets place things in a 640 x 480 space centred on the screen: the
widget draw (8001C690h) sets the GTE's screen offset to x times the display's width over 640
(the `0x66666667` multiply and `>> 8` are a division by 640) and to y halved, for 240 lines. So a
pointer at display pixel (px, py) of a W x 240 display is at (px * 640 / W - 320, py * 2 - 240).
A text line's y is its top; letters are about 28 units tall and 20 wide.

**Widgets.** Hung from the menu objects at 800A0E78h + slot * 9Ch (+6Ch the first), linked
through +5Ch. +0 flags: 10008000h a drawn text line (10000000h the same, hidden — the description
until it is shown), 12008001h a panel, 11008000h/01008000h models; +4 x — a centred line keeps
8000h plus its centre (8086h: 134; CHOOSE LEVEL's 7FA1h: -95); +8 y; +6Ch the text; +7Ch the
state — 0 plain, 2 highlighted, 3 a line not available, 4 a description. There are nine menu objects: they run up to 800A13F4h, slot 0's first widget.

**Which list is up.** OPTIONS is built into slot 4 (records 800B8F20h: title OPTIONS at y -140,
SOUND -50, CONTROLLER -10, EXIT 30, all centred on 0) while the main menu stays in slot 0 with
OPTIONS lit; closing it builds nothing — Select Game Type's frame simply runs again — and slot 4
keeps its widgets. The menu objects do not change either. What does is the menu screen manager's
current screen (8009F8A4h): every list is built while its screen is current (Select Game Type
800B8E28h, OPTIONS 800B9510h, the Adventure submenu 800B8E50h, Tournament 800B8E3Ch), so a list
is live while the screen it was built under is. A torn-down menu (the demo, a match) empties slot
0.

**The picture screens.** The Battle Mode path is main menu, SELECT NUMBER OF PLAYERS (800B8E3Ch,
a list; it takes cross only after some 150 frames), CHARACTER SELECT (800B9DF4h, frame handler
800B6734h), CHOOSE LEVEL (800BA72Ch, 800B7458h), SELECT BATTLE TYPE (800BAAB4h: VS BATTLE, left
and right the type, cross starts) and GAME OPTIONS (800B8E8Ch: cups to win, difficulty), then the
match, under a current screen of 0, its objective panels waiting for cross. CHARACTER SELECT's
slot 0 holds the P1 marker (widget 0) and the eight portraits (widgets 4..11) as sprites placed
from the screen's top left in 640 x 480 units: x 150/240/330/420, y 38/138, each about 70 x 77
inside a frame 90 x 100. Right and left walk the eight as one ring (7 -> 0 -> 1); the marker
slides over some ten frames to 1 left of and 2 above the portrait chosen. CHOOSE LEVEL's slot 0
has the level's name (widget 0), the arrow (widget 1) and the arena's name (widget 6); left and
right change the arena (CRATE CRUSH -> POLAR PUSH), up and down the level, and the arrow's y is
-154 + 99 * the level in the centred units — the four thumbnails 135..290 across in those bands,
the big preview -287..91 across and -2..198 down.

**The choices are indexes.** Each screen keeps its choice as a number its frame handler draws from
every frame, so a mod writes it (and plays the move sound, 190h) rather than pressing its way
there: Select Game Type 0..3 at 800B95F0h (with the description timer 800B9624h = 90); SELECT
NUMBER OF PLAYERS the players 1..4 at 8005A63Ah (game state 8005A614h + 26h; up and down stop at
1 and at the pads connected, 80051600h — and cross is ignored while it is 0, before any pad is
seen); the Adventure submenu 0..1 at 800B9628h; OPTIONS 0..2 at 800B9508h; CHARACTER SELECT each
player's portrait 0..7 at +30h of its record (800B9FD4h + 60h each: +4 its pad, +24h 0 while it
is still choosing; left/right +-1, up/down +-4, then & 7; its move sound is the word at 800B9CB4h +
4 * pad); CHOOSE LEVEL the arena at 8005A614h + 36h (0..6, left/right; a change also sets
800BA744h to 4) and the level at + 37h (up/down, below the arena's count at 800BA324h + 8 * arena
+ 4). The inputs are in 800B5F40h (the portrait), 800B6E0Ch (arena and level), and each list's
frame handler (800B3F7Ch, 800B42B0h, 800B4910h).

**Input.** The pad reader is 800138A4h (exe): it reads the eight controllers (records at 80051338h
+ i * 58h), leaves the buttons pressed this frame at 80051380h (controller 0's +48h) and counts
idle frames at 80051604h. The mouse mod adds its presses there right after it. The onlinemenu mod
had a bug this uncovered: it took any build into another slot as leaving the main menu, so after
OPTIONS its ONLINE line and the mouse stopped working; only slot 0's builds count now.

**The menus in play** — PAUSED and what opens from it — are not widgets but the boot overlay's
own. 80080FBCh, called every frame, picks a definition by the game state's flags (8005A614h + 10h)
and 800809A0h (definition a0, base y a1 — 8009BD18h, 112) draws it: 24-byte items to a type of
-1, +0 the type, +2 x (8000h plus a centre, 320 for none), +4 y below the base, +6 the index of a
string in the language's table (80059748h + 4 * language, English 80059668h: 0 CONTINUE, 1 SHOW
RULES, 2 OPTIONS, 3 CHANGE ARENA, 5 QUIT GAME, 6 EXIT ARENA, 12 CHEAT MENU, 14 QUIT GAME?, 16
"YES" and 17 "NO", padded with spaces to share a row). Type 0 lines, and type 1 while game +4 holds
80010000h (the cheat line), are counted, and the one equal to 8009AEECh is drawn lit; types
10+k, 20+k and 30+k are option k's values, drawn while the halfword at 8009BD1Ch + 2k is 1, 0 and
9; 2 is the panel, 4 and 5 titles. PAUSED is 800598DCh in a battle (CONTINUE, SHOW RULES,
OPTIONS, CHANGE ARENA, QUIT GAME), 800599B4h in the Adventure hub (CONTINUE, OPTIONS, QUIT GAME),
8005975Ch and 8005981Ch in other modes; QUIT GAME? is 80059ABCh and the pause's OPTIONS
80059C9Ch. The lines are drawn by 800243A0h, whose width 80024008h measures: the font at
8005B2B4h (0 here), a letter's width the signed byte at 8005AEB4h + 100h * font + the letter (a
glyph flagged 2 at 8005B0B4h + the same does not advance), times 640 over the display's width (+4
of 8005B698h's record, 512). So CONTINUE spans 240..400, QUIT GAME 233..408, YES 223..283 and NO
375..415, each line from its y to some 30 below — the owner's screenshot of the hub's PAUSED
agrees to a unit. The input is 8007EFC0h (pad, last line): up and down move 8009AEECh (sound 190h,
clamped), START resumes (clearing the pause's bits of game +10h), and it returns cross, which the
menu's handler takes by the line; the pad is the player at 8009AEF0h, whose buttons pressed this
frame are at 80051380h + 58h * player. The questions and the pause's OPTIONS go back on
triangle; PAUSED itself does not look at it.

## 2026-09-28: ONLINE — an address only, the game's port, typing, and the demo timer

The address keyboard takes an IPv4 address and nothing else (four numbers 0..255, no leading
zeros): the port is the game's own, 9457 (`onlinemenu.Online.PORT`, ADR-0035), and DONE tries it
at that address the PS1's own way (ADR-0040): the i-mode adaptor on a port of the mod's, driven
through libimode one transfer a vblank — AUTH_START, GW_CONNECT, SND of `GET
http://<address>:9457/SCUS94570 HTTP/1.0`, RCV, GW_DISCONNECT, AUTH_END — and the line under the
field says "connecting to", then "connected to" (an HTTP response came back), "no answer from" or
"no network". Where the machine has a keyboard it types into the field too: the mod reads a PS/2
keyboard on a port of its own (Set 2 scancodes, as a US keyboard types what the host typed) and
takes digits and '.', Backspace, Enter for DONE, Escape for CANCEL; every other key is ignored,
as the game's keyboard has no key for it.

**The demo timer.** The executable's pad reader (80013974h) counts frames with no pad input at
80051604h and zeroes it on any press; Select Game Type's frame handler calls 800B39C8h first,
which past 900 (`slti 385h`) resets it and starts the attract demo (8001E588h, with the fade
object 8009F644h). The count runs once per game frame — the menus run at 30 fps, so about 30 s.
Typing is no pad input, so a player typing an address let it run on, and back in the menu the
handler's first call started the demo at once. The keyboard holds 80051604h at zero while it is
open, and gives the field up (the PS1 keyboard no longer read, so the host's keyboard plays the
pad again) if the game builds any other screen under it. Verified headless: 2,400 frames at the keyboard, Enter, and the demo 1,861 frames later —
the full wait.

## 2026-09-28: Cross in the menus did nothing — the screen manager's leaves, and a fourth stage block

With controllers the menus could be walked for the first time, and cross on Select Game Type played
its sound and stayed. The frontend names the next screen through the menu screen manager at
8009F8A4h: +0 the current screen, +4 the next, +8 the one before, +0Ch a
state. 8001E848h sets the next (state 0), 8001E838h and 8001E824h the same with states 1 and 2 —
three-instruction leaves in a row, with no prologue for the sweep to find, so the stage overlay's
`jal 8001E848h` reached nothing ("no function at 0x8001e848", ra 800B5380h). The manager's update
(8001E610h, from 80092EDCh through the boot overlay's per-frame callback) switches when a next
screen is set and the fade object at 8009F644h (value, speed, steps) is idle or has made three
steps; it runs every frame, so the missing setter was the whole fault.

Walking on into a battle (cross on every screen: two presses down, then cross, player count,
character, arena) reported, one round at a time: 80015284h (character select, ra 800B75C8h), the
stage overlay's 800B544Ch (a screen's exit), a fourth block in the 800B32B4h window —
CRASHBSH.DAT sector 28382, 71680 bytes, entries 800BB370h, 800BB360h, 800BB1B4h, now overlay
`stage4` — boot's 80086D88h, 8008AB50h, 8008A810h, and the executable's 80026D00h, 80025AE4h,
80027F7Ch, 8002C29Ch, 8002C290h, 8002321Ch. After them a 16,000-frame run through that battle
reaches nothing missing. The attract loop never takes these paths: its digests are unchanged
(3000 `654669df`, 9000 `fda4764f`, 30000 `2d1ca4b6`).

**Adventure mode** walked the same way (cross on ADVENTURE MODE, NEW GAME, the player count and
the character) loads the adventure hub block — CRASHBSH.DAT sector 28136, 86,016 bytes at
800B32B4h, now overlay `adventure` — and reported, one round at a time, fourteen of its entries,
boot's 8009020Ch and the executable's 8001DCD4h and 80015984h. On the way the frame loop at
80027110h called address 0: a callee that was missing had been skipped, the mode descriptor in s0
did not survive it, and the loop read its render pointer from address 8. With the entries in, the
hub (mode descriptor 800BCC04h) runs 14,000 frames with nothing missing. Saving (ENTER NAME) is
reached from inside the hub by walking; it was not scripted.

**The name keyboard** (for the onlinemenu mod's address keyboard, which imitates it): ENTER NAME,
DONE and CANCEL live in the adventure overlay, CRASHBSH.DAT sector 28136 (86,016 bytes), loaded in
the same 800B32B4h window as the menus — so it is never resident beside them. Its keys are a table
of 16-byte entries from 800BD5D4h: the label (A..Z, '@' drawn as a square, '<' drawn as the
delete arrow), navigation words, and x, y in a 7 x 4 grid 40 units apart; DONE and CANCEL follow
as records at 800BD790h. Menu fonts 0 and 1 carry `!%',-.0-9:<>@A-Za-z` (no '_').

## 2026-09-28: The main menu (Select Game Type), read for the onlinemenu mod

Measured on the disc and in headless runs; used by `mods/onlinemenu` (ADR-0033).

**The menus are data.** The frontend overlay `stage` (800B32B4h, CRASHBSH.DAT sector 28178)
opens with its strings (ADVENTURE MODE 800B333Ch, BATTLE MODE 800B334Ch, TOURNAMENT 800B3358h,
OPTIONS 800B3364h, SELECT GAME TYPE 800B3370h; the four descriptions from 800B32B8h, pointed to
by the table at 800B8508h). Each screen is a list of 36-byte records, ending at a record whose
type is below 2:

| offset | meaning |
|---|---|
| +0 | type: 3 a text line, 4 a panel or bar, 0 the end |
| +4 | halfword: flags/x (8086h for the menu lines, 8000h for a title) |
| +6 | halfword: y (the main menu's lines at -44, -10, 24, 58: 34 apart) |
| +8, +A | a panel's other extent (the main panel: -70, 114) |
| +14 | the text |
| +18 | the widget's initial state (4 for the description) |

Select Game Type is 800B8518h: panel, the four lines, the description (y 130, text empty until
set), the title, the title bar, the end. The player-count menu follows at 800B865Ch.

**Building.** `boot`'s 80095BECh (slot a0, records a1) builds a screen: menu objects at
800A0E78h + slot * 9Ch, their widgets (+6Ch) 0A8h bytes each, one per record, contiguous and
linked through +5Ch. 800952F8h fills them: a text widget takes flags 10008000h (8000h: shown),
x (+4), y (+8), text (+6Ch) and state (+7Ch); its draw function is 8001C448h.

**Screens** are {enter, frame, exit} triples from 800B8E28h (Select Game Type: 800B5614h,
800B3CA8h, the shared exit 800B57BCh), in sequences such as 800B8EA0h; 800B5360h moves to the
next. The frame handler 800B3CA8h reads the buttons pressed this frame at 80051380h (10h up,
40h down, 4000h cross), keeps the selection 0..3 at 800B95F0h, plays sound 190h on a move and
starts the description timer (800B9624h, 90 frames); while it runs the description widget (5)
is shown with the table's text for the selection. Each frame it sets every line widget's state
to 0 and the selected one's (selection + 1) to 2 — the highlight. Cross switches on the
selection (next screens 800B8EC0h, 800B8EA4h, 800B8ED4h; OPTIONS through 8001E838h).

**QUIT** (ADR-0041) is a tenth record in the mod's list, a line under OPTIONS (y 126 with ONLINE
in; the panel's bottom and the description each a line lower, the description at y 198 — one
line of text still fits above the screen's bottom, two would not). The game keeps selection 3
under it: down from OPTIONS and cross are the mod's, up is the game's own down from TOURNAMENT
(selection 2 -> 3), so OPTIONS comes back with the game's sound and "CHANGE THE OPTIONS".

In the attract loop (no input) the menu is built at about frames 1980, 6660 and 15600. A scripted
pad in a headless run shows the game's own cross on BATTLE MODE doing nothing there, with or
without the mod — the attract menu does not take it.

## 2026-09-25: the third mini-game, and where the cutscene's sound comes from

**stage3.** At about frame 18060 of the attract loop (after Select Game Type) `boot` calls
0x800c0b94 through a pointer from 0x80078d10. The runtime reported the block in the 0x800b32b4
window as missing: CRASHBSH.DAT sector 28241, offset (28241 - 236) * 2048 = 57354240, 63488
bytes. 0x800c0b94 is a 26-instruction initialiser that stores seven callbacks into the table at
0x8005aa70 (0x800b36cc, 0x800b3b20, 0x800b40ac, 0x800c0b7c, 0x800c0b84, 0x800bfd9c,
0x800b9728); the tool had refused the hint because its plausibility check read past the
function's `jr ra` into the data behind it (fixed in the tool, not here). Before the fix the call
was skipped and the demo ran on the previous game's callbacks. Hints then added from the
runtime's reports: stage3 0x800c0760, 0x800b4efc, 0x800c0a74; boot 0x80086f78, 0x80086714;
base 0x80015758, 0x8002694c, 0x80026ad8, 0x80026b70. The attract loop now runs 70,000 frames
with no missing code. SPU key-ons from frame 18000 rose by about 9 %.

**Sound sources.** No CD-XA: every sector of CRASHBSH.DAT and BASHY is a form-1 data sector (the
only XA file on the disc, SPYRO3/SPEECH.STR, is the Spyro 3 demo's). No CD-DA: the disc has one
data track, and the single CdlPlay in the attract loop plays nothing. No noise, pitch
modulation, reverb or volume sweeps in 30,000 frames. Everything is SPU voices. The intro
cutscene (Uka Uka, from frame ~24100) streams its sound: the game reads a chunk from the disc
into one half of sound RAM (0x1010 or 0x1fc90) while the other half plays, each half one note of
220,528 samples at pitch 0x7fa (21,985 Hz, 10.03 s), keyed alternately on voices 0 and 1 every
~597 frames. That is longer than an AICA channel holds, which is why the Dreamcast lost it
(ADR-0024).

## 2026-09-09: main reconciled with the committed console branch

The earlier claim that working features existed only in an untracked JS bundle was incorrect.
`25d9a5d` and `6819782` on `dreamcast-hardware-rendering` already contain the GTE operations,
textured rasterizer, CD acknowledgements/held-sector reset, 7-cycle loads and additional entry
metadata. `main` was based on the older `d731004` runtime when `2c80e68` added scalar codegen.
Rebuilding that older source exposed the missing branch integration. No commit or media was lost.

Those changes are now reconciled into the main working tree, keeping the new IR/regions and
compiled-handle continuations. `game.json` again supplies 1004 executable functions, 324 boot,
180 stage2 and 69 stage functions. These are per-game discoveries, not runtime address checks.
The timed SCEx fixture added during diagnosis remains: Test 05 returns two persistent counters
and does not infer head position from GetID licensing. Its one-observation timing is coarse.

The observed protection check is SeekP → Play → Test 04 → delay → Test 05 with no GetlocP in
its 1500-frame trace, i.e. [SCEx/modchip detection](https://psx-spx.consoledev.net/cdromformat/#stealth-hidden-modchip),
not [LibCrypt subchannel-Q checking](https://psx-spx.consoledev.net/cdromformat/#cdrom-protection-libcrypt).
The old main response exited around frame 600; the SCEx-only repair went further but hit 15
missing paths and VSync timeouts. That `b542d57e` run was an intermediate failure, not a baseline.

After reconciliation, optimized cooperative JS, forced yields every 31 checkpoints,
`--no-opt` synchronous JS and full reflaxe.CPP (normal/forced yields) all reach frame 3000 with
`0e180c28` and zero missing paths:
28,871 scheduler events, 6,420 IRQs, 7,832,308 GPU words, 855,112 primitives and 1,714 sectors.
The browser reaches Select Game Type with a rendered 3D character beyond frame 7366.
The original old bundle's `8af4d44b` is historical; it has different runtime timing and unwind
behavior. Current mode comparisons use the same sources and inputs. Logs are ignored under
`out/_reconcile/`; the old artifact remains ignored at `out/_web/previous-game.js`.

## Dump shape

The reference dump on the development machine is an **extracted-files directory**, not a BIN/CUE
(see `docs/specs/tool.md` §1.1 for how that input mode works and its LBA caveat). Layout:

```
SYSTEM.CNF
SCUS_945.70              432,128 bytes   boot executable
BASHY.                31,752,000 bytes   (name has an empty ISO9660 extension)
CRASHBSH/CRASHBSH.DAT 73,220,096 bytes   main data archive
SPYRO3/SPYRO3.EXE        372,736 bytes   bundled Spyro 3 demo (not configured)
SPYRO3/WAD.WAD        16,797,696 bytes
SPYRO3/SPEECH.STR     32,249,856 bytes
```

Rebuilt BIN/CUE images also exist on this machine (produced by the sibling `crash-bash-editor`
project). Prefer a real BIN/CUE for *running*; `filesDir` is fine for `analyze`/`gen`.

## SYSTEM.CNF

```
BOOT = cdrom:\SCUS_945.70;1
TCB = 4
EVENT = 16
STACK = 801FFF00
```

Load-bearing for the runtime: the kernel HLE must size its TCB array to 4 and its EvCB array to
16, and honor `STACK = 0x801FFF00` as the initial SP — note this differs from the value in the
EXE header (0x801FFFF0); the BIOS prefers SYSTEM.CNF. See `docs/specs/runtime.md` §1.

## PS-EXE header (SCUS_945.70), verified 2026-08-08

| Field | Value |
|---|---|
| magic | `PS-X EXE` |
| initialPc | `0x8002E7B0` |
| initialGp | `0x00000000` |
| loadAddr | `0x80010000` |
| fileSize | `0x00069000` (430,080) → text/data occupies `0x80010000`–`0x80078FFF` |
| dataAddr/dataSize | 0 / 0 |
| memfillAddr/Size | 0 / 0 (no BSS zerofill requested by the header) |
| spBase / spOffset | `0x801FFFF0` / 0 (overridden by SYSTEM.CNF `STACK`) |
| region marker | "Sony Computer Entert…" |

File size on disc (432,128) = 0x800 header + 0x69000 payload — exact, so the dump is not
truncated. Entry point sits at payload offset `0x1E7B0`, inside the loaded range, as expected.

sha256 `fd5727a18feb2a2d5a6359a55966f0266284d1e50f64ee9b8a127a97091bd516` — recorded in
`game.json` as `exeSha256`; a mismatch means a different revision and is a hard error.

## Entry point, read from the real executable

`./scripts/recompsx.sh dis <SCUS_945.70> --count 28` produces the standard Psy-Q startup, which
also serves as the first real validation of the decoder:

```
0x8002e7b0: lui   $v0, 0x8007        ; \
0x8002e7b4: addiu $v0, $v0, -0x1610  ;  > 0x8006e9f0 — start of the region to clear
0x8002e7b8: lui   $v1, 0x8008        ; \
0x8002e7bc: addiu $v1, $v1, -0x7370  ;  > 0x80078c90 — end of it
0x8002e7c0: sw    $zero, 0($v0)      ; the BSS clear loop
0x8002e7c4: addiu $v0, $v0, 4
0x8002e7c8: sltu  $at, $v0, $v1
0x8002e7cc: bne   $at, $zero, 0x8002e7c0
0x8002e7d0: nop
...
0x8002e7f4: lw    $v0, 0($a0)        ; stack pointer, from a table indexed by a mode value
0x8002e7f8: lui   $t0, 0x8000
0x8002e7fc: or    $sp, $v0, $t0      ; ...forced into KSEG0
```

Two things worth carrying forward:

- **The game clears its own BSS**, from 0x8006e9f0 to 0x80078c90, even though the header's
  memfill fields are zero. So the loaded image ends at 0x80078fff but the *used* data region
  extends to at least 0x80078c90, and anything the analyzer sees between those is initialised
  data rather than code.
- **`lui`+`addiu` is how every address is built**, including negative `addiu` halves
  (`0x8007` then `-0x1610`). The jump-table matcher must fold exactly this pattern, and the
  sign of the second half is the part that is easy to get wrong.

## Open questions (answered during M1/M6, recorded here as they resolve)

- **Overlays**: where the game's overlay loader lives, which file(s) overlays come from
  (`BASHY.` and `CRASHBSH.DAT` are the candidates by size), their load addresses, and whether
  they are stored compressed. Method: `recompsx extract` for the file list, then trace CD-read
  call sites (LIBCD `CdRead`/`CdReadFile` cross-references) in the disassembly. If compressed,
  capture the decompressed regions once with a debugger and use `memdump` overlay sources.
- **Audio**: whether music is sequenced through SPU registers, XA streams, CDDA, or a mix.
- **FMV**: MDEC usage and where the STR data lives.
- **Multitap** (answered 2026-09-29, ADR-0042): raw SIO0 through libpad, never the kernel's
  `InitPad`. See "The multitap" below.

## The multitap (2026-09-29)

libpad asks port 1's tap for long reads from boot on. In a headless run with four scripted pads
the tap was in use by vblank 300. The pad reader (800138A4h) fills eight controller records,
80051338h + i * 58h: records 0-3 are port 1's slots A-D and 4-7 port 2's. A record in use holds 5
at +0; the buttons pressed this frame are at +48h. 80051600h counts the pads the game has found,
and SELECT NUMBER OF PLAYERS goes up to that count. Measured (ADR-0042):

- Four pads: 80051600h = 4. Records 0-3 are in use and 4-7 empty. Cross, circle, square and
  triangle, one on each pad, reached records 0, 1, 2 and 3 as 4000h, 2000h, 8000h and 1000h.
- Two pads: 80051600h = 2, records 0 and 1. Pad 1 has left port 2 for slot B, so it is not counted
  twice.

## Prior art on this machine

The sibling project `crash-bash-editor` (the user's own work) contains extensive format
documentation for this game's data files. It is a legitimate reference for *data* formats and
disc rebuilding. It says nothing about executable code layout, which is what recompsx needs — do
not assume overlap.

## The console had no region, so the game thought it was Japanese (2026-08-09)

The characters the anti-piracy screen asked the font ROM for decode, as Shift-JIS, to
**強制終了しました。本体が…** — the *Japanese* text of "software terminated, the console may have
been modified". An NTSC-U disc, drawing the Japanese message.

Because our machine had no region. Games read the letter at the tail of the BIOS ROM's version
string — `0x1FC7FF52`, 'A' America, 'E' Europe, 'I' Japan — and the ROM window was not served at
all: not stubbed, not reported, simply absent from the memory map, so every read returned zero and
the region test fell through to its first case. Serving that one byte as 'A' stopped the Japanese
glyph requests dead: fifty-six calls to `Krom2RawAdd` became none, and the sixteen hundred uploads
that went with them became thirteen.

**It did not stop the screen.** The circle is still drawn and the game still concludes something
is wrong — so the region byte was one wrong answer, not the wrong answer. Whatever check decides
"modified" is still unidentified, and the next round of the same method (measure what the game
reads before it decides) is where to look.

## How the English text is drawn, measured to the byte (2026-08-09)

Why did the American branch draw *nothing*, not even blanks? Scanning the executable for every
`lui` that builds a ROM-window address answers it completely — there are exactly two:

- `0x8002d488`: `lbu 0xBFC7FF52` — the region letter, compared against 'E' (69) then 'A' (65),
  with ≥'F' branching to the Japanese path. This is the *whole* region check: one byte, the one
  we serve. Serving 'A' stores 1 in `[0x80067894]`.
- `0x8002e324`: the text renderer computes `0xBFC7F8DE + (char - 33) * 15` and reads the glyph
  **directly from the ROM window** — no kernel call. Fifteen bytes per glyph, one per row. The
  helper at `0x8002e584` proves the geometry: it walks `t0 = 14..0` rows, one `lbu` per row,
  scanning bits 7..0 to measure the glyph's used column range for proportional spacing.

That extent scan is also why nothing at all was drawn: our ROM answered zero for every glyph
byte, the measured extent came back empty, and the renderer skipped the character entirely.
So the Japanese path asks the kernel (`Krom2RawAdd`) and the English path reads the ROM raw —
two different mechanisms, and the region byte switched us from the first to the second.

The fix is `mem.RomFont`: our own 8×15 ASCII glyphs served at `0x1FC7F8DE`. The three interface
numbers (base, stride 15, index origin '!') come from the game's own disassembly above, and the
pixel art is drawn for this project — nothing is copied from any ROM. The format was confirmed
against a real ROM at that exact address before the glyphs were drawn: fifteen bytes, one row
each, eight wide, most significant bit leftmost, `'!'` first. Uploads went from 13 to 3733, and
three lines of text appear where the message belongs.

**The strokes were a mask bug, now fixed.** The glyphs first rendered as thin strokes, and the
font was ruled out three ways: the upload payload is correct per pixel; the geometry is correct
(`5x1` transfers, `x` alternating 76/77 for the game's one-pixel double-strike, `y` advancing per
row); and *serving the real ROM's glyphs rendered identically*. So it was the renderer.

Measuring the upload payloads settled it. The warning screen draws its text in two passes:
letters first, in white (`0xFFFF`, bit 15 set), then a black pass (`0x8000`) over the whole cell.
On hardware the second pass is a mask-checked copy — GP0(A0) uploads obey GP0(E6) exactly as
drawn primitives do (psx-spx, "Mask/Round") — so it skips every pixel whose bit 15 is already set,
and the white letters survive. `putTexel` ignored the check, so the black pass erased the letters
down to one stray column each. The text had been in VRAM and then overwritten, which is why it
read as strokes. Implementing mask-check and mask-set in `putTexel` (matching `blend()`, which
copies already do) restored it: white pixels in the region went 454 → 2161, and the message reads
"SOFTWARE TERMINATED / CONSOLE MAY HAVE BEEN MODIFIED / CALL 1-888-780-7690".

**And the same rule again, one layer up.** Comparing against a photograph of the real screen
showed the remaining difference: on hardware the red "no" circle passes *behind* the words, and
ours painted over them, cutting each line where it crossed. Same cause — the game draws the text
with the mask bit set, then draws the circle with mask-check on so it skips protected pixels —
and `plot()`, the primitive path, ignored the check exactly as `putTexel` had. Three writers into
VRAM, three copies of the same rule; two of them were missing it. With `plot()` fixed the text
sits in front of the circle, matching the original.

## The message table, and why the text looked shifted (2026-08-09)

The text then sat left of where the real screen puts it, and it was tempting to hunt for a
centring bug. There is none: **the game does not centre anything.** Its message table is data in
the executable, one twelve-byte record per region, indexed by the same region index the ROM byte
sets:

    0x800678A0 + idx*12   →   { u16 x, u16 y, char* text }      (and a scale byte at +0x789C)

    idx 0  x=80  y=92  scale=2   "強制終了しました。\n本体が改造されている\nおそれがあります。"
    idx 1  x=36  y=92  scale=1   "     SOFTWARE TERMINATED\nCONSOLE MAY HAVE BEEN MODIFIED\n     CALL 1-888-780-7690"

So x is a constant, a newline resets the pen to that same x (`sh $s5, 0($s1)`), and the short
lines are centred **by five literal spaces in the string**. The scale byte is the horizontal
repeat count — two for the wide Japanese glyphs, one for ASCII. We were drawing at exactly the x
the game asked for.

What differed was the font's proportions. The cell is 8x15, and the first draft put a 5x7 design
in it doubled vertically only — 5 wide against 14 tall, far narrower than the ROM's glyphs. Since
every line is pinned at the left and each glyph advances by its own measured ink width, a narrow
font makes every line end early, and the eye reads a short line pinned at the left as one shifted
left. Widening the designs to seven ink columns (stretching each row 5→7 rather than re-drawing)
put the longest line at 36..296, centre 166 against the screen's 160 — the original's layout.

## The anti-piracy screen, and why its text is missing (2026-08-09)

The game reaches its "SOFTWARE TERMINATED / CONSOLE MAY HAVE BEEN MODIFIED" screen and draws the
red circle correctly — 65 flat quads in a ring, centred at (160, 120), which the GP0 census shows
as `0x28 x65` and which account for 130 of the frame's 132 primitives. **The three lines of text
are absent entirely**: nothing in VRAM, no primitives, no uploads.

They are absent because they are not the game's own glyphs. The screen calls **`B0(51h)`
`Krom2RawAdd` fifty-six times** — one per character of the message, which is exactly its length —
asking the BIOS for the address of each character's bitmap in the font ROM. We answer nothing, so
the game has nothing to upload.

That makes the missing text a *kernel* gap, not a GPU one, and an interesting one: golden rule 4
keeps a real BIOS out of the repository, so the honest fix is a font of our own in the BIOS stub
region — the kernel is HLE anyway, and its font may be too. `Krom2Offset` (B0:53h) is the sibling
that will want the same table.

Worth noting separately: the screen appearing at all means the machine fails a check the game
makes. That is a question about our emulation's fidelity, not about the disc — the same run
identifies as a licensed disc through `GetID` and answers the drive's `Test 04h`/`05h`
sub-commands. Which check it is has not been traced yet.

## Three functions in a row, one found (2026-08-09)

`0x800309ec`, `0x80030a00` and `0x80030a08` are consecutive one-line functions — a setter, an
empty stub (`jr $ra; nop`), and a display-list helper — reached as slots of the table at
`[0x8006794c]`. The sweep found the first and stopped, so a call through slot +20 landed on
nothing and the game's list-building silently did half its work.

Worth remembering as a shape, not a one-off: **after-return sweeping stops at a stub whose body
is a single `nop`**, because a lone zero word is indistinguishable from the padding rule that
keeps the sweep out of data. Two hints fixed it; the general fix would be to let the sweep cross
a `jr $ra` + zero-slot pair when the words after it decode as a plausible entry.

The evidence it was worth chasing: primitives per run went from 1 to 132.

## Indirect-call seeds (2026-08-08)

libcd reaches parts of itself through function-pointer tables the static analysis cannot read.
The runtime names each miss (`no function at 0x...`); feeding them back closes the loop:

    ./scripts/recompsx.sh gen <SCUS_945.70> \
      --seed 0x80031d28 --seed 0x8003ae40 --seed 0x8003b068 \
      --seed 0x8003b1bc --seed 0x800403b4 --seed 0x8003b224

One of these carries libcd's own `I_MASK |= cdrom|dma` write — without it the CD line never
unmasks and every controller interrupt sits undelivered. `0x8003b224` is the **pad/SIO** interrupt
handler, not the CD one — it dereferences `[0x8006D99C]`, which the image holds as `0x1F801040`,
the SIO0 base, and reads `JOY_CTRL` at +10. The chain element `0x8006d984`
(f1=`0x8003b1bc`, f2=`0x8003b224`) is libpad's. libcd's handler has not been identified yet.
It is a chain element func2: the sweep used to seed its *prologue* at `0x8003b22c`,
eight bytes past the true entry, because GCC schedules two loads ahead of the stack adjust —
fixed in the sweep, and the explicit seed is kept as documentation of what the address is.

An earlier revision of this note said seeding 0x8003b224 regresses the game. It does not. The
"regression" was a wall-clock artefact: the game spends its first ~30–60k frames limping through
VSync timeouts before it installs handlers or touches the CD, and a loaded host let a 40-second
run reach only frame ~29k — still on the normal trajectory, misread as "stuck earlier". The
counters that told the truth all along: the *working* run also shows `handlers 0` at frame 6000.


## libcd's timeout, located (2026-08-08)

Disassembling around the address the poll trace kept naming turned up the wrong thing being
watched, and then the right one.

`ra=0x8003EEB8` is **not** a polling site. The instruction before it is `jal 0x8003f08c`, and the
two before *that* load a string and call `0x800322fc` — the printf that emits
`CD timeout: CD_cw:(...)`. So every CD register read attributed to "libcd polling" was in fact the
post-mortem state dump, taken after the library had already given up. Three sessions of reasoning
were aimed at a conversation that had ended.

The timeout itself is at `0x8003ee48`:

    8003ee48  lui  $v0, 0x003c        ; 3,932,160
    8003ee4c  slt  $v0, $v0, $v1      ; has the elapsed measure passed it
    8003ee50  beq  $v0, $zero, 0x8003eec0   ; no -> keep waiting (returns 0)
    ...                                     ; yes -> print, call 8003f08c, return -1

`$v1` is not a clock. Reading a little further up settles it:

    8003ee2c  lui  $v0, 0x8007
    8003ee30  lw   $v0, 0x7630($v0)    ; counter := [0x80077630]
    8003ee38  addu $v1, $v0, $zero     ; the value tested
    8003ee3c  addiu $v0, $v0, 1
    8003ee44  sw   $v0, 0x7630($at)    ; store counter + 1

**It is a plain spin counter**, one increment per poll, compared against 3,932,160. So the timeout
means "I went round this many times", not "this much time passed" — and that makes it directly
observable: watch `0x80077630`.

Two readings follow, and they are distinguishable by that one word:

- If it reaches 3.9M, the loop really is spinning that hard and the interrupt is arriving too late
  or not at all — a scheduling question.
- If it is already past 3.9M when a wait *begins*, the counter is never being reset between
  attempts and every wait after the first fails instantly, regardless of what the controller does.
  That would explain a first attempt behaving differently from all the rest, which is exactly the
  shape of `CdInit` looping.

A memory watch on `0x80077630` decides it in one run. The real polling loop is further up, before
`0x8003ee10`.


## What the spin counter said (2026-08-08)

Watched `0x80077630` at every heartbeat: **it is 0, always.** So the game is not sitting in
libcd's timeout loop at all — those `CD timeout` lines were printed once, early, and passed. The
counter never climbs because that loop is not where the game lives.

Which retires "CdInit loops forever" as the explanation for the stall. The game is stuck
somewhere else, and the profile names it: `f_8003ebf8` calls `f_800320ec`, which reads a hardware
counter, on every iteration of a tight loop. **That** is the wait to understand next — it is a
timer poll, not a CD poll, and the two have been conflated all along because the CD's error
messages are the loudest thing in the log.


## The stalled loop waits on a word nothing writes (2026-08-08)

`f_8003ebf8` opens by reading `[0x8006DBBC]` and branching on it being under 2. A write watch on
that address, with the writer's return address from `Memory.raHint`, caught **nothing at all** —
across a full run, no code ever stores to it.

So the value stays whatever the executable image put there, the branch always goes the same way,
and whatever sets that state never runs. That is the shape of code the analysis has not reached:
either a function still missing from the program (the earlier black holes were found exactly this
way, by naming what the runtime could not dispatch), or a subsystem whose absence means its
initialiser is never called.

Searched, statically, two ways. In the **emitted program** the address is read twenty times and
written zero times. In the **raw executable** there is not a single `sb`/`sh`/`sw` anywhere with
displacement `0xDBBC`, which is how `lui $at, 0x8007` + `sw $v0, -9284($at)` would encode.

Two readings, and they are not equally likely:

1. **The writer lives in an overlay** — code loaded from the disc that is not in the main
   executable at all. Crash Bash uses overlays, and this would close the loop back to the CD: the
   state is set by code the game has not been able to load.
2. **The address is held in a register** and stored through with a small or zero displacement, in
   which case this scan was too narrow to see it. A scan that resolves `lui`/`addiu` pairs into
   absolute addresses would catch it; the tool's jump-table recovery already does exactly that
   kind of constant folding and could be pointed at stores.

Reading 2 is worth ruling out first because it costs one scan and would be embarrassing to miss.
If it comes back empty, reading 1 stands, and the boot screen is behind the disc after all.


## The boot screen, and the seven things between it and us (2026-08-09)

The game shows "Sony Computer Entertainment America Presents". Getting there corrected a reading
recorded twice above, and then found six more defects, each of which only became visible once the
one before it was fixed.

**`f_8003ebf8` was never waiting on anything.** The branch is `slti $v0, $v0, 2` then
`bne $v0, $zero` — when `[0x8006DBBC] < 2` it *skips* a printf and carries on. It is a debug
verbosity level, and nothing writes it because zero is the right value. Both scans above were
answering a question that did not need asking; the two commits that recorded the "stalled loop"
are wrong and this supersedes them.

**The exception hook was entered with whatever `v0` the interrupted code held.** The game calls
its own `setjmp` at `0x8003acec`, hands the buffer to `HookEntryInt`, and reads the landing site
at `0x80031ae8` as a `setjmp` return: zero means "carry on with initialisation", non-zero means
"an interrupt brought me here, dispatch it". `KThreads.enterJmpBuf` restored every saved register
and left `v0` alone, so that test was a coin toss — and the CD driver is registered on the
non-zero branch. This is why libcd polled its way through `CD_init` and still reported
`Sync=NoIntr`: the protocol was working, the driver was not running.

Its interrupt callbacks live in the game's own table at `0x80067B00`, indexed by IRQ number,
installed through a vtable at `[0x80068B84]`. After the fix: IRQ0 `0x80036d2c` (libetc vblank),
IRQ2 `0x8003f5f0` (libcd), IRQ3 `0x8003aee8` (DMA).

**`0x80031ae8` is mid-function**, which is the general point: a `longjmp` lands after a `jal` by
construction, never on a prologue. A dispatch table of function entries answers "no function
there" to every resume, and the jump silently does nothing.

**The sweep could not see a scheduled prologue.** GCC hoists loads above the stack adjustment, so
`0x8003add4` and `0x8003c790` open with `lui`/`lw` and reach `addiu sp` two and four instructions
in. Code that follows a return is now taken as a function: 91 more of them.

**The CD-ROM, three defects.** It never re-armed after answering — `ReadN`'s first answer is an
INT3 meaning "started", and nothing scheduled the sectors it promised. It ignored Setmode bit 5,
while libcd asks for whole sectors (`Setmode A0`) precisely so it can check each sector's own
address header. And clearing the request bit resets the data FIFO; it does not discard the
drive's sector. Reading it as "done" moved the drive on one sector early, so every transfer
delivered sector N+1 where N was asked for — which the game correctly rejected as a sector error.

**Three DMA channels did not exist.** Channel 3 is how a sector reaches RAM; channel 4 is how
wave data reaches the SPU, and libspu waits on an event for it; channel 6 builds the ordering
table, without which `DrawOTag` walks uninitialised memory. The game says so itself: "empty
prims".

**GP0(80h) was sized and skipped.** VRAM-to-VRAM blits are how this game draws — 6931 of them
against a single rectangle in 8000 frames. Uploads put the artwork in VRAM; the blits put it on
the screen.

### Overlays

`CRASHBSH.DAT` is loaded into `0x80076288..0x800d7490` and called through a vtable. The runtime
now recognises a miss into anything the disc wrote and writes RAM out with the command to
recompile it (`--ram ram.bin --ram-range <lo>..<hi> --seed <addr>`), and the tool lays that slice
in above the executable. Two limits are already visible and are the next work:

- **A capture describes one overlay.** The game loads several into the same memory, so addresses
  that were code when the capture was taken are data later, and the reverse. Seeds are validated
  before being believed, and a function traced into data above the executable is abandoned rather
  than being a hard error — but that only makes the tool survive the ambiguity, it does not
  resolve it. Plan section 6.4's per-overlay identification is what does.
- **The sweep stops at the executable's end.** Above it the tool is reading a memory image where
  code and assets are adjacent, and sweeping finds functions in texture data.


## Overlays, from nothing to config (2026-08-09)

The workflow that produced the two stanzas in game.json, recorded because it is the workflow for
every game:

1. Generate from the config with `overlays: []` and run. A dispatch miss into memory the disc
   wrote is reported with the span, the sector it came from, and the numbers to paste:
   `loadAddr 2147978384 length 387072 ... from disc sector 35799`.
2. Turn the sector into a file offset — CRASHBSH.DAT starts at LBA 236, so
   `(35799 - 236) * 2048 = 72833024` — and write the stanza. The `boot` overlay is the last
   387072 bytes of the file exactly, which is a good sign the span was coalesced correctly.
3. Regenerate, run again. The next miss named the second overlay the same way: `stage`,
   32 KB into the middle of boot's window, sector 28178. Two rounds, two overlays, no captures.
4. Misses whose `ra` is *inside* an overlay are base functions reached through the overlay's
   pointers — they go into `functionHints`, not into a stanza.

What the game taught the model: `stage` does not replace `boot`, it nests inside it — both are
genuinely present, and the smaller window answers for the addresses they share. Exclusive
windows were the first implementation and the real game refused them within a minute.

The audit after bring-up (session log 2026-08-09) tightened three things worth knowing when
reading the code: a resident overlay shadows the executable even where it has no code (no
fallthrough to stale base functions); the executable's own functions inside a window are always
dispatched, never direct-called, for the same reason; and a window shorter than its own
fingerprint is a build error, because the tool and the runtime would hash different lengths and
the overlay would silently never activate.

## libpad's handlers, found by plugging a controller in (2026-09-27)

Until SIO0 had a device on it, libpad only ever ran its probe: the port answered FFh and never
acknowledged, and the library settled on "no controller". With a digital pad answering, it runs
its per-port state machine, whose steps it reaches through pointers — so the first Dreamcast run
with a pad connected (Flycast plugs one in) reported three functions the analysis had never
seen: `0x80040540`, `0x80040584` and `0x80040910`. All three work on libpad's port records at
`0x8007765c`, F0h apart. Headless runs keep the ports empty and never reach them, which is why no
digest ever pointed at them; the hints are in game.json.
