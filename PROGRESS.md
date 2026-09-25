# PROGRESS — recompsx (single source of truth; see AGENTS.md session protocol)

## Status snapshot

**2026-09-25: Dreamcast gameplay 19.7 -> 25.2 fps with the AICA; silent SPU path 3.5x cheaper.**
Flycast overlay after ADR-0024: gameplay spu 244 -> 20 ms per 30 vblanks. The menu still read
spu 366 ms: fading notes walked tick by tick. `Spu.fallRun` now takes releases, decays and
falling sustains in exact stretches (SpuFall). Presents are held to the video rate.

**2026-09-25: on the Dreamcast the AICA plays the SPU's voices (ADR-0024, `--audio-hw`).**
The SPU (244 ms of 1517 per 30 gameplay vblanks) now only advances state; each voice is an
AICA channel playing its sample decoded once into sound RAM, with the SPU's envelope sent as
volume. A presentation fork like `--video-hw`: off on every run that hashes. Awaiting a Flycast
measurement.

**2026-09-25: the machine's integers stay unboxed on V8 (ADR-0023); JS 9000 frames 15.6 → 9.4 s.**
A -0 from `%`, a -0 from a negated SPU envelope step and SRL/SRLV's unsigned reading had turned
`CpuState`'s register fields into V8 double fields, and every read or call crossing boxed a
number: 90 % of the page's garbage. Fixed at the source, plus physical addresses at the bus (a
KSEG0 pointer is never a small integer in Chrome), once-built diagnostic strings and an
allocation-free audio path. Node: garbage −97 %, scavenges 105 → 22 over 9000 frames, 40 %
faster. Brave: scavenges per frame −67 %, speed neutral; Chrome's register fields still hold
pointers and stay doubles — the next lever (a rotated register encoding) is in the log.

**2026-09-25: the browser draws with WebGL2 (ADR-0020); main-thread CPU per frame 3.85 → 2.43 ms.**
`web/gpu-webgl.js` takes ADR-0008's presentation fork in the page: VRAM lives in an R16UI
texture and texels are decoded in the fragment shader (4/8-bit through the CLUT, 15-bit direct,
texture window folded in); a 1024x512 framebuffer texture stands for the rendered VRAM, refreshed
by dirty rectangles, drawn on in submission order with no depth buffer, and blitted per vblank
(24-bit rows decoded from VRAM). Every vertex carries its texture state and the three adding
blend modes share one GL blend state, so a vblank of gameplay is one to three draw calls; only a
textured mode-2 primitive draws in two passes as its own batch (ADR-0020 revision). The ABI gained `bp_gpu_clip` (32 functions): the first build showed a double-buffered
game's geometry spilling from the drawing buffer onto the displayed one, which the software path
clips at the drawing area. The runtime now tells the backend of an upload when its last word lands rather than at its
header — the ABI speaks in the past tense, and a backend that copies the region on hearing of
it read the palette that was there before; that was the noisy colours of the second build. The
JS backend answers `caps(4)` only when the page supplies a `gpu` object, so headless runs and
every digest are untouched. Measured in the page over the same
stretch of the attract mode: 3.85 ms of main-thread CPU per emulated frame with the software
rasteriser, 2.43 ms with WebGL. Visual check: the Select Game Type menu at frame 17000 in both
modes. Mask bits followed (`bp_gpu_mask`, 33 ABI functions): the stencil buffer carries bit 15
from uploads, "set" primitives increment it, "check" primitives pass where it is zero;
verified by driving the renderer directly in the page, since Crash Bash's attract loop only
ever writes GP0(E6h) as 0/0. Remaining gap, as on the Dreamcast: VRAM readback of rendered
pixels.

**2026-09-25: the generated code is structured; 9 dispatchers remain of 632 (ADR-0019).**
`RegionPlan` reduces natural loops (dominators, any number of exits) and forward runs (a
single-entry slice in topological order); the emitter uses the entry-routing local `resume` as
the Relooper's label: every block resets it, every sequence part is guarded by it, a jump past
the next part records its target, a loop exit records it and `break`s, and a loop ends with
`if (resume >= 0 && resume != header) break`. Jump tables record their targets too and are never
placed where a `break` inside a `switch` would be needed. All three hottest functions are
structured. Bit-identical: `Codegen 632ff691`, `Regions d6b90d6e`, `Yielding 203c40c1`; game
`0e180c28` / `ab13c60f` / `31c46089` at 3000 / 9000 / 18000. JS timing neutral within noise
(9000 frames 27.08 → 28.19 s wall, 33.35 → 31.55 s user, minimum of three interleaved); the
vblank wait loop's self time fell 44 %. The C++ effect is the point of the shape and is
unmeasured until that path resumes.

**2026-09-25: two GTE experiments measured and rejected (ADR-0018).** A JavaScript `I64` on
an exact double passed `GteOps` (`1cf89aa2`) and the game digests but did not move the clock:
interleaved 9000-frame runs, minimum of three, pair 26.84 s, double 27.20 s, double with the
wrap only on overflow 29.22 s. `Gte.execute` as a `switch` was isolated at +10 % (27.4 s
against 25.0 s) and is rejected too. The GTE code is unchanged; the pair shim's high-word-only
check and three-operation wrap are cheaper than a latency-bound double chain on a boxed static.
The remaining GTE lever is a value-passing accumulator that lives in a register on both targets.

**2026-09-25: the rasteriser walks spans, not bounding boxes; JS 9000 frames 34.6 s → 25.2 s.**
`Gpu.rowSpan` solves each row's covered columns from the three edge functions in closed form,
so the span loops visit only pixels inside the triangle and pay no per-pixel inside test.
Textured spans decide the window masks, page and palette origins, depth and mode flags once per
triangle and fetch texels from the linear framebuffer index inline; they were three out-of-line
calls a pixel. Pixels are counted per span; opaque flat rows and fills go through the new
`RawMem.fill16Index` (`TypedArray.fill` on JS, a loop on C++). Bit-identical: the Raster
fixture's pre-existing sections still digest `b66077e7` on the new code and the game digests are
unchanged. The fixture gained blended and textured sections (every depth, the window, all four
blend modes, raw and modulated, the mask bits); its digest is now `a749a71a`, recorded on JS.
Profile after, per class: GTE 34 %, GPU 22.5 % (was 44 %), generated 19 %, SPU 11 %, Memory 7 %.

    conformance Raster (old sections only)   b66077e7   values=524
    conformance Raster (with new sections)   a749a71a   values=525
    node out/_gen/game.js ... --headless-hash 3000   digest=0e180c28
    node out/_gen/game.js ... --headless-hash 9000   digest=ab13c60f   25.35 s / 25.04 s
    the previous build, same runs                     digest=ab13c60f   34.48 s / 34.77 s
    check.sh: clean; test.sh: 367 tool checks, 18 JS conformance groups, demo 329de455

**2026-09-25: first per-subsystem profiles of the reconciled tree, both targets, one digest.**
`node --cpu-prof` over 9000 frames (the 3D **Select Game Type** menu), bucketed by runtime
class: GPU rasterizer 44 %, GTE 24 % plus I64 shim 2 %, generated game code 14 %, SPU 8 %,
Memory 5 %. Wall time 34.7 s for 9000 frames, about four times real time. The native C++ build
of the same tree runs the same 9000 frames in 9.3 s; both targets report `digest=ab13c60f`.
In the native `sample` profile `Memory::read32`/`write32` are the fourth and sixth hottest
symbols and `Vram::get` is in the top thirteen: the non-inline accessors of ADR-0013 are a JS
bundle-size decision that became an out-of-line call per guest load/store on C++ (1656 calls in
one shard, zero direct RAM accesses, against the direct `*(int*)(recompsx_ram + off)` of the
pre-0013 build). It was not measured on C++ before this and must become per-target before the
console path resumes. `node --trace-deopt` over 3000 frames: 513 deopts, mostly `wrong map` and
`not a Smi`, because KSEG0 addresses lie outside V8's 31-bit Smi range and every `CpuState`
field that ever holds one is double-represented; `cycles` crosses 2^30 after about 32 s and
transitions too. ADR-0014, 0016 and 0017 changed the Crash Bash output by six lines in total and
carry no speed measurement. The ranked levers are in "Next up".

**2026-09-21: JavaScript-only iteration is now the default (ADR-0015).**
`scripts/conformance.sh` and `scripts/test.sh` skip reflaxe.CPP unless invoked with
`RECOMPSX_JS_ONLY=0`; the C++ build files and shims remain intact for the later return. The JS
gate still runs all tool tests, 18 conformance groups and the deterministic demo digest.

**2026-09-21: conservative stack word forwarding added to generic codegen (ADR-0016).**
`StackMemoryForwarding` removes superseded aligned word stores and forwards exact `$sp`/`$fp`
`sw` → `lw` reloads within one basic block, guarded by register versions and memory-effect
barriers. Raw memory remains at uncertain boundaries; the first fixture covers store elimination,
forwarding and stack-pointer invalidation. The rebuilt Crash Bash source is 553,670 lines /
15,232,114 bytes; raw JS is 10,525,412 bytes and Closure output is 4,929,742 bytes
(`fdca8703c2a9`). The 3000-frame game digest remains `0e180c28`.

**2026-09-22: CFG liveness now removes dead pure register writes (ADR-0017).**
The emitter drops non-trapping arithmetic, logical, shift, comparison, `lui` and `mfhi/mflo`
writes only outside reverse CFG paths that reach a pump, call, trap or external transfer. Interior
entries, transfer/delay-slot reads, publication paths and raw memory effects remain conservative;
instruction counts and cycle charges are unchanged. The Crash Bash protected slice is byte-stable;
the synthetic leaf fixture verifies the actual write elimination. The rebuilt bundle remains
`fdca8703c2a9`, with `frames=3000 digest=0e180c28`.

**2026-09-21: closed instruction patterns fused before Haxe emission (ADR-0014).**
`PatternMatcher` now folds `lui → ori/addiu` constant formation and routes adjacent
`mult/multu/div/divu → mflo/mfhi` pairs through tested `core.Ops` result helpers. A discarded
`mflo/mfhi` still preserves the HI:LO write. The pass stays inside basic-block bodies and never
crosses delay slots, control transfers, traps, memory effects or scheduler boundaries. The
generated Crash Bash source fell to 553,676 lines / 15,232,397 bytes; raw browser JS is
10,525,845 bytes and Closure ES6 output is 4,929,926 bytes (`dab5faf1a01e`). Raw and Closure
game runs agree at `frames=3000 digest=0e180c28` (raw 6.71 s, Closure 6.56 s). The full
two-target conformance gate passes all 18 groups, including Codegen `a71569d0` and Yielding
`203c40c1`; `check.sh` is clean.

**2026-09-21: clipped raster spans and ES6 Closure browser bundle added (ADR-0013).**
Raster triangle spans now carry a precomputed linear VRAM index, rectangle drawing clips once and
uses row fills, and only wrapping upload/VRAM-copy paths keep coordinate masking in the pixel loop.
Large `Memory` and wrapped `Vram` accessors are no longer Haxe-inline, preventing their full
address trees from expanding into every generated guest function. Crash Bash raw JS is 10,564,124
bytes and the ES6-preserving Closure bundle is 4,930,496 bytes (`b97768f188a6`). Raw and Closure
Node runs agree at `frames=3000 digest=0e180c28`; raw measured 6.91 s and Closure 7.14 s. The
Raster fixture agrees on both targets (`b66077e7`), and the JS-only gate remains green. Full C++
game validation remains deferred while JS is the active iteration target.

**2026-09-21: boundary-aware register liveness added to static Haxe generation (ADR-0012).**
`RegisterPlan` now runs backwards CFG liveness and narrows reloads after calls, due pumps and
syscalls while keeping publication conservative and seeding function exits with the full written
architectural state. The pass is generic over discovered MIPS CFGs and keeps interior entries and
cooperative callbacks correct. `RegisterMask` remains an allocation-free `Int` abstraction in the
build-time tool; generated code still uses scalar `CpuState` fields and plain `Int`s.

Crash Bash generation is byte-stable in discovery and now emits 555,652 lines / 15,282,659 bytes,
down from 583,506 lines / 15,803,189 bytes before the pass. Publication lines remain 97,203 while
reload lines fall 84,959 → 57,105. The JS game still reports `frames=3000 digest=0e180c28`, and
`RECOMPSX_JS_ONLY=1 ./scripts/test.sh` passes all 341 tool checks, 18 JavaScript conformance
groups and the demo digest `329de455`. C++ spikes/build remain available through the default gate
and are intentionally deferred during the fast JS iteration loop. The served browser bundle was
rebuilt as `35a52a761a52` from this source tree and its served artifact also reports
`frames=3000 digest=0e180c28`.

**2026-09-09: committed console features reconciled into main; browser menu restored.**
The previous claim that working features existed only in an untracked JS artifact was wrong.
They are committed in `25d9a5d` and `6819782` on `dreamcast-hardware-rendering`, which diverged
from main at `d731004`. Main's `2c80e68` added scalar codegen on the older runtime. Main now
combines those committed device, rendering, memory, backend and discovery changes with the
newer scalar registers, machine IR/regions and continuations.
No generated sources or game assets are imported into Git; existing vendor edits are retained
and carried as reproducible patches. Setup applies both 0004 (continue) and 0005 (locals),
plus the contiguous-array patch, without changing the submodule pins.

Restored: complete committed GTE operations/textured rasterizer, CD acknowledgement and held
sector cleanup, load instruction cycle charges, flat dispatch caches, native aligned memory,
raw-pointer CpuState and I64 operations, optional instruction profiling and Dreamcast backend.
The newer timed SCEx model and main-thread cooperative driver remain. Launcher initialization
prepares the tables before execution; a cache sentinel and a shard function-name collision found
by the new synthetic Dispatch fixture are corrected. `CdCommands` checks abandoned sectors and
queued interrupt acknowledgement. `analyzer-optimize` and JS ES6 stay enabled on every build.

The source-built browser bundle `bcafe8128288` reaches the **Select Game Type** menu with a
rendered 3D character and advances beyond frame 7366. No game-script error appeared in the
browser error log (one unrelated browser-extension error was present). It uses no Web Worker.
Optimized cooperative JS, forced-yield JS and synchronous `--no-opt` JS agree at frame 3000:

    [info] frames 3000 | events fired 28871 | irqs delivered 6420 | handler calls 9302
    [info] distinct unimplemented things reached: 0
    [info] frames=3000 digest=0e180c28

Acceptance output, 2026-09-09:

    ./scripts/check.sh
      every backend implements all 31 ABI functions
      check.sh: clean
    ./scripts/test.sh
      all 341 checks passed
      conformance: 18 test(s) x 2 targets
      CdCommands 840417e3   values=40
      CdScex     36383746   values=70
      Codegen    9a417b15   values=13924
      CtxPass    8a6e7e04   values=20
      Dispatch   88b340ec   values=595
      GteOps     1cf89aa2   values=5299
      Raster     b66077e7   values=524
      Regions    d6b90d6e   values=38333
      Yielding   203c40c1   values=7780
      conformance: all targets agree
      test.sh: both targets agree — 329de455

Codegen/region/yield fixture digests changed with the restored load costs and live clock
binding; all modes/targets agree, with explicit 7-cycle load/delay-slot assertions. Optional
instruction profiling also preserves the JS Codegen digest. The current source fingerprint
matches the served bundle; all four bounded JS logs (candidate, forced yields, reference and
served artifact) have the same emulated counters. The full reflaxe.CPP game, built against the
null backend with cooperative continuations, also matches at frame 3000 with and without
`--yield-every 31`:

    ./out/_reconcile-native/build/recompsx web/boot.exe web/disc.bin --headless-hash 3000
    ./out/_reconcile-native/build/recompsx web/boot.exe web/disc.bin --headless-hash 3000 --yield-every 31
      [info] distinct unimplemented things reached: 0
      [info] frames=3000 digest=0e180c28

This is a bounded bring-up/menu result, not an assertion that every game/level is supported.
Evidence and source provenance are under ignored `out/_reconcile/` and `out/_web/build.json`.

**2026-09-09: source-built main-thread browser execution and SCEx response fix verified.**
`scripts/build-web.sh crashbash` now regenerates the same optimized code and compiles optional
cooperative continuations (ADR-0010). The page at `127.0.0.1:8000` loads manifest-keyed build
`e08491afe0f7` (17,195,116 bytes). No Web Worker is used. Pause held frame 3152 unchanged across
checks; resume advanced beyond frame 5802; the browser reported no JavaScript errors. Source,
build flags, media links and local-server instructions are documented in `docs/WEB.md`.

Continuations retain compiled body handles and stable block entries, including pending callers,
so delay slots are not replayed and overlay replacement cannot change a suspended function's
identity. HLE/pump callbacks remain atomic. The feature is optional; synchronous builds allocate
no continuation buffers. `Yielding` compares register/memory/timing state under varied slice
budgets, nested calls, unwind, callbacks and dispatcher replacement on both targets.

