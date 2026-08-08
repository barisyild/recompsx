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
      --seed 0x8003b1bc --seed 0x800403b4

One of these carries libcd's own `I_MASK |= cdrom|dma` write — without it the CD line never
unmasks and every controller interrupt sits undelivered.

**Do not seed 0x8003b224.** It lies inside another function's extent, and seeding it truncates
the host function (the tool lacks §6.2's multi-entry duplication), which regresses the game to
before handler installation. It stays a reported black hole until the tool learns overlap.
