# Browser backend (JavaScript) — agent notes

Read this when the work touches `web/` (the page, `gpu-webgl.js`, the audio worklet),
`src/shims/js/`, `scripts/build-web.sh` or `scripts/serve-https.py`. The root `AGENTS.md` still
applies in full; JavaScript is also the reference target for digests (ADR-0003).

- There is no C backend here: `src/shims/js/shim/Backend.hx` is the ABI for JavaScript and
  forwards to a host object the page puts on `globalThis.recompsxHost`. Under Node there is no
  host: headless runs (`node game.js <exe> <bin> --headless-hash N`) never draw, never take input
  and are the digest reference.
- Logs go to `console.log` only, never into the page (it re-rendered on every line). Read them
  with the browser tool's console reader.
- Hardware drawing is `gpu-webgl.js` (ADR-0020): WebGL2, `vramTex` (R16UI, emulated VRAM as the
  runtime wrote it) and `fbTex` (RGBA8, the rendered picture), texels decoded in the shader,
  primitives in submission order, the four blend equations, the mask bit as the stencil (it
  stores the bit a write would: cleared unless "set", set in a subtracting primitive's blending
  pass). Drawn tiles are converted back into `vramTex` when a primitive samples them. The page
  loads the renderer under its own version from `build.json`.
- Because drawn pixels become texels, the renderer must hear of every upload, not only of those
  that changed emulated VRAM: the shim answers `BP_CAP_GPU_UPLOADS` (capability 6) and the
  runtime then reports them all (`Gpu.reportUploads`). Without it Crash Bash's menu lost all its
  text after the attract loop's cutscene: a 511x511 rectangle clears VRAM under the font, the game
  uploads the same font again, emulated VRAM (never cleared — the rectangle was ours) did not
  change, and `vramTex` kept the black.
- Storage (`bp_storage_*`): the page keeps blobs up to 256 KB in `localStorage` as
  `recompsx:<name>` (base64) — the console settings `system.cfg` (ADR-0034), later memory cards;
  larger ones (the VRAM dump) are only logged. The dev server sends `Cache-Control: no-cache` for
  the page and build.json, so an edited page is never served stale beside a new bundle.
- Input: `src/shims/js/shim/Input.hx`, browser externs (`js.Browser`, `KeyboardEvent`,
  `Gamepad`), SDL2 key names, the standard gamepad mapping. It also types for the machine's PS/2
  keyboard (ADR-0036, ADR-0040): while text entry is on — while that keyboard is polled —
  `KeyboardEvent.key` goes to a queue and only the arrows stay pad buttons. Synthetic key events reach it, but a pad press must outlast a vblank — and a
  hidden pane throttles rAF to about one frame a second, so hold presses for over a second there.
  The pointer is what the machine's Sony Mouse follows (ADR-0038, ADR-0040): pointer events over
  `recompsxHost.screen` (the page's
  `.screen` box, which both renderers fill), as fractions of it; the context menu and the side
  buttons' history navigation are kept from the page there while the machine has a pointer.
  It has one while its mouse is polled (`bp_mouse_pointer`): the class `pointer` on the box,
  whose cursor is the Dreamcast's pointer art (`.screen.pointer` CSS, 1x and 2x PNGs of
  `src/backend/api/pointer_art.h`), and `cursor: none` while the kernel says a pad is in use;
  before that the page's own cursor. The browser tool's `hover` and `left_click` are real pointer
  events and reach it. `Input.attach` applies the state a mod set before the page attached.
- QUIT (`bp_exit_to_menu`, ADR-0041): `recompsxHost.exitToMenu` in `index.html` reloads the page,
  which is its start screen; the memory card is already in local storage. Node ends the program.
- Network (`bp_http_*`, ADR-0040): `recompsxHost.httpOpen/httpRead/httpClose` in `index.html`
  send the i-mode centre's raw HTTP request with `fetch` — its method, the headers a page may set
  (never Host, Content-Length, Connection or User-Agent) and its body, to `http://host:port/path`
  (`https://` from an https page, which may fetch nothing else) — and rebuild the raw response
  (an HTTP/1.0 status line, the headers but Content-Length, Content-Encoding, Transfer-Encoding and
  Connection, a Content-Length of what arrived, the body). So a server must allow the page's
  origin (CORS), and the browser sends its own User-Agent. Node has no network.
- Mods (ADR-0033): `./scripts/build-web.sh <SERIAL> --mods <id,id | all>` builds the game with
  `games/<SERIAL>/mods/<id>` in (`-D recompsx_mods`); `build.json` lists them. Without the flag
  the bundle is the unmodded game.
- Build and serve: `./scripts/build-web.sh <SERIAL>` writes `out/_web` and links `web/`;
  `python3 scripts/serve-https.py` serves it (a LAN address needs https for WebKit's JIT). In an
  agent session, preview it with the browser pane; the page's Start button boots the game, the
  Speed limit box fast-forwards.
