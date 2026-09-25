# Building the browser bundle from source

The browser runs generated MIPS code on the main thread, with cooperative safe points. Use the
same pinned toolchain as the other targets; `scripts/build-web.sh` sources `scripts/env.sh`.

```sh
./scripts/setup.sh                     # once per checkout
./scripts/build-web.sh crashbash        # also accepts games/<id>/game.json
python3 -m http.server 8000 --bind 127.0.0.1 --directory web
```

The web build keeps the Haxe ES6 output as `out/_web/game.raw.js`, then runs the served bundle
through the pinned `google-closure-compiler` npm package at `SIMPLE_OPTIMIZATIONS` with
`ECMASCRIPT_2015` output. This keeps ES6 classes and the page host ABI intact; `ADVANCED` is not
safe for the generated runtime because the page and runtime communicate through dynamic JS names.
Run `npm install` once after checkout. The build uses `npx --no-install`, so a missing local
compiler is an explicit build error rather than an accidental version change.

Open <http://127.0.0.1:8000/> and press **Oyunu başlat**. The same button pauses/resumes. The
page displays the bundle's content hash. **Runtime logs go to the browser console, never into
the page**: the runtime writes hundreds of lines a second at boot, and an element rebuilt per
line re-rendered the page. Read them in the developer console.

Sound is an `AudioWorkletNode` (`web/audio-worklet.js`): the SPU's 44100 Hz stereo batches are
transferred to the rendering thread, which plays them in order and reports what it still holds;
the JS backend forwards that report as `audioBuffered`, so the SPU's pacing holds the queue at
its 4410-frame cap (about 100 ms). A browser without worklets falls back to the deprecated
`ScriptProcessorNode`. The loop paces to real time by the backlog between vblanks and wall time,
rebasing only when it falls more than a second behind.

**Ses** (on by default) is the audio output. Off, the page creates no `AudioContext` and
passes `--no-audio`, and `spu.Spu.outputEnabled` goes false: the SPU still advances every voice
— envelopes, block positions, ENDX and the loop flags, the current-volume registers a game can
read — and skips only what a listener needs, the volume multiplies, the accumulators, the
main-volume pass and the buffer. It is a presentation switch in the sense of ADR-0008, not a
digest mode: `nonSilent` and the peak diagnostics measure nothing without a mix, so a headless
digest taken with `--no-audio` describes a different machine and is not comparable.

**Hız sınırı** (on by default) is the pacing. Off, `host.unpaced` is true and the loop in
`shim.BrowserLoop` runs as many frames as fit in fourteen milliseconds of every tick instead of
holding to real time; the status line shows the frame rate reached. It is a live switch — the
loop reads it every tick — and pacing is presentation only (golden rule 3), so the emulated
machine sees the same cycles either way. For profiling and for measuring what the machine can
do, not for playing: the sound queue runs ahead and is dropped at the latency cap.

**WebGL çizim** (on by default where WebGL2 exists) hands the PlayStation's primitives to
`web/gpu-webgl.js` instead of the software rasteriser: the page passes `--video-hw` and a `gpu`
object on the host, the JS backend answers `caps(4)`, and `gpu.Gpu.hw` takes the ADR-0008
presentation fork. Texels are decoded in the fragment shader straight out of a 16-bit copy of
VRAM; a 1024x512 framebuffer texture stands in for the rendered VRAM, refreshed from uploads by
dirty rectangles and blitted to the canvas at each vblank. There is no depth buffer and no depth
test, as on the PlayStation: primitives draw in submission order. Triangles are scissored to
the drawing area (`bp_gpu_clip`), rectangles are not, matching the software path. The mask bits
(`bp_gpu_mask`) are the stencil buffer: uploads carry bit 15 into it, "set" marks what a
primitive draws, "check" skips what is marked. Headless Node runs have no host and never take
this path, so the digest is unaffected. Untick the box for the
software rasteriser and the 2D canvas. Reload after rebuilding; it fetches an uncached
manifest and loads `game.js?v=<hash>`. The manifest records the source branch, commit, dirty
status and a digest of generator/runtime/config inputs, in addition to the bundle digest.

The selected game's `local.json` supplies the generator's disc path. The local page expects
`web/boot.exe` and `web/disc.bin` to point to that same game's executable and image. These are
user-provided, ignored media; switching build configs also requires matching those links. The
build script does not copy or publish media. For example:

```sh
ln -s /absolute/path/to/executable web/boot.exe
ln -s /absolute/path/to/disc.bin web/disc.bin
```

Generated Haxe, JS and the manifest live under `out/_web`. The served `web/game.js` and
`web/build.json` are ignored symlinks. The first rebuild preserves a pre-existing regular
bundle as `out/_web/previous-game.js` for diagnosis.

For bounded reference checks:

```sh
source scripts/env.sh
node out/_web/game.js web/boot.exe web/disc.bin --headless-hash 3000
node out/_web/game.js web/boot.exe web/disc.bin --headless-hash 3000 --yield-every 31
./scripts/conformance.sh Yielding CdScex
./scripts/test.sh
./scripts/check.sh
```

Node uses the same continuation code without browser pacing. `--yield-every` is a diagnostic
stress option, not required by the page. These commands use the JavaScript-only gate by default;
set `RECOMPSX_JS_ONLY=0` when the deferred reflaxe.CPP comparison is needed. The source defines
and continuation contract are in
[ADR-0010](decisions/ADR-0010-cooperative-main-thread.md).

Current compatibility and measured digests are in [PROGRESS.md](../PROGRESS.md). The missing
features were committed on `dreamcast-hardware-rendering` (`25d9a5d`, `6819782`), and have now
been reconciled into the `main` working tree while retaining scalar registers, IR/regions and
main-thread continuations. At 3000 frames the optimized cooperative, forced-yield and `--no-opt`
JS runs agree on `0e180c28` with zero missing paths. The browser reaches Select Game Type with
rendered 3D characters. The reflaxe.CPP check remains available through `RECOMPSX_JS_ONLY=0` and
is deferred while JS is the active iteration target. This is a bounded bring-up check, not proof
that every level or every PS1 game is supported.
