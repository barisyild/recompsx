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
page displays the bundle's content hash.

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