Historical intermediate diagnosis, corrected above: rebuilding exposed a runtime fix missing
from the then-current main branch (already committed on the console branch): `Test 05h`
in the Haxe CD controller returned `(status,1,1)` regardless of head position. The observed
boot check is SCEx/modchip detection: SeekP → Play → Test 04 → delay → Test 05, with no GetlocP
in the 1500-frame command trace. The controller now returns two persistent counters, models
lead-in separately from data LBA zero, and resets/samples them using guest time. Exact wobble
timing remains a coarse one-observation model. This is a generic drive correction, not a game
patch or a LibCrypt/subchannel implementation. Evidence is in `games/crashbash/notes.md`.

The corrected source passes this check and reads 1970 sectors by frame 3000 instead of 731.
It then reaches 15 missing function/overlay/GTE paths, VSync timeouts and a black screen;
full-game compatibility is **not** established. Optimized synchronous JS, cooperative JS,
forced-checkpoint JS and the `--no-opt` reference agree on `b542d57e`. The old local bundle
reports `8af4d44b` and zero gaps;
it contains additional runtime/discovery changes from the console branch, not then merged into
main. It is retained only
as an ignored diagnostic artifact. The earlier `6bd5e3fd` represents the pre-SCEx-fix state.

Acceptance output, 2026-09-09:

    ./scripts/check.sh
      check.sh: clean
    ./scripts/test.sh
      all 341 checks passed
      conformance: 14 test(s) x 2 targets
      CdScex     36383746   values=70
      Codegen    818e2901   values=13907
      Regions    c1baa399   values=38333
      Yielding   3cbb7802   values=7780
      conformance: all targets agree
      test.sh: both targets agree — 329de455
    node out/_web/game.js web/boot.exe web/disc.bin --headless-hash 3000
    node out/_web/game.js web/boot.exe web/disc.bin --headless-hash 3000 --yield-every 31
    node out/_browser/game-sync.js web/boot.exe web/disc.bin --headless-hash 3000
    node out/_browser/game-reference.js web/boot.exe web/disc.bin --headless-hash 3000
      [info] distinct unimplemented things reached: 15
      [info] frames=3000 digest=b542d57e

Logs are ignored under `out/_browser/`. The new game digest above is verified on JS; the new
CD and continuation behavior is verified by cross-target conformance, not a full C++ game run.

**2026-09-09: generic machine IR and regional control-flow structuring verified (ADR-0008).**
Code generation now shares decoded instructions, explicit register/effect masks, delay slots,
cycle charges and stable resume IDs. Int-backed Haxe `RegisterMask` / `Effect` abstractions live
only in the build-time tool. Unique-predecessor sequences and convergent branches become native
flow inside larger CFGs; irreducible edges and checked computed transfers retain a dispatcher.
Every original block remains independently resumable and has one emitted body. There are no
game-specific addresses, library patterns or calling-convention assumptions in these passes.
Register synchronization is still function-wide; general native multi-block loops and liveness
remain follow-ups. `--no-regions` isolates the prior scalar/simple-loop pass; `--no-opt` keeps
the context-field reference.

Synthetic coverage includes 18 CFGs and every valid block entry, plus delay-slot changes,
callback register changes, halt, unwind, cycle wrapping and modified jump-table targets. The
full gate passes 341 tool checks and 12 conformance groups on JS and reflaxe.CPP. Crash Bash's
optimized JS/C++ and scalar-only JS builds retain `6bd5e3fd` over 3000 frames. Spyro 3 demo generates
633 functions / 47 switch tables and compiles to JS; this is not a full-game execution check.
Function/overlay dispatch metadata is byte-identical to the pre-change output in both modes.

Acceptance output, 2026-09-09:

    ./scripts/check.sh
      check.sh: clean
    ./scripts/test.sh
      all 341 checks passed
      conformance: 12 test(s) x 2 targets
      Codegen    818e2901   values=13907
      Regions    c1baa399   values=38333
      conformance: all targets agree
      test.sh: both targets agree — 329de455
    node out/_gen/game.js web/boot.exe web/disc.bin --headless-hash 3000
    node out/_regions/scalar/game.js web/boot.exe web/disc.bin --headless-hash 3000
    ./out/_gen/build/recompsx web/boot.exe web/disc.bin --headless-hash 3000
      [info] distinct unimplemented things reached: 0
      [info] frames=3000 digest=6bd5e3fd

Crash Bash's 1358 functions retain 522 block/region dispatchers instead of 916; their dispatcher
case groups fall 17,515 → 7,615. The pass applies 5,549 sequence and 3,251 choice reductions in
891 functions. Spyro's 633 functions contain 286 dispatchers after 4,623 sequence and 3,307 choice
reductions. These are structural counts, not performance measurements.

JS timing on macOS 26.5.2 / ARM64 / Node v22.13.0, 3000 frames, one warm-up plus five alternating
samples with no builds running: medians 4.4335 → 4.2686 s (1.039x, about 3.7% less elapsed time).
Samples overlap; this is a modest observation on the boot workload, not demonstrated gameplay
acceleration. Generated Haxe grows 8,436,743 → 9,287,714 bytes (+10.1%); JS grows 15,228,737 →
16,354,240 bytes (+7.4%). Resume guards and nesting have a real size cost. Raw evidence is in
ignored `out/_regions/{game-benchmark,structure}.json`. At measurement time the served browser
bundle was still the older artifact described below; these are not browser measurements.

`./scripts/bench-regions.sh` builds and times 25M synthetic MIPS branch/loop iterations with
identical scalar registers and safe points, enabling only the regional pass. Both targets and
modes report `[info] result=25000000 slots=5000001 cycles=250000025`. Five-sample medians after
warm-up, alternating modes with no other builds running:

| Target | Scalar-only | Regions | Speedup |
|---|---:|---:|---:|
| JS | 0.9203 s | 0.4615 s | 1.99x |
| C++ | 0.0944 s | 0.0596 s | 1.58x |

Raw samples: ignored `out/_regions_bench/results.json`. This isolated loop gain must not be
extrapolated to the full game. Release/null game executable size is unchanged at 5,545,416 bytes.
The native 3000-frame comparison gives medians 11.0765 → 10.1931 s (1.087x); samples vary widely
and overlap, so this does not establish a repeatable game speedup. Absolute timings also differ
substantially from the earlier session; compare paired variants within this run, not across
sessions. All twelve warm-up/measured runs retain `6bd5e3fd`. Raw samples and binary hashes are
in ignored `out/_regions/native-benchmark.json`.

**2026-09-09: optimization audit confirms remaining hot paths and a stale browser artifact.**
Before the regional pass, a fresh JS build with the shipped analyzer/ES6/DCE flags was
byte-identical to `out/_gen/game.js`.
A bounded Node v22.13.0 CPU profile over 3000 frames still reports `digest=6bd5e3fd`:
49.0% of self samples are in `f_8002de2c` and `f_8002d4f4`, 9.4% in `Memory.slowRead8`,
and 5.9% in GC. This is one diagnostic profile including startup, media loading, logging and
PCM export, not a timing benchmark, browser FPS result or representative gameplay check.
The two generated functions retain 15- and 190-block dispatchers. Register synchronization uses
function-wide read/write sets, without per-boundary liveness. Independently, `Cdrom.read1803`
constructs its diagnostic string before `tnote` checks whether tracing has ended; the profile
does not isolate how much time that allocation costs. Raw evidence is ignored under
`out/_codegen_audit/`. The earlier five-run JS comparison below remains the timing evidence:
the scalar/self-loop optimization did not measurably speed up this 3000-frame boot workload.
At audit time `web/index.html` served a different, older `web/game.js`, without scalar GPR
lowering and with yield/rewind support missing from the sources. That provenance issue is now
resolved by the source-built cooperative path above.
This audit motivated the machine IR and regional pass above. Haxe already folds local constants
and some fixed RAM accesses; further passes should target facts across blocks and observable
machine-state boundaries, including register synchronization per boundary.

**2026-09-08: scalar-register and structured code generation is verified (ADR-0007).**
GPRs become Haxe locals, with publication/reload at calls and due pumps. Linear chains and
conditional self-loops use native control flow while retaining every block's resume index and
a single copy of its body. Crash Bash's 1358 functions now contain 916 block dispatchers instead
of 1212, plus 231 native loops. `gen --no-opt` retains the context-field/dispatcher reference.
Both modes also correct JALR-zero tail transfers, conditional linked calls, cycle wrapping and
immediate halt/unwind propagation. The halt correction changes this checkout's 3000-frame game
digest from `d8ab3d52` to `6bd5e3fd`; optimized/reference JS and optimized C++ agree. This does
not add load-delay accuracy or overflow exceptions. Spyro 3's 633 functions / 47 switch tables
also generate and compile to JS (not a full-game execution check).

Acceptance output, 2026-09-08:

    ./scripts/check.sh
      check.sh: clean
    ./scripts/test.sh
      all 194 checks passed
      conformance: 11 test(s) x 2 targets
      Codegen    818e2901   values=13907
      conformance: all targets agree
      test.sh: both targets agree — 329de455
    node out/_gen/game.js web/boot.exe web/disc.bin --headless-hash 3000
    ./out/_gen/build/recompsx web/boot.exe web/disc.bin --headless-hash 3000
      [info] distinct unimplemented things reached: 0
      [info] frames=3000 digest=6bd5e3fd

Scalar locals exposed reflaxe's declaration mover producing duplicate declarations and moving
declarations past reads. Three synthetic MIPS reproductions now pass on both targets; patch
0005 is exported and applied idempotently by `scripts/setup.sh`, with existing pins preserved.

Measured on macOS 26.5.2 / ARM64, five-run medians after warm-up, alternating modes, no builds
running during timing. `./scripts/bench-codegen.sh` regenerates and checks both loop variants;
each reports `result=2120718581 cycles=450000010` on both targets.

| Workload | Target / baseline | Baseline | Optimized | Result |
|---|---|---:|---:|---|
| 50M MIPS xorshift iterations | JS / `--no-opt` | 0.6747 s | 0.1603 s | 4.21x |
| 50M MIPS xorshift iterations | C++ / `--no-opt` | 0.0896 s | 0.0871 s | 1.03x; small |
| Crash Bash, 3000 frames | JS / corrected `--no-opt` | 4.026 s | 4.036 s | no measurable gain |
| Crash Bash, 3000 frames | C++ / pre-change build | 3.009 s | 2.839 s | 1.06x in this run |

The original JS game took 4.095 s. The C++ whole-game comparison includes the halt/call fixes;
it is not an isolated optimization comparison. Do not extrapolate the loop speedup to a game.
Release/null binary size: 5,495,880 → 5,545,416 bytes (+0.9%). JS size:
14,594,319 → 15,228,737 bytes (+4.3%; corrected reference 15,045,100). Generated Haxe grows
6,623,130 → 8,436,743 bytes versus the reference because boundary synchronization is explicit.
Raw samples and structure counts are in ignored `out/_codegen/{game-benchmark,structure}.json`
and `out/_codegen_bench/results.json`.

Phase: **M0 complete.** Toolchain pinned, specs committed, walking skeleton running on two
targets, and cross-target determinism verified — `./scripts/test.sh` builds the JavaScript and
the reflaxe.CPP builds and asserts their headless digests match (currently `329de455` over 300
frames). The windowed SDL2 build presents a gradient at 60 Hz.

Three decisions came out of M0, all forced by measurement rather than preference:
- **ADR-0002**: memory accessors are static methods, and the function table stores integer
  handles — inlined instance methods and arrays of function values do not compile.
- **ADR-0003**: develop on JavaScript, design for reflaxe.CPP. reflaxe.CPP was caught silently
  deleting `if` statements, including guard clauses, in code that then takes the wrong path.
  Haxe's own targets are correct on identical source. JS is the reference; every reflaxe.CPP
  constraint still applies everywhere.
- `IntMath.div` and `IntMath.mul` are mandatory: `/` on Ints yields Float, and `*` loses low bits
  on JS above 2^53. The first cross-target comparison diverged for exactly that reason.

Scope reminders that shape every decision: **all PS1 games are the target** (Crash Bash is the
bring-up vehicle, Spyro 3 demo is the anti-overfitting check), and **consoles are the
destination** (PC/SDL2 first; PS2 and derivatives, plus JVM, behind the same backend ABI).

**2026-08-09: the bring-up game boots to its first screen.** Crash Bash NTSC-U reaches "Sony
Computer Entertainment America Presents" — it initialises libcd, reads its own filesystem, loads
`CRASHBSH.DAT`, runs code out of it, uploads artwork to VRAM and composites it. The same build
runs headless under Node and live in a browser: one JavaScript shim, two hosts, chosen by whether
the page supplied `globalThis.recompsxHost`.

The last stretch was a chain of seven defects where each one hid the next, and the shape of it is
worth keeping: **every layer worked except the one below it**, so the symptom never named the
cause. A CD that answered every command but never streamed a sector; a driver that was never
installed because a `setjmp` return value was left to chance; ordering tables walked faithfully
after being built out of uninitialised memory; a game waiting not on sound but on being told that
sound had finished. Nothing here was a missing feature that announced itself.

**2026-08-09: overlays are done, and the boot screen is now reproducible from the disc alone.**
A game bigger than RAM is compiled as several *universes* — the executable, and the executable
with each overlay's bytes laid over its window — and which one answers at run time is decided by
fingerprinting what is actually in the window. Crash Bash's two overlays are 41 lines of committed
config pointing at disc offsets; no capture file exists anywhere in the build, which is what
golden rule 4 requires and what the reverted first attempt got wrong. The design is ADR-0006.

The work left the run bounded for the first time: `--headless-hash <frames>` stops a game whose
main loop never returns, by sending a halt down the same road a `longjmp` travels, and prints one
digest over VRAM plus twenty-two deterministic counters. That is what makes a *game* — not just a
demo — comparable between JavaScript and reflaxe.CPP.

**The CD dialogue is now correct end to end, and the boot has no dead time in it.** Four separate
causes had been hiding behind one symptom each. The controller's interrupt enable belongs to the
BIOS, not to the game — starting it at zero cost seven seconds of every boot while libcd timed
out and re-armed a controller nobody had armed. Halfword stores to the CD page reached no device
at all, because `slowWrite16` had a branch for every peripheral except that one. `CdlPlay` and
`CdlStop` answered with errors. And `Test 04h`/`05h` — two sub-commands in libcd's CD-audio
startup — answered with errors too, which made the game abandon and restart a ten-command
sequence three times a second for as long as it ran. None of these announced itself; each was
found by asking the machine what it actually did, one register write at a time.

## Next up (ordered)

Measured order, 2026-09-25 (`node --cpu-prof`, 9000 frames, per-class buckets in the snapshot):
1) rasterizer span specialisation per texture depth and semi-transparency with the texel
constants hoisted out of the pixel loop, or the WebGL presentation fork behind the ADR-0008
gates; 2) a double-backed JS `shim.I64` for the GTE's 44-bit accumulator (exact below 2^53;
needs an ADR amending golden rule 1 for that one shim, with the GteOps digest as the guard),
plus emitting the specific GTE op instead of the `Gte.execute` decode; 3) done — ADR-0019
structures all but 9 functions, neutral on JS within noise, unmeasured on C++; 4) a one-line
inline RAM fast path and a direct typed-array index in
the JS MemA; 5) closed-form fast-forward of wait loops such as f_80032264; 6) interprocedural
register summaries at static calls. Cross-block constant/copy propagation and range propagation
are demoted: ADR-0014/0016/0017 show instruction-level passes do not move this program. Any
boundary pass must continue to account for due pumps, callbacks, cooperative suspension and
interior entries. Before the console path resumes, make ADR-0013's accessor inlining
per-target; it is an out-of-line call per guest access on C++ today.

The browser runs reconciled main sources with cooperative code (ADR-0010); the committed
console branch features now restore the menu. Extend bounded gameplay/overlay coverage before
claiming broader compatibility, and separately measure an early trace guard for CD-register
diagnostics. Web Workers remain excluded by the user's constraint.

