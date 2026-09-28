# Dreamcast backend — agent notes

Read this when the work touches `src/backend/dreamcast/`, the Dreamcast branch of
`build/templates/CMakeLists.txt`, `scripts/build-dc.sh`, `scripts/dc-flycast-prof.sh`,
`scripts/dc-prof.py` or a CDI. The root `AGENTS.md` still applies in full.

## Rule: sh4zam first

**On the Dreamcast, sh4zam is always preferred.** It is vendored at `vendor/sh4zam` (upstream
github.com/gyrovorbis/sh4zam, MIT, pinned as a submodule; its C API needs C17, which the C files
are built with). The build takes its headers and assembles `source/sh4/shz_mem_sh4.s`, which its
larger copies and `shz_memset8` call into; a new sh4zam group whose inline code calls out of line
needs its source added to the Dreamcast `BACKEND_SRC` the same way. **Whenever a C standard library function has an sh4zam counterpart, the sh4zam
one is used** — in new code, and when touching old code. Include the header of the group you
use (`<sh4zam/shz_mem.h>`, `<sh4zam/shz_scalar.h>`, `<sh4zam/shz_trig.h>`, ...).

| std                                  | sh4zam                                                       |
|--------------------------------------|--------------------------------------------------------------|
| `memcpy`                             | `shz_memcpy`, or the sized form when alignment and size are known: `shz_memcpy2/4/8/32/64/128`, `shz_memcpy32_1` (one 32-byte line), `shz_memcpy2_16` (16 halfwords), `shz_memcpy4_16` |
| `memmove`                            | `shz_memmove`                                                |
| `memset`                             | `shz_memset8` (8-byte aligned, multiple of 8), `shz_memset2_16`; plain `memset` only where neither fits |
| `sqrtf`, `sinf`, `cosf`, `floorf`, `fabsf`, `fminf`, `fmaxf`, `powf`, ... | `shz_sqrtf`, `shz_sinf`, `shz_cosf`, `shz_floorf`, `shz_fabsf`, `shz_fminf`, `shz_fmaxf`, `shz_powf`, ... |
| `__builtin_expect`, `__builtin_prefetch` | `SHZ_LIKELY` / `SHZ_UNLIKELY`, `SHZ_PREFETCH`              |
| 32 bytes to the TA or texture memory | `shz_sq_memcpy32_1` / `shz_sq_memcpy32` (store queues)       |

Functions with no counterpart (`memcmp`, `snprintf`, file I/O) stay std. Keep sh4zam's contracts:
the sized copies want their stated alignment; `shz_dcache_alloc_line` (`movca.l`) is only for a
32-byte-aligned line that is then written **whole** — the rest of the line is left undefined, and
Flycast treats `movca.l` as a plain store, so a mistake there shows only on a console; the
`fschg` routines clobber `fr0`-`fr7`, the `_xmtrx` ones XMTRX. Release builds define `NDEBUG`,
which removes sh4zam's alignment asserts — check alignment by construction, not at run time.

## Measuring

Flycast (the profiling fork `scripts/dc-flycast-prof.sh` drives) counts guest cycles, but it does
not model cache misses, store-queue bursts, `movca.l`, VRAM/bus timing or FPU pairing. Its
figures are the gate for **correctness** and for **CPU-work regressions** only; a change made for
the hardware — sh4zam, alignment, prefetching, store queues — is judged on a real console with a
CDI from `out/dc/`. Report Flycast numbers with that caveat, never as the verdict on such a change.

- Build: `./scripts/build-dc.sh <out-dir-name> --max` (Release -O3, LTO, `DC_MAX_FLAGS`; the link
  takes minutes). A whole-game reflaxe.CPP transpile takes several minutes and gigabytes of
  memory: run one at a time.
- CDI: copy `build-dc-max/SYMS.BIN` into the data directory, then
  `mkdcdisc -q --allow-overwrite -N -e <elf> -D <data dir> -n "<name>" -a recompsx -s <SERIAL> -o <cdi>`.
  `-s` is the game's product code (SCUS94570): the disc's serial, which Flycast keys its per-game
  VMU by (Per Game VMU A1, on by default). Without it mkdcdisc makes one from a hash of the boot
  binary, so every build gets a new, empty VMU and saves seem to vanish. The BIOS, with no disc,
  shows the shared VMU (`vmu_save_A1.bin`), not a game's.
