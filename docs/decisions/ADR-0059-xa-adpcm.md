# ADR-0059: XA-ADPCM — decoded by the drive into the SPU's CD input, read in real time
Status: accepted   Date: 2026-10-05
Part of "Tekken 3 must run properly" (the owner, bringing up SLUS00402): its music and its movies'
sound are XA-ADPCM, and none of it played.

## Context

Under Setmode bit 6 the CD controller sends XA-ADPCM sectors — Form 2 sectors whose subheader's
submode has the audio bit — to the SPU's CD audio input instead of to the CPU; under bit 3 only
those whose file and channel match Setfilter's (psx-spx, "Setmode", "Setfilter"). A stream
interleaves channels: Tekken 3's TEKKEN3.XAS holds its songs eight to a file, one sector in eight
each, and its movies interleave their sound with their pictures.

The drive delivered every sector to the CPU, audio ones included, and nothing decoded them. It
also read slower than a disc spins: after each data sector's INT1 — itself deferred by the
acknowledgement latency — it waited a whole sector time again, so a double-speed stream read
123 sectors a second where the disc holds 150.

## Decision

- **The drive plays audio sectors itself** (`Cdrom.audioSector`): under Setmode bit 6 a sector with
  the audio submode bit is decoded when the filter passes it (bit 3 off, or file and channel
  match) and skipped when not, and never delivered — the next sector is read a sector time later
  whatever the CPU is doing. Data sectors are delivered as before, whatever Setfilter says.
- **`cd.XaAdpcm` decodes** psx-spx's way: 18 portions of 28 samples a block, 4- or 8-bit, mono or
  stereo, `(t << 12 or 8) >> shift` plus `(old * f0 + older * f1 + 32) >> 6`, clamped; then
  psx-spx's 25-point zigzag interpolation, 37800 Hz to 44100 (seven outputs per six inputs; 18900
  Hz fed doubled), its products shifted term by term as psx-spx writes it. A new read resets the
  decoder's history; Pause, Stop and Init drop what was not yet played.
- **A FIFO between the drive and the SPU, primed**: the SPU takes one pair per sample in emulated
  time (`Spu.addCdInput`, under SPUCNT bit 0), through the controller's four CD volumes and mute
  bit, then the SPU's CD volume (1F801DB0h/1F801DB2h), into the mix before the main volume. Nothing
  is taken until two sectors' worth is in, after a start or running dry, because a stream's rate is
  exactly the SPU's and an unprimed FIFO would touch empty at every sector. With the voices on a
  backend's sampler (`--audio-hw`), the CD input is mixed in software and pushed with the declined
  voices.
- **Under Setmode bit 6 the drive reads in real time**: a sector every sector time, the answer's
  latency inside it rather than added to it. Other reads keep their timing, and with it every
  game's timeline that does not stream XA — Crash 3's and Crash Bash's digests and the frame
  windows the Dreamcast benches measure.

## Alternatives

- **Real-time reading for every read.** It is the hardware's, but it moves every load of every game
  earlier by a sixth: all digests and every bench window recorded so far would change for a
  timing that nothing has shown to matter. Kept as a known difference (Consequences).
- **The SPU's capture buffers** (the CD's samples written into sound RAM at 0-7FFh): state a game
  could read; no game here does, and without them the FIFO is sound only — no digest depends on it.
- **Floats or a resampling library**: not exact, and not the same on every target.

## Consequences

- Tekken 3 has its music and its movies' sound (JS: 18.8 XA sectors a second through the opening
  movie, 150 sectors a second in all; no gap after the FIFO primes). Its movie now runs at its real
  speed, about a sixth shorter than before.
- `tests/conformance/XaDecode.hx`: every format against psx-spx's decoder written out in the test,
  the FIFO's priming — JS = C++ (a nested `>>>` lost the nibble's sign on C++ first: upstream
  defect 11, written around with `>>`).
- Crash 3 and Crash Bash stream no XA in their digest windows: 52875c77 and 37eefb07 unchanged.
- The frame report's CD field counts XA sectors decoded (`…drop/Nxa`).
- Not done: CD-DA tracks (Tekken 3's disc has two; `CdlPlay` stays silent), XA emphasis, the
  capture buffers, and real-time timing for data reads outside XA mode.