1. **M2 kernel HLE — done.** Crash Bash makes **no unimplemented kernel call**: every A0, B0, C0
   and syscall it reaches is handled, and both targets produce identical output across 238 lines.

   The whole surface is implemented, not only what this game touches: the C library and heap,
   `printf`, file descriptors and the TTY, events and interrupt chains, critical sections, COP0,
   threads, `setjmp`/`longjmp`, kernel timers, the device table, the GPU helper calls (which
   forward to GP0/GP1 and start working the moment those registers exist), and the kernel's own
   RAM tables at 100h/200h/674h/874h so a game that reads `GetB0Table` and jumps through an entry
   lands on a stub the runtime recognises.

   What is genuinely still blocked, and on what:

   - `cdrom:` files need ISO9660 — M1's remaining work.
   - `bu00:` files need SIO and a card image.
   - `longjmp` is wired end to end: generated functions take an entry-block parameter, every call
     is followed by `if (ctx.unwindToken != 0) return;`, and `Runtime.callAndResume` dispatches
     afresh from the saved `pc`. What is *not* built is block-granular resume — a saved return
     address in the middle of a block cannot be entered there, because call sites are not block
     leaders. Landing on a function entry works; landing mid-block reports the address. Making it
     general means promoting call-return sites to leaders and emitting a block table, which is
     worth doing when a game is found that needs it.
   - `qsort`/`bsearch`/`lsearch` take a comparison callback, which means calling back into
     recompiled code from a sort — possible, but no game seen so far calls them.

   **The GPU register file is in**, and `GPU timeout` is gone — `ResetGraph` completes. GPUSTAT is
   assembled on every read from the state the commands set plus the beam position, rather than
   stored, so a game polling it sees something that moves without an event having to fire. Bits 26
   and 28 read ready always, which is the truthful answer for a model where drawing is instant.

2. **The game renders. Pixels of its own making are in VRAM.**

   Two things stood between Crash Bash and a picture, and neither was the CD.

   **DMA channel 2.** Psy-Q does not write GP0 a word at a time — `DrawOTag` hands the GPU an
   ordering table and DMA walks it. With no controller, every display list went into an
   unimplemented register. Twenty-nine GP0 words in eight minutes of play was not a game with
   nothing to draw; it was a game whose drawing went nowhere. Channel 2's linked-list and block
   modes turned that into 544 commands.

   **GP0(A0h), the CPU-to-VRAM upload.** An opcode census of a whole frame settled what the
   display list actually holds: 364 NOPs, 159 cache-clears, one rectangle for the screen clear,
   and **three uploads**. No polygons at all. That is how a game puts an image on screen without
   drawing anything — fonts, logos and loading screens are uploads, not primitives. A transfer
   arms itself once its header completes, since the size is only known then, and writes two
   pixels a word wrapping within VRAM's torus as the hardware does.

       gpu 552w/16c/1prim/261121px/1056up      618 non-zero pixels
       content at VRAM x896..927, y256..384

   Counting an upload's words and discarding them renders a game that draws nothing as a game
   that shows nothing, and from outside the two are identical. That is what made the CD look like
   the blocker for most of a day.

   **Still open, now secondary:** `CdInit` fails after fourteen candidates eliminated by
   measurement, so no level assets load and most of the screen stays empty. The escalation
   ladder's answer is unchanged — capture the same exchange in DuckStation with a CD-register
   breakpoint and diff it against our `cd#` trace. What changed is that the path behind it is
   proven all the way to visible pixels.

3. **M1 remaining** — BIN/CUE + ISO9660 + `filesDir` loaders, overlay extraction, syms.txt/.map
   import. The PS-EXE path works; the disc path is untouched, and overlays need it.

4. **Report the reflaxe defects upstream** — three now, with minimal repros already in
   `tests/spike/{ifdrop,guard,bbswitch}` and patches in `vendor/patches/000{1,2,4}`. Defect 9
   (`continue` deleting preceding statements) is the one that matters most to anyone else using
   reflaxe for generated code.

## Milestones

- [ ] **M0 (M): toolchain + walking skeleton + docs**
  - [x] 0.1 process docs committed — accept: files exist on main ✔ 2026-08-08
        Evidence: commit `de6e264` "M0.1: process docs, specs, license and repo skeleton",
        49 files tracked on `main`. `.gitignore` behavior verified by experiment:
        `tests/fixtures/hello.exe` tracked, `tests/fixtures/external/psxtest_cpu.exe` ignored,
        `games/crashbash/local.json` ignored.
  - [x] 0.2 pinned toolchain — accept: `haxe -version` == 4.3.7 from `.toolchain` ✔ 2026-08-08
        Evidence: `haxe -version` -> `4.3.7`; `which haxe` ->
        `<repo>/.toolchain/haxe/haxe`; `haxelib list` -> `reflaxe.cpp: [dev:<repo>/vendor/reflaxe.CPP]`,
        `reflaxe: [dev:<repo>/vendor/reflaxe]`. System Haxe still reports `5.0.0-preview.1`,
        untouched. Submodules pinned: reflaxe `73a9831`, reflaxe.CPP `e07ab05`.
        Bonus: the macOS tarball is a universal binary, so no Rosetta — that risk is closed.
  - [x] 0.3 [M0-VERIFY] executed — accept: every item answered + evidence ✔ 2026-08-08
        14 of 19 items answered by experiment; 5 deferred to the milestone that needs them
        (each marked in the table below). Six upstream defects found and recorded. Two answers
        changed the architecture -> ADR-0002.
  - [x] 0.4 reflaxe.CPP hello — accept: 2-module hello compiles, layout documented, runs
        ✔ 2026-08-08. Evidence: `./scripts/spike.sh` -> "spike.sh: clean". Layout is
        `include/<Module>.h` + `src/<Module>.cpp` per class + `src/_main_.cpp` +
        `_GeneratedFiles.json`, as predicted. CMake template deferred to 0.5, where it has a
        real backend to link.
  - [x] 0.5 SDL window test pattern — accept: runtime.Main draws gradient VRAM via bp_present
        ✔ 2026-08-08. Evidence: `./scripts/run-pc.sh _demo` presented 3547 frames of the gradient
        with the moving marker before the window was closed. The chain Haxe → reflaxe.CPP →
        backend_c_api.h → SDL2 carries pixels end to end.
  - [x] 0.6 headless hash mode — accept: digest stable across two runs ✔ 2026-08-08
        Evidence: `--headless-hash 300` printed `digest=329de455` on both runs; `--headless-hash
        30` printed `ca3afab5`, so the digest tracks content rather than being constant.
  - [x] 0.7 (added) cross-target parity — accept: JS and C++ digests agree ✔ 2026-08-08
        Evidence: `./scripts/test.sh` → "both targets agree — 329de455". The first attempt
        diverged (js=1370700c) and found a real bug in our FNV-1a; see ADR-0003.
- [~] **M1 (L)**: tool — loaders, disasm, discovery, coverage report
  - [x] PS-EXE loader, R3000A decoder, disassembler — accept: golden tests green ✔ 2026-08-08
  - [x] function discovery + CFG + coverage report — accept: coverage printed for both games
        ✔ 2026-08-08. Crash Bash: 844 functions, 46,705 instructions, code ends at 0x8004c564,
        **25.0% of the code region unreached**. Spyro 3 demo: 597 functions, 70,351 instructions,
        **26.1% unreached**. The raw whole-image percentages (42.8% / 68.1%) differ only because
        the games have different data/code ratios; the code-region figure is the comparable one,
        and two unrelated engines agreeing at ~25% suggests it is the honest cost of static
        analysis rather than a defect in ours. 134 tool tests green.
  - [x] jump-table + BIOS-call recovery ✔ 2026-08-08 — and it was the lever it looked like:

        | | Crash Bash | Spyro 3 demo |
        |---|---|---|
        | unreached in code region | 25.0% -> **19.3%** | 26.1% -> **5.2%** |
        | switch tables recovered | 17 (381 arms) | 47 (1108 arms) |
        | BIOS calls identified | 41 | 16 |
        | computed jumps still unresolved | 55 -> **1** | -> 8 |

        Two findings drove it. Most "unresolved computed jumps" were not switches at all but
        **BIOS calls**: Psy-Q reaches the kernel with `addiu $t2,$zero,0xB0 / jr $t2 / addiu
        $t1,$zero,N`, so constant propagation plus reading the delay slot identifies both the
        vector and the function number. And the recovery pass has to run **after** the prologue
        sweep as well as before it, since swept functions contain computed jumps of their own —
        missing that was leaving two thirds of them unexplained.
  - [ ] BIN/CUE + ISO9660 + filesDir loaders, overlay extraction
  - [ ] syms.txt / .map import; optional Psy-Q signature naming (docs/specs/tool.md §2.1)
