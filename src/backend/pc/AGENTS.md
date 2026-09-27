# PC backend (SDL2) — agent notes

Read this when the work touches `src/backend/pc/`, `scripts/build-pc.sh` or
`scripts/run-pc.sh`. The root `AGENTS.md` still applies in full.

- `backend_sdl2.c` is the only file in the project that includes SDL: window, audio, keyboard and
  game controllers, files, storage. Keep it boring — no emulation logic, nothing that can reach
  emulated state.
- It draws in software only: `bp_caps(BP_CAP_GPU_DRAW)` is 0, so `--video-hw` falls back to the
  runtime's rasteriser and `bp_present` blits the VRAM window. Hardware drawing is the Dreamcast's
  and the browser's.
- It is how the C++ build is run on a desktop: `./scripts/build-pc.sh <out-dir>` (add `--null`
  for the null backend), `./scripts/run-pc.sh <out-dir> [--headless-hash N]`. A headless digest
  from here must equal the JavaScript one — that comparison is the point of the C++ build.
- Input: SDL game controller n is port n, and the keyboard is merged into port 0 (which is a
  digital pad when no controller is there); the key layout matches the browser's (SDL2 names).
