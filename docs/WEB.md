# Building the browser bundle from source

The browser runs generated MIPS code on the main thread, with cooperative safe points. Use the
same pinned toolchain as the other targets; `scripts/build-web.sh` sources `scripts/env.sh`.

```sh
./scripts/setup.sh                     # once per checkout
./scripts/build-web.sh crashbash        # also accepts games/<id>/game.json
python3 -m http.server 8000 --bind 127.0.0.1 --directory web
```

Open <http://127.0.0.1:8000/> and press **Oyunu başlat**. The same button pauses/resumes. The
page displays the bundle's content hash. Reload after rebuilding; it fetches an uncached
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
stress option, not required by the page. The source defines and continuation contract are in
[ADR-0010](decisions/ADR-0010-cooperative-main-thread.md).

Current compatibility and measured digests are in [PROGRESS.md](../PROGRESS.md). The missing
features were committed on `dreamcast-hardware-rendering` (`25d9a5d`, `6819782`), and have now
been reconciled into the `main` working tree while retaining scalar registers, IR/regions and
main-thread continuations. At 3000 frames the optimized cooperative, forced-yield and `--no-opt`
JS runs and full reflaxe.CPP game runs (normal/forced yields) agree on `0e180c28` with zero
missing paths. The browser reaches Select Game Type with rendered 3D characters. This is a bounded bring-up check, not proof
that every level or every PS1 game is supported.