- [~] **M1.5 (M)**: scale spike — run early against the real game rather than a synthetic one,
      because the real one was available. Findings 2026-08-08:

      | Stage | Result |
      |---|---|
      | `recompsx gen` on Crash Bash | 861 functions, 11 files, **87,547 lines**, 0.9 s |
      | Haxe typecheck | 0.95 s |
      | Haxe → JavaScript | 3.7 s, 6.9 MB, **and it runs** |
      | Haxe → C++ (reflaxe.CPP) | **fails: "Uncaught exception Stack overflow" after ~19 s** |

      **The C++ target does not currently scale to a whole PS1 game.** Not fixed by raising the
      OS stack to 64 MB (so it is Haxe's eval stack, not the process stack), nor by
      `-D analyzer-optimize`, nor by cutting shards from 120 functions to 25 — which rules out
      per-file size and points at either one large function's expression tree or something
      global. 88 K lines is not a lot; this is a limit in a v0.1.0 compiler, not in the approach.

      **Bisected 2026-08-08.** `gen --limit N` emits the first N functions by address; binary
      search over N puts the boundary at exactly 860 functions passing and 861 failing — roughly
      87,500 lines. Everything that would explain a *structural* cause has been ruled out:

      - Not one large function. Function 861 is `f_8004c55c`: one block, three instructions.
      - Not per-file size. 25 functions per shard fails identically to 120.
      - Not the dispatch table's 861-element array literals. Replacing them with `[0]` still
        overflows.
      - Not the process stack. 64 MB changes nothing, so it is Haxe's eval stack.
      - Not the analyzer, in either direction.

      So it is cumulative: some recursion inside reflaxe.CPP grows with total program size and
      runs out of eval stack a hair past where Crash Bash lands. A slightly smaller game would
      compile and a slightly larger one would not, which makes this a hard blocker rather than a
      tuning problem.

      **Fixed 2026-08-08, in the vendored fork.** The stack trace named
      `reflaxe/preprocessors/implementations/RemovePureExpressionsImpl.blockElement`, which walked
      a block's statement list by recursing once per element. Every call was in tail position, so
      it is now a loop. The whole game generates C++ in **63 s, 19 files, 2.1 MB**.

      Reading that file to fix the recursion also turned up the cause of upstream defect 8 —
      see below. Both patches are exported to `vendor/patches/`.

      **Full M1.5 numbers, Crash Bash, 861 functions:**

      | Stage | Result |
      |---|---|
      | `recompsx gen` | 11 files, 87,547 lines, 0.9 s |
      | Haxe typecheck | 0.95 s |
      | Haxe → JavaScript | 3.7 s, 6.9 MB — **runs** |
      | Haxe → C++ | 63 s, 19 files, 2.1 MB |
      | clang -O2 | 9 s, **2.1 MB binary** |

      Every threshold in the original plan is met with room to spare. The binary size is the
      number that matters for the console targets: 2.1 MB of code against a 32 MB machine, with
      3.5 MB of emulated hardware state and ~7 KB of dispatch table. The memory budget in
      `docs/specs/backend.md` §0 holds.

      **Correction:** this table first recorded a 340 KB binary. That figure was measuring a
      program with 86% of its basic-block bodies deleted by upstream defect 9 (below) — a
      compiler bug flattering a benchmark. 2.1 MB is the honest number.

  - [x] **The recompiled game runs on JavaScript.** `build/game-js.hxml` compiles out/gen in
        **4.5 s** with `-D analyzer-optimize` and `node` executes it. It gets through Crash Bash's
        real startup, in this order:

            A0(39h) InitHeap        the kernel heap the game asks for at boot
            A0(49h) GPU_cw          a GP0 command word — the GPU being set up
            SYS(01h) Enter…         a critical section opening
            A0(44h) FlushCache      immediately after a code copy — an overlay landing
            SYS(02h) Exit…          and closing again
            mfc0/mtc0 COP0 r12      the status register: interrupts being set up
            GTE control 24..30      the projection constants

        **The image is loaded now, and it changed the picture.** `ExeLoader` copies the payload
        from offset 0x800 to the load address `GameInfo` recorded at build time. With real bytes
        in RAM, `InitHeap` reports **1,569,644 bytes at 0x80078c98** instead of zero — a sane
        1.5 MB heap for a 2 MB machine — and the game reaches calls it never got to before:
        `B0(19h)`, `A0(72h)`, `B0(35h)`. That is the difference between running on the game's own
        data and running on a memory full of nothing.

        **Both targets, and byte-identical.** An earlier note here claimed arguments do not reach
        Haxe under reflaxe.CPP and marked [M0-VERIFY] 16 answered NO. That was wrong, and the
        mistake is worth keeping: the C++ build had been compiled with an ad-hoc `clang++` line
        over `cpp/src/*.cpp`, which pulls in reflaxe's `_main_.cpp` — the one whose `main`
        discards argv — and never links `main_pc.cpp`, which is the file that exists precisely to
        capture it. The architecture was right and the build command was not. Diagnosing a
        bypassed build path as a platform limitation is an easy way to design around a problem
        that is not there.

        Fixed properly instead: `main_pc.cpp` now takes its entry class as a compile definition,
        CMake reads that class out of the `_main_.cpp` it excludes (so nothing is told twice), and
        `build-pc.sh --null` builds against the null backend with no SDL2 dependency. Running both
        targets on the real executable gives the same 35 lines, in the same order.

        Names verified against psx-spx "BIOS Function Summary", not written from memory. The
        first three are now implemented: `FlushCache` is a genuine no-op under static
        recompilation — there is no instruction fetch to invalidate — and the critical-section
        pair became a depth counter, which makes nesting work the way the hardware's single flag
        never had to. `InitHeap` and `GPU_cw` are next, and both need real subsystems behind
        them rather than a stub.

        and then spins. The spin is *correct behaviour for what exists*: having enabled
        interrupts and configured the GTE, the game waits for VBlank, and there is no scheduler
        to deliver one yet. Seven hundred instructions of real game code executed to reach that
        point, through the dispatch table, the memory map, and the emitted arithmetic.

        That list is also the M2 work order, written by the game itself in the order it needs
        things — worth more than any checklist drawn up in advance.

        Two entries were wrong when first recorded here, both because the diagnostic was.
        `Kernel.syscall` reported the instruction's 20-bit code field, which compilers emit as 0
        essentially always; the function is selected by **$a0**. So every syscall printed
        `syscall 0`, and because `reportOnce` keys on what it prints, the *second* distinct call
        was suppressed entirely — a diagnostic that could not distinguish anything was also
        hiding something. It now reports `$a0`, and the game turns out to open and close a
        critical section around its early setup (`a0=1` then `a0=2`).

        The A0 function numbers above are deliberately not named yet: naming them from memory is
        exactly what golden rule 6 forbids. They get names when each is implemented against
        psx-spx.

  - [x] **The C++ build now matches JavaScript, and the cause was upstream defect 9.**
        `Fns_04_8002c97c::dispatch` missed `case 14` on the first dispatch. Chasing it down
        found something far larger: **86% of the switch-case bodies in the generated C++ were
        empty** — 1119 of shard 4's 1296 `case` blocks compiled to a bare `break;` while
        JavaScript kept the statements.

        One line in `RemovePureExpressionsImpl.blockElement`:

            case TContinue: { acc = []; el = tail; continue; }

        `continue` ends a block: everything *before* it must be kept and everything *after* it is
        unreachable. This cleared `acc` — the statements already collected, which are the ones
        before — and then walked the tail anyway. Exactly backwards, and the same shape as
        defect 8's inverted return, sixty lines away in the same file.

        Invisible in ordinary code, total in ours: every recompiled function is a
        `while(true) switch(bb)` state machine whose cases end in `bb = N; continue;`, so this
        deleted the body of nearly every basic block. The dispatch symptom followed from it — with
        the arms gutted, clang folded a 91-case switch into a 13-comparison tree with no jump
        table, and `case 14` was not in the compiled code at all.

        Fixed in `vendor/patches/0004-reflaxe-continue-deletes-preceding.patch`. Empty case blocks
        in shard 4: 1119 → **0**. The C++ build now produces the same startup sequence as
        JavaScript, call for call, and waits for the same VBlank.

        Reduced to `tests/spike/bbswitch/` — a four-block state machine assigning to fields — so
        `scripts/spike.sh` reports if upstream fixes it.

- [~] **MO (L): overlays** — the design is in the approved plan; four stages, each gated on its
      own acceptance output being pasted here before the next begins.

  - [x] **S1 config + disc access** — accept: config-driven `gen` is byte-identical to the
        flag-driven invocation it replaces, and idempotent ✔ 2026-08-09

        `games/<id>/game.json` now carries the seeds that were living in a command line in
        notes.md, and `gen` reads the executable out of the disc that the gitignored `local.json`
        names — so a build depends on the repository plus somebody's own dump, and on nothing
        that was extracted by hand. New: `config/GameConfig.hx`, `loader/DiscImage.hx`,
        `loader/IsoWalk.hx`; `gen` takes either a config or a bare executable.

        Evidence:

            $ recompsx gen <SCUS_945.70> --out out/gen_baseline --seed 0x80031d28 ... (6 seeds)
            wrote 12 files, 106129 lines to out/gen_baseline
            957 functions, 17 switch tables

            $ recompsx gen games/crashbash/game.json
            wrote 12 files, 106129 lines to out/gen
            957 functions, 17 switch tables

            $ diff -r out/gen_baseline out/gen
            IDENTICAL: config mode == flag-driven, byte for byte

            $ recompsx gen games/crashbash/game.json --out out/gen_twice && diff -r out/gen ...
            IDEMPOTENT: two runs, identical trees

            check.sh: clean
            conformance: 6 tests x 2 targets, all agree
            js digest = c++ digest = 329de455

        Two notes for later stages. The tool's disc reader deliberately duplicates the layout
        detection in `src/runtime/cd/Iso9660.hx` rather than sharing it: one reads through the
        backend ABI into a `RawBuf` under the portable subset, the other through `sys.io` into
        `haxe.io.Bytes`, and unifying them means building the byte-buffer abstraction
        `shared/psxdisc` was meant to be — worth doing as its own change, not inside this one.
        And overlay stanzas parse and validate now but nothing reads them until S2.

  - [x] **S2 universes + emission** — accept: synthetic tool tests cover the call policy, two
        universes' tables, sharing and determinism ✔ 2026-08-09

        The executable is one *universe*; each overlay is another — the executable with that
        overlay's bytes laid over its window, analysed on its own, because while it is resident
        that is what the memory holds. Overlay passes are scoped to their window (the base is
        analysed once) and lenient inside it (code and artwork are adjacent with no linker map, so
        a wrong boundary costs one dropped function rather than the build). Shard indices are
        program-wide, classes are prefixed `Ovl_<id>_`, and a generated `Overlays.hx` carries each
        window, its FNV-1a fingerprint and its own dispatch rows as flat integer arrays.

        The call policy is the whole cost model, and it is three cases: a call inside the
        executable stays a direct call; a call *into* a window becomes a dispatch, because nothing
        at build time knows which overlay is loaded; a call from an overlay into its **own** window
        stays direct, because the caller running proves the callee is resident. Identical function
        bodies in two universes are emitted once and forwarded to, which is where a console gets
        its size back.

        Evidence:

            $ haxe build/tests-tool.hxml
              overlay: a call into a window is dispatched, one inside the base is not
              overlay: an overlay calls the base directly and itself directly
              overlay: two overlays in one window keep their own classes
              overlay: identical code is emitted once and shared
              overlay: the generated table describes both windows
              overlay: the executable's own table excludes overlay code
              overlay: generation is deterministic
              overlay: two overlays the runtime could not tell apart are refused
            all 175 checks passed          (150 before; 25 new)

            $ recompsx gen games/crashbash/game.json --out out/gen_s2 && diff -r out/gen out/gen_s2
            wrote 13 files, 106232 lines
            957 functions, 17 switch tables
            (only difference: the new Overlays.hx, and two doc lines in FnTable)

            check.sh: clean
            conformance: 6 tests x 2 targets, all agree
            js digest = c++ digest = 329de455

        A game with no overlays configured therefore generates what it generated before, which is
        the property that made this safe to land ahead of any real overlay. Nothing dispatches
        into `Overlays` yet — that is S3, and until then the file is written and unread.

  - [x] **S3 runtime activation** — accept: a conformance test drives the whole state machine and
        both targets agree ✔ 2026-08-09

        `kernel.OverlayMgr` decides which code is in a window. The runtime installs nothing: the
        game loads its own overlays through hardware that is already emulated, so RAM already
        holds the right bytes and only the address-to-code mapping has to follow. Three signals:
        a load into a window **evicts** (what was compiled for those addresses is gone, even if
        what replaced it is artwork — the half a fingerprint cannot see); `FlushCache` **rescans**
        (a real machine cannot see newly written code until then, so every loader ends there,
        which makes it the one complete checkpoint); and a dispatch that misses inside a window
        rescans **once** before reporting.

        Recognition is FNV-1a over the window's first words against the value the tool computed.
        The same seven lines exist in three places — `recomp.codegen.Universe`,
        `kernel.OverlayMgr` and the test — deliberately, because a fingerprint that differs by one
        bit between targets activates an overlay on one and not the other.

        Evidence:

            $ ./scripts/conformance.sh Overlay
              ok   Overlay    7564ec5d   values=43
            conformance: all targets agree

        *Revised during S4 bring-up and the audit that followed.* The real game replaced the
        exclusive-windows model with nesting (a 32 KB overlay loads into the middle of a 378 KB
        one and both are genuinely present; the smaller window answers where they share), and the
        audit added KSEG canonicalisation and the resident-but-no-row diagnostic. The test grew
        with each: digest `9fdcde0f`, 54 values, both targets agreeing throughout.

            $ ./scripts/test.sh
            conformance: 7 test(s) x 2 targets — all agree
            js digest = c++ digest = 329de455
            check.sh: clean

        The test found one thing worth recording: when two windows overlap and the bytes of the
        second are overwritten, the *first* is recognised again and takes back the shared
        addresses. That is correct — at any moment exactly one thing is in memory, and "whichever
        one's bytes are actually there" is the only answer that can be right — and it was the
        assertion that was wrong, not the code.

        **Two deviations from the plan, both deliberate.** There is no `--record-overlays` flag
        and no `overlays.suggested.json`: instead a miss reports the span the disc was read into
        that covers it, with the numbers to paste. Same information, no new flag, no new file, and
        it is the form that actually got used when this problem was first met. And load *matching*
        by disc key is not implemented — a load only evicts, and the fingerprint at `FlushCache`
        is the sole authority on identity. It is complete on its own, and the LBA plumbing would
        have bought a second, weaker answer to a question already settled.

        On the real game, with no overlays configured yet, the diagnostic now reads:

            no function at 0x80092bdc (ra=0x80010478) — but the disc was read into
            0x80078c90..0x800d7490, which covers it. That is an overlay: code the executable
            never held, so the tool never saw it. Add it to games/<id>/game.json with
            loadAddr 2147978384 length 387072 and entryHint 2148084700.

  - [x] **S4 Crash Bash end-to-end + ADR-0006** — accept: the game generated from disc and config
        alone, running on both targets to the same digest ✔ 2026-08-09

        Two overlays, found by running the game and reading what the misses said, written into
        `games/crashbash/game.json` as disc offsets: `boot` (387072 bytes at 0x80078c90) and
        `stage` (32768 bytes at 0x800b32b4, inside boot's window). **No capture file exists
        anywhere in the build** — the tool opens the disc the gitignored `local.json` names and
        reads the extents itself.

            $ ./scripts/recompsx.sh gen games/crashbash/game.json
            wrote 21 files, 180722 lines to out/gen
            963 functions, 17 switch tables
            overlay boot: 0x80078c90..0x800d748f (387072 bytes): 319 functions, 26 rejected as data
            overlay stage: 0x800b32b4..0x800bb2b3 (32768 bytes): 66 functions

        The audit that closed the stage found eight things; the four that were defects are fixed
        and now have tests. A resident overlay **shadows** the executable even where it has no row
        (falling back to the base table would run code the game overwrote); the executable's own
        functions *inside* a window are dispatched, never direct-called (same reason, and the
        window test now runs before the own-universe test); a window shorter than its own
        fingerprint is a build error (the tool clamped where the runtime would not, so the overlay
        could never activate); and the resident-but-no-row miss now names the overlay and the hint
        to add instead of implying nothing is loaded. The rest were documentation — the
        fingerprint-region-only eviction rule and its accepted cost are in ADR-0006 and in the
        `OverlayMgr` header — plus KSEG canonicalisation on every address entering the manager and
        an unsigned-decimal printer, because `x >>> 0` still prints negative through C++.

        **The overlay program compiles and runs through reflaxe.CPP**, which nothing had yet
        proved: eight `Ovl_*` translation units, and the two builds agree to the bit.

            $ ./out/_gen/build/recompsx SCUS_945.70 disc.bin --headless-hash 600
            frame 600 | events 5057 | irqs 992 | handlers 1479 | delivered 215/0cb
              | dma 523w/1list/98880cdw | gpu 552w/16c/1prim/261121px/1056up
              | cd 19cmd/192sec/215irq/1drop | spu 109656hw/72kon/442318smp
            frames=600 digest=7e32dc6d          # C++
            frames=600 digest=7e32dc6d          # JavaScript, every counter line identical

        Comparing a *game* at all is new. Its main loop never returns, so `--headless-hash
        <frames>` stops one from inside: `Kernel.UNWIND_HALT` travels the road a `longjmp` already
        travels — every generated call site returns when a token is set — and nothing catches it,
        so `Runtime.callAndResume` stops instead of resuming. The digest is VRAM plus twenty-two
        deterministic counters, because either half can agree while the machine differs: the
        picture alone would miss a dropped interrupt, and the counters alone would miss a wrong
        pixel. C++ runs the 600 frames in 0.31 s against JavaScript's 1.91 s.

        Two things found on the way, both instruments rather than features. `core.Hash` — what
        every digest in this project is measured with — had **no test at all**, and `Hash.word`
        was the exact shape upstream defect 1 mishandles: a multi-statement `inline` whose
        parameter is used four times. It is correct on both targets, but that was luck until
        `tests/conformance/HashFold.hx` (`a5b38872`, 69 values) made it a fact. And `check.sh`
        caught four bare integer divisions that lowered to `double` in generated C++
        (`Gpu.putTexel`, `Iso9660.totalSectors`, and two constant-folded ones in `Cdrom`/
        `KTables`) — ADR-0004 forbids `a / b` on Ints and these predate the rule's enforcement
        reaching generated output. Conformance digests are unchanged by the fix, as expected.

        Also measured, not acted on: **upstream defect 8 is fixed in the pinned fork.** All nine
        `spike-ifbody` cases pass, including a two-statement `if` with no `else` and an inverted
        guard clause. The `else {}` workaround stays everywhere for now — removing hundreds of
        them is its own decision, and `scripts/spike.sh` is the regression test that says when it
        is safe. (That script was also printing its own finding as a shell syntax error; fixed.)

  - [ ] **Deferred from S4, deliberately.** `shared/psxdisc` stays an aspiration: the tool and the
        runtime each keep a small disc reader (~150 lines apiece, three-layout autodetect proven
        twice) rather than being unified mid-feature. §6.2 multi-entry extent duplication is still
        the known gap it was; overlay tracing did not hit it.

## [M0-VERIFY] checklist

Each item is one small experiment under `tests/spike/`. Record **YES/NO + one-line evidence**.
Everything here is an assumption about reflaxe.CPP or the toolchain that code shape depends on.

Executed 2026-08-08 with the spikes under `tests/spike/`. Rebuild them with
`haxe build/spike-verify.hxml` (from the repo root) — they are kept as regression tests for the
upstream behavior this project's code shape depends on.

| # | Item | Answer | Evidence |
|---|---|---|---|
| 1 | `haxelib dev` works from the submodule `main` branch, or is the pre-built `nightly` branch required? (their haxelib.json differ) | **YES, with a caveat** | `main` works, but `-lib reflaxe.cpp` alone fails with `Type not found : cxx.Compiler`. The `reflaxe.stdPaths` declaration in haxelib.json is only consumed by `haxelib run reflaxe` (which flattens a release build — that is what the `nightly` branch is). A source checkout needs `-p vendor/reflaxe.CPP/std -p vendor/reflaxe.CPP/std/cxx/_std` passed explicitly. Encoded once in `build/reflaxe-cpp.hxml`. |
| 2 | Which `reflaxe` base commit pairs with the pinned reflaxe.CPP commit (4.0.0-beta lineage)? Pin both. | **YES** | reflaxe `73a9831` (main, 2026-03-22, haxelib.json version 4.0.0-beta — there is no v4 git tag) pairs with reflaxe.CPP `e07ab05` (main, 2025-12-09). Both pinned as submodules; the 3-month gap did not break anything. Fallback pin if it ever does: reflaxe `5a91527` (2025-12-03, contemporaneous). |
| 3 | Two-module hello → output layout is `include/*.h` + `src/*.cpp` + `_main_.cpp` + `_GeneratedFiles.json`, and our CMake glob builds it | **YES** | `tests/spike/hello` (Main + Helper) produced exactly that layout; `clang++ -std=c++17 -O2` built and ran it. |
| 4 | macOS Haxe 4.3.7 tarball runs on Apple Silicon; haxelib works with project-local NEKOPATH; `.haxelib/` isolation confirmed | **YES (better than assumed)** | The `-osx` asset is a **universal binary** (x86_64 + arm64, confirmed with `file`), so it runs natively — **no Rosetta needed**, and the "Rosetta dependency" risk is closed. Neko universal likewise. `haxelib list` resolves both dev libs; system Haxe still reports 5.0.0-preview.1, untouched. |
| 5 | `-D cxx_exceptions_disabled` compiles hello + a runtime-shaped file (then add `-fno-exceptions` to CMake); if std breaks, fall back to policy-only | *deferred* | Not exercised yet; the spikes compiled without it. Revisit when the runtime skeleton exists (M2). Policy-only (no `throw`/`try` in our code, enforced by check.sh) already holds. |
| 6 | RawBytes: 2 MB `Stdlib.malloc` + `ccast` → `CArray<UInt8>`; inline get/set produce raw indexing in the emitted C++ | **YES — but the API shape is forced** | 2 MB alloc + unchecked indexing works and inlines perfectly: `Mem.set32(0x1000, …)` emits four `Mem::ram[4096] = 239;` stores, and `get32` expands to a single `((Mem::ram[4096] \| (Mem::ram[4097] << 8)) \| …)` expression — no calls. **However** memory accessors must be `static` methods on a class with `static` fields. Instance methods (and abstracts) are unusable: see #12. |
| 7 | Extern C binding of `bp_log`/`bp_present` against a stub .c; `String`→`ConstCharPtr` mechanics; `Ptr` into a buffer interior | **YES** | `@:include("cstub.h") @:topLevel extern function …` binds cleanly. `ConstCharPtr.fromString(s)` is the documented String conversion and works. `CArray.toPtr()` + `Stdlib.ccast` yields a `Ptr<UInt16>` into our buffer, verified by summing values written from Haxe inside the C function. |
| 8 | `untyped __cpp__` expression form with `{0}` interpolation compiles | **YES** | `untyped __cpp__("((int)({0}) * 3 + 1)", 14)` → 43. The escape hatch is real; statement form untested (not yet needed). |
| 9 | `cxx.num.Int64` arithmetic (32×32→64 multiply, shifts, sign) emits plain `int64_t` ops; no accidental `haxe.Int64` pull-in | **YES** | `0x12345678 * 0x10` gives high=0x1, low=0x23456780; a 64-bit value round-trips through a C extern taking `uint64_t`. `haxe.Int64` never appeared in the output. |
| 10 | What backs Haxe `Array<Int>` and `String` in the emitted C++ | **ANSWERED** | `Array<T>` → `std::shared_ptr<std::deque<T>>`; `String` → `std::string`. Confirms the rule: Haxe arrays are init-time only, never in hot paths or in fixed-size buffers — those use `CArray`. |
| 11 | `-dce full` + a dispatch-table reference keeps functions alive without `@:keep` | **YES (via Plan B)** | With `-dce full`, `fnDouble`/`fnNegate` are reachable only through a static `switch` in `Dispatch.dispatch` and both survive and execute correctly. Reachability through a generated switch is sufficient; `@:keep` is not needed. |
| 12 | `inline` effectiveness of accessors in the emitted C++ | **YES for static methods; instance inlining is BROKEN** | Haxe's inliner introduces a receiver temp (`_this` for classes, `this1` for abstracts) and reflaxe.CPP prints the name without uniquifying it, so **two inlined instance-method calls in one scope emit `redefinition of '_this'` and do not compile**. Generated MIPS functions perform many memory accesses per function, so this rules out both an abstract and an instance-method `RawBytes`. Static methods have no receiver and no temp — they inline flawlessly. This is why `Memory` is a static-accessor class. |
| 13 | CLAUDE.md `@AGENTS.md` import actually loads | *pending* | Needs a fresh Claude Code session in-repo to confirm via `/context`. |
| 14 | The installed Codex CLI auto-reads AGENTS.md from the repo root; note its version | *pending* | Needs a Codex CLI session. |
| 15 | reflaxe.CPP's `-D cmake` emission — 10-minute look | *deferred* | Ours stays authoritative regardless; look at it when the real CMake template is written (M0.4/M0.5). |
| 16 | `Sys.args()` works under reflaxe.CPP | **NO — and the fix is ours** | The generated `_main_.cpp` is literally `int main(int, const char**) { Verify::main(); return 0; }` — argc/argv are **discarded**, so `Sys.args()` returns empty (verified: passed two arguments, got count 0). Decision: our CMake **excludes the generated `_main_.cpp`** and links our own `main.c`, which stores argc/argv for the backend and then calls the generated entry point. Command-line access then goes through the backend ABI like everything else. |
| 17 | Integer overflow semantics: does the emitted C++ rely on signed `int` overflow (UB)? | **YES it does — so `-fwrapv` is mandatory** | Haxe `Int` maps to C++ `int`, and `0x7FFFFFFF + 1` produced −2147483648 at `-O2` — the MIPS-correct answer, but only because clang happened to wrap. Signed overflow is UB in C++, so this is not something to rely on: **all builds must pass `-fwrapv`** (added to the CMake template). Recorded in ADR-0001. |
| 18 | Function-reference values lower to plain C function pointers, not `std::function` | **NO — Plan A is dead, Plan B is now the design** | `Array<(Int)->Int>` lowers to `std::deque<std::shared_ptr<std::function<int(int)>>>`: an allocation and a type-erased indirect call per entry, and the array literal **does not even compile** (`arithmetic on a pointer to the function type`). The FnTable therefore stores packed Int handles in raw memory and dispatches through generated `switch` statements — no function values anywhere. `docs/specs/tool.md` §3 updated accordingly. |
| 19 | `haxe --no-output` typechecks generated code against the runtime classpath on 4.3.7 | *deferred* | Needs generated code to exist (M1/M2). |

### Upstream defects found (fork-and-fix backlog, per ADR-0001)

Recorded so they are not rediscovered. None currently block us; workarounds are in place.

1. **Inlined locals collide — FIXED IN OUR FORK.** Haxe's inliner materialises a callee's
   parameters and temporaries as locals in the caller's scope, always with the callee's own
   names, so two calls to the same inline function in one scope emitted two declarations of the
   same name: `redefinition of 'a'`. The `_this` / `this1` receiver temporaries were the same
   bug wearing a different name, and it also blocked `RawMem.get16`/`get32` (whose parameter is
   used more than once, so Haxe binds it) from being called twice in a scope — which generated
   game code would do constantly.

   Fixed on branch `recompsx-fixes` in `vendor/reflaxe.CPP`: every declaration and reference
   already funnels through `Compiler.compileVarName`, and Haxe gives each variable a unique id,
   so names are now made unique per function body — first claimant keeps the name, later ones
   get their id appended (`a`, `a_24018`). Three small edits: `Compiler.hx` (the map and scope
   push/pop), `Expressions.hx` (declaration and reference sites), `Classes.hx` (reset per
   function). Worth offering upstream.
2. **`Array<FunctionType>` does not compile** — the `std::deque` of `std::function` initializer
   is malformed. *Impact: high* (killed FnTable Plan A). *Workaround:* Plan B integer handles.
3. **`Sys.println` emits `std::cout` without `#include <iostream>`.** *Workaround:*
   `@:cppInclude("iostream", true)` on the class, or route output through the backend (which is
   what the runtime does anyway).
4. **Interpolating `array.length`** emits `->size()` (`size_type`), which does not compile
   against `std::string operator+`. *Workaround:* bind to an `Int` first.
5. **`trace(cond ? a : b)`** default-constructs `haxe::DynamicToString`, which has no default
   constructor. *Workaround:* use plain `if`/`else` statements.
6. **`@:valueType` class as a static field** requires a default constructor that is not
   generated. *Workaround:* static fields of primitive/`CArray` type instead.
7. **Target-code templates splice arguments without parentheses — in BOTH mechanisms.**
   `"({0} / {1})"` via `untyped __cpp__`, and `"({arg0} / {arg1})"` via `@:nativeFunctionCode`,
   both emit `(y * 31 / h - 1)` for `div(y * 31, h - 1)` — returning 42 where 54 is correct.
   *Impact: high, silent.* *Rule:* parenthesise every placeholder by hand, always:
   `"(({arg0}) / ({arg1}))"`. Locked by checks in `tests/spike/{verify,intdiv}`.

   On mechanism choice: `@:nativeFunctionCode` is the reflaxe.CPP-native way and what its own std
   uses (`cxx.CArray`, `cxx.ConstCharPtr`, `cxx.Stdlib`); `untyped __cpp__` is reflaxe's generic
   injection hook, whose name is merely configured to hxcpp's spelling. Prefer the former and
   keep target code inside declarations; reserve `__cpp__` for statement-level injection.
8. **FIXED in our fork.** *An `if` with no `else` and more than one statement in its body was
   silently deleted.* The cause was one missing `!`:
   `RemovePureExpressionsImpl.hasSideEffects` returns true to mean "has side effects" in every
   branch except the composite one covering TBlock/TIf/TVar/TSwitch, which computed a local named
   `isPure` and returned it unnegated. `blockElement` then used that to rewrite
   `if (cond) { body }` into just `cond`, believing a body full of assignments and calls was
   side-effect free.

   That single inversion explains everything filed here: guard clauses compiling to their
   fall-through, loop bodies losing branches, ternaries vanishing. It also explains why it looked
   like a size limit — a one-statement body is not a `TBlock` and never reached the inverted
   branch.

   The `else {}` workarounds in `src/runtime` and `tests/conformance` stay for now, so the code
   still builds against an unpatched reflaxe until this is upstreamed. `scripts/spike.sh` reports
   the change of state. Original characterisation, kept because it is what a future occurrence
   would look like:

   | Shape | Result |
   |---|---|
   | `if (c) { one; }` | kept |
   | `if (c) { two; statements; }` | **entire `if` deleted** |
   | `if (c) { two; statements; } else { ... }` | kept |
   | `if (c) { one; }  if (c) { one; }` | kept |

   Not the body — the whole statement disappears, so execution continues as if the condition
   were never tested. Everything previously filed as separate shapes was this one rule: guard
   clauses (`{ ...; return; }` is two statements), loop bodies that also advance the index, and
   ternaries (which lower to several statements). It bit the conformance harness itself:
   `Conf.expect` compiled to `feed(actual);` alone, so every assertion silently passed on C++
   while failing on JS.

   Haxe's own `--interp` and `-js` compile identical source correctly, so this is reflaxe.CPP's
   alone. Root cause not yet located — `compileIf` and `isMutator` both look correct, so it is
   further up the preprocessor pipeline. Reported shape is minimal and ready to file upstream.

   *Workarounds, all verified:* add `else {}`; extract the body into a function call; or invert
   a guard into `if (!c) {} else { ... }`. `scripts/spike.sh` reports when upstream fixes it.

   **Related, and the one that cost the most time so far: `inline` on a multi-statement function
   is unsafe.** Writing `core.Ops.div`/`divu` took four attempts, each correct on JavaScript and
   wrong on C++ — a ternary inside a branch, guard clauses ending in `return`, an
   `if / else if / else` chain with two-statement bodies, and finally a one-statement-per-branch
   version whose helper was `inline`. Only removing the `inline` made both targets agree.

   Practical rule for `src/runtime`: reserve `inline` for single-expression accessors with each
   parameter used once (`RawMem.get8` is the shape that is safe). Anything with a body gets a
   plain call — the C++ compiler inlines it anyway, and none of this is a hot path in the sense
   that would justify the risk.

9. **FIXED in our fork: statements before `continue` were deleted.** The block walker cleared
   its accumulated statements instead of returning them. Patch 0004 and the `bbswitch` spike
   retain the reduction; the M1.5 section above records the game-sized failure and acceptance.
10. **FIXED by patch 0005: declaration motion loses reads or duplicates variable ids.**
    `RemoveReassignedVariableDeclarationsImpl` reused a candidate after moving it and missed
    reads in initializers/nested blocks. Scalar GPR locals exposed both `Logic error` during
    Haxe-to-C++ generation and undeclared C++ identifiers. `constantStores`, `loadThenRedefine`
    and `storeThenRedefine` in `TestCodegen` reproduce the failures; the Codegen conformance
    test passes on JS and C++ after the fix. Setup applies the exported patch (ADR-0007).

## Blockers & open questions

- **Resolved: missing console-branch integration caused the browser regression.** Commits
  `25d9a5d` / `6819782` were present all along. Their GTE/CD/rendering/timing and per-game
  metadata are now reconciled into main; the browser reaches the menu and JS variants report
  zero missing paths. Full gameplay coverage and a new Dreamcast hardware run remain open;
  see the current acceptance output and `games/crashbash/notes.md`.
- **The kernel has no font**, and will need one the moment a game draws text through the ROM.
  `B0(51h) Krom2RawAdd` and `B0(53h) Krom2Offset` hand out addresses of glyphs in the BIOS font
  ROM. Measured from a real ROM's structure (a format, not its data): 16×16 glyphs, 32 bytes
  each, two bytes a row, most significant bit leftmost. A real BIOS cannot be in the repository
  (golden rule 4) and neither can anything derived from its bitmaps, so the answer is either
  glyphs of our own or a freely-licensed bitmap font — and if the text needed is Japanese, only
  the second is realistic. Crash Bash stopped asking once it knew what console it was on, so this
  is no longer blocking anything.
- Other known unknowns are tracked as `[M0-VERIFY]` items above and as the open
  questions in `games/crashbash/notes.md`.

## Session log (append-only, newest-first)

2026-09-25 [claude] Silent SPU path: falling envelopes (release, decay, falling sustain) taken
a stretch of equal steps at a time (`Spu.fallRun`), exact; new `SpuFall` conformance test sweeps
every shift/step on both targets (fe04d507). JS catchUp over 17,500 frames 590-623 -> 160-183 ms;
digests unchanged incl. --no-audio 17500 = 1831e9c7 on JS and C++. Dreamcast: presents paced to
59.94/50 Hz (`pace` on the overlay); a cutscene had run at 75 fps. Next: the user's missing sounds.

2026-09-25 [claude] SPU voices on the Dreamcast's AICA under `--audio-hw` (ADR-0024; ABI 37:
`bp_spu_ram/dirty/voice`, `BP_CAP_SPU_VOICES`). C ADPCM decode identical to the runtime's on 128
samples; digests unchanged on JS and C++. Details in the Dreamcast entry below. Next: the user's
Flycast run with the overlay, to read `spu`/`aica` against the 244 ms before.

2026-09-25 [claude] Call-site `inline` for the I/O reads inside `slowRead32` (Timers, SIO, DMA,
CD, SPU, ROM) and `inline` on the Timers read chain (`value/fold/ticksIn/dotsIn/videoClocksIn/
unsignedDiv/unsignedMod` and the small helpers, early returns turned into if/else so Haxe can
inline them). Digests unchanged (Mem 27f9aa59, VideoTime eb49ad68, game 0e180c28 / ab13c60f);
bundle +5 KB of 9.8 MB. Wall time within noise over five interleaved rounds (min 15.38 vs
15.68 s); the timer chain's self time in the profile fell 527 → 440 ms. Kept because it costs
nothing — unlike the class-wide accessor inlining (B: +34 % bundle, H: +9 %), which stays rejected.
The same call-site `inline` then went into `slowRead8` and `slowRead16` (+2.5 KB, five rounds
within noise, mean 19.37 → 19.10 s; Mem/CdCommands/SpuVoice digests unchanged), and then the
three `slowWrite`s, where `ioWrite32` also inlines `Gpu.writeGp0` (its two early returns became
an if/else chain) so a GP0 word reaches the GPU dispatcher from `write32` in one call: +2.5 KB,
min 18.15 → 16.97 s, mean 18.88 → 18.59 s over five rounds; Raster a749a71a unchanged.
Second level: the dispatch helpers those bodies call are `inline` in their own classes (Timers
`readMode/writeValue/writeMode`, SIO `readWide/writeWide/popRx`, DMA `readDicr/writeDicr/
channelRead/channelWrite`) and `ioWriteNarrow` inlines `ioRead32`/`ioWrite32`; +4.3 KB, within
noise (min 16.87 → 16.50 s). CD, SPU and GPU internals stay calls: they do work, not dispatch.
A `--trace-turbo-inlining` run explains the shape: V8 inlines `read32` (140 bytes of bytecode)
and `write32` (152) into the generated functions, and refuses `slowRead32`/`slowWrite32`
(reason 5, over the 460-byte limit) — so the slow path must stay out of the accessor, or every
RAM access at 14 k sites becomes a real call. Static-address dispatch in the tool was verified
to fold (an `inline slowWrite32(0x1F801810, v)` reduces to the GP0 body) but not adopted: only
7 `lui 0x1F80` sites exist in this game, libgpu reaches the ports through pointers in RAM,
and for constant RAM addresses both compilers already fold the RAM test after inlining.
The polled counter is timer 1 (libetc's VSync counting hblanks through the pointer at
0x80068BC0 → 0x1F801110), so a read cost three divides, not nine. All three are compares on
the common path now, bit-identically: fold's quotient is zero exactly when
`0 <= elapsed < period`, the folded hblank residue is shorter than a line, and `unsignedMod` is
the identity below the modulus; the dotclock residue uses `x - q*d` for its remainders (5
divides → 3). Digests unchanged (VideoTime eb49ad68, game 0e180c28 / ab13c60f); five rounds
min 16.79 → 15.92 s, mean 17.36 → 16.66 s. Noted, not fixed: `fold` wraps `base` past the
target/0xFFFF without raising the reached bits, so a wrap that lands inside a folded period is
never flagged — pre-existing, and a game reading those bits on timer 1 would notice.
**Audio off** (`--no-audio`, the page's "Ses" box): `spu.Spu.outputEnabled` false keeps every
voice advancing — envelope, position, ENDX, loop flags — and skips the mix, the main-volume pass
and the buffer. Verified state-identical: the 3000-frame stat lines of the two modes differ only
in the peak diagnostics, `samplesOut` and every event count match; the digest differs only by
`nonSilent` (c346c0af / 53e5c7fd for 3000 / 9000 frames), so it is not a digest mode. Node:
mean 18.83 → 17.81 s, SPU share 8.0 → 6.8 %: the sample-by-sample state walk costs nearly what
mixing did. The user's 6× browser profile (bundle b31819ef73ce, before this switch) put the SPU
at ~13 % self: voiceSample 4.3, mixVoice 3.3, decodeBlock 2.1, envelope 3.4.
Done: a silent voice moves from event to event (`advanceVoice`: the run is the shorter of
ticks-to-envelope-period and ticks-to-block-end, capped by the batch; the event is applied by
the phase's own code and the block header by `startBlock`, in the per-sample order). Proven
three ways: `SpuAdvance` (new conformance test, 7172e474) snapshots six voices of six shapes
after every batch on both paths and requires equality; the `--no-audio` game digest is the
per-sample walk's exactly (c346c0af / 53e5c7fd); sound-on digests unchanged. Node `--no-audio`:
min 17.09 → 15.80 s, mean 17.51 → 16.34 s; SPU share 6.8 → 2.1 %.
**Fast-forward** ("Hız sınırı" off, `host.unpaced`): the browser loop runs on a fourteen-
millisecond budget per tick instead of holding to wall time, keeps its origin fresh so pacing
resumes cleanly, and the page presents at most once per display interval and shows the frame
rate reached. Live switch, presentation only (golden rule 3). Verified in the app's browser:
58 kare/s locked → 371 and 246 unlocked (menu / gameplay) → 60 locked again, console clean.
Two refinements of the silent walk, measured by instrumenting a 9000-frame run: 13.4 M runs for
56 M samples, 9.9 M of them one sample long and only 168 k on a pinned level. The game's voices
spend most of their time in a period-one exponential release (`hi=dfe4`: shift 4, every tick an
event), where the run machinery cost more than the per-sample walk it replaced. Now: (1) a
sustain at its rail (rising at 0x7FFF, falling at 0) is "no event" and the counter wraps modulo
the period; (2) with a period of one the phase's own code runs tick by tick in a tight loop and
the position follows in one step, a phase change ending the run on the tick that made it.
Same three proofs (SpuAdvance 7172e474, `--no-audio` c346c0af / 53e5c7fd, sound-on unchanged);
Node `--no-audio` mean 16.11 → 15.53 s, SPU share → 1.8 %, SPU self 305 → 203 ms.
User's 6× and 20× Chrome profiles (sound off, lock on): `read16u` 8 % at 6×, absent at 20×, and
0.2 % in Node on the identical Closure bundle — a throttling artefact, not a cost. Profile at 1×
for shares. The VSync wait loop (`f_80032264`, libetc) is the largest single item left: 8 % self
locked, 30 % in fast-forward; an exact idle-skip in the recompiler is proposed, not started.
**GC.** Node's sampling heap profiler is blind to HeapNumbers, typed-array views and other
allocations made from JIT code or builtins (measured: a micro-test boxing 310 MB of doubles
sampled 0.2 MB), so the source was found with the inspector's allocation tracker (inline
allocation disabled) and by bisecting bundle copies: the garbage is 16-byte HeapNumbers from the
GTE's double accumulator (`rtps`, `mvmvaNormal`, inlined into the transform functions), mostly
in deopt/re-opt windows at loading (frames 1320–1380: 21 scavenges; the last sixth of a
9000-frame run: 5), with `--no-opt` doubling the count. Fixed two certain allocators: the
`subarray` view per CD sector in the JS shim's `fileRead` (a copy loop now; within noise on the
scavenge count) and the WebGL renderer's per-batch record objects (pooled; browser only,
rendering verified). Digests unchanged. A hi/lo int-pair accumulator (pre-ADR-0021 `Gte.hx`) is
was measured against the double one on today's tree (digests identical, GteOps 1cf89aa2, Acc64
0deeafe0): the pair is slower — min 14.89 → 16.58 s (+11 %), mean 16.37 → 17.18 s (+5 %), GTE
share 31.1 → 33.4 % — and removes only part of the garbage: scavenges 91–93 → 84 over 3000
frames, 194 → 160 over 9000, the loading burst 90 → 70. A scavenge here is 0.1–0.3 ms, so the
difference over 150 s of emulated time is milliseconds. Decision: the double accumulator stays
(ADR-0021 holds); the remaining 160 scavenges have another source, not yet attributed.
**Accessor decode** (a proposal the user obtained from another model, verified here): the RAM
test and the mirror mask are one operation — `r = p & 0x1F9FFFFF` keeps the region bits above
the mirrors and drops bits 21–22, so `r < RAM_SIZE` is exactly `isRam(p)` and, when true, `r` is
already the RAM offset; the scratchpad test is one masked compare. Applied to all eight
accessors; every non-RAM path still takes `p`. Digests unchanged (Mem 27f9aa59, game 0e180c28 /
ab13c60f); bytecode read32 140 → 133, write32 152 → 145; five rounds `--no-audio` mean
15.97 → 15.76 s, min 15.45 → 15.42 s — at the noise band's edge, kept because it is free.
Its second idea, access grouping under one condition `q <= RAM_SIZE − span` (mirror-boundary
safe), is the right form of the grouping noted above and is recompiler work, not started.
Targeted call-site `inline` of the accessors inside the GTE transform functions (the user's
question: V8's cumulative budget of 920 bytes cannot inline all 30 `read32` sites of
`f_800193a8`): one function +11 KB, mean 14.96 → 14.82 s, min equal; four functions +46 KB,
mean 15.17 s. Within noise, not adopted — V8's own inlining is enough.
**Idle-loop skip (ADR-0022, approved by the user).** `recomp.codegen.IdleLoopPlan` proves a
natural loop is a wait (one path of blocks with the header's pump only; arithmetic, loads, one
`lw/addiu/sw` of a `$sp` slot and branches; no loop-carried register; the count read, while a
register holds it — through the compiler's store-then-reload too — only by its `addiu`, its
store and one `beq`/`bne` against an invariant), and `Emitter.emitIdlePrologue` places, after
the pump, a dry turn into shadow locals (loads guarded to plain memory and off the slot at run
time, the store left out, invariant branches checked) followed by the count of turns before the
next event and before the counter's exit; all but the last are taken by arithmetic, the last
runs as code. Proof: the tool tests (391), the `Codegen` conformance test (75194be4: a
hand-assembled VSync and libetc's exact reload shape, reached / timed out / satisfied on entry /
polling ROM, both builds equal in every register, the slot, the polled word and the cycles),
and the game's four digests unchanged with the skip active. Fifteen loops match in the game,
`f_80032264` among them; 88.7 M turns over 9000 frames were taken by arithmetic (41 k skips) —
56 % of the machine's cycles were the wait. Node `--no-audio`: `f_80032264` gone from the
profile (2.0 % → 0), mean 15.78 → 15.31 s — small there because the software rasteriser
dominates a headless run. In the app's browser the skip is active (60 k turns by frame 240) but
the pane's throttling made frame rates unreadable; the fast-forward rate in the user's Chrome,
where the wait was 30 % of the main thread, is the measurement still to take.
The user's Chrome profiles with the skip (1×, fast-forward, sound on): the VSync loop is gone;
SPU ~21 % (voiceSample 6.4, mixVoice 5.5, decodeBlock 2.9, envelope 5.8), GTE ~14 %, the
transform functions ~9 %, accessors ~7 %, GP0 → WebGL ~6 %. Ruffle (a browser extension)
wraps the page's tick and takes 65 % "total" in those profiles; disable it before profiling.
**Sounding mixer in runs.** `mixVoice` now moves a voice the way the silent path does:
between the envelope's next change and the block's end every sample does the same thing, so
a run's samples go through `mixRun` — one loop, position in locals, no calls — the counter
jumps by the run, the event sample gets its `stepEnvelope` first, and a period of one steps
the envelope inside the loop and ends where the phase changes. The level is read after the
position advances, because a block that ends a one-shot zeroes it on that sample. Output bit
for bit the same (SpuVoice d7680e93; game 0e180c28 / ab13c60f; `--no-audio` unchanged). Node
with sound: mixer self 1022 → 698 ms, SPU share 8.6 → 6.2 %, wall time within noise
(mean 15.91 → 16.03 s); in the browser the SPU was a fifth of the main thread.
**GTE accumulator arithmetic (JS shim).** `Acc.wrap44` reduced modulo 2^44 by
`floor(t / 2^44)`, a divide, a floor and a multiply on every one of the nine MAC steps of an
RTPS; every value there is an integer below 2^53, so repeated subtraction of 2^44 lands on the
same representative and a chain that does not overflow — nearly all — pays two compares. The
`>> 12` / `>> 16` shifts multiply by 2^-12 / 2^-16 instead of dividing: exact, the exponent
moves. GteOps 1cf89aa2 and Acc64 0deeafe0 unchanged, four digests unchanged; five rounds
`--no-audio` mean 17.16 → 16.41 s (−4.4 %), min 16.62 → 15.87 s, GTE share 31.0 → 29.7 %.
The perspective divide's leading-zero count was a loop of up to sixteen turns per RTPS; it is
`IntMath.clz32` now (`Math.clz32` / `__builtin_clz`, 32 for zero), exact by definition.
Digests unchanged; five rounds min 15.39 → 14.81 s, mean within noise, GTE share 30.2 → 29.3 %.
What remains in `rtps` is the arithmetic itself — nine multiply-adds with their range checks,
the table divide, the saturations, two FIFOs — and V8 loads a static field at a constant
offset, so the static traffic is not the lever it looks like. GTE closed here: −4.4 % mean and
−3.8 % min over the two steps.
The user's in-game profile (6×, locked) puts MVMVA first among the GTE's commands — the
engine's overlay code (`f_800c353c → … → f_800330cc`) calls it per vertex — with RTPS second
and the sounding mixer between them. `mvmva` chose its matrix, vector and translation by
copying them into nine plus six static scratch fields and reading them back lane by lane;
they are locals now, passed to `mvmvaNormal`/`mvmvaFarColor`, and the two lighting commands
that also fed the lanes pass their constant selections directly, so the scratch and the three
selectors are gone. GteOps 1cf89aa2 and Acc64 unchanged, four digests unchanged. A scratchpad
microbenchmark (`Gte.cmdMvmva`, 3 M calls): 30.4–31.5 → 25.2–26.6 ns per call; `rtps`
untouched at ~45 ns. Game, three rounds `--no-audio`: mean 16.66 → 16.08 s.
**GTE register accessors fold at their call sites.** The in-game profile showed `Gte.getData`
at 6 % self: a `switch` over thirty-two registers, called with a constant register number at
every one of its 127 generated sites (and `setData` at 138, `setCtrl` at 139). Made `inline`,
Haxe's analyzer folds the switch on the constant to the one case — verified on a small
program first — so every site is now a direct static field read or write, the FIFO pushes and
IRGB/LZCS cases included, and the bundle shrank by 7 KB. GteOps 1cf89aa2, Codegen 75194be4,
four digests unchanged; five rounds `--no-audio` mean 15.22 → 14.11 s (−7.3 %), min 14.27 →
13.35 s; `getData`/`setData` gone from the profile, `f_800193a8` self 933 → 686 ms.
**WebGL batching (ADR-0020 revision).** Texture page, CLUT, window, flags and blend mode moved
into the vertex (three `uint` words, flat varyings); the adding blend modes share one GL state
(ONE, SRC_ALPHA, colour pre-scaled in the shader), mode 2 keeps its own; GL state is shadowed
inside a flush; sampler units set once; `dirty` allocates nothing and uploads only the rows the
rectangle spans. GL calls per vblank of gameplay 2359 → 39, draws 192 → 3 (Node, counting stub
context). A first version stored the shader's alpha weight: a mode-2 subtraction left zero
alpha, which no later draw overwrote, and the user's Chrome showed the Select Game Type scene
filling with black silhouettes; the blend now keeps the destination's alpha and the blit writes 1.
Replay harness (scratchpad; renderer calls recorded under Node, replayed into two renderers in
lockstep in the browser): framebuffer and presented-canvas RGB identical to the old renderer
over six 300-frame stretches (1500, 2400, 4500, 5200, 5700, 6000) and a synthetic every-state
trace, alpha 255 everywhere; a deliberately wrong mode-0 weight is caught (22 M bytes differ).
Renderer main-thread time, minimum of ten, 300 vblanks: 26.1 → 6.0 ms, 28.1 → 6.2 ms,
79.3 → 10.3 ms. The page's text is English now. Safari (reported at 10 fps, rAF every ~150 ms
with ~25 ms of work) is unmeasured on the new renderer.
**The page's garbage (ADR-0023).** The user saw many collections, most with the speed limit off.
The inspector's allocation tracker — under Node on the page's bundle with a page-like host, and
in a headless Brave (throwaway profile, DevTools protocol; V8 15.3, 31-bit Smis like Chrome) —
put ~90 % of it in the generated functions as boxed numbers: `CpuState`'s register fields had
become V8 double fields (`%DebugPrint`), after which reads in unoptimised code and values crossing
un-inlined calls allocate. `--trace-generalization` and probes found why: `IntMath.mod` was JS
`%` (-0 for DIV's remainder into HI), the SPU's `envLevel[v] += rising ? by : -by` stored a
boxed 4095 after `-0` (array → doubles, read through the voice registers into `ctx`, then 25
fields by contagion, frame ~2600), and SRL by zero / SRLV emitted `>>> ` untruncated — which
also made BEQ disagree with C++ (new `Codegen` fixture: fails with 2147483648 for -2147483648
without the fix). On 31-bit engines KSEG0 pointers are never Smis, so loads and stores now pass
`addr & 0x1FFFFFFF` (`Emitter.busAddr`; every accessor masks first anyway). Also: 12 dynamic
`noteOnce` messages guarded by `Runtime.alreadyReported` (built on every SPU voice write,
key-on, I_MASK write), and the page's sound path copies into its own buffer instead of a slice
plus a copy per push. Digests unchanged (0e180c28 / ab13c60f, c346c0af / 53e5c7fd, 329de455, all
conformance; `Codegen` 51a15d34 with the fixture). Node, frames 5000–5300, sound on: garbage
33.5 → 0.85 MB; 9000 frames: scavenges 105 → 22, wall min 14.27 → 8.98 s, mean 15.61 → 9.41 s
(five interleaved rounds). Brave: objects per emulated frame ~44 k → ~21 k, scavenges per 1000
frames 103–113 → 32–39, GC 2.0–2.3 % → 0.8 % of wall unpaced; speed neutral (vblanks
5000–15000: 1433/1435 → 1545/1414/1408 fps sound off). Rejected on Brave: registers in an
`Int32Array` (getters box their own), accessors cut to the RAM path (20 k vs 16.7 k objects).
Next: what remains on 31-bit engines is guest words beyond ±2^30 crossing un-inlined accessors
and the double register fields; candidates are a rotated register encoding (KSEG0 pointers and
small numbers both fit 31 bits after a one-bit rotation) and inline RAM paths in the emitter.
Safari's 10 fps (rAF every ~150 ms) still needs the replay benchmark run in Safari.
**iPhone at ~60 fps: WebKit without its JIT on insecure origins.** The user reported the game
capped near 60 fps on an iPhone (over 1000 before). A WKWebView harness (`wkrun`, scratchpad)
showed the same WebKit build running the page at 757–3279 fps from `http://localhost` and ~70
from `http://192.168.1.238`, whatever the bundle (old renderer, old runtime, sound off: all
~60–100); a plain integer loop took 44 ms against 396 ms. The LAN origin is not a secure
context, and WebKit runs such a page without its optimising JIT. Over HTTPS with a self-signed
certificate the LAN origin is secure again: 45 ms, 808–2818 fps, AudioWorklet back.
`scripts/serve-https.py` (launch configuration `web-https`) makes the certificate once per LAN
address in `out/_web/tls/` and serves `web/` on 8443; the page's build line says when it is not
a secure context. The SPU's lent buffer is now `host.audioLend(bytes, byteLength)`; a page
without it gets the old `audioPush(slice)`, so a cached page cannot play the whole buffer.
(An earlier "collapse" in the harness was its own window being occluded — rAF stops; the
window now floats and App Nap is off.)
**Lines across floors and models (ADR-0020 revision).** The WebGL renderer floored the
interpolated texel coordinate; landing a hair below a whole number, it took the previous texel
along polygon edges. `compare.html` (scratchpad) replays a trace to a vblank and diffs the
framebuffer against the software rasteriser's picture of the same vblank (`refgrab.js`): pixels
off by >= 6/31 at 2450/2600/5250/5400 went 412/432/518/623 → 20/17/49/55 with a 1/1024 nudge
(1e-4 … 3e-3 identical; a nudge down ×10 worse). Present since the first renderer.
**The phone kept the old address.** The server log showed the iPhone (192.168.1.249) loading
from `http://…:8000` again, so it still ran without the JIT. `scripts/serve-https.py 8443
--http 8000` is now the `web` launch configuration: HTTP serves localhost and redirects any
other host to `https://<host>:8443`. In WebKit, `http://192.168.1.238:8000/` lands on the HTTPS
page: secure context, AudioWorklet, 1112–3379 fps.
**The C++ path compiles again; a Dreamcast build.** First C++ build since the JS-only stretch:
reflaxe.CPP translated the game (4 min 51 s, 61 files), and the desktop compile stopped at
`gpu_Gpu.cpp` — `bp_gpu_clip`/`bp_gpu_mask` had been declared without their own
`@:include`/`@:topLevel` (metadata binds to one declaration), so they became members of the
module's field class. Fixed in `src/shims/cxx/shim/BackendNative.hx`. Desktop C++ (null
backend) then matches JavaScript exactly: 0e180c28 / ab13c60f at 3000 / 9000, `--no-audio`
c346c0af / 53e5c7fd; 9000 frames in 3.50 s. KallistiOS (sh-elf GCC 15.2) builds
`out/_gen/build-dc/recompsx.elf` and `1ST_READ.BIN`: loaded image 6,388,751 bytes. `mkdcdisc`
v0.0.4 rebuilt from gitlab.com/simulant/mkdcdisc (libisofs from Homebrew) and kept in
`~/toolchains/dc/bin`; `mkdcdisc -N -e out/_gen/build-dc/recompsx.elf -D out/dc/data -n
"recompsx Crash Bash" -a recompsx -o out/dc/crashbash.cdi` wrote a 208,930,473-byte CDI whose
RECOMPSX.CFG adds `--video-hw` (PVR drawing). Not yet run: the user's Flycast or console.
The Dreamcast backend's `bp_gpu_clip` records and `bp_gpu_mask` has no stencil (ADR-0020).
**Dreamcast, measured in Flycast with the overlay (`--dc-overlay`).** Eurocom logo: 30 vblanks
924 ms (emu 656, up 163, sub 104). Gameplay: 1981 ms (emu 1108, sub 709, up 163). Loading:
1762 ms, 1018 of them in the drive. Fixed since: the overlay drawn after the game; the VRAM
background skipped under an opaque fill covering the picture (every gameplay frame); a scene
with nothing new not built again (a 30 fps game presented each frame twice); the background
upload two texels a word through the store queues; the disc read ahead on a KOS thread in two
aligned 128 KB windows (host-tested on pthreads: 200,000 reads, 471 MB, no byte different).
ABI function 34, `bp_profile_mark(section, begin)`: the runtime brackets the SPU's decoding
and mixing and the Dreamcast backend times it (`spu` in the overlay); nothing returns to Haxe.
Digests unchanged on JS and C++ (0e180c28 / ab13c60f / c346c0af). Gameplay then read 1517 ms
per 30 vblanks (19.7 fps): emu 1150, of it spu 244; build 365.
**The SPU's voices on the AICA (ADR-0024, ABI functions 35-37, `BP_CAP_SPU_VOICES`).** Under
`--audio-hw` the SPU advances with output off and after each 128-sample batch sends the voices
whose key-on count, on/off, pitch or folded volume changed, plus the sound RAM span written
since. The Dreamcast backend decodes a sample once, start to end block, into AICA RAM (LRU,
invalidated by writes) and plays each SPU voice on its own AICA channel via the KOS firmware;
the mixed stream is destroyed. The C decoder matches the runtime's `decodeBlock`/`advanceBlock`
at every key-on of 9000 frames: 4847 key-ons, 128 distinct samples, 1,239,336 PCM values, loop
points and lengths identical. Overlay line two reads `emu … spu … aica <ms>/<decodes> wait …`.
Not yet heard or measured on the user's Flycast.