- Data directories under `out/dc/` hold `BOOT.EXE`, `DISC.BIN`, `SYMS.BIN` and `RECOMPSX.CFG`
  (the command line: `--video-hw --audio-hw [--dc-overlay]`; profiling adds
  `--dc-bench=FROM:TO --dc-rxprof`). Bench windows: Crash 3 `4700:5000` (attract demo), Crash Bash
  `18800:20300`. A `--dc-rxprof` run keeps the pad ports empty so every run measures the same
  frames.
- Profile: `scripts/dc-flycast-prof.sh <cdi> <elf> <out.txt>` then
  `scripts/dc-prof.py <out.txt> <elf> --top N [--hot FUNC]`; `--callers NAME` on the first counts
  callers. `RXPROF_SHOTS=<dir> RXPROF_SHOT_SEC=<s>` saves screenshots by emulated time — the
  way to check a picture. The count is exact for a given binary; a relink moves code, so compare
  builds of the same sources.

## How the backend draws (hardware mode, ADR-0011)

- Primitives are recorded as they arrive (`bp_gpu_*` → `g_cmds`, `g_states`, both 32-byte
  records, one cache line each, allocated with `movca.l` and prefetched while walked) and built
  into one PVR scene per present (`build_scene`): one translucent list, autosort off, submission
  order, no depth — never re-derive order with Z (ADR-0011, the amended section).
- Everything bound for the TA or texture memory goes through the store queues: vertices written
  straight into `pvr_dr_target()`, whole headers and vertices with `put_hdr`/`put_vtx`, runs of
  texture data with `txr_put` (`dc_internal.h`, sh4zam copies). `pvr_prim` and `pvr_txr_load`
  are not used. `pvr_list_begin` holds `sq_lock(PVR_TA_INPUT)` for the whole list, and texture
  memory shares the TA's QACR region, so a texture written mid-list does not disturb it.
- Code that walks emulated VRAM (the texture decoders, background uploads) prefetches the lines
  it will read next with `SHZ_PREFETCH` — a console misses the cache on nearly every new line.
- Textures are decoded out of emulated VRAM into twiddled PVR textures through the store queues:
  4bpp pages are mirrored (`page4_mirror`) with palettes in 64 banks of 16, addressed by content;
  what does not fit is baked (`bake_slot`, 64x64 patches on `BAKE_STEP` boundaries). Anything
  that writes emulated VRAM reaches here as `bp_gpu_dirty`, which evicts by page and palette.
- `screen_origin` decides which buffer a primitive draws into; the runtime's off-screen rule
  (`gpu.Gpu.offscreen`, ADR-0030) is the same rule, so off-screen drawing never arrives here.
- Semi-transparency: modes 0/1/3 as PVR blends; B-F as three passes; mixed-CLUT primitives split
  into solid and STP passes from baked variants.
- Pads: maple controllers mapped to PS1 digital pads (`dc_input.c`); A+B+X+Y+Start quits. A maple
  keyboard is pad 0 as well (the desktop's key map, `keyboard_pad`) and types while text entry is
  on — while the machine's PS/2 keyboard is polled (ADR-0036, ADR-0040) — by the keyboard's own
  region — Flycast passes the host's keys on by position and
  reports a host layout it does not recognise as US (Turkish Q: its '.' key types '/'); the keypad
  types the same under every region. A maple mouse is the pointer the machine's Sony Mouse
  follows (ADR-0038, ADR-0040): a vblank handler adds up every bus frame's motion, the pointer lives on the
  640 x 480 screen, and `draw_mouse_pointer` draws it last in each scene — the art of
  `src/backend/api/pointer_art.h` as a 16 x 32 ARGB1555 texture, a texel a pixel (both
  `build_scene` and a blank present end with it) while the kernel says it is shown
  (`bp_mouse_pointer`: the machine's mouse is polled, no pad in use). In Flycast the host mouse
  and keyboard must be assigned to the same maple port as the Dreamcast Mouse and Keyboard
  devices, or those hear nothing.
- Network (`dc_net.c`, `bp_http_*`, ADR-0040): the i-mode centre's HTTP requests over
  KallistiOS's TCP. The network comes up at the first request, not at boot — `net_init` (the
  broadband or LAN adaptor, DHCP or the flashrom's settings) in a thread of its own while the
  requests wait — so a game that never goes online never waits for it; no adaptor, and every
  request fails. Sockets are non-blocking; a name lookup is the one wait. Flycast needs its
  broadband adaptor emulation for any of it; untested on hardware.
