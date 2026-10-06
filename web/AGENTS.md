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
  primitives in submission order, the four blend equations. Colour is the PlayStation's five bits
  a channel (ADR-0054): the shader cuts a primitive's colour as gpu.Gpu's `modulate`/`pack555` do,
  and fbTex stores k as (k + 1/2) / 32 — read it back as `floor(32 * c)`, never as `c * 255 >> 3`;
  that lets mode 0 floor like the hardware. Compare a picture against the reference by reading
  fbTex back (`readPixels` on the context after `peek` binds fbo) and POSTing it to a local
  receiver, beside `--vram-at` dumps of the same vblanks from Node. The mask bit is the depth buffer
  (`fbDepth`, a DEPTH24_STENCIL8 texture): every fragment writes the bit the PlayStation stores
  as `gl_FragDepth` — 1 under "set", otherwise the texel's bit 15, 0 untextured (ADR-0054); the
  stencil serves "check" alone, rebuilt from the depth. Drawn tiles are converted back into
  `vramTex` (bit 15 from the depth) when a primitive samples them. VRAM-to-VRAM copies arrive as
  `bp_gpu_copy` (the shim answers capability 7, `BP_CAP_GPU_COPIES`) and are drawn from fbTex and
  its depth through a scratch target, so a copy out of a buffer on screen copies what was drawn
  there (Crash 3's level transitions). The page loads the renderer under its own version from
  `build.json`.
- **The picture's resolution** (ADR-0056): `gpu.scale(percent)` (`bp_gpu_scale`; the shim answers
  capability 8, `BP_CAP_GPU_SCALE`, with 100, and 9, `BP_CAP_GPU_LINES`, with 0: no limit) makes
  fbTex, fbDepth and the copy's scratch VRAM's size times the scale, rounded — 25 to 400 percent,
  819x410 at 80 — carrying their contents over, and the canvas the display's pixels times it.
  Coordinates are VRAM's everywhere; only the viewport, the scissor (`setScissor`) and a copy's
  source texels count target pixels, at each axis's rounded scale (`SX`, `SY`), and `toWord` reads
  the target pixel at a VRAM pixel's centre. `gpu.scaled` says the scale asked for; `peek(x, y)`
  takes VRAM coordinates. The setting is `video.scale` in `recompsx:system.cfg`, a multiplier, so a
  page boots at the last scale chosen: clear it (`localStorage.removeItem('recompsx:system.cfg')`)
  for a run at 1x. Programs set it with the PS1 Pro system calls (ADR-0060). A hidden pane skips the
  present, so the canvas keeps its size until the pane shows; read fbTex back to see a scale there.
  A present with PRESENT_HOLD (32; HoldPicture) is skipped in the page's `present` before any
  blit, as fast-forwarding skips one: the canvas keeps the last picture while a program draws it
  anew (Crash 3's RES redrawing its pause picture), and the drawing waits in fbTex for the next.
- **The screen's shape (ADR-0064).** The host says `widescreen: true` (BP_CAP_WIDESCREEN), and every
  present carries PRESENT_WIDE (64, the console's screen is 16:9) and PRESENT_WIDE_FILL (128, the
  picture fills it): `present` puts them on `.screen` as the classes `wide` and `wide-fill` when they
  change — after the hold check, so a held picture keeps its shape. The CSS makes `.screen.wide`
  16:9, stretches the canvas over it with `wide-fill`, and keeps it to the middle three quarters
  without (a 4:3 picture between black bars); `shim.Input` reads the pointer over the canvas shown,
  not the element. The setting is `video.wide` in `recompsx:system.cfg` (0 4:3, 1 16:9, 2 STRETCH).
- **A framebuffer must renew its texture after an upload (ANGLE on Metal).** Chrome 152 on an Apple
  GPU gives a texture fresh storage when `texSubImage2D` writes it while the GPU may still read it,
  and a framebuffer that had it attached goes on drawing into the old storage — silently, no GL
  error, `checkFramebufferStatus` complete. `syncDrawn` therefore detaches and attaches vramTex to
  `wordFbo` every time (ADR-0054); any new framebuffer over an uploaded texture needs the same.
  Found because Crash 3's attract loop ends its second demo with a transition 40 frames after a
  palette upload: the converted words went nowhere and the picture halved to black at once.
- Finding a frame in the page itself: `?slow=auto` plays 300 frames in slow motion from each copy
  of the picture on screen (WebGL only: the renderer counts them), `?slow=A-B,C-D` those frames,
  `?slowfps=N` how slowly (10), `?ff=N` with the speed limit off and nothing slowed until frame N;
  any of them, or `?frames`, shows the frame number on the picture (the vblank `--pad-script`
  counts) and gives the keys "," (slow motion on/off) and "." (one frame, while paused). The loop
  stops inside a tick when the host pauses (`BrowserLoop`), so a pause is exact to the frame.
- The page appends each `arg` of its address to the runtime's command line:
  `?arg=--pad-script&arg=4700:CROSS,4710:-` (sio.PadScript) is a browser run that reaches the same
  frames every time — how a picture bug is found at one vblank. To watch frames from the first, wrap
  `recompsxHost.present` from a setter on `globalThis.recompsxHost` defined before Start is pressed
  (the page creates the host after fetching the files, and the game presents at once); counting
  presents from a wrapper installed later is off by however many already ran. The renderer's
  diagnostics (`peek`, `peekVram`, `drawnTile`, `glCheck`, `syncs`, `copies`) read fbTex, vramTex
  and the tile books at such a frame. A hidden pane runs an unpaced game at ~12 frames a second
  and a paced one not at all.
- Because drawn pixels become texels, the renderer must hear of every upload, not only of those
  that changed emulated VRAM: the shim answers `BP_CAP_GPU_UPLOADS` (capability 6) and the
  runtime then reports them all (`Gpu.reportUploads`). Without it Crash Bash's menu lost all its
  text after the attract loop's cutscene: a 511x511 rectangle clears VRAM under the font, the game
  uploads the same font again, emulated VRAM (never cleared — the rectangle was ours) did not
  change, and `vramTex` kept the black.
- Storage (`bp_storage_*`): the page keeps blobs up to 256 KB in `localStorage` as
  `recompsx:<name>` (base64) — the console settings `system.cfg` (ADR-0034), later memory cards;
  larger ones (the VRAM dump) are only logged. The dev server sends `Cache-Control: no-cache` for
  everything but `?v=` URLs, with an ETag of the file's identity (the file a link reaches, its
  size and time), and the page fetches boot.exe and disc.bin with `cache: 'no-cache'`: pointing
  those links at another game once left Crash Bash's executable cached beside Crash 3's disc and
  bundle, which jumped to address zero at boot.
- Input: `src/shims/js/shim/Input.hx`, browser externs (`js.Browser`, `KeyboardEvent`,
  `Gamepad`), SDL2 key names, the standard gamepad mapping. Four pads: the keyboard with the first
  gamepad, then the second to fourth gamepads — the multitap's slots A-D (ADR-0042). A pad with a
  gamepad behind it is a DualShock (ADR-0052): axes 0-3 are its sticks (made bytes in plain JS),
  button 16 its ANALOG button, and its motors play on `vibrationActuator` ("dual-rumble", 500 ms,
  renewed every 4 polls); the keyboard alone is a digital pad. A fake gamepad (an object with
  `buttons`, `axes`, `index`, `connected` and a `vibrationActuator` whose `playEffect` records its
  calls, returned by a replaced `navigator.getGamepads`) tests it in the pane. It also types for the machine's PS/2
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