2026-09-25 [claude] GTE accumulator as a value (ADR-0021): `shim.Acc`, an abstract over a local
double on JS (exact below 2^53) and a local int64 on C++; every MAC chain in `Gte.hx` is now
`m = step44(Acc.mac(m, …), …)` with no static field in the loop. Digests unchanged (GteOps
1cf89aa2, Acc64 0deeafe0, game 0e180c28 / ab13c60f). Five interleaved rounds, four to one:
mean 19.55 → 19.24 s, min 18.95 → 17.96 s; GTE share 29.7 → 27.1 %. C++ twin unverified.

2026-09-25 [claude] JS `MemA` reads and writes the typed-array element directly (the `LE` and
alignment tests are gone from every aligned access; `RawMem` refuses to start on a big-endian
host instead). Digests unchanged (Mem 27f9aa59, Codegen 632ff691, game ab13c60f); five
interleaved rounds, median 20.03 → 18.53 s (−7 %). Rejected in the same run: call-site `inline`
for the 5,023 byte/halfword loads in generated code — bundle +9 %, no gain, as with the word
accessors before; targeted inlining of memory accessors does not pay on V8 either.

2026-09-25 [claude] GTE commands called by name: the emitter decodes the constant command word
at build time and emits `Gte.cmdRtps(sf, lm)` etc. (22 entries, `execute` kept for unknown
words and fixtures); Crash Bash: 66 direct calls, 0 fallbacks. Digests unchanged (Codegen
632ff691, GteOps 1cf89aa2, Regions d6b90d6e, game 0e180c28 / ab13c60f). Five interleaved rounds:
mean 19.98 → 19.41 s (−3 %), min 19.65 → 18.61 s; `execute` gone from the profile.

