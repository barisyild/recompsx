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
- Input: `src/shims/js/shim/Input.hx`, browser externs (`js.Browser`, `KeyboardEvent`,
  `Gamepad`), SDL2 key names, the standard gamepad mapping.
- Build and serve: `./scripts/build-web.sh <SERIAL>` writes `out/_web` and links `web/`;
  `python3 scripts/serve-https.py` serves it (a LAN address needs https for WebKit's JIT). In an
  agent session, preview it with the browser pane; the page's Start button boots the game, the
  Speed limit box fast-forwards.
