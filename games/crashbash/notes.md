# Crash Bash (NTSC-U, SCUS-94570) — bring-up notes

Clean-room observations recorded by this project. No game code or data lives in this repository;
everything below is a measurement taken from the user's own dump, or a plan for taking one.

## Dump shape

The reference dump on the development machine is an **extracted-files directory**, not a BIN/CUE
(see `docs/specs/tool.md` §1.1 for how that input mode works and its LBA caveat). Layout:

```
SYSTEM.CNF
SCUS_945.70              432,128 bytes   boot executable
BASHY.                31,752,000 bytes   (name has an empty ISO9660 extension)
CRASHBSH/CRASHBSH.DAT 73,220,096 bytes   main data archive
SPYRO3/SPYRO3.EXE        372,736 bytes   bundled Spyro 3 demo — see games/spyro3demo/
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
- **Multitap**: which path the game uses (kernel `InitPad` buffers vs raw SIO0) — both are
  implemented, but the 4-player arming behavior needs verifying against the real game.

## Prior art on this machine

The sibling project `crash-bash-editor` (the user's own work) contains extensive format
documentation for this game's data files. It is a legitimate reference for *data* formats and
disc rebuilding. It says nothing about executable code layout, which is what recompsx needs — do
not assume overlap.

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