2026-09-25 [claude] Two inlining experiments after the mixer. Kept (`ce808eb`): the JS I64
pair's small operations and `Gte.step44`/`mac0From32` inline — every digest unchanged (Mem
27f9aa59, GteOps 1cf89aa2, Acc64 0deeafe0, Codegen 632ff691, game ab13c60f), five interleaved
rounds all faster, mean −5 %, min −8 %; the C++ build of the two inline GTE helpers is
unverified (ADR-0015). Rejected: the RAM fast path inline in every guest access with a
branch-free JS `MemA` — bundle 9.8 → 13.1 MB, medians 3 % slower, ADR-0013's finding again.

2026-09-25 [claude] SPU: voice-major batch mixer (`mixBatch`/`mixVoice`): each voice runs its
samples into accumulators in one loop with its volumes decoded once, main volume and saturation in
one pass, halfword output stores. Bit-identical: SpuVoice d7680e93, game 0e180c28 / ab13c60f.
Node 9000 frames min of three 21.66 → 19.70 s (−9 %), SPU share ~10 → 7.1 %; the user's 6×
browser profile puts the mixer subtree at 14.7 → 8.6 %. Next: inline I64 pair ops, inline RAM path.

2026-09-25 [claude] Page profile follow-up: status line written four times a second instead
of per tick (it forced a layout each tick), audio batches sent to the worklet once per tick
instead of 344 times a second, the loop keeps one scheduler at a time (rAF visible, timer hidden)
instead of racing both, and `Cooperative.wantsYield` is an inline two-load fast path with the
full test behind it (Yielding 203c40c1 unchanged). Main-thread CPU per emulated frame over frames
11506–13509: 2.43 → 1.86 ms at a steady 60 fps. SPU mixer (14.7 % in the page profile) is next.

