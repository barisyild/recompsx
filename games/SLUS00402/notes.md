# Tekken 3 (NTSC-U, SLUS-00402) — bring-up notes

Clean-room observations recorded by this project. No game code or data lives in this repository;
everything below is a measurement taken from the owner's own dump.

## 2026-10-05: first bring-up (JavaScript), and what it needed of the machine

The disc: a MODE2 data track (632 MB; `\TEKKEN3\SLUS_004.02;1`, TEKKEN3.BNS, the XA music in
TEKKEN3.XAS, TEKKEN3.DA, TEKKEN3.DMY) and two CD-DA tracks, which nothing here plays yet.

**The code.** The executable, thirteen function hints (`functionHints`: entries reached only through
pointers on the paths below) and five overlays, all from TEKKEN3.BNS and all but one loaded at
0x800b8d58, the same window: 250156 (the attract sequence's characters), 251748 (the opening
movie's player, its MDEC library among it), 251888 (after the first demo), 251522 (ARCADE MODE),
and 251471 at 0x800b0548. Each was found the same way: a run that reached a pointer this build did
not describe, reported by the runtime with the overlay's sector and length (`out/_work/t3/iterate.sh`
turns those reports into game.json entries). Two paths drive the runs:
- the attract loop with pad 0 plugged and idle, `--pad-script 0:-`: Namco's logo, the opening movie
  (about 7,500 frames before ADR-0059, a sixth fewer after), the title, a demo fight, CHARACTER TIME
  RECORD, NAMCO PRESENTS, the characters' introductions;
- a played path, `out/_work/t3/monkey.py`: START through the movie and the title, CROSS into ARCADE
  MODE and the player select, then a fight of steps, punches and kicks (Xiaoyu against King, then
  Nina).
`--pad-script` takes `frame:buttons` from frame 0; a `0:` put in front of a script makes it
unreadable, and the pad unplugged — the first played runs were the attract loop again.

**What the machine lacked** — each now done for every game, not for this one:
- the MDEC (ADR-0057): the movie, the portraits of the player select and VS screens;
- textured rectangles (ADR-0058): every name, timer and caption was a black box;
- XA-ADPCM (ADR-0059): the music and the movie's sound; the drive reads XA streams in real time;
- narrow (8- and 16-bit) DMA register accesses, DICR's write-one-to-clear among them;
- CdlSetfilter, CdlGetlocL and CdlGetlocP (the movie player reads each sector's subheader);
- a switch table bounded by an index scaled in its own register (`sll $v1,$v1,2; addu
  $v1,$v1,$v0`): read one entry too long before (tools/recomp TableFinder).

**Not a bug: the "cut" fighters.** The fights run 368x480 interlaced from one buffer, drawing while
it is on screen. A picture taken between two vblanks — the browser paused mid-frame — shows the
floor drawn over the last frame's legs and the legs not yet redrawn; at every vblank (sixteen in a
row checked, software and WebGL) the frame is whole.
