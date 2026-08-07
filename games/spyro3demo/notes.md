# Spyro 3 demo (bundled on the Crash Bash disc) — second bring-up target

This exists to keep the project honest about its actual goal: **recompsx targets all PS1 games,
not one**. A second game whose engine shares nothing with Crash Bash is the cheapest possible
guard against baking game-specific assumptions into the tool or runtime. It also happens to be
free — it ships on the same disc as the primary bring-up target, so it needs no extra dump.

Different studio (Insomniac vs Eurocom), different engine, different data layout. Where Crash
Bash exercises overlays and 4-player multitap, this one exercises a streaming 3D engine with a
large WAD and a speech STR. When something works for both, it is probably general.

## PS-EXE header (SPYRO3.EXE), verified 2026-08-08

| Field | Value |
|---|---|
| magic | `PS-X EXE` |
| initialPc | `0x8005A628` |
| initialGp | `0x00000000` |
| loadAddr | `0x80010000` |
| fileSize | `0x0005A800` (370,688) → occupies `0x80010000`–`0x8006A7FF` |
| dataAddr/dataSize, memfillAddr/Size | 0 |
| spBase / spOffset | `0x801FFFF0` / 0 |

File size on disc 372,736 = 0x800 header + 0x5A800 payload — exact, not truncated.
sha256 `56473545d46de5620ac4e52bed43401e7b978f2bdc85f473cfc87176eb7fd89e`.

Companion data on the disc: `SPYRO3/WAD.WAD` (16,797,696 bytes), `SPYRO3/SPEECH.STR`
(32,249,856 bytes — an MDEC/XA stream, useful as a real STR fixture for the MDEC bring-up).

## Status

Not scheduled as its own milestone. Used opportunistically: run `analyze` on it whenever the
tool changes, and treat any Crash-Bash-only assumption it exposes as a bug in the tool.