2026-09-25 [claude] Browser page: sound moved to an AudioWorklet (`web/audio-worklet.js`), the
JS backend now forwards the host's `audioBuffered` so the SPU's pacing holds the queue near its
cap, runtime logs go to the console only (writing them into the page re-rendered it per line),
and `BrowserLoop` paces by backlog rather than the origin's age — it had rebased every tick
after the first second and run two to three times real time. Now 60 fps, ~75 ms of audio.

2026-09-25 [claude] Browser WebGL2 presentation fork (ADR-0020): shader-decoded texels from a
VRAM texture, framebuffer texture refreshed by dirty rects, four blend modes, two-pass textured
blending, `bp_gpu_clip` added to the ABI for drawing-area scissoring. Main-thread CPU per frame
3.85 → 2.43 ms in the page; digests untouched. Mask bits added the same day as a stencil
(`bp_gpu_mask`). Next: the ScriptProcessorNode → AudioWorklet migration on the page, then the
register summaries.

2026-09-25 [claude] Codegen structuring (ADR-0019): natural loops with recorded exits and
topological forward runs on `resume` as label; dispatchers 632 → 9, hottest functions
structured, every digest unchanged, 375 tool checks. JS neutral within noise; C++ unmeasured.
Next: interprocedural register summaries at static calls, the inline RAM fast path, the wait-loop
fast-forward, and a value-passing GTE accumulator — each measured interleaved before it is kept.

2026-09-25 [claude] GTE: the JS I64-as-double shim (ADR-0018) and a `switch` dispatcher were
built, verified digest-identical, timed interleaved and rejected: 27.2 s and 29.2 s against the
26.8 s pair, and the switch alone +10 %. No GTE change ships. Next: codegen structuring
(natural loops, if-chains) or a value-passing GTE accumulator, both to be measured the same way.

2026-09-25 [claude] Rasteriser: closed-form row spans, per-triangle texel constants with inline
linear fetches, span-level pixel counts, typed-array row fills. The old Raster sections reproduce
b66077e7; game digests unchanged; JS 9000 frames 34.6 s → 25.2 s. The fixture gains blended and
textured coverage (a749a71a). Next: the GTE's JS I64 as an exact double (ADR-0018).

2026-09-25 [claude] Profiled the reconciled tree on both targets at 9000 frames (JS 34.7 s,
C++ 9.3 s, digest ab13c60f): rasterizer 44 %, GTE 26 %, generated code 14 %, SPU 8 %, Memory 5 %
on JS; ADR-0013's accessors are out-of-line calls on C++. Committed the JS-iteration work
(ADR-0012..0017, Closure bundle, JS-only gate). Next: rasterizer span specialisation, a
double-backed JS I64 for the GTE, then natural-loop/if-chain structuring in RegionPlan.

2026-09-22 [codex] Added CFG-liveness dead pure-write elimination (ADR-0017), with fixtures for
overwritten register assignments and interior-entry safety. Protected reverse paths retain
publication semantics; 367 tool checks, 18 JS conformance groups, `check.sh`, and Crash Bash
`frames=3000 digest=0e180c28` all pass. Bundle remains `fdca8703c2a9`.

2026-09-21 [codex] Added conservative same-block stack word forwarding (ADR-0016): superseded
`sw` stores are dropped and exact `$sp`/`$fp` `lw` reloads forward through stable GPR locals;
memory/control barriers and stack-pointer writes clear facts. Acceptance: 363 tool checks, 18 JS
conformance groups including Codegen `79549398`, demo digest `329de455`, `check.sh` clean, and
Crash Bash `frames=3000 digest=0e180c28` from the rebuilt `fdca8703c2a9` bundle.

2026-09-21 [codex] Made JS-only conformance/test gates the default while retaining reflaxe.CPP as
  an opt-in via RECOMPSX_JS_ONLY=0 (ADR-0015). Updated build/web guidance and recorded the
  deferred-target workflow; no C++ files or shims were removed.

2026-09-21 [codex] Added generic IR pattern fusion for constant formation and MIPS multiply/divide
  result pairs, preserving HI:LO and zero destinations. Crash Bash generation fell to 553,676 lines;
  raw/Closure browser bundles are 10.53/4.93 MB and both report 0e180c28. Full two-target
  conformance passes all 18 groups (Codegen a71569d0, Yielding 203c40c1); check.sh is clean.

2026-09-21 [codex] Added clipped linear VRAM raster paths and removed large Memory/Vram Haxe
  inlines; raw JS fell to 10.56 MB and Closure ES6 output to 4.93 MB. Raw/Closure game runs
  agree on 0e180c28, Raster agrees across JS/C++, and the JS-only gate passes. Next: keep generic
  codegen propagation work on the JS-first loop and validate Closure output in the browser.

2026-09-09 [codex] Prepared the verified runtime/codegen/browser reconciliation for main commit
  and push; made setup apply the existing continue patch as well as locals/array patches.
  Validation: previous full gate 341 checks, 18 groups x2, game 0e180c28 on JS/C++; check.sh clean.
  Next: extend gameplay coverage and measure the remaining generic codegen optimizations.

2026-09-09 [codex] Reconciled committed 25d9a5d/6819782 features into main's working tree,
  preserving scalar/IR/regions and main-thread continuations; corrected the source-loss diagnosis.
  Browser bcafe8128288 reaches Select Game Type; 3000-frame JS/reference/stress and C++/stress
  all report 0e180c28, zero gaps; gate 341 checks, 18 groups x2, demo 329de455; check.sh clean.
  Next: extend gameplay/overlay coverage and measure further generic codegen work.

2026-09-21 [codex] Added ADR-0012 boundary-aware GPR liveness and JS-only gate. Crash Bash output
  fell 583506→555652 lines and reloads 84959→57105; JS game digest stayed 0e180c28; all 341 tool
  checks and 18 JS conformance groups passed. Next: cross-block constant/copy propagation.

2026-09-09 [codex] Restored source-built main-thread browser execution with pinned continuations
  (ADR-0010), pause/resume and hash-keyed bundles; traced/fixed SCEx Test 04/05 drive responses.
  Gate: 341 checks, 14 groups x2; Yielding 3cbb7802, CdScex 36383746, demo 329de455.
  Browser e08491afe0f7 active; JS reference/sync/yield/stress b542d57e pass SCEx, reach 15 later gaps.
  Next: reconcile indirect-entry and GTE source drift behind the later black screen.

2026-09-09 [codex] Added generic machine IR, Int-backed effect/register abstractions and resumable
  sequence/choice regions (ADR-0008), plus --no-regions and synthetic cross-target fixtures.
  Gate: 341 tool checks, 12 groups x2; game JS/C++ 6bd5e3fd; Spyro also generates/JS-compiles.
  Synthetic loop JS 1.99x / C++ 1.58x; game timings noisy, JS size +7.4%, native size unchanged.
  Next: general native multi-block loops and boundary liveness; restore source-built browser yields.

2026-09-09 [codex] Scoped codegen proposals from current emitter/CFG contracts: small IR,
  regional structuring and boundary-aware register data flow; next implement and measure separately.

2026-09-09 [codex] Audited generated Haxe/JS and profiled a fresh 3000-frame build: 6bd5e3fd.
  Two generated functions account for 49.0% of CPU self samples; found eager CD trace strings.
  Browser serves a different artifact; next measure trace guards and restore source-built yields.

2026-09-08 [codex] Added scalar GPR lowering and structured chains/self-loops (ADR-0007),
  corrected call/unwind semantics, and exported reproducible reflaxe declaration patch 0005.
  Gate: 194 tool checks, 11 conformance groups x2; game JS/C++ 3000-frame digest 6bd5e3fd.
  Loop JS 4.21x; whole-game JS unchanged, native 1.06x measured; next profile multi-block CFGs.

2026-08-09 [opus] The console now says what it is, and has a font. The ROM window at 0x1FC00000
  was not in the memory map at all — every read returned zero — so the region letter games test
  at `0x1FC7FF52` said nothing and Crash Bash NTSC-U drew its anti-piracy message in *Japanese*
  (the glyph codes decode to 強制終了しました。本体が…). Serving that one byte as 'A' ended fifty-six
  `Krom2RawAdd` calls. The English branch then reads glyphs straight out of the ROM —
  `0xBFC7F8DE + (char-33)*15`, measured from the game's own disassembly — so `mem.RomFont` serves
  ninety-four 8×15 glyphs drawn for this project. Uploads went 13 → 3733 and three lines of text
  appear. They rendered as strokes at first, and the font was ruled out — payload correct per
  pixel, and the real ROM's glyphs render identically — so it was the rasteriser. The warning
  screen writes text in two passes (white letters with bit 15 set, then a black pass over the
  cell), and on hardware a CPU-to-VRAM upload obeys the mask bits exactly as a drawn primitive
  does, so the black pass skips the letters. `putTexel` ignored the check and erased them.
  Implementing mask-check/mask-set in the upload path restored the text — and then a photograph
  of the real screen showed the circle should pass *behind* the words, which is the same rule a
  layer up: `plot()`, the primitive path, ignored the mask too, so the circle painted over the
  text. Three writers into VRAM (`plot`, `putTexel`, `blend`) and only one of them obeyed
  GP0(E6). The text then sat left of the original, which turned out not to be a placement bug at
  all: the game's message table is data in the executable — `{x, y, text}` per region at
  0x800678A0, x=36 for America, short lines centred by literal spaces in the string — so we were
  drawing exactly where it asked. The font was too narrow, five ink columns against fourteen
  rows, so every line ended early and read as shifted. Stretched to seven columns, the longest
  line lands at 36..296 against a screen centre of 160. **The screen now reads "SOFTWARE
  TERMINATED / CONSOLE MAY HAVE BEEN MODIFIED / CALL 1-888-780-7690" with the circle behind it,
  laid out as the original.**

