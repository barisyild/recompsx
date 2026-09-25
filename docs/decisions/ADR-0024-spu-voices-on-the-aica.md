# ADR-0024: The SPU's voices on the Dreamcast's AICA
Status: accepted   Date: 2026-09-25

## Context
The Dreamcast profile overlay put the SPU at 244 ms of every 30 emulated vblanks in Crash Bash
gameplay: about a fifth of the emulator's time, on a machine that is already short of it
(PROGRESS.md, 2026-09-25). Almost all of that is mixing: decoding ADPCM, stepping envelopes,
multiplying volumes, summing twenty-four voices at 44.1 kHz on the SH-4, then streaming the mix
to the AICA. The AICA is a 64-channel sampler with its own 2 MB of RAM that does exactly the
multiply-and-sum part in hardware, and it sits idle playing one stream.

The state a game can read (envelope levels, block positions, ENDX, the loop flags) must not
change: the SPU already has an output-off mode (`--no-audio`) that advances every voice
without mixing, held to the same state by `SpuAdvance` and the game digests.

## Decision
Add an optional backend capability, `BP_CAP_SPU_VOICES`, and three ABI functions
(`bp_spu_ram`, `bp_spu_dirty`, `bp_spu_voice`). Under `--audio-hw`, on a backend that offers it
and never on a headless run, the SPU runs with output off and, after each batch, sends each
voice whose key-on count, on/off state, pitch or folded volume changed, plus the span of sound
RAM written since the previous batch. The Dreamcast backend decodes a voice's sample once, from
its start address to the block that ends it, with the SPU's own arithmetic and loop rule, keeps
the 16-bit PCM in AICA RAM keyed by start address (least recently used evicted, written ranges
invalidated), and plays each SPU voice on its own AICA channel through the KallistiOS ARM
firmware's channel commands. Envelopes stay the SPU's: they arrive as volumes, because the
AICA's ADSR has different curves.

## Alternatives
- Mixing faster on the SH-4: the mix is already voice-major and silent voices are skipped.
  What remains is arithmetic per sample the AICA does for free.
- Uploading raw ADPCM and letting the AICA decode it: the AICA's ADPCM is Yamaha's, not Sony's.
  The blocks would have to be transcoded anyway, which is a decode.
- Using the AICA's own envelopes: different curves and rates, and the runtime would still need
  its own for the state games read. The volume update is cheap because only changes of the
  quantised 0..255 volume become commands.
- Streaming each voice separately: 24 streams of PCM through the G2 bus costs more than the one
  mixed stream it replaces.

## Consequences
- What is heard is an approximation, a presentation fork like `--video-hw` (ADR-0011): no
  reverb, noise voices or pitch modulation. A loop's seam replays the first pass's decode, where
  the SPU carries the ADPCM filter history across the jump. A loop target the game writes after
  key-on is not followed. Volume moves in 2.9 ms steps. A sample longer than 65534 samples (the
  channel's 16-bit loop registers) is cut; none of Crash Bash's 128 distinct samples comes close
  (longest 52024).
- The first key-on of a sample pays its decode and upload on the emulator thread, shown as
  `aica <ms>/<decodes>` on the overlay.
- Verified: the C decoder against the runtime's `decodeBlock`/`advanceBlock` at every key-on of
  9000 frames of Crash Bash, 128 distinct samples, 1,239,336 PCM values identical with identical
  loop points and lengths. Digests are unchanged on both targets because the path is off on every
  run that hashes.
