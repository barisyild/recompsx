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
  The keyboard also types (`bp_key_*`, ADR-0036) — the runtime turns that on while the machine's
  PS/2 keyboard is polled (ADR-0040) — and the mouse is the pointer the machine's Sony Mouse
  follows (`bp_mouse`, ADR-0038, ADR-0040): `bp_present` keeps the letterbox rectangle,
  `latch_mouse` scales window points to renderer pixels (high-DPI) and reports a fraction of that
  rectangle; X1/X2 are the side buttons. `bp_mouse_pointer`: the system cursor while the machine
  has no pointer, the art of `src/backend/api/pointer_art.h` as a color cursor while its mouse is
  polled, and no cursor while the kernel says a pad is in use.
- QUIT (`bp_exit_to_menu`, ADR-0041): the desktop is the host's menu — `bp_shutdown`, then
  `exit(0)`. The runtime has written the memory card back before it calls this.
- Network (`bp_http_*`, ADR-0040): the i-mode centre's HTTP requests over non-blocking TCP —
  POSIX sockets, Winsock on Windows — resolved with `getaddrinfo`, connected in the background
  (`poll` + `SO_ERROR`), the request sent as the socket takes it and the response read raw until
  the server closes; SIGPIPE is kept away (`SO_NOSIGPIPE` / `MSG_NOSIGNAL`). Nothing blocks a
  frame but a name lookup.