2026-08-09 [opus] The `unimplemented:` list is down to one line. Memory-control registers
  (1F801000-1020, RAM_SIZE, cache control) stored with the BIOS's reset values — bus timing is
  not modelled, but a register a game writes and reads back must answer. Every SPU register that
  was reporting itself as "reverb, not yet" now stores and returns: reverb output volume, the CD
  and external *input* volumes (which were never reverb at all), the 32-word reverb block, and
  the current-volume registers, which without sweeps are the set volume. Timers 0 and 1 count
  real dot clocks and scanlines: whole periods fold out exactly — `VIDEO_DEN * divider` cycles is
  exactly `numerator` dots — and the residue converts with the numerator split so nothing passes
  2^31. `A0(ABh) _card_info` answers for an empty slot by posting the timeout event, which
  **fired the kernel's callback path for the first time since it was written** (`delivered
  590/6cb`) and exposed eight more functions nothing calls statically. Left: `B0(51h)
  Krom2RawAdd`, which needs a font of our own — it is why the anti-piracy screen draws its circle
  and none of its words.

2026-08-09 [opus] GTE, first half: `shim.I64` (the 44-bit accumulator ADR-0004 specified and
  nobody had written), the whole register file with its side effects — SXY FIFO push on the mirror
  write, IRGB/ORGB, LZCS/LZCR, H's sign-extend-on-read bug, FLAG's computed bit 31 — the UNR
  division, and the projection ops RTPS/RTPT/NCLIP/AVSZ3/AVSZ4. Tool side needed nothing: all
  seven COP2 forms already compiled to these calls. Two new conformance tests, both agreeing
  across targets: `Acc64` 0deeafe0 (carry chains and the exact ±2^43 / ±2^31 fenceposts) and
  `GteOps` 6a9d8047 (1304 values; hand-computed identity transforms, permutation matrices, NCLIP
  areas, one vector per FLAG bit, the divider's edges). The GTE register warnings are gone from
  the game's log. **A null check on `Array<Int>` cost a segfault C++-only**: the type is not
  nullable, so the guard folded away on one target and not the other — the table was never built.
  With two more `functionHints` (three one-line functions sit in a row at 0x800309ec/0a00/0a08 and
  the sweep found only the first), **the game draws geometry for the first time: 132 primitives
  where there was 1.** Next: MVMVA and the lighting family.

2026-08-09 [opus] CD protocol + interrupt correctness — **the boot stall and the command storm are
  both gone**. Four causes, none of them the one the log named. The controller's interrupt enable
  starts at 0x1F because the BIOS leaves it there and a game's library never re-arms it (seven
  seconds of every boot were libcd timing out and resetting a controller we had never armed);
  `slowWrite16` had no CD branch at all, so every halfword store to the CD page was read-modify-
  written into a register that does not exist; `Test 04h`/`05h` are part of libcd's CD-audio
  startup and answering them with INT5 made Crash Bash restart that whole ten-command sequence
  three times a second forever; and `CdlPlay`/`CdlStop` existed only as errors. Also: an interrupt
  raised inside a handler is now delivered before `Irq.dispatch` returns instead of waiting an
  unbounded time for the next pump. Frame 900 went from 1289 CD commands and 1705 dropped answers
  to 52 and 17. Next: S2, the GTE.

2026-08-09 [fable] Overlay S4 closes the milestone: two overlays from disc offsets in committed
  config, no capture anywhere; the audit's four defects fixed and tested (resident overlays
  shadow the base with no fallthrough, in-window base functions dispatch, a fingerprint longer
  than its overlay is a build error, misses name the overlay). `--headless-hash` bounds a game
  whose loop never returns — JS and C++ agree at `7e32dc6d` over 600 frames. New `HashFold` test
  covers the digest instrument itself; four Int divisions that lowered to `double` fixed.
  Next: the logged `unimplemented:` work, S1 (CD Play + IRQ latch) first.

2026-08-09 [opus] Overlay S3: `kernel.OverlayMgr` decides which code is in a window. The runtime
  installs nothing — the game loads its own overlays through hardware already emulated, so only
  the mapping has to follow. A load evicts; `FlushCache` rescans and identifies by FNV-1a over the
  window's first words; a miss inside a window rescans once. A miss *outside* every window now
  quotes the span the disc was read into, with the numbers to paste into game.json, which is how a
  new game's config gets written. New conformance test `Overlay` — both targets agree at
  `7564ec5d`; 7 tests x 2 targets. Next: S4, Crash Bash end-to-end and ADR-0006.

2026-08-09 [opus] Overlay S2: universes. Each overlay is the executable with its bytes over its
  window, analysed on its own — scoped so the base is analysed once, lenient inside the window
  because code and artwork are adjacent there. Program-wide shard indices, `Ovl_<id>_` classes, a
  generated `Overlays.hx` of windows, fingerprints and per-overlay dispatch rows. Call policy:
  direct inside the executable, dispatched into a window, direct from an overlay into its own
  window. Identical bodies emitted once. 175 tool checks (25 new); a game with no overlays
  generates what it did before. Next: S3, `OverlayMgr` and activation.

2026-08-09 [opus] Overlay S1: `gen` reads a game config and pulls the executable off the disc
  itself. `config/GameConfig.hx` (game.json + gitignored local.json, overlay stanzas, hints —
  decimal addresses folded into the tool's signed representation), `loader/DiscImage.hx`
  (CD001 probe picks 2048 / 2352+16 / 2352+24), `loader/IsoWalk.hx`. Crash Bash's six seeds moved
  out of a notes.md command line into `functionHints`. Byte-identical to the flag-driven output
  it replaces and idempotent across two runs; gate green. Next: S2, patched-image universes.

2026-08-09 [opus] **SOUND.** Twenty-four ADPCM voices, ADSR, one stereo pair every 768 cycles.
  The bug that would have hidden all of it: the SPU was reachable by halfword only, and libspu
  sets volume pairs — including the main volume — with one word store, so every voice was
  multiplied by zero. `tests/conformance/SpuVoice` writes a waveform by hand, keys a voice on and
  listens, then keys it off and listens for nothing; both targets agree at `d7680e93`. The game
  reaches real audio at 15.4s emulated: 92% of samples non-silent, peak 79% of full scale, and
  114–535 zero-crossings per half second, which is notes rather than noise. Browser plays it live
  through a SharedArrayBuffer ring that also paces the machine — a full ring means the game is
  ahead of what anyone can hear. Missing and written down: gaussian interpolation, noise, pitch
  modulation, reverb, gliding volume sweeps. **Overlay support was written this session and then
  reverted at the user's instruction** — it is a sensitive area and its design is theirs to plan,
  not something to arrive at sideways while chasing a symptom. Nothing overlay-shaped is to be
  written until they say so. One consequence, recorded rather than hidden: the boot screen and the
  audio above both depended on code the disc loaded, so the tool can no longer produce the program
  that showed them. Open on the runtime side: timers still run dotclock and hblank at system clock.

2026-08-09 [opus] **BOOT SCREEN.** Crash Bash NTSC-U shows "Sony Computer Entertainment America
  Presents", on Node and in a browser. Seven fixes in a chain, each hidden by the one after it:
  `enterJmpBuf` left `v0` alone, so the game's exception hook — installed via `setjmp` — could
  not tell "just installed" from "an interrupt brought me here" and never dispatched its CD
  driver; FnTable now maps every basic block, since a longjmp lands after a `jal` and never on a
  prologue; the sweep takes code following a return as a function (GCC hoists loads above the
  stack adjust); the CD re-arms after answering, honours Setmode bit 5, and clearing the request
  bit resets the FIFO rather than discarding the drive's sector; DMA 3/4/6 and GP0(80h) exist.
  Next: overlays are transient — a RAM capture describes one, and the game loads several into the
  same memory, so `--ram` wants the per-overlay identification of plan section 6.4.

2026-08-08 [opus] THE GAME RENDERS. Two blockers, neither the CD: DMA channel 2 (Psy-Q draws via
  ordering tables, so every display list went nowhere) and GP0(A0h) CPU-to-VRAM uploads (an
  opcode census showed a frame is 3 uploads and a clear, no polygons — fonts and logos are
  uploads, not primitives). 618 non-zero pixels at VRAM x896..927/y256..384. CdInit still fails
  and is now secondary; next is the DuckStation register diff.

2026-08-08 [opus] DMA channel 2 was the render blocker, not the CD: Psy-Q draws through ordering
  tables, so every display list went into an unimplemented register. With DMA + a minimal
  rasteriser the path is proven end to end — 23 draw commands became 544, 261,121 pixels reached
  VRAM. The frame dumps uniformly black: the only primitive Crash Bash sends is a screen clear,
  because CdInit still fails. 14 CD candidates now eliminated by measurement. Final trace fact:
  every CD register access is [poll], never [handler] — libcd drives the drive entirely from
  ordinary code. NEXT: DuckStation register-breakpoint capture, diffed against our cd# trace.

2026-08-08 [opus] CD dialogue fully traced: Getstat and Init both complete correctly, libcd acks
  both, then loops the whole init forever. Delivery/ordering/ack all proven working. Tell: libcd
  never reads the response FIFO — so the suspect is 1F801800's status bits, which it does read.
  Next: trace 1800 reads against psx-spx's bit table.

2026-08-08 [opus] Timer wrap clamp (froze all counters at 2^31), SIO0 empty port, HookEntryInt
  now invoked as the exception epilogue OpenBIOS documents. Game passes frame 120k. Measured:
  libcd installs NO chain element and opens NO event — only libpad does. CD route still
  unidentified; next probe is tracing 1F80180x reads outside dispatch to find CdSync.

2026-08-08 [fable] Frame-29100 stall solved by profiler, twice: report-once built its string
  before the dedup check (25% of ticks in StringAdd), and libpad's ACK timeout counts on timer 2
  which read zero forever. Landed: Timers 0-2 closed-form (§7.10), SIO0 as honest empty port,
  alreadyReported guard, cycleHint at every pump point. Game now passes frame 120k with its own
  handlers live. Next: where do 120k frames go — CD_init not reached yet.

2026-08-08 [fable] The CD handler black hole was the sweep seeding a prologue 8 bytes past the
  true entry (GCC schedules loads before addiu sp) — sweep now seeds gap starts. Retracted the
  phantom "6th-seed regression": host load made 40s runs reach frame 29k instead of 65k, same
  trajectory. Detour cost: stale out/gen shard files (writeTo now cleans? no — TODO), zsh not
  splitting $VAR seed lists, and a diff script that lied. Long run in flight; next reads cd#.

2026-08-08 [fable] Named the dispatch misses (address+ra), found libcd's function-pointer black
  holes, added `gen --seed`. Five seeds: libcd now unmasks CD+DMA itself, its handler installs and
  runs, CD interrupts deliver (irqs>frames, handlers~1.12x frames). CdInit still fails — next is
  the chain/RFE/HookEntryInt contract, readable in OpenBIOS kernel/handlers.c (MIT). Sixth seed
  regresses (entry-inside-extent truncation): tool needs §6.2 multi-entry duplication.

2026-08-08 [claude] GPU register file, cdrom: in both shapes (directory and image — ISO9660
  detects Mode 2 Form 1 on a real Crash Bash BIN), and the CD-ROM controller. Game now initialises
  libcd and issues 17 commands. Four candidates for its NoIntr eliminated by measurement; three
  were real bugs fixed on their own merits. Next: disassemble CD_init at 8006de94 to find what
  libcd's wait loops actually poll — the answer is a memory address, not a register.

2026-08-08 [claude] Kernel HLE complete: threads, setjmp/longjmp, timers, device table, GPU helper
  calls, kernel RAM tables, the rest of the C library. Crash Bash now makes zero unimplemented
  kernel calls and both targets match over 238 lines. Three reflaxe.CPP traps found and each one
  turned into a check.sh guard: a root-package class shadowing a system header, a static table
  built at its declaration, and an identifier that is a C macro (`errno`). Next: the GPU register
  file — libgpu is timing out on GPUSTAT.

2026-08-08 [claude] M2 kernel HLE: scheduler, interrupt controller, event system, priority chains,
  C library, heap, printf, file descriptors, TTY. Crash Bash reaches its main loop and prints its
  own libgpu output; both targets identical over 239 lines. Two of my own bugs found by my own
  guards (frame-length overflow, a non-wrapping cycle compare that diverged JS from C++) and one
  fidelity error corrected (critical sections are a flag, not a counter). OpenBIOS supplied the
  event status values psx-spx omits. Next: the GPU register file — the game is timing out on it.

2026-08-08 [claude] Designed time/scheduling/interrupts as one piece (ADR-0005) after the startup
  trace showed the game waiting on the event system, not on five separate stubs. TimeBase landed
  and pinned on both targets (VideoTime, 052bdaac). User found OpenBIOS: its files are MIT even
  though pcsx-redux is GPL-2, so it is the one non-spec source we may read and translate — added
  to the escalation ladder with the attribution rules; kernel stays HLE, we never run it.
  Next: Scheduler, then I/O dispatch so I_STAT/I_MASK have somewhere to live.

2026-08-08 [claude] Fixed reflaxe defect 9: `case TContinue: acc = []` deleted every statement
  BEFORE a continue, gutting 86% of the basic-block bodies in the C++ build (1119/1296 cases in
  one shard). C++ now matches JS call-for-call on the real game. Corrected the M1.5 binary size
  (340 KB was measuring deleted code; 2.1 MB is honest). First 3 kernel calls implemented from
  psx-spx. Next: load the program image into RAM — nothing does, so every load returns 0.

2026-08-08 [claude] Found and fixed BOTH of reflaxe's worst defects, sixty lines apart in
  RemovePureExpressionsImpl: an inverted return in `hasSideEffects` was deleting if-bodies
  (defect 8), and a per-statement recursion in `blockElement` was overflowing the eval stack on
  large programs (M1.5). Whole game now: gen 0.9 s -> C++ 63 s -> clang 7.7 s -> 340 KB binary.
  The JS build RUNS the recompiled game into Crash Bash's real init sequence; the C++ build
  mis-dispatches on the first call, which is now the top open item.

2026-08-08 [claude] Whole-program generation works: 861 Crash Bash functions -> 87.5 K lines of
  Haxe in 0.9 s. The JS build links in 3.7 s and RUNS — recompiled startup code clears its BSS,
  calls through several functions, and reaches A0(44h) FlushCache, COP0 SR access and GTE control
  writes, all reported as unimplemented. The C++ build hits a stack overflow inside reflaxe.CPP
  (M1.5 above); not caused by shard size, OS stack or the analyzer. Adopted `-D js-es=6` project
  wide; measured `-D analyzer-optimize` as behaviour-preserving but currently worthless.

2026-08-08 [claude] core.Ops (mult/div, hardware edge cases) + tests/conformance/Mul.hx. The test
  earned itself immediately: four successive formulations of div/divu were correct on JS and
  wrong on C++, and the last culprit was `inline` on a two-statement helper. Both targets now
  agree (b5a873d9). Added the resulting rule to upstream defect 8: in runtime code, `inline` is
  only for single-expression accessors. Conformance now covers Arith, Mem and Mul.

2026-08-08 [claude] First generated code. runtime/{core.CpuState, core.Ops, mem.Memory} written,
  then codegen.Emitter + `recompsx emit`. Emitting Crash Bash's real entry point reads correctly:
  BSS-clear loop closes on itself, branch conditions latch before their delay slots, jal writes
  the link before the slot, and the closing `jr $t2` comes out as `Kernel.call(ctx, 0xa0, ...)`
  — A0(51h), Load and Exec, exactly what an entry point should end with.

2026-08-08 [claude] Jump-table + BIOS-call recovery. Unreached code fell 25.0%->19.3% (Crash Bash)
  and 26.1%->5.2% (Spyro); unresolved computed jumps 55->1 and ->8. The big surprise was that most
  of them were kernel calls through a vector register, not switches. 150 tool tests green.

2026-08-08 [claude] M1 analysis: Image/Func/Discovery/Coverage + the analyze command. Runs on both
  real games. Building the tests found a real CFG bug — blocks overlapped because a later backward
  branch can make an address inside an already-traced run a leader, so tracing is now two passes
  (reachability + leaders, then cut). Instruction counts dropped 57k->47k accordingly while
  coverage held, which is exactly the signature of removing double-counting. Also answered the
  Psy-Q version question in docs/specs/tool.md §2.1: no per-version abstraction needed, because we
  recompile library code rather than reimplementing it; signatures are a naming convenience.

2026-08-08 [claude] M1: decoder + disassembler + tool CLI, 99 tool tests green. Validated against
  the real Crash Bash executable — `info` reproduces every header field recorded in notes.md, and
  `dis` renders the Psy-Q startup correctly (BSS clear loop, backward branch target, lui/addiu
  address pairs). Findings added to games/crashbash/notes.md. Tool tests are now step 1 of
  test.sh. Next: function discovery and the CFG.

2026-08-08 [claude] Conformance testing made first-class: tests/conformance/ + Conf harness +
  scripts/conformance.sh runs every test on every target and compares digests; adding a test is
  dropping in a file. Two tests so far (Arith 14b7201f, Mem 27f9aa59). Building them found two
  things: upstream defect 1 (inline local collisions) is now FIXED in our vendored fork, and
  defect 8 is characterised exactly — an `if` with no `else` and >1 statement is deleted whole.
  It had silently disabled Conf.expect on C++, which is precisely the failure this harness
  exists to catch.

2026-08-08 [claude] Integer semantics settled (ADR-0004) after a suggestion to use haxe.Int64
  led to measuring it. Two findings: haxe.Int64 allocates per value on BOTH our targets (no
  native override for js or reflaxe.CPP) — 41ms vs 7ms hand-rolled hi/lo on the GTE workload;
  and far worse, JS does NOT wrap Int + / -, so every addu/subu would have diverged. Fix is
  `| 0` on overflowing results (free on C++). tests/conformance/Arith.hx now guards all of it
  on both targets (f975e3f9) as step 2 of test.sh.

2026-08-08 [claude] JS memory fast path: RawBuf now carries u8/u16/i32 views over one
  ArrayBuffer; aligned wide accesses use them (endianness measured at startup, not assumed).
  Motivated by a performance question; measured first: byte-composed get32 = 596 Mops/s,
  view = 1204 Mops/s, PS1 realtime needs ~10 M/s. Digests unchanged (329de455).

2026-08-08 [claude] M1 started: Vaddr, PsxExe loader (full header validation + warnings), mips.Op
  (exhaustive enum abstract) and mips.Instr written; decoder + golden tests are the next step.
  Added docs/specs/tool.md §3.1: why memory stays a flat array and what may be promoted later
  (registers already are variables; stack-slot promotion is the future win). Paused at user
  request.

2026-08-08 [claude] M0 COMPLETE. Backend ABI + SDL2 + our own main; shim/{RawBuf,RawMem,IntMath,
  Backend}; runtime/{Main,core.Hash,gpu.Vram}; CMake template; scripts/{build-pc,run-pc,test}.sh.
  Found reflaxe.CPP silently deleting `if` statements (guard clauses run the WRONG path) -> added
  the JS target and made it the reference (ADR-0003). Cross-target digests now agree: 329de455.
  Next: M1, the recompiler tool, starting with the PS-EXE loader.
2026-08-08 [claude] M0.2-0.4 done: pinned toolchain installed (Haxe 4.3.7 universal, no Rosetta),
  reflaxe pair pinned as submodules, [M0-VERIFY] executed via tests/spike/*. Two findings forced
  design changes (ADR-0002): static memory accessors, integer-handle dispatch. Haxe 5 confirmed
  incompatible. scripts/{env,setup,check,spike}.sh written. Next: M0.5 SDL2 backend shim.
2026-08-08 [claude] M0.1 done: AGENTS/CLAUDE/PROGRESS/LICENSE/.gitignore, ADR-0001 + template,
  docs/architecture.md, docs/specs/{tool,runtime,backend}.md, dir skeleton, games/crashbash +
  games/spyro3demo configs. Verified both EXE headers + SYSTEM.CNF from the user's dump (TCB=4,
  EVENT=16, STACK=801FFF00 are load-bearing for kernel HLE). Added filesDir input mode and the
  PS2/console target matrix. Next: M0.2 toolchain fetch.
2026-08-08 [claude] master plan written incl. verified reflaxe.CPP facts; next: commit M0.1 docs
