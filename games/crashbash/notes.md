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
