# PROGRESS — recompsx (single source of truth; see AGENTS.md session protocol)

## Status snapshot

**2026-10-05 (night): Crash 3's level transitions on every target (ADR-0054, the owner's report).**
Not committed. The transition copies the frame on screen into the other buffer (GP0 80h) and draws it
back over itself as four turning, semi-transparent textures, with a darkening diamond.
- **The software rasteriser kept no texel's bit 15** (every target, the reference too): psx-spx says a
  textured pixel writes its texel's bit 15 unless E6h.0 forces it, and a semi-transparent texture
  blends only texels with the bit — 83 % of Crash 3's frame carries it, so nothing blended and the
  colours went flat. Fixed in `Gpu` (`set || stp`). Digests changed, JavaScript = Dreamcast for both
  games (dc-digest.sh), C++ = JavaScript for the conformance suite:
  Crash 3 at 5000 **52875c77**, Crash Bash with its mods at 20300 **37eefb07**, conformance `Raster`
  **1bdad19d**.
- **ABI `bp_gpu_copy(sx, sy, dx, dy, w, h, changed)` and `BP_CAP_GPU_COPIES` (7):** a backend that
  copies what it drew hears of every VRAM copy in its place among the primitives. The browser
  (WebGL) answers it: copies from fbTex and its mask bits through a scratch, the mask bit now the
  depth buffer (every fragment writes the bit the PlayStation stores), the stencil only for "check".
  The Dreamcast answers it: a copy out of a buffer with a picture is a record drawn from that picture
  (`GCMD_COPY`), and a 15-bit page inside such a buffer binds the picture (512x256, `dim_v`).
- **The browser's colour is now five-bit** (the owner still saw its transition wrong): the shader
  cuts a primitive's colour to five bits as gpu.Gpu does and fbTex stores k as (k + 1/2) / 32, so
  the diamond subtracts 1/31 (it took 15.5/255) and mode 0 floors. fbTex against the reference's
  VRAM at the same vblanks: the first transition 0.06-0.33 of a step a channel (was up to 2.1),
  gameplay frames 87-89 % of pixels exact. The Dreamcast's transition works (the owner, Flycast)
  but stays brighter for longer: the PVR blends at eight bits.
- **The owner's "second time" found and fixed:** the attract loop's own transition at the end of
  its second demo (~12200, no button). ANGLE on Metal renamed vramTex's storage at a palette upload
  and `wordFbo` kept drawing into the old one; the browser's conversion now re-attaches vramTex
  every time (web/AGENTS.md). Matches the reference within 0.15 of a step. The page also has
  `?slow=auto|A-B`, `?slowfps`, `?ff`, `?frames` to find a frame (keys "," and ".").
- **Crash Bash's Adventure hub paused "CONTROLLER 1-A IS UNPLUGGED" with a DualShock** (the owner, on
  the Dreamcast, whose stick pads are DualShocks): the multitap answered each slot's commands in the
  same long read, where the SCPH-1070 answers them in the next one (BlueRetro's logs; DuckStation
  likewise). libpad fell out of step and probed a normal-mode pad with 45h forever. `Multitap` now
  sends a long read's slot bytes to the controllers when it ends and answers them in the next
  (ADR-0042 amended). Headless the hub plays on with `--pad-dualshock`; `DualShockSio` 6081cd6f
  (was a1fdfeea), JS = C++; game digests unchanged (52875c77, 37eefb07 with the standard JS build).
  The browser bundle (`recompsx_cooperative`) prints its own for Crash 3 at 5000, 385253b4, the same
  before the change and after; why it differs from the standard build is not looked into yet.
- **Verified** with `--pad-script 4700:CROSS,4710:-,8000:CROSS,8010:-` (the attract loop's first and
  second demo): JS reference, WebGL in the pane frame by frame (both transitions, also with the blit
  version and with every vblank presented), Dreamcast in Flycast's fork (`--dc-shots`, new: pictures
  by present). The owner's "the second time does not work" in the browser is **not reproduced** —
  asked for the browser and the steps. TA hash: Crash 3 unchanged; Crash Bash one more render and
  then scenes differing only in which picture memory a texture is read from (ADR-0054). Cost E-165:
  Crash 3's demo cf 17.60 → 17.73. E-162 (run_tris in assembly) measured slower and reverted.
- Tester CDIs: out/dc/crash3-pic-max.cdi, crashbash-pic-max.cdi (02:31 / 02:52, placed, with all
  of the above). Browser: :8000 serves Crash 3 (bundle 60c6fb4a3ef7, raw — Closure took 20+ minutes
  under memory pressure and was stopped), :8797 Crash Bash with its mods (out/_cbweb, f3ae8d4ce19f,
  raw; `.claude/launch.json` web-crashbash). The owner deleted most of out/dc's data directories (disk); the ones the CDIs and
  web/boot.exe need are back as hard links.

**2026-10-04 (evening): the development phase — the DualShock on every backend (ADR-0052), and
the Dreamcast keeps what it draws (ADR-0053).** Not committed. The owner moved from optimisation
to development ("şimdi geliştirme faslına geçtik"); optimisation resumes afterwards from where it
is paused (out/_work/paused-opt/README.md).
- **The DualShock (SCPH-1200)**, `sio.DualShock`, per nocash's psx-spx: power-on digital; ANALOG
  (bit 16 of `bp_pad_buttons`) toggles analog mode unless locked; configuration mode (43h, 44h-4Dh);
  two motors, old and mapped; in normal mode only 42h/43h are taken (DuckStation's behaviour for the
  rest). A host pad with sticks (BP_PAD_ANALOG) is plugged in as one, any other as a digital pad.
  The tap's long read is a transfer of its own per slot window, the BIOS handler reads it. ABI:
  `BP_PAD_ANALOG_BUTTON`, `bp_pad_rumble` (on change). Scripts: `--pad-dualshock`, sticks
  `F:B/LX.LY.RX.RY`, `--log-rumble`.
- **Backends:** SDL2 (both sticks, Guide = ANALOG, `SDL_GameControllerRumble` renewed every 250 ms);
  browser (Gamepad axes, button 16, `vibrationActuator` dual-rumble renewed; :8000 serves bundle
  1172feda23f5, raw — no Closure); Dreamcast (the maple pad's stick, a second one where the pad has
  it, Start + full R = ANALOG, Z = R3, a Puru Puru pack with continuous effects, stopped before the
  BIOS menu); null and JVM no-ops. check.sh clean (51/51 functions). Tester CDIs with both:
  out/dc/crash3-pic-max.cdi, crashbash-pic-max.cdi (they replace the -ds- ones).
- **Verified:** conformance `DualShockSio` a1fdfeea JS = C++; `PadSio` 47a7a665, `MultitapSio`
  644b488d, `PadBios` 42a146e6, `Mouse` 8d7276ce unchanged; the whole JS suite passes; Crash 3 JS
  5000 still 47853ef7. Crash 3 sets analog mode itself (44h at vblank 275); the left stick walks Crash
  in the warp room as the d-pad does; with the game's rumble timers written (80068E98h + 1F0h/1F4h)
  its motors reach `bp_pad_rumble` (small 1, large C0h). Crash Bash configures the pad through the
  tap's long read and reaches Select Game Type with it as with a digital pad.
- **Crash 3 reads a DualShock every fourth vblank:** its pad routine (80015798h) calls
  PadSetActAlign whenever the pad is stable, and libpad accepts whenever idle (8004B190h), so it
  repeats 43h 01h / 4Dh / 43h 00h — on a PS1 too, by the code. The owner felt it ("jumps less") and
  chose the PS1's behaviour over a mod.
- **Dreamcast pictures (ADR-0053, accepted; the owner's two reports):** the backend kept nothing it
  drew and showed emulated VRAM, which lacks it, as a frame's background — Crash 3's pause over
  black, Crash Bash's legal screen (uploaded once, cleared with primitives) at every loading
  pause; Flycast confirmed the diagnosis at six presents of the attract loop against JS VRAM. Now
  each display buffer has a PVR picture (512x256 RGB565 in g_txr's slots 1-3, the buffer's own
  resolution): records rendered into it once, the screen a bilinear quad of the displayed one.
  Flycast: Crash 3's pause shows the frozen game; Crash Bash black where the PS1 is black. Cost
  under the model (E-164): Crash 3 demo cf 17.52 → 17.60, Crash Bash B210 work 11.40 → 11.47,
  after a fix (the frame's first state, carried over, made every present render the shown
  picture again: +0.62 ms). The picture is softer than the 640x480 direct render (1x, scaled).
- **Paused optimisation:** r140 installed (E-152); fh (E-153..E-157) and fi (E-158/E-159) in the
  tree and exact (TA identical, DC digests 47853ef7/95e17b07); E-160/E-161 in the tree, not yet
  measured on DC; E-162 prepared, not applied; B-lite parked (Sh4Emitter.hx back to its tested
  version); placement round r141 ran (out/_work/round5d-r141.log), not installed.

**2026-10-04 (afternoon): Dreamcast — a function's ordinary entry apart from its resumes and the
dispatchers' jumps as goto (ADR-0050), the shadow's small triangles, the SPU's mix, ports through the
libraries' pointers without a trap (ADR-0049 amended), and placement round r138. Crash 3's Uka Uka
scene and warp room at full speed under the model; its demo 22.02 → 20.02.** Not committed.
- **Under the cache model** (g99's code on r139's placement, ledger E-138..E-151): Crash 3's title
  16.64, **the gameplay demo (Toad Village) 22.02 → 20.02** (20.58 on r138's placement, the CDIs'),
  **the dark Uka Uka scene 18.38 → 16.50**, **the warp room 16.95 → 16.64**;
  Crash Bash's Ballistix 16.63 (work 12.63 → 11.92), its disc load 16.6 a present (work 14.43 →
  9.55), the scene after it 16.5. Hardware CDIs for the tester: **out/dc/crash3-r138-max.cdi,
  crashbash-r138-max.cdi** (the fm136 pair stays for comparison).
- **What changed:** (1) ADR-0050 / E-138: on C++ a generated function's body is written once,
  `<name>__body` (always_inline), entered by `<name>` with entry 0 and by a cold `<name>__at` for
  every other entry, so GCC folds the resume guards away on the ordinary entry (a Crash 3 shard
  66.9 → 27.7 KB). (2) E-140: a block dispatcher's jumps as `goto` its case's label (875 in Crash 3).
  (3) E-139: Crash 3's shadow (~210 small flat triangles a frame drawn into VRAM) by stepped edge
  functions, out of line. (4) E-141, E-147: the SPU's software mix through RawBufs and locals, its
  samples out in pairs; VRAM through MemA. (5) E-146, ADR-0049 amended (`PortBases`): ports reached
  through the PsyQ libraries' pointer variables decode their address instead of trapping — traps a
  frame 268 → 2 (Crash 3's demo), 1,036 → 4 (Ballistix), 6,173 → 6 (the disc load). (6) E-148:
  placement round r138, then r139 with every window traced at length and sliced (E-151), installed
  (games/*/dc-placement.txt, dc-data-placement.txt and the shared dc-code-placement.txt). (7) E-150:
  FnTable's FAST (256 slots) and two GPU tables in arrays of their own, which the data placement can
  colour where malloc's could not — in the tree of round r140 (running: out/_work/r140.sh).
- **Rejected** (ledger): E-142 GCC's inliner given room, E-143 FnTable's FAST in a quarter of the
  slots, E-144 pre-RA scheduling again, E-145/E-145b the scene build at -O2.
- **Exact:** JS digests 47853ef7 (Crash 3 at 5000), 95e17b07 (Crash Bash with its mods at 20300),
  the demo's 329de455; tool tests 62,007; conformance on JS (Codegen 5a431e3b); the Dreamcast
  digests of the r138fd builds: Crash 3 47853ef7 at 5000, Crash Bash 95e17b07 at 20300; TA hash of
  g99's trees identical to ta10's over 1,889 + 2,170 + 7,974 scenes.
- **Where the demo's present goes** (r138p1: 3.29 M SH-4 instructions — generated code 1.09 M, the
  scene build 0.69 M, the GPU runtime and polygon core 0.54 M, the GTE cores 0.53 M, the rest 0.43 M;
  out/_work): ~1,590 triangles a built frame (two presents), 36 % brightened (a second pass each),
  ~1,550 SH-4 instructions a triangle on the graphics path (scene 868, GPU 684); ~7.1 SH-4 cycles
  spent a PlayStation cycle, where full speed is 5.9.

**2026-10-04: Dreamcast — fastmem (ADR-0049, the owner's option A): guest RAM and the scratchpad
through the SH-4's MMU, and a placement round for it (r136). Exact on both games; Crash Bash full
speed, Crash 3's warp room nearly.** Not committed.
- **Under the cache model now** (r136p2, ledger E-135..E-137): Crash 3's title 16.65 (full speed),
  **the gameplay demo (Toad Village) 25.50 → 22.02**, **the dark Uka Uka scene 21.08 → 18.38**,
  **the warp room 19.24 → 16.95**; Crash Bash's Ballistix **16.63** (16.6 a present in the match, the
  disc load and the scene after it; work 12.63). Hardware CDIs for the tester:
  **out/dc/crash3-fm136-max.cdi, crashbash-fm136-max.cdi** — the first builds with the MMU on.
- **What it is:** RAM, its mirrors and the scratchpad are wired UTLB pages at their bus addresses in
  P0; every guest access the generated code makes is one `mov.{b,w,l}` (by base register and offset:
  `base & 0x1FFFFFFF` shared among a base's accesses, the offset in the displacement or R0); anything
  else misses the TLB, and the backend's own vector (VBR, 14 instructions) and a lean trampoline run
  the runtime's slow path. The pump tests read the deadline volatile (`Runtime.deadline`): a trapped
  port write can schedule an event. A Dreamcast tree is transpiled with `build/game-cpp-dc.hxml`;
  `scripts/build-dc.sh` sees one and builds it with RECOMPSX_FASTMEM.
- **Exact:** Dreamcast digests JavaScript's — Crash 3 47853ef7 at 5000 (every step), Crash Bash
  95e17b07 at 20300; the TA hash of fastmem builds identical to ta10's over 1,889 + 2,170 + 7,974
  scenes; the regenerated trees' JS digests unchanged; conformance 63/63 on JS and reflaxe.CPP;
  check.sh clean.
- **Measured on a copy of the model's Flycast** (~/Desktop/Project/flycast-fastmem, the owner's call;
  four MMU faults of its fast path patched there, none in the original; the copy reads a build
  without fastmem exactly as the original). Traps: Crash 3 292 a frame (I_STAT/I_MASK through a
  pointer), Crash Bash ~1,000 (the root counters, I_STAT, GPUSTAT; ~0.85 ms of its frame).
- **Placement round r136 installed** (games/*/dc-placement.txt, dc-data-placement.txt, and the shared
  dc-code-placement.txt remade from Crash 3's): code colours from Crash 3's four windows and Crash
  Bash's three phases, then the data colours and pool halves over all seven.
- **ADR-0048's emitter on fastmem** (E-136, opt-in, off): exact, but still 16-23 % more instructions
  than GCC's code for the same functions — its allocator, not the decode, is what it lacks.

**2026-10-03 (late): ADR-0048's first step measured — exact and slower; windows of real play for the
model (sio.PadScript).** Not committed.
- **SH-4 assembly for guest functions** (ledger E-131; `gen --sh4`, `-D recompsx_sh4`,
  tools/recomp/src/recomp/codegen/Sh4Emitter.hx): 198 of Crash 3's functions (loopless leaves that
  call nothing) written as SH-4 assembly beside their C++ form, linked on a Dreamcast build that
  asks; every other build byte-identical. The Dreamcast digest at Crash 3's 5000 is JavaScript's
  (47853ef7). But `f_8003d0fc` runs 178,480 SH-4 instructions a frame against GCC's 139,108 (+7,747
  in glue), and the frame's conflict-free time rose (gameplay 22.59 → 23.80, title 14.87 → 16.40,
  both unplaced): the prologue loads every homed register, guest registers past six go through
  CpuState, every access has its RAM test where the C++ form spans. ADR-0048 has a "Measured"
  section; the owner's call stands, now with this.
- **Real play on the model** (E-132): `--pad-script F:B,...` (sio.PadScript, every game and target)
  plays pad 0 by vblank; Crash 3's START at 3400 reaches the intro's dark Uka Uka scene (bench disc
  out/dc/c3data-uka, 6750:7050: **23.02 ms**, cf 18.10) and the warp room (c3data-warp, 15000:15300:
  **20.38**, cf 16.75; the console's picture there is the tester's). The gameplay demo is Toad
  Village itself (its picture at 4800) and matches the console (25.46 now, 25.2 on r112's CDI).
- **A correction (E-130):** the first reading of the tester's results said the model's demo window
  runs none of real play's hot functions — that came from reading the title window's profile (a
  batch's bare name is its first window, the title's). The demo runs them.
- **Placement round r130** (E-133, installed): Crash 3's code colours from all four windows — the
  Uka Uka scene 23.02 → **21.08**, the warp room 20.38 → **19.24**, the demo and the title unchanged
  (25.50, 16.64). Hardware CDI: out/dc/crash3-r130-max.cdi (Crash Bash's latest stays
  crashbash-r126-max.cdi). The shared half of a placement — the runtime's and the backend's sections,
  the same in every game — gives 53-57 % of its gain on Crash 3 (batch133); whether Crash 3's shared
  half helps Crash Bash as much is measured next (batch134): the case for a placement every game gets.

**2026-10-03 (hardware): 5fa9442's CDIs on a Dreamcast** (the tester, chap3l: crash3-r112-max.cdi,
crashbash-r109-max.cdi; docs/perf/dreamcast-ledger.md E-130). The overlay's 30-frame figures, Crash 3:
the Aku Aku jungle intro 59.8 fps, the Cortex and Uka Uka intro 60.2, the LOAD/SAVE menu 60.0, a bonus
round 58.3 (17.1 ms a frame), the warp room 47.5 (21.0), the dark Uka Uka scene 40.7 (24.5), **Toad
Village 39.6 (25.2 ms a frame; the model's gameplay window said 25.49 for this build)**. Crash Bash's
Select Game Type menu 59.6 with 165 of its 503 ms waiting; no Ballistix shot. Against E-053's g40 run:
the Uka Uka intro 29.5 → 24.5 ms, the warp room 26.0 → 21.0, the jungle 18.7 → 16.7 (full speed).
Toad Village's 30 frames: emulation 462 ms, GPU 138, scene build 127, SPU 15. The model's gameplay
demo window (4700:5000; its profile is `out/_x_<name>w1` in these batches — the first window placed.sh
is given, the title's, takes the bare name) runs what the console's overlay shows hottest in Toad
Village: the RTPS core 5.3 %, run_tris 5.3 %, f_80041550 4.8 %, f_80041d28 4.4 %, the polygon core
4.3 %, f_80038e28 3.6 %. The warp room and the dark Uka Uka scene (overlay: f_800418cc, f_800415a4,
f_80042c58) are reached by a scripted START now (sio.PadScript, Next up 000) and measured as windows
of their own.

**2026-10-03 (night): Dreamcast — the case for generating the guest code as SH-4 assembly written up
(ADR-0048, proposed); the Dreamcast build held to JavaScript's digest; function spans taken where they
are needed (E-125), the counters' and events' runtime paths (E-126), and a placement round (r126).**
Under the cache model now (round r126, E-128): Crash 3's title 16.64 (work 15.44 → 15.03), **gameplay
25.16 → 25.01** (cf 22.79 → 22.39), Crash Bash's Ballistix 16.72 (work 13.39 → 13.25). Hardware CDIs:
out/dc/crash3-r126-max.cdi, crashbash-r126-max.cdi. Gameplay is still the one window short of full
speed, and what is left in place is ~0.1 ms an item (docs/perf/dreamcast-ledger.md E-121..E-127):
- **Where the time goes now** (ledger, "Where the time goes (2026-10-03, after E-119)"): in the
  generated code literal-pool loads are 13.3 % of its instructions and 0.99 ms of operand fills a
  frame; CpuState traffic ~20 %; span set-ups ~146 K instructions a frame (a scratchpad base pays the
  RAM test first: Crash 3's renderer, ~3,200 a frame); 31 % of the code slots it fetches never run;
  6.4 K far branches a frame read their offsets through the operand cache. None moves more than ~0.3
  ms in place; together they are what a code generator holding the memory map's constants and the hot
  guest registers in SH-4 registers would not emit — **ADR-0048 (proposed)**: generated code ~10.7 →
  ~6-7 ms, gameplay ~25 → ~20-21; the owner's call.
- **The game digest on the Dreamcast** (`scripts/dc-digest.sh`, ledger How to measure): a build run
  headless under the model's Flycast prints GenMain's digest. The r117 builds: Crash 3 at 5000
  **47853ef7** and Crash Bash (with its mods) at 20300 **95e17b07**, JavaScript's — every word of the machine's state
  the same through the generated code, the runtime and the RTPS core as GCC and the SH-4 run them.
- **E-122** (runtime, exact): the SPU's due samples by a multiply, where a loop subtracted one sample
  at a time (kept: `Scheduler.fireRest` −0.02 ms in both Crash 3 windows; SPU conformance and the
  JS digests unchanged, TA hash identical over 1,889 + 2,170 + 7,974 scenes). A quad's second
  triangle from the first's words in the polygon core (`_recompsx_gpu_poly2q`, dc-polyrun.py 44,000
  packets 0 differ, 65 cycles a quad fewer) was **rejected**: the core runs in bursts between the
  generated code, and the short path's own lines cost in fills what it saved in issue — running the
  whole core again reused the lines the first triangle had just filled.
- **E-125** (recompiler, exact, kept): a function span live at the entry but not needed on every
  path from it is taken at the start of the blocks from which every path needs it, not at the
  entry. A probe in the JavaScript build first: Crash 3's gameplay took 8,591 function spans a
  frame, 2,273 never used; now 7,212. Gameplay cf 22.79 → 22.39 (the generated code −0.335 ms:
  issue −0.12, instruction fills −0.13), title work −0.13, Crash Bash neutral; JS digests and the
  63 JS conformance groups unchanged. On r117's placement the frame rose (25.38: the layout no
  longer fits the code) — a placement round for it is due.
- **E-126** (runtime, exact, kept): timer 2's reads in a body of their own (its index a constant),
  the root counters first in the slow reads, and kernel event delivery walking the slots only up to
  the last enabled one. The JS build showed the slow halfword reads are timer 2's mode and count in
  both games (Crash 3 ~280 a frame, Crash Bash ~490, ~100 SH-4 instructions each): `slowRead16`
  −30 % in Crash 3, −35 % in Crash Bash (Ballistix work 13.36 → 13.29).
- **E-127** (recompiler, rejected): a span taken again after a call or pump only where its register
  changed — exact, a third of those takes found the register unchanged, but the compares and base
  copies at every site cost what they saved and the code grew 200 KB (gameplay +0.1 ms).
- **Rejected:** E-121 (likely entry constants for function spans: the renderer's helpers are entered
  only by computed jumps, so no call site knows `$v1`), E-123 (RTPT's three vertices as one assembly
  block: 472 cycles against ~490 — the EX unit, not the multiplier, bounds it), **E-124** (ADR-0048's
  fourth alternative: a function's six hottest guest registers in locals, synchronised at calls, pumps,
  traps and exits — exact, and slower: GCC spills them, stack references ×2-3 in the hot functions;
  the generated code +0.12 ms in gameplay, +0.23 in the title).

**2026-10-03 (evening): Dreamcast — Crash 3's gameplay taken apart to the instruction; the scene
build's lookups exact and cheaper; a round for the code; full speed there needs a redesign.** Global
and exact (backend only: TA hash identical over Crash 3's 1,889 + 2,170 and Crash Bash's 7,974
scenes for every batch; the runtime and the recompiler unchanged, so the game digests are too), on
the cache model (docs/perf/dreamcast-ledger.md E-113..E-119):
- **Where gameplay's frame goes** (E-112's build, 25.49 ms): 3.69 M SH-4 instructions — generated
  code 1.41 M for ~290 K guest instructions, the scene build ~0.70 M for ~1,350 triangles, the
  polygon core 0.27 M, the GTE cores 0.47 M, the GPU runtime 0.30 M. The generated code's 12.3 ms
  are 4.4 of issue and 4.3 of capacity fills; guest memory access is 30 % of its time, CpuState
  traffic 20 %. What is left in place is 0.05-0.2 ms an item; the architectural options are written
  up under Blockers (2026-10-03) for the owner.
- **E-113/E-114** (backend): a record's baked patch kept; the clipper's steps that cut nothing left
  out; `bake_slot`'s index exact (open addressing, no walk of the pool); a fast path in build_scene
  for a return to a state whose binding and header the build already made. Gameplay −36 K
  instructions a frame, Ballistix's build_scene −16 %. Host checks of both indexes (4 M and 3 M
  lookups against the old searches).
- **E-115**: far-branch islands in GCC's assembly (scripts/sh4/islands.py) — exact, no gain on the
  model (the islands land in lines the hot path fills anyway); kept opt-in for a console A/B.
- **E-116**: placement round r114 for E-113/E-114: gameplay 25.49 → 25.38, Ballistix 16.76 → 16.74;
  CDIs out/dc/crash3-r114-max.cdi, crashbash-r114-max.cdi (a checkpoint; superseded by E-119).
- **E-117** (backend): a run of triangles goes on into the next state when build_scene's fast path
  would take it (`run_switch`: only the header changes); the palette banks by content hash.
  Gameplay's backend −0.09 ms conflict-free, Ballistix's work 13.51 → 13.31 (build_scene halved).
- **E-118** (runtime, rejected): a textured packet's keys decoded before the polygon core, to spare
  its 552 restarts a frame — exact, but the test costs what the restarts did.
- **E-120** (recompiler, rejected): FnTable's dynamic-call cache in 8-byte slots — exact, neutral.
- **E-119**: placement round r117 for the code with E-117 (installed): title 16.64, **gameplay 25.49 →
  25.16** (cf 23.08 → 22.79; heavy presents 39.2 → 38.4), **Ballistix 16.76 → 16.71** (work 13.56 →
  13.39; 6 of 1,500 presents over 33 ms). Hardware CDIs: **out/dc/crash3-r117-max.cdi,
  out/dc/crashbash-r117-max.cdi** (the r117p2 ELFs, the overlay on). Not committed.

**2026-10-03 (later): Dreamcast — Ballistix's slow presents named and all but the game's own gone;
Crash 3's gameplay unchanged.** Global and exact (digests unchanged: C3 4523 88c8b426, 5000 47853ef7;
CB+mods 20300 95e17b07; demo 329de455), on the cache model (docs/perf/dreamcast-ledger.md E-108..E-110):
- **What the 17 were** (E-108; the bench names its presents over 33.4 ms, "bench slow presents",
  and a JavaScript count of guest instructions per function says what ran in each): five were
  **the FPS overlay's redraw** every 120 presents (~4.7 ms in one present) — now the five presents
  after a report draw a line each, a row at a time through a 1 KB row (the 128 KB buffer is gone);
  ten were **a disc load** (19820-19885: nothing drawn, the game polling the drive in a loop of
  ~15 functions with five VSync calls a turn, 218 K guest instructions a vblank — the PlayStation
  at 100 %), which the placement had never seen: its trace was the window's first ~100 frames; the
  rest are vblanks of the scene after the load where the game's own work runs on into the next
  vblank (the PlayStation at 100 % for two). And the recording now ends before the bench's report,
  whose serial output had been 0.13 ms of each gameplay frame.
- **GPUSTAT's line and timer 1's hblanks without a divide** (E-109): `TimeBase.line` keeps the line
  it found with the cycles it lasts for (forgotten every frame); `Timers.fold` takes one period by a
  compare. The load loop: work 11.62 → 10.80 ms a frame. Fixture `BeamLine` (ffc5a49a, JS and C++).
- **Placement rounds with every phase of a window traced** (E-108 r108, E-110 r109;
  out/_work/round3.sh, src/backend/dreamcast/AGENTS.md step 2): Crash Bash's trace joins the match,
  the load (cbdata-ldbench, 19840) and the scene after it (cbdata-pbbench, 20100), 16 + 4 + 4 M, 180
  sections placed. Installed (games/*/dc-placement.txt, dc-data-placement.txt).
- **Where it stands** (r109p2): the title 16.64 ms (pairs 31.8-32.6 within 33.4); **Ballistix 16.76**
  (the bench's mean 16.7): heavy pairs 29.8 + 3.3 = **33.1 ms within 33.4**, the load's frames
  11.6-13.4 ms, 7 of 1,500 presents over (the game's own double vblanks); **Crash 3's gameplay 25.88**
  (heavy presents 39.5 ms) — the PlayStation is ~95 % busy in both vblanks there (250-310 K guest
  instructions each), and the emulation runs such code at ~0.65 of real time. Hardware CDIs, sent to
  the tester with the commit of this state: out/dc/crash3-r112-max.cdi (E-112's code, r109's
  placements) and out/dc/crashbash-r109-max.cdi (E-109's code; E-112 is exact and changes nothing
  Ballistix draws on the hardware path).
- **Since** (E-111, E-112): `-freorder-blocks-algorithm=simple` for the game's code — images 3 % smaller,
  gameplay's fetches unchanged: rejected. A flat triangle's rows carried rather than divided for
  (`Gpu.flatSpans`; Crash 3's shadow is ~107 flat triangles a frame drawn into VRAM in software):
  gameplay 25.88 → **25.49** (cf −0.10), exact (VRAM digests, Raster). Measured for the next steps:
  the GPU walk's 168 stretches a frame cost the rest of the code 7.5 % of its instruction misses
  (~0.45 ms) besides their own (~0.9 ms); the world loop is hand-written threaded code
  (`jr $t9` between handlers), whose copies per entry E-077 found cheaper than hand-overs.

**2026-10-03: Dreamcast — Crash 3's title screen and Crash Bash's Ballistix within their 30 Hz pairs
under the cache model.** Global and exact (game digests unchanged: C3 4523 88c8b426, 5000 47853ef7;
CB+mods 20300 95e17b07), judged on the cache model (docs/perf/dreamcast-ledger.md E-097..E-107):
- **The pump's path for a stretch of the GPU's list walk** (E-098): ~210 of the title's ~230 pumps
  a frame are DMA2 stretches (ADR-0039). The scheduler's state is one array (`shim.SchedFile`,
  `recompsx_sched`, 16 words, the words a stretch touches on one line); REST, the earliest armed slot
  but DMA_STEP, is kept as the others are armed, cancelled and fired, so a stretch's re-arm is a
  compare instead of a scan; the other handlers are out of line (`fireRest`); `Runtime.pump` is one
  call, never inlined (GCC had put half of it at each of the thousands of pump sites). Pump 101
  instructions where ~385; images C3 −92 KB, CB −53 KB; conflict-free title −0.12, gameplay −0.17,
  Ballistix work −0.19. New fixture `SchedulerOrder` (200,000 random arms, cancels and fires against
  a search of every slot; e3bc279e on JS and C++, and the same with the old scheduler).
- **Relocatable code's answers kept by address** (E-099, ADR-0025 revision): Crash 3's GOOL calls
  (~36 a frame) no longer hash eight words byte by byte each time; 64 slots keep each answer with
  the words it was found by (86 % hits on JS). Gameplay `FnTable.call` 0.314 → 0.204 ms a frame.
- **Placement rounds** (E-097 r85; E-100 r99, which also remade the **data colours** — the five
  backend tables E-091..E-095 added were never placed, and the code's literal pools sat on
  `recompsx_gte`): `scripts/build-dc.sh --data-placement F` takes a candidate; the steps are
  out/_work/round2.sh's (ledger E-100). Title 18.88 → 17.19 → **16.69 ms** a frame: heavy presents
  26.6-27.8 ms with light ones 5.0, **a 30 Hz pair in 31.6-32.8 ms against 33.4**, and the pacer
  waits 0.66 ms a frame. Ballistix 18.25 → 17.44 → **17.01** (heavy pairs ~33.4, 19 of 1,500
  presents at 37.4). Gameplay 29.36 → 27.01 → **25.50** (heavy presents 38.8 ms).
- **Set aside**: the span-fail paths `cold` and their address unmasked (E-101) — gameplay's capacity
  fills +0.4 ms (the trampolines to far blocks spread the hot paths); the root counters first in the
  slow reads (E-102) — cheaper counters, dearer other devices, a moved layout. Measured on the way: 29.5 % of
  the bytes in the instruction-cache lines gameplay's generated code touches are never run there —
  the game's own cold paths (62 % of the long cold runs), the inline scratchpad path (17 %),
  literal pools and `bf`+`bra` trampolines.
- **Crash Bash's margin** (E-103..E-107): a GP0 state command a list carries no longer calls `draw`
  (~450 a frame, 0.11 ms); INTPL at its call sites (`GteQuick.intpl`, fixture `GteInterpolate`,
  b7f03c86 on JS and C++; ~300 a frame, 0.22 ms through the general form); build_scene's area and
  memo tests by one word, and a flat triangle's colour converted once (TA hash identical over
  1,889 + 2,170 + 7,974 scenes); placement round r100 with the data colours. Ballistix 17.01 →
  **16.87** ms (work 13.79 → 13.63): **heavy pairs 29.6 + 3.3 = 32.9 ms, within 33.4** — 17 of
  1,500 presents still at ~37 ms (frames with ~8 ms more emulation). Title unchanged (pairs
  31.6-32.9); gameplay 25.50 → 25.86 (capacity fills moved with the code).
- **Where it stands.** The title screen fits; Ballistix fits but for 17 of 1,500 presents;
  Crash 3's gameplay needs ~35 % less (a pair ~51 ms: heavy presents ~39 ms — ~29 of emulation,
  ~9 of scene — and light ones ~12).
  The title's light vblank is real work too (JS: 271 K guest instructions against the heavy one's
  375 K). Confirm on hardware next (a CDI of this build).

**2026-10-02 (evening): Dreamcast — RTPS and the polygon packet as scheduled SH-4 cores in the
runtime (ADR-0046, ADR-0047).** Global, exact, judged on the cache model's conflict-free time
(docs/perf/dreamcast-ledger.md E-083..E-086):
- **RTPS's vertex** (E-083, E-084): scripts/sh4/rtp1.blk and rtp1n.blk, list-scheduled by
  scripts/dc-sched.py (new) under the model's issue rules and written into Gte.hx: 155/144 cycles
  a vertex against GCC's ~204 inline and 233 out of line; a vertex behind the camera, a divide that
  overflows and a quotient above 16 bits finish in 64 bits on the core too (the title's last
  vertices 28,310 of 28,318 there). The divisor's leading zeros from the register file's CLZ table:
  no floating point anywhere (golden rule 1; `scripts/check.sh` had flagged the FPU's exact
  int-to-float exponent, +6 cycles a vertex). Exact by scripts/dc-shrun.py (new: an SH-4
  interpreter) over 76,000 vertices recorded from JavaScript, and check builds (5,308,416 vertices,
  0 differ).
- **The polygon packet** (E-085, E-086): scripts/sh4/poly.blk — texture keys, flags, triState's
  test, the three positions, the size and line rejects, the count, the GPU time and the backend's
  triangle as twelve words; the backend ABI gains `bp_gpu_tri_w` and `bp_gpu_state_w` (the same
  calls as words), and the Dreamcast writes its records as words. Exact by scripts/dc-polyrun.py
  (new) and a check build (2,293,760 packets, 0 differ); the JavaScript GPU-stream hash at Crash 3's
  4050 unchanged (5f877994a1335867).
- **The state path and RTPS everywhere** (E-087, E-088): when a triangle's state is not the one
  last sent the core does triState's and sendState's work and leaves the state for
  `bp_gpu_state_w` (the backend's state record compared and written as words) — Ballistix, half
  of whose triangles change state, −0.23 cf; RTPS inline at every site with its C form cold and out
  of line on the SH-4 (E-031's leaf rule dropped) — Ballistix work −0.28 (cmdRtps's wrapper gone).
- **Where it stands** (g82, conflict-free a present, against g76 before the cores): title 16.74 →
  15.84, gameplay 26.26 → 24.69, Ballistix 17.45 → 16.58 (work 15.71 → 14.88). Frames wait on the
  placement round for this code (r81, in progress); the title's 30 Hz pair should land within
  ~0.5 ms of 33.4, Ballistix's ~4-5 ms over.

**2026-10-02 (later): Dreamcast toward full speed — the CpuState's layout, placement, GTE, the
scratchpad test; three measured and set aside.** Global changes, judged on the cache model's
conflict-free time (docs/perf/dreamcast-ledger.md E-073..E-082):
- **Kept.** CpuState's 16 most-named words within the SH-4's 60-byte displacement (reflaxe.CPP
  patch 0007, `@:declarationOrder`; E-076): title cf 16.92 → 16.76, Crash Bash work 15.74 → 15.68,
  gameplay level. Placement rounds for the code of the time (E-073; E-079 for g70's; E-082 for
  g75's): title 19.20 → 18.17 → 17.73 → 17.83, gameplay 30.29 → 29.06 → 28.80 → 28.53, Ballistix
  19.34 → 19.12 → 18.89 → 18.96 (a round's own spread is 0.1-0.3 ms). `Memory.span`'s scratchpad
  test as one compare an end (E-081): Crash 3's generated issue −0.055 ms, images −110 / −64 KB,
  exact — the new `SpanTake` fixture checks every byte of every run taken against the full decode.
  RTPS/RTPT's saturation as one test (E-074): Crash Bash's `cmdRtps` −0.05. Function summaries no
  longer treat an unproved ADD/ADDI/SUB as a trap into unknown code (E-075): no speed, Crash 3
  −33 KB. All 58 conformance tests agree on JavaScript and desktop C++ with these changes.
- **Set aside.** Hand-overs where functions share code (ADR-0045, `gen --cut-shared`; E-077):
  exact (digests, a pump trace, the `HandOver` fixture on both targets) and smaller (Crash 3
  −376 KB, Crash Bash −194 KB) but gameplay cf +0.65 ms — each copy carried only its entry's
  paths. The software rasteriser's row ends carried without a division (E-078): exact, and what the
  divisions cost (0.1 ms) came back in the carried state's issue; reverted. Pre-RA scheduling for
  the game's code (E-072), the triangle state flag (E-071).
- **Set aside, not built** (then superseded the same day by E-083: scheduled, it is 155). RTPS by
  hand in SH-4 assembly (E-080): timed first with scripts/dc-issue-sim.py (new; the cache model's
  issue rules replayed over a path, 233 cycles for GCC's `cmdRtps` against the 232 measured): 211
  cycles, where GCC's inline form is ~204.
- **Where it stands** (the model): title 17.83 ms a present, its 30 Hz pairs 35.4 against 33.4;
  Ballistix 18.96, its pairs 39.3 against 33.4; gameplay 28.53, its heavy presents 43.6. Full speed
  is not reached; the levers left are in Next up 000. Measured for what comes next: gameplay runs ~290 K guest instructions a present
  (title ~323 K) as 1.64 M SH-4 instructions of generated code over 13,869 distinct cache lines (an
  8 KB cache holds 256), 5.4 of its 13.2 cf ms instruction fills a fully associative cache would
  have too; the GPU path costs ~1,200-1,500 SH-4 instructions a polygon in every window (list walk,
  polygonHw, the scene build); RTPS ~230 cycles (Crash Bash's out-of-line `cmdRtps`, 1,655 a
  present), its 15 multiplies alone ~45 of them under the model's issue rules.

**2026-10-02: The GTE and LWL/LWR in recovered scalar helpers (ADR-0044); no Dreamcast speed effect.**
`ScalarGraph` admits coprocessor 2 and unaligned loads where effects are ordered: MTC2/CTC2 and
named COP2 commands are ordered effects (predicated on their CFG arm), MFC2/CFC2 reads stay where
they stand, LWC2/SWC2 go through checked spans, LWL/LWR through `Memory.spanLwl`/`spanLwr` (byte
preflight, no alignment condition). Helpers call new CPU-state-free accessors (`Gte.readData`,
`writeData`, `readControl`, `writeControl`; the ctx forms delegate). GTE helpers stay out of the
pure pool; GTE projections stay with their caller. Two general fixes found on the model: a CFG arm
no path reaches (`bgez $zero`'s other side) is no longer lifted or preflighted, and a constant CFG
accounting word is charged at the call site instead of passing through `ScalarResult.accounting`.

Helpers: Crash 3 151 -> 171, Crash Bash 175 -> 180. Share of the generated code's executed SH-4
instructions in recovered functions (model, RXCOUNT): C3 gameplay 0.36 -> 1.71 %, title 0.13 ->
0.33 %, Ballistix 0.25 -> 1.00 %. Dreamcast model (ledger E-067, E-068), frame / conflict-free ms:
title g60 19.76 / 17.12, g63 19.74 / 17.13, g64 19.53 / 17.11, g65 (final) 19.77 / 17.12; gameplay
30.80 / 27.21, 30.87 / 27.05, 30.72 / 27.32, 30.79 / 27.20; Ballistix 19.48 / 17.64, 19.46 / 17.62,
g65 19.48 / 17.61 (work 15.98 -> 15.96). Issue time is the same in every build (gameplay 13.27 /
13.29 / 13.27 / 13.27 ms); the cf moves are instruction fills
that follow the layout (`dc-cmp.py g60g-c3 g64g-c3`: generated issue -0.015 ms, non-conflict fills
+0.171, +0.08 in f_80041d28, which did not change). The earlier ADR-0044 stages measure the same
way: `--no-scalar` and `--no-scalar --no-value-regions` change executed instructions by <= 0.11 %.
JS ES6: C3 25,409,681 -> 25,567,682 B, CB with mods 24,243,721 -> 24,264,455 B.

Where the time is, measured (g60/g64 gameplay): generated code 13.6 of 27.1 cf ms; within it
CpuState loads/stores are 14.9 % of executed instructions and literal-pool loads 13.3 %, half of
those the address-decode constants of span and memory checks (0x1FFFFF, 0x1F9FFFFF, the arena,
the scratchpad's). The three hottest generated functions are GTE loops (f_80041d28 1.93,
f_80041550 1.43, f_8003fc50 1.27 ms). The hottest acyclic GTE/LWL functions stay unrecovered:
indexed addresses (base + computed index) have no span anchor; their CpuState share is ~15 %.

Acceptance (`out/_cop_validate`, `out/_cop_survey`; DC logs `$SP/g6[0-5]*.out`):
```
./scripts/test.sh
all 61949 checks passed
conformance: 57 test(s) x JS
ok ScalarCop 10882ef3 values=237450
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCop ScalarCfg ScalarMemoryCfg ScalarEffects ScalarCompose ScalarResults ScalarBorrow ScalarShare ScalarCalls ScalarPointers ScalarCodegen ScalarMemoryCodegen RangeCodegen
ok ScalarCop 10882ef3 values=237450
ok ScalarCfg 750ee5b6 values=192290
ok ScalarMemoryCfg bac8188c values=1682130
ok ScalarEffects 3cfb6f71 values=1136641
ok ScalarCompose 9868486c values=2768992
ok ScalarResults 9c6ba8fc values=51714
ok ScalarBorrow 09b9df4b values=1959395
ok ScalarShare 670c3bdc values=77833
ok ScalarCalls ff62afe6 values=96344
ok ScalarPointers 3bdd733d values=5800672
ok ScalarCodegen 4ebe3340 values=124013
ok ScalarMemoryCodegen 852cd0fd values=3830
ok RangeCodegen 33c5b85a values=10090
conformance: all targets agree
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh Unaligned GteOps GteProject
ok Unaligned 896889ce values=204
ok GteOps de71ee8a values=5440
ok GteProject 43a78d52 values=396010
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node <c3 g60|g65 JS> --headless-hash 20000   frames=20000 digest=36dcd8ee (both)
node <cb+mods g60|g65 JS> --headless-hash 20000   frames=20000 digest=98109571 (both)
```
The other 56 JS group digests are unchanged. Deliberately removing the LWR merge, the predicate on
GTE effects or the ordered emission each fails ScalarCop. Next: decide with the owner between the
loop work (where the generated code's time is) and the measured global costs above (entry work,
decode constants in literal pools); indexed spans would admit the remaining acyclic candidates.

**2026-10-02: Equal memory projections share one helper/adapter pair per class.**
`Program` emits one copy of a memory projection pair for all call sites of an emitted class whose
pair texts are equal up to the pair's own two names (`ProjectionShare`, ADR-0044). The key is the
complete text: parameters, results and publication, preflight, ordered effects, accounting,
fallback owner/callee, borrowed/fresh form and entry guards. Sharing runs after the cross-universe
body comparison and never crosses a class. `--no-projection-share` reproduces the preceding stage
byte for byte (both games' generated Haxe and ES6 JS).

Emitted pairs fall **73 -> 48 (C3) / 108 -> 69 (CB)** (25/39 call sites renamed); ES6 JS
**25,451,666 -> 25,409,681 (-41,985 B)** and **24,220,093 -> 24,137,205 (-82,888 B)**. An out-of-tree
check confirms that every call site runs a pair equal to its own former pair and that no other text
changed (`out/_proj_share/{Structure,Equivalence}.py`). These are static properties.
Timing on a loaded host (load average 8-16): five wall-clock pairs gave C3 median +4.86% (four pairs
slower) and CB -0.78% (mixed); ten pairs with child CPU time gave pairwise medians C3 wall +0.68% /
CPU -0.13% and CB wall +1.20% / CPU +1.73% (seven pairs slower), with overlapping ranges. No speed
change is established; this is a size reduction.

Acceptance (`out/_proj_share/{gate,cross-final,check,validation}.log`, timings `bench{,2}.json`):
```
./scripts/test.sh
all 61906 checks passed
conformance: 56 test(s) x JS
ok ScalarShare 670c3bdc values=77833
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarShare ScalarBorrow ScalarResults ScalarCompose
ok ScalarShare 670c3bdc values=77833
ok ScalarBorrow 09b9df4b values=1959395
ok ScalarResults 9c6ba8fc values=51714
ok ScalarCompose 9868486c values=2768992
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_proj_share/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 shared: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb shared: frames=20000 digest=a9864f26
```
The other 55 JS group digests and value counts are unchanged. A key weakened to "same callee and
form" fails ScalarShare with 60 mismatches. No C++ game was built. Next: the per-call entry cost of
projections (adapter guards and preflight) and the earlier C3 timing question; general loops,
conditional summaries and ABI/stack recovery remain open.

Whole-pipeline A/B on the same tool, eight rotating rounds per game with child CPU time
(`out/_proj_share/bench{3,4}.json`; new measurement flag `--no-scalar-calls` keeps helpers inside
their functions but calls every function through its CpuState entry): default against
`--no-scalar` gave CB CPU **+1.82%** (eight of eight rounds slower) in one run and **-0.94%** (four
of eight) in the next; C3 **-1.50%** and **-0.23%**. Within a variant, C3 ran 19.6-35.7 s at load
averages 7.8-14.8. On this host the JS timing cannot resolve these differences: neither a gain nor
a cost of scalar recovery, its call-site use or its projections is established. A one-run CPU
profile of CB attributes 17 ms to helpers/adapters of 5.4 s, while host I/O (`read`) alone varied
by 126 ms between runs; about 60% of JS time is runtime (software rasterizer spans, GP0, audio).

**2026-10-02 handoff:** the owner requested a detailed continuation prompt for another LLM.
Use this same working tree: current recovery sources include uncommitted/untracked files and
modified compiler submodules, so HEAD alone does not contain this state. No implementation or
acceptance changed during handoff preparation. Next: safely share duplicate memory projections.

**2026-10-02: Caller-specific memory results reach program generation; optimizer flags verified.**
Direct resident JAL calls may now omit a bounded memory callee's outputs when every caller
path overwrites them before a read or observation. Full access/alias preflight, ordered stores,
path accounting and the original entry fallback remain. Adapters either reuse identical
borrowed-span proofs or construct the complete preflight, including constant/loaded addresses.
All-dead read results can use Void helpers. Public/interior entries retain full machine state;
events, resumes, existing unwind tokens, MMIO and failed guards use the original path.
Memory projections remain outside pure pooling and do not recover internal guest calls.

An integration regression exposed Program's older pure-only summary gate: 13 new program-level
checks failed although emitter fixtures passed. Its gate now admits control/read/write-memory
effects for the independent value/access proof; calls, traps, unknown and nonlocal effects
still reject projection. Program tests also verify cached hook invalidation. ScalarBorrow
covers 47 programs, including partial/all-dead results, ordered aliases, conditional charges,
missing donor spans, loaded pointers, constant addresses, public entries, every deadline,
cooperative resumes, existing unwinds and dead-result FIFO reads on both adapter paths.

Real generated call sites now contain **73 C3 / 108 CB** memory projections (3/1 borrowed,
70/107 fresh; 34/66 Void helpers). They omit **80/125 static GPR publication sites** compared
with existing full helpers; one additional C3 projection has no accepted full helper and is
excluded from that reduction count. All **151/175 previous full helper bodies are unchanged**.
ES6 JS grows **25,317,638 -> 25,451,666 (+134,028 B)** and
**24,010,469 -> 24,220,093 (+209,624 B)**. These are static code properties, not dynamic savings.
Exact keys/hashes: `out/_entry_cost/{projection-coverage,validated-sources}.json`.

The requested optimizer settings were already enabled: all 16 build entries inherit
`-D analyzer-optimize` and `-dce full` from `build/common.hxml`; JS retains `-D js-es=6`.
No flag change was necessary. Fresh pinned JS demo still reports `frames=300 digest=329de455`.
Acceptance (`out/_entry_cost/{gate-final,cross-full,check-final,validation,evidence}.log`):
```
./scripts/test.sh
all 61848 checks passed
conformance: 55 test(s) x JS
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarBorrow ScalarResults ScalarCompose
ok ScalarBorrow 09b9df4b values=1959395
ok ScalarResults 9c6ba8fc values=51714
ok ScalarCompose 9868486c values=2768992
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_entry_cost/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 results: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb results: frames=20000 digest=a9864f26
```
The other 54 JS group digests are unchanged. Focused native fixtures validate emitted adapter
semantics; final program-routing checks and real-game runs validate their integration. No C++
game was built. Both baselines are the preceding stage's validated artifacts, with checked hashes.

Five alternating timing pairs per game ran after builds finished; all 20 bounded digests agree.
C3 baseline **22.5920 / 20.1061 / 22.5727 / 21.0986 / 25.8542 s**, projected
**23.6054 / 20.9060 / 21.6444 / 21.7142 / 21.5792 s**: median **-4.11%**, but three pairs slower.
CB baseline **4.3972 / 4.2579 / 4.2317 / 4.8483 / 5.3332 s**, projected
**4.2298 / 4.5776 / 4.9053 / 4.1468 / 4.9857 s**: median **+4.10%**, but three pairs faster.
Ranges overlap; neither a general speedup nor the prior C3 slowdown's cause is established.
Before this change, sampled helper self time was a small part of the two profiles; inlined
work prevents attributing the earlier regression from those samples alone. Evidence remains in
`out/_entry_cost/`. Exact helper/adapter pairs within each owning class number only **48/69**
for the 73/108 projections: sharing those repetitions is the next code-size opportunity.
General loops, conditional/numeric summaries and ABI/stack recovery remain open.

**2026-10-02: Larger functions recover by live-body cost; native short circuiting repaired.**
`ScalarPlan` now separates its 256-guest-instruction analysis cap from a 96-unit surviving
body budget (live SSA definitions/effects, transported results and accounting publication).
The former 32-instruction limit rejected compact recovered calculations before liveness.
Six parameters, six preflight spans, sixteen alias exclusions, 10-bit accounting lanes,
effect order, fallback and observation boundaries remain bounded as before. No forced
inline, runtime allocation, game-specific rule or generated-source edit was introduced.
`ScalarPointers` now compares 58 programs, covering long dead prefixes, larger live/branch
bodies, 40 ordered stores, a large summarized child and both budget rejection paths.

A read-only survey of static function universes found 15 size-only candidates in each game
under a 256-instruction scan; the live-body cap admits 11 C3 / 12 CB. Loop/unresolved-callee/
unsupported-op counts are prioritized classifications, not independent exhaustive causes.
Recovered whole helpers increase **C3 140 -> 151 / CB 163 -> 175**; all prior helper bodies
remain byte-identical, with no removals. Typed child call sites increase **14 -> 21 / 17 -> 24**.
ES6 JS grows **25,273,160 -> 25,317,638 (+44,478 B)** and
**23,967,325 -> 24,010,469 (+43,144 B)**. These are static coverage/size results, not speedups.
Survey evidence: `out/_recovery_survey/`; exact helper keys: `out/_body_budget/coverage.json`.

Native validation exposed a pre-existing compiler error: statement-bearing RHS values of
`&&`/`||` were evaluated before their guards. `Scheduler.init` consequently read `due[-1]`,
intermittently faulting in either pointer or composition fixtures. A deterministic 22-value
reproduction failed 11 C++ assertions; exported compiler patch 0006 fixes evaluation order
and guarded execution. The expanded 53-value ShortCircuit fixture and the corrected generated
scheduler branches prove the fix. Setup applies it idempotently and spike.sh runs it on both
targets. Runtime source and analyzer/full-DCE/JS-ES6 flags remain unchanged; see defect 12.

Acceptance (`out/_body_budget/{gate-fixed,cross-fixed,spike-fixed,check-fixed,validation}.log`):
```
./scripts/test.sh
all 61528 checks passed
conformance: 55 test(s) x JS
ok ScalarPointers 3bdd733d values=5800672
ok ShortCircuit 157a406f values=53
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ShortCircuit ScalarPointers ScalarCompose ScalarCalls
ok ShortCircuit 157a406f values=53
ok ScalarPointers 3bdd733d values=5800672
ok ScalarCompose 9868486c values=2768992
ok ScalarCalls ff62afe6 values=96344
conformance: all targets agree
./scripts/spike.sh
spike.sh: clean
./scripts/check.sh
check.sh: clean
python3 out/_body_budget/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 results: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb results: frames=20000 digest=a9864f26
```
Fresh pinned JS compilation of all four baseline/new artifacts on October 2 reproduces
their already-validated hashes exactly. No C++ game was built: only focused conformance and
compiler spikes. General loops, conditional/numeric call summaries, changed-pointer
continuations and ABI/stack recovery remain open; this is not complete CpuState removal.

After builds finished, five alternating pairs per game (Node startup included) retained
C3's 9000-frame `4de78425` and CB's 3000-frame `db892c4b` in all 20 runs.
C3 baseline **23.9714 / 21.7074 / 21.9441 / 22.4593 / 21.5237 s**;
new **23.0600 / 22.9611 / 23.4738 / 23.4828 / 21.5534 s**.
Median **21.9441 -> 23.0600 s (+5.09%)**, new slower in four of five pairs.
CB baseline **5.4233 / 4.4406 / 4.4549 / 5.2132 / 5.0533 s**;
new **4.6610 / 4.3675 / 4.2673 / 4.2743 / 6.5958 s**.
Median **5.0533 -> 4.3675 s (-13.57%)**, but the last pair is 30.53% slower.
Ranges overlap and host load varies materially; no general speedup is established and the
C3 slowdown needs investigation. Preserve these measurements, not just the favorable CB
median. `out/_body_budget/{bench.json,evidence.log}` verifies source hashes, unchanged prior
helpers, all four 20k results, all tests and all 20 timing runs. Next: isolate entry/preflight
and result-publication cost before further coverage expansion on performance grounds.

**2026-10-01: Optimizer flags rechecked during recovered-body budget work.**
`build/common.hxml` already enables `-D analyzer-optimize` and `-dce full`; JS and
reflaxe.CPP game entries, conformance and benchmark commands include it. JS retains
`-D js-es=6`. No additional flag changes were needed. Fresh pinned JS smoke output:
```
source scripts/env.sh && haxe build/js-demo.hxml && node out/_demo/js/demo.js --headless-hash 300
[info] frames=300 digest=329de455
```
The larger recovered-body budget remains under validation; this smoke check does not
establish native acceptance. Its two focused cross-target runs intermittently failed
in different native fixtures (ScalarPointers, then ScalarCompose); investigation continues.

**2026-10-01: Child result equalities and fixed charges cross recovered calls (ADR-0044).**
An unconditional call imports its child's separate numeric `sampleRead` proof for normal
and secondary results, preserving exact source/version/offset/extension and prefix writes.
The read can become entry-proved only in the parent. Boundary reconstruction can then make
a read-only child call dead; every effect, still-used result or dynamic charge keeps its
dependency. All original spans remain in preflight, including zero-target reads and device
fallback. Fixed packed charges now fold through nested summaries without requiring a child
invocation just to read its accounting word. Guest instructions/cycles/blocks, original
observation horizons and public interior entries remain unchanged. No child body is inlined.

Narrow memory forwarding keeps an exact read identity for converted bytes/halfwords instead
of losing provenance after a mask/sign extension. This emits only the existing conversion.
Its new version includes every earlier write, so a converted value from an overlapping store
cannot use stale entry bytes. Conditional conversions/calls do not export unconditional
equality. `ScalarPointers` covers 51 programs: normal/secondary results, surviving primary
with omitted secondary capture, nested constant/dynamic charges, conditional invocations,
before/after writes, forwarded signedness/byte offsets and discarded-result MMIO fallback.
Other 53 JS group digests remain unchanged.

Both real-game JS outputs are **byte-identical to the prior stage**, so no timing comparison
was run and no game speedup is claimed. This extends general recovery on the synthetic cases;
the current game helper counts remain **C3 140 / CB 163**, child call sites **14/17**, static
read sites **101/138** and result words **155/172**. Seven C3/thirteen CB Haxe helper bodies
simplify constant accounting which Haxe's analyzer already folded. JS sizes stay
**25,273,160 / 23,967,325 B**. Exact keys and source hashes are in
`out/_call_results/{coverage,validated-sources}.json`. Acceptance:
```
./scripts/test.sh
all 61486 checks passed
conformance: 54 test(s) x JS
ok ScalarPointers 8e96dd1b values=2606293
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarPointers ScalarCompose ScalarMemoryCfg
ok ScalarPointers 8e96dd1b values=2606293
ok ScalarCompose 9868486c values=2768992
ok ScalarMemoryCfg bac8188c values=1682130
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_call_results/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 results: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb results: frames=20000 digest=a9864f26
python3 out/_call_results/Evidence.py
61486 tool checks; 54 JS groups; other 53 unchanged; 3 groups agree JS/C++; four 20k runs verified
No timing comparison: both game JS files are byte-identical to baseline
```
Logs are `out/_call_results/{gate,cross,check,validation,evidence}.log`. Only the three
focused fixtures were compiled for C++; no game C++ build was run. General loops, wider
signatures, changed-pointer continuations, differing-pointer phis and ABI/stack recovery
remain open. Next: conditional/numeric value recovery across calls and broader function
coverage; this stage does not establish complete CpuState removal.

**2026-10-01: Known entry values leave the helper result ABI (ADR-0044).**
`ScalarValue.sampleRead` proves unconditional equality to an immutable entry read plus a
wrapped constant offset; pointer provenance alone does not. Remove such outputs before
helper liveness, reconstruct them from saved preflight samples at publication, and omit
boundary-only sample arguments. Earlier-write exclusions and every original span check
remain, including dead/zero-target accesses. All-known memory-helper outputs now permit
`Void`, preserving effects and path accounting; pure-pool signatures keep an Int result.
Nested calls capture reconstructed child outputs before effects, retaining separate read
versions and conditional reach. Input snapshots protect values overwritten during output
publication. No runtime allocation, forced inline, JIT or game-specific rule was added.

Generated full-helper secondary-result writes fall **C3 80 -> 71 / CB 84 -> 74**; ordinary
Int-returning helpers fall **115 -> 84 / 158 -> 98**. Source-level transported result words
therefore fall **195 -> 155 / 242 -> 172** (static counts, not traffic per frame). Sample
parameters fall **13 -> 2 / 23 -> 18**. Read sites remain **101/138**. Every prior helper
survives; C3 additionally admits `f_800205f4_value`, with totals **140/163**. ES6 JS size is
**25,271,622 -> 25,273,160 (+1,538 B)** / **23,968,254 -> 23,967,325 (-929 B)**. Exact helper
keys, changed bodies and source hashes are in `out/_sample_results/{coverage,validated-sources}.json`.

`ScalarPointers` now executes 38 programs, including sole/multiple/affine known outputs,
Void effects and forwarding, input overwrite, predicated/nested calls and separate child
read versions around a write. Its six-argument fallback now consumes the pointer in real
arithmetic so removing an output alone cannot eliminate the budget case. Other 53 JS
group digests remain unchanged. Acceptance (`out/_sample_results/{gate,cross,check,validation}.log`):
```
./scripts/test.sh
all 61378 checks passed
conformance: 54 test(s) x JS
ok ScalarPointers 5dbfdd9f values=1823852
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarPointers ScalarBorrow ScalarResults
ok ScalarPointers 5dbfdd9f values=1823852
ok ScalarBorrow efe0d707 values=1229039
ok ScalarResults 9c6ba8fc values=51714
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_sample_results/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 results: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb results: frames=20000 digest=a9864f26
```
Only the three focused conformance programs were built for C++; no C++ game build was run.
Fresh baseline JS hashes match the preceding sample-input stage. After all builds/tests and
20k validations finished, five alternating timing pairs (Node startup included) retained
C3's 9000-frame 4de78425 and CB's 3000-frame db892c4b:
C3 baseline **12.0866 / 11.9120 / 11.9709 / 11.9721 / 12.0026 s**;
new **12.0060 / 11.9846 / 12.0058 / 11.9077 / 12.0369 s**. Median **11.9721 -> 12.0058 (+0.28%)**.
CB baseline **2.7078 / 2.6849 / 2.7882 / 2.6219 / 2.6106 s**;
new **2.6914 / 2.7050 / 2.6252 / 2.6133 / 2.5914 s**. Median **2.6849 -> 2.6252 (-2.22%)**.
Ranges overlap and host load fell during the run. This does not establish a general speed
benefit: C3 is mixed/slightly slower by median; CB is faster in four of five pairs. Never
compare absolute times across sessions. `out/_sample_results/{bench.json,evidence.log}` records
the timings and verification of all 20 runs, 54 groups, three cross-target groups and source
hashes. General loops, changed-
pointer continuations, ABI/stack recovery and opaque returned loads remain open. Next:
propagate independently proved child result equalities without assuming opaque pointer
provenance implies numeric equality or discarding child effects/accounting.

**2026-10-01: Requested optimizer settings reverified after sample-input recovery.**
All 15 HXMLs with a main class, plus the interpreter tool entry, inherit
`-D analyzer-optimize` and `-dce full` from `build/common.hxml`. JS entries retain
`-D js-es=6`; conformance and benchmark commands also include the common settings.
No flag changes were necessary. Fresh pinned-toolchain smoke acceptance:
```
source scripts/env.sh && haxe build/js-demo.hxml && node out/_demo/js/demo.js --headless-hash 300
[info] frames=300 digest=329de455
./scripts/check.sh
check.sh: clean
git diff --check
# no output; exit 0
```
This is a configuration/demo check; C++ was not rebuilt during this verification.

**2026-10-01: Proved entry reads become ordinary Int helper inputs (ADR-0044).**
`ScalarSignature` lowers live parameters after the complete memory proof. A real load node
with active read provenance can use the entry's numeric sample, retaining its reach predicate.
Spans unused by the lowered body leave the signature but remain in all preflight checks.
Selection prefers fewer arguments, then more replaced reads, within six parameters; an
unaffordable sample stays an ordered body load. Preflight separately stays within six spans.
Equal entry sources/offsets/widths/signedness share a sample, with each original version's
earlier-write exclusions intact. Inactive later versions still read RAM even with the same
source key. Child calls pass explicit sample values which parent lowering can reuse too.
There is no new runtime state, object allocation, forced inline, JIT or game-specific rule.

Generated full-helper read sites fall **C3 114 -> 101; CB 161 -> 138**. Body span parameters
fall **177 -> 164 / 230 -> 220**, replaced by **13/23 Int sample parameters in 13/21 helpers**.
All prior full helpers remain; removing unused body span arguments admits one additional C3
wrapper (`f_80071500_value`). Counts are **C3 138 -> 139; CB 163 -> 163**. These are static
source counts, not reads saved per frame. ES6 JS changes **25,270,329 -> 25,271,622 (+1,293 B)**
for C3 and **23,970,037 -> 23,968,254 (-1,783 B)** for CB. Rebuilt baselines match the preceding
validated loaded-pointer hashes, and both baseline/new 20k runs match. Coverage/source hashes
are in `out/_sample_inputs/{coverage.json,validated-sources.json}`.

`ScalarPointers` now executes 30 programs. Added cases check distinct proved versions sharing
one input, a later unproved version still loading after a write, signed/unsigned samples at
one source, parameter-budget fallback, omitted source-only views and propagated child inputs.
All alias/device/entry/event/wrap/suspension checks remain. The other 53 JS group digests are
unchanged. The pointer and borrowed-adapter fixtures agree on JS and reflaxe.CPP.
Acceptance (`out/_sample_inputs/{gate-final,tool-final,cross,check,validation}.log`):
```
./scripts/test.sh
all 61274 checks passed
conformance: 54 test(s) x JS
ok ScalarPointers 9c9a264b values=1377981
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarPointers ScalarBorrow
ok ScalarPointers 9c9a264b values=1377981
ok ScalarBorrow efe0d707 values=1229039
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_sample_inputs/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 samples: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb samples: frames=20000 digest=a9864f26
```
Only small conformance programs were built for C++; no game C++ build was run.
After all builds/tests/validation finished, five alternating timing pairs per game retained
C3's 9000-frame 4de78425 and CB's 3000-frame db892c4b (Node startup included):
C3 baseline **13.9944 / 14.4311 / 14.7316 / 14.0946 / 14.8459 s**;
new **13.7825 / 13.8479 / 13.9180 / 13.8831 / 14.5064 s**. Median **14.4311 -> 13.8831 (-3.80%)**.
CB baseline **3.0045 / 2.8700 / 2.8992 / 2.9060 / 2.9488 s**;
new **2.9134 / 2.8574 / 2.8699 / 2.8133 / 2.8780 s**. Median **2.9060 -> 2.8699 (-1.24%)**.
The new build is faster in each of the five pairs for each game. Ranges still overlap and
host load changes; these bounded JS samples are not a general FPS or console-performance
claim. Absolute times must not be compared with earlier sessions. Raw timings/load and source
hashes are in `out/_sample_inputs/{bench.json,validated-sources.json}`; hashes stayed unchanged.
Some sampled inputs still cross redundant result slots, and an opaque child's
returned load is not replaced just because its pointer provenance is known. Next: eliminate
redundant transport of already-known values with explicit boundary proofs; general changed-
pointer continuations, loops, ABI/stack recovery and complete state removal remain open.

**2026-10-01: Checked loaded pointers cross recovered Haxe signatures (ADR-0044).**
`ScalarRead` tracks each immutable read's source range, width/signedness and preceding
may-writes. Entry validates a plain RAM/scratchpad source before sampling its pointer and
recursively constructing dependent spans. Earlier writes must be statically disjoint or
pass physical alias exclusions; known overlap rejects the helper. Later writes can alias
the source because actual helper loads remain ordered. Invalid/unaligned sources propagate
invalid spans without reads. Final guards precede guest effects; failure executes the entire
original body, with no speculative stores or device reads.

`ScalarCall` imports source views and exact read versions through nested calls, including
returned pointers unused as addresses in the child. Each call owns fresh provenance; its
prefix includes caller writes and only child writes preceding the particular load. Return
words carry this metadata directly, without additional SSA copies. Borrowed adapters exclude
loaded views. All metadata is build-time; there is no new runtime state, allocation, forced
inline, worker, JIT or game-specific rule. Existing event/deadline/entry bounds remain.

Full helpers increase **C3 116 -> 138; CB 138 -> 163**, adding **8/2 ordinary helper-to-helper
calls**. Every previous helper body is byte-identical. ES6 JS sizes are C3 **25,232,922 ->
25,270,329 (+37,407 bytes)** and CB **23,916,235 -> 23,970,037 (+53,802 bytes)**. Baselines were
rebuilt with the same runtime/common flags and match the preceding validated JS hashes.
Both baseline/new builds retain their 20k digests. Source hashes and coverage are saved in
`out/_loaded_pointers/{validated-sources.json,coverage.json}`.

`ScalarPointers` executes 26 synthetic programs and probes source/target guards: chains,
affine/wrapped pointers, signed/narrow reads, exact call versions, caller/child/nested write
prefixes, later writes, conditional paths, every public root entry, events/cycle wrap and
suspension mutations. Physical mirrors and FIFO source/target checks exercise fallback.
One initial extended fixture changed a pointer's low byte before another wide load; both
reference/optimized agreed within each target but differed across targets due to the existing
unsupported misaligned-wide-access behavior. That fixture now keeps wide guest pointers
aligned; separate guard-only tests retain invalid source/intermediate alignment coverage.
No runtime alignment behavior changed. `ScalarCompose` now admits its returned-pointer case
and exercises its nonzero observation horizon. The other 52 JS groups retain their digests.
Acceptance (`out/_loaded_pointers/{gate-complete,cross-final,cross-pointers-final,check,validation}.log`):
```
./scripts/test.sh
all 61178 checks passed
conformance: 54 test(s) x JS
ok ScalarPointers 30d209bf values=1208663
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarPointers ScalarCompose
# Compose passed; this run exposed the unaligned pointer fixture described above.
ok ScalarCompose 9868486c values=2768992
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarPointers  # corrected aligned fixture
ok ScalarPointers 30d209bf values=1208663
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_loaded_pointers/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 pointers: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb pointers: frames=20000 digest=a9864f26
```
Only small conformance programs were compiled for C++; no game C++ build was run.
After all builds/tests/validation finished, five alternating timing pairs per game retained
C3's 9000-frame 4de78425 and CB's 3000-frame db892c4b (Node startup included):
C3 baseline **19.3329 / 21.3130 / 21.2997 / 23.2679 / 22.1492 s**;
new **21.8567 / 20.7596 / 21.9422 / 21.5886 / 20.5133 s**. Median **21.3130 -> 21.5886 (+1.29%)**.
CB baseline **4.0445 / 3.9294 / 4.0312 / 4.7207 / 3.9117 s**;
new **4.1408 / 4.4643 / 3.9438 / 4.1800 / 3.8544 s**. Median **4.0312 -> 4.1408 (+2.72%)**.
Both ranges overlap and pair ordering reverses; there is no established speed gain. The
sample medians increased, and the extra preflight/duplicate-read cost needs further work.
Raw timings/load are in `out/_loaded_pointers/bench.json`; validated JS hashes stayed unchanged
through the benchmark. Next: reduce that entry cost while preserving the dependent-read proof.
General changed-pointer continuations, loops, larger ABI signatures and stack-object/escape
recovery remain open; this stage does not remove all CpuState boundaries.

**2026-10-01: Optimizer settings rechecked at the owner's request.** All 16 build-entry HXML
files inherit `-D analyzer-optimize` and `-dce full` from `build/common.hxml`; all JS entries
retain `-D js-es=6`. These settings were already enabled, so no additional flag change or
performance gain is claimed. Fresh pinned-toolchain JS verification:
```
haxe build/js-demo.hxml && node out/_demo/js/demo.js --headless-hash 300
[info] frames=300 digest=329de455
./scripts/check.sh
check.sh: clean
git diff --check  # exit 0
```
C++ settings were inspected; C++ was not rebuilt for this request. Loaded-pointer recovery
remains work in progress and is not covered by this demo verification.

**2026-10-01: Precise child writes and physical alias guards preserve saved values (ADR-0044).**
`ScalarMemory.stores` records every possible byte write, including conditional and translated
child effects, without filling gaps. Same-view disjoint writes preserve facts. Composed call
trees can retain conditional saved-value facts across other views; using one requests an
entry exclusion against every possibly clobbering range. CFG joins union the exclusions from
all predecessor paths. No ABI rule makes stack bytes private, and every guest store remains.
Child alias preconditions translate into the parent; known overlap rejects composition.

`Memory.spansDisjoint` compares already validated arena positions, so RAM/KSEG mirrors cannot
hide an alias. All validity/alignment/exclusion checks precede guest effects; any failure uses
the complete original body. Borrowed adapters use the same proof with input-span offsets,
including after suspension changes a formerly disjoint pointer into an alias. This is a small
ordinary runtime method, without forced inline, allocation or a backend-specific operation.
Equivalent adjacent/overlapping exclusions merge on either side; gaps never merge. One real
saved-register/three-store check shrinks from six calls to one. More than 16 resulting checks
rejects the helper rather than dropping a condition. Existing event/deadline bounds remain.

Current generated full helpers: **C3 113 -> 116; CB 124 -> 138**. All previous helper bodies
remain byte-identical. The new helpers add **3/14 ordinary helper-to-helper calls** without
intermediate CpuState publication. CB's last additional helper becomes eligible after guard
coalescing brings it within the proof budget. Final ES6 sizes: C3 **25,226,928 -> 25,232,922
(+5,994 bytes)**; CB **23,892,516 -> 23,916,235 (+23,719 bytes)**. No game-specific rules,
workers, JIT or C++ game builds were added. Both rebuilt baselines match the preceding stage's
validated JS hashes. Final manifests/coverage are in `out/_call_writes`.

`ScalarCompose` now compares 36 programs, including holes/adjacent/partial clobbers, translated
arguments, nested frames, conditional stores, path-specific exclusions, a child guard becoming
a known overlap, borrowed entry, pointer mutation during suspension, and FIFO fallback after
a preceding write. It retains all public entries, event offsets, cycle wrapping and existing
unwind tests. `SpanAlias` checks 51,328 physical-range results, including coalesced widths,
against explicit reference positions. A final 1,024-placement tool fixture proves that merging
the six-condition conjunction retains exactly its original truth value. The other 51 existing
JS conformance digests remain unchanged. Generated C++ inspection confirms validity checks
precede arena-index conversion in the tested ordinary and borrowed entries.
Acceptance (`out/_call_writes/{gate-final,tool-final,cross-final,check-final,validation,validation-final}.log`):
```
./scripts/test.sh
all 60021 checks passed
conformance: 53 test(s) x JS
ok ScalarCompose 73a38c40 values=2760016
ok SpanAlias 2429c7a5 values=51328
test.sh: JS-only gate passed — 329de455
haxe build/tests-tool.hxml  # final additional conjunction-equivalence fixture
all 61045 checks passed
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCompose SpanAlias
ok ScalarCompose 73a38c40 values=2760016
ok SpanAlias 2429c7a5 values=51328
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_call_writes/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 writes: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb writes: frames=20000 digest=a9864f26
python3 out/_call_writes/ValidateFinal.py  # final coalesced guards; unchanged baselines
c3 merged: frames=20000 digest=36dcd8ee
cb merged: frames=20000 digest=a9864f26
```
After all builds/tests/validation finished, five alternating timing pairs per game retained
C3's 9000-frame 4de78425 and CB's 3000-frame db892c4b (Node startup included):
C3 baseline **19.7282 / 19.8677 / 19.3443 / 19.2554 / 19.9124 s**;
new **19.5714 / 19.3347 / 19.7159 / 19.2827 / 19.6331 s**. Median **19.7282 -> 19.5714 (-0.8%)**.
CB baseline **4.0471 / 4.0057 / 3.9038 / 3.9179 / 3.8849 s**;
new **3.9196 / 3.8978 / 3.9602 / 3.9574 / 3.8976 s**. Median **3.9179 -> 3.9196 (+0.05%)**.
Ranges overlap; no repeatable game-speed improvement is established. Raw samples/load and
source hashes remain in `out/_call_writes/{bench.json,validated-sources.json}`. The result is
verified recovery of more ordinary calls, not a claim that CpuState costs have disappeared.
Next: measure surviving entry costs and recover loaded-address inputs with correct continuation
state; general loops, ABI/stack-object recovery and complete CpuState removal remain open.

**2026-10-01: Bounded direct call trees use ordinary recovered Haxe signatures (ADR-0044).**
`ScalarCall` composes resident, unhooked direct JAL callees as `_value` calls with explicit
arguments/results, without expanding their bodies or publishing intermediate CpuState.
Link writes precede delay slots; SSA must prove the sampled and final return address restored.
CFG edges carry immutable memory snapshots, and joins intersect exact byte/value facts from
every predecessor. This proves some saved stack words across read-only calls and branches;
all guest stores remain observable. Child stores conservatively discard caller memory facts.
Child spans translate into the caller's complete preflight, including alignment and anchors.
Every secondary result/accounting word is captured before another helper can overwrite it.
Pure-body normalization preserves ABI member names while renaming local SSA values.

Whole-call bounds must fit all three 10-bit accounting lanes. Entry requires no existing
unwind and enough time to finish strictly before the next event/cooperative deadline; stress
yielding, interior entries and failed memory proofs use the original frames/checkpoints.
Recursive, unknown, hooked and genuinely loaded-address calls remain ineligible. The local
32-instruction/six-parameter limits remain. No runtime allocation, worker, JIT, game-specific
rule, forced inline or game C++ build was added. Scalar caches reset when hooks/output change.

Real-game coverage increases **CB 123 -> 124** full helpers; the new `f_80027a74_value` calls
the existing `f_80012ffc_value`. CB ES6 grows **23,891,220 -> 23,892,516 (+1,296 bytes)**.
All previous helper bodies stay identical. **C3 remains 113 helpers and 25,226,928 bytes**;
its rebuilt JS is byte-identical to the preceding validated 20k build (36dcd8ee). Both baseline
bundles match the prior stage's hashes. Final CLI regeneration also reproduces both generated
Haxe sets byte for byte. The 39 survey candidates were possibilities, not proved eligibility;
conservative memory clobbers and signature limits still exclude most ordinary callers.

`ScalarCompose` covers 19 generated programs, all public root entries, aliasing/mirror/scratch
memory, nested/conditional calls, multiple outputs, cooperative mutation, each event offset
through the call bound, cycle wrap, unwind and FIFO order. Its initial cross-target mismatch
came solely from two continuation fixtures dereferencing the harness's unaligned default v0;
they now supply valid live pointers. No runtime alignment behavior was changed or hidden:
the existing unsupported-wide-access issue remains in Blockers. All previous **51 JS group
digests are unchanged**. All **16 build-entry HXMLs** inherit analyzer-optimize/full DCE and
JS retains ES6; these flags were already active in the measured game baselines.
Acceptance (`out/_scalar_profile/{gate-final,cross-final,check,validation,coverage,flags}.log`):
```
./scripts/test.sh
all 59911 checks passed
conformance: 52 test(s) x JS
ok ScalarCompose b21f9b20 values=1468313
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCompose ScalarResults
ok ScalarCompose b21f9b20 values=1468313
ok ScalarResults 9c6ba8fc values=51714
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_scalar_profile/Validate.py
cb baseline: frames=20000 digest=a9864f26
cb compose: frames=20000 digest=a9864f26
```
Prior-stage Node profiles sampled borrowed adapters for only 8,001/1,208 us in C3 and zero
in CB. Generated bodies dominate alongside GPU work, but sampling does not isolate CpuState
assignments or prove that their cost disappeared. Profiles and corrected class-aware summaries
remain in `out/_scalar_profile`; profiled durations are not speed measurements.
After all builds/tests/validation finished, five alternating CB timing pairs (3000 frames,
Node startup included) retained db892c4b. Baseline **4.7599 / 4.8648 / 5.2633 / 4.6794 / 4.3753 s**;
composed **4.5651 / 4.8683 / 4.9419 / 4.8988 / 4.2783 s**. Medians **4.7599 -> 4.8683 s (+2.3%)**;
ranges overlap and host load varies, so no repeatable speed improvement is established.
C3 timing was not repeated for a byte-identical bundle. Raw samples/load and validated source
hashes are saved in `out/_scalar_profile/{bench.json,validated-sources.json}`.
Next: recover precise child memory effects and saved-value preservation before widening
composed signatures; general loop/ABI/stack recovery and complete CpuState removal remain open.

**2026-10-01: Affine call arguments can reuse checked spans on other registers (ADR-0044).**
`CallAliases` proves exact wrapped relations between immutable GPR values inside each call's
block. It starts fresh at every public entry, clears facts at observable effects, invalidates
link writes before the delay slot, and snapshots before the callee runs. Copies retain their
old value when the source changes. `ScalarBorrow` still prefers same-register coverage, then
tries donors in register order. All callee bytes/anchors must fit; a nonzero shift must also
keep its intermediate pointer within the donor range. Caller rebasing occurs only in the valid
arm of `Memory.spanOk`, otherwise passing none. The shared adapter retains alignment/event/
cooperative guards and full-entry fallback. Donor registers enter post-slot span liveness so
last-use changes, previous calls and resumptions refresh/step the correct span. No new runtime
state, allocation, guest checkpoint, worker, JIT, inline expansion or game-specific rule.

Generation matches the read-only survey: **C3 187 -> 200 borrowed call sites, CB 0 -> 2**;
one new shifted call per game. Full DCE retains **10/2 adapters** from 63/37 declarations.
All **113/123 full state-free helper bodies remain byte-identical**, including signatures.
ES6 JS grows C3 **25,224,926 -> 25,226,928 (+2,002 bytes)** and CB
**23,890,302 -> 23,891,220 (+918 bytes)**. The expanded 32-program `ScalarBorrow` fixture
compares every public entry, old/new source versions, positive/negative shifts, body/slot
copies, donor refresh/steps, two shifted spans, effects, suspensions and due events.
Tool tests check symbolic equalities against concrete edge-word executions and link timing.
The generated C++ keeps positive/negative donor pointer arithmetic inside the validity arm.

Rechecked the owner's optimizer request: all **16 build-entry HXML files** include common.hxml,
which enables **analyzer-optimize and full DCE**; all JS entries retain **js-es=6**. Both flags
were already active in the previous game builds, so this is not an additional flag speed gain.
The current stage was built/tested with these same settings. All 50 other JS conformance
groups retain their preceding digests; ScalarBorrow expands to efe0d707/1229039.
Acceptance (`out/_scalar_alias/{gate,cross,check,validation,flags}.log`):
```
./scripts/test.sh
all 59782 checks passed
conformance: 51 test(s) x JS
ok ScalarBorrow efe0d707 values=1229039
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarBorrow ScalarCalls Regions Yielding
ok ScalarBorrow efe0d707 values=1229039
ok ScalarCalls ff62afe6 values=96344
ok Regions 9420e9fd values=38333
ok Yielding f730beee values=7906
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_scalar_alias/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 aliases: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb aliases: frames=20000 digest=a9864f26
```
Both baselines and new builds use the same current runtime. C++ remained conformance-only.
After builds and validation finished, five alternating pairs per game retained all timing
digests (C3 9000: 4de78425, CB 3000: db892c4b); Node startup is included:
C3 first round baseline 21.8249 / 20.7892 / 19.0984 / 19.6112 / 20.5460 s;
new 20.6140 / 21.9976 / 24.3878 / 22.0609 / 23.0474 s. Medians **20.5460 -> 22.0609 (+7.4%)**.
CB first round baseline 4.0059 / 4.2779 / 4.3802 / 4.1405 / 3.9411 s;
new 3.8258 / 4.0560 / 4.2307 / 4.2264 / 4.1030 s. Medians **4.1405 -> 4.1030 (-0.9%)**.
C3 reverse-order repeat baseline 21.5282 / 20.2897 / 20.5434 / 19.2154 / 19.5372 s;
new 21.8299 / 21.5842 / 20.1877 / 20.4192 / 20.3915 s. Medians **20.2897 -> 20.4192 (+0.6%)**.
C3's first +7.4% median increase prompted the second five-pair run with reversed order. The
repeat is +0.6%; ranges overlap and host load changes. No repeatable game-speed improvement
is established, and the first slower run is retained rather than discarded. Further profiling
is needed before expanding this path on performance grounds. All four JS hashes still match
`out/_scalar_alias/validated-sources.json`; raw samples/load, coverage, generated diffs and
surveys live alongside it. Experimental `--value-cfg` remains off.
Next: profile recovered-call entry/state costs before widening coverage; general ABI/stack
recovery and complete CpuState removal remain open.

**2026-10-01: Borrowed-span entry code is shared once per callee (ADR-0044).**
A read-only boundary-liveness survey found no omittable GPR results among the 187 currently
borrowable C3 calls (CB has none). Instead of adding an unused memory-projection path, this
stage removes the concrete repetition from the preceding extension. `ScalarEntry` emits one
`_withSpans` adapter per eligible memory callee. Callers pass current CpuState and unshifted
existing spans; the adapter owns the original entry guards, span rebasing, result publication
and accounting. It calls the original full entry on a failed guard, or the unchanged state-free
`_value` helper otherwise. It adds no guest checkpoint, dispatch entry, runtime storage or
allocation. The ordinary caller still owns after-call unwind/resumption and span refresh.
Pure direct calls and ordinary scalar entries share the same build-time guard/charge emitter.
Deduplicated adapters forward typed spans to the same owner as the entry and value helper.
Constant-address callees have no borrowable register and emit no such adapter. The initial JS
gate caught an attempted `ctx.zero` in their unused adapters; this was fixed in the generator,
covered by a tool assertion and regenerated before the successful gate below.

C3's **187 calls now use 5 shared adapters**. The generator emits 63 declarations, of which
full DCE keeps those five. All **113/123 full state-free helper bodies remain byte-identical**.
C3 ES6 JS shrinks **25,279,992 -> 25,224,926 bytes (-55,066)**: about 90% of the preceding
borrow extension's 61,422-byte growth is recovered; net +6,356 bytes versus pre-borrowing.
CB emits 37 unused adapter declarations but DCE removes all of them; its 23,890,302-byte JS
is byte-identical to the previous validated build. This is code sharing/size evidence, not
an established game-speed gain. No forced inline, worker, JIT or game-specific rule was added.
`ScalarBorrow` retains its 16 programs/all public entries and adds forwarded-adapter tests
with aliased/distinct spans and invalid spans. Tool tests enforce raw argument forwarding,
centralized guards, constant exclusion and rebasing behind the guard. Its expanded digest is
b6db50c1/649002; all other 50 JS groups retain their preceding digests. Generated C++ for the
positive-offset fixture keeps pointer arithmetic inside the successful guarded arm.
Acceptance (`out/_scalar_projection/{gate,cross,final-check,validation}.log`; pinned common/js-es=6):
```
./scripts/test.sh
all 59671 checks passed
conformance: 51 test(s) x JS
ok ScalarBorrow b6db50c1 values=649002
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarBorrow ScalarCalls ScalarMemoryCfg Yielding
ok ScalarBorrow b6db50c1 values=649002
ok ScalarCalls ff62afe6 values=96344
ok ScalarMemoryCfg bac8188c values=1682130
ok Yielding f730beee values=7906
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_scalar_projection/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 adapters: frames=20000 digest=36dcd8ee
```
C3 baseline/new were built against the same current runtime. CB's identical binary matches the
prior 20k-validated manifest (a9864f26) and was not run/timed again. C++ remained conformance-only.
After builds and validation finished, five alternating C3 pairs (9000 frames, Node startup
included) retained every 4de78425 digest:
C3 baseline 20.0777 / 19.6209 / 19.7136 / 19.4660 / 19.3961 s;
new 20.1425 / 19.1726 / 19.3469 / 19.8729 / 19.5475 s. Medians **19.6209 -> 19.5475 (-0.4%)**.
Ranges overlap; no repeatable speed change is established. Binary hashes still match
`out/_scalar_projection/validated-sources.json`; raw samples/load, source coverage and the
projection survey live in the same directory. Experimental `--value-cfg` remains off.
Next: investigate affine argument aliases at calls so a copied pointer can reuse an existing
span on another register; general ABI/stack recovery and complete CpuState removal remain open.

**2026-10-01: Direct scalar calls can borrow a caller's checked memory spans (ADR-0044).**
`ScalarBorrow` proves that every callee anchor/access fits an existing function span on the same
incoming GPR. No new caller span or range widening is introduced. Borrowed bases become liveness
uses after the delay slot and before the callee's writes, so body/slot changes, previous calls,
joins, loop paths and resumptions retain current pointers even without a later caller load.
The fast arm keeps runtime span validity/alignment and the pure-call due-event/cooperative
entry guards. Any failure invokes the full callee wrapper with its original checkpoint and
preflight. All derived span arguments are rebased only inside that arm via `Memory.spanOffset`;
the operation goes through the existing shim ABI and accesses no guest bytes. Effects may alias,
all GPR results and path charges remain visible, and after-call unwind/span refresh is unchanged.
Hooks, unknown residency, uncovered/constant spans and indirect/tail/relocatable callers keep
their existing paths. No new CpuState field, runtime allocation, worker, JIT or forced inline.

A read-only survey found 187 eligible calls out of 338 memory-helper calls in C3 and none out
of 266 in CB. Final generation emits exactly **187 borrowed call sites / 236 rebased arguments**
in eight C3 shard files. Full helper coverage remains 113/123. Full-DCE ES6 JS grows
**25,218,570 -> 25,279,992 bytes (+61,422)**. CB's 38 Haxe files and 23,890,302-byte JS are
byte-identical to the preceding validated build: no CB speed/coverage gain is claimed.
`ScalarBorrow` conformance compares 16 programs at every public caller entry, including
positive/negative offsets, last-use pointer refreshes/steps, prior unknown calls, callee writes,
aliased spans, CFG stores, partial coverage, constants, unknown targets, joins and loops.
Suspension changes pointers/RAM; due events halt before callee effects; FIFO fallback preserves
read order. Tool checks cover alignment, byte-exact coverage, wrapped anchors, hooks and relocation.
All 50 pre-existing JS conformance digests remain unchanged.
Acceptance (`out/_scalar_borrow/{gate,cross,check,validation}.log`; pinned common flags/js-es=6):
```
./scripts/test.sh
all 59655 checks passed
conformance: 51 test(s) x JS
ok ScalarBorrow 12845cf5 values=648458
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarBorrow ScalarCalls Regions Yielding
ok ScalarBorrow 12845cf5 values=648458
ok ScalarCalls ff62afe6 values=96344
ok Regions 9420e9fd values=38333
ok Yielding f730beee values=7906
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_scalar_borrow/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 borrow: frames=20000 digest=36dcd8ee
```
C3 baseline/new use the same current runtime. CB's byte identity was checked against the prior
20k-validated JS manifest (a9864f26); its identical binary was not timed or run again. C++ stayed
limited to conformance. After builds/checks/validation finished, five alternating C3 timing
pairs (9000 frames, Node startup included) all retained 4de78425:
C3 baseline 20.4429 / 19.3973 / 20.4183 / 21.7760 / 22.4339 s;
new 20.0693 / 19.5983 / 22.3338 / 23.4779 / 19.9603 s. Medians **20.4429 -> 20.0693 (-1.8%)**.
Ranges overlap widely and host load changes; no repeatable game-speed improvement is established.
This is broader use of explicit memory signatures, with a measured code-size cost. All four JS
hashes still match `out/_scalar_borrow/validated-sources.json`; raw samples/load, source coverage
and survey counts are in that directory. Experimental `--value-cfg` remains off.
Next: reduce duplicated entry guards and recover caller-specific memory results using the
new complete-span proof; general ABI/stack recovery and complete CpuState removal remain open.

**2026-10-01: Scalar CFG predicates, phi selections and path charges are simplified (ADR-0044).**
`ScalarPredicates` shares comparisons by immutable SSA inputs and proves Boolean identities:
complementary paths recover their incoming reach, repeated tests share a capture, and known
phi arms/equal affine values collapse. Separate memory versions remain separate predicates;
a store/reload cannot reuse an old condition. `ScalarAccounting` aggregates original packed
block costs by reach, combines equal-cost disjoint paths and selects complementary costs.
Equal results/effects/costs can remove a branch parameter entirely. Entry-unreachable arms
can disappear from the helper but remain valid public interior entries in the original body.
No runtime cache, allocation, new ABI storage, checkpoint change, forced inline, worker or JIT.
The normal scalar pass retains its checked-memory restrictions and size/input bounds.

C3 retains 113 full helpers; 21 changed bodies shrink **23,988 -> 18,893 bytes**, locals 471->342,
ternaries 136->99. CB retains 123 helpers; 22 changed bodies shrink **25,902 -> 21,903 bytes**,
locals 497->394, ternaries 150->124. Every full helper was audited for absence of CpuState/ctx.
Full-DCE ES6 JS shrinks **25,220,891 -> 25,218,570 (-2,321)** / **23,892,103 -> 23,890,302 (-1,801)**
bytes. These are static reductions, not a corresponding percentage improvement in game speed.
Tool coverage adds complete truth tables for Boolean rewrites and checks SSA/cost identities.
ScalarCfg now has 19 programs, including equal-cost constant returns and repeated comparisons;
ScalarMemoryCfg has 22, adding nested partial joins and changed conditions after store/reload.
All public entries, counters, memory effects and cooperative resumes retain reference behavior.
The other 48 JS conformance digests are unchanged.
Acceptance (`out/_scalar_conditions/{gate,cross,check,validation}.log`; pinned common flags/js-es=6):
```
./scripts/test.sh
all 59573 checks passed
conformance: 50 test(s) x JS
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCfg ScalarMemoryCfg ScalarCalls ScalarResults
ok ScalarCfg 750ee5b6 values=192290
ok ScalarMemoryCfg bac8188c values=1682130
ok ScalarCalls ff62afe6 values=96344
ok ScalarResults 9c6ba8fc values=51714
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_scalar_conditions/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 conditions: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb conditions: frames=20000 digest=a9864f26
```
Both game baselines were rebuilt against the same current runtime; C++ remained limited to
conformance. After builds/checks/validation ended, five alternating timing pairs (Node startup
included) retained every digest: C3 9000 frames 4de78425, CB 3000 frames db892c4b.
C3 baseline 23.3740 / 22.4423 / 21.7183 / 22.7962 / 23.4572 s;
new 22.5613 / 22.3550 / 21.3349 / 22.3888 / 21.5035 s. Medians **22.7962 -> 22.3550 (-1.9%)**.
CB baseline 4.7543 / 4.3204 / 4.3021 / 4.7036 / 5.9066 s;
new 4.1694 / 4.3767 / 4.2509 / 4.2093 / 4.6388 s. Medians **4.7036 -> 4.2509 (-9.6%)**.
Ranges overlap and host load varies substantially; these samples favor the new version but
do not establish a repeatable speed gain. All four JS hashes still match the validation manifest.
Raw samples/load averages, coverage and exact binaries: `out/_scalar_conditions/bench.json`,
`coverage.json`, `validated-sources.json`. Experimental `--value-cfg` remains off.
Next: reduce checked-span and entry-adapter overhead using caller proofs before expanding to
loaded addresses/loops; general ABI/stack recovery and complete CpuState removal remain open.

**2026-10-01: Acyclic scalar signatures now include checked memory effects (ADR-0044).**
`ScalarCfg` lifts affine plain-memory accesses under each block's reach predicate: loads use
conditional expressions, stores explicit guarded statements. Only pure arithmetic is eager.
Delay-slot stores preserve the already-captured branch decision, and selected effects retain
their original order through joins and multiple exits. All possible spans are preflighted
before the first effect, even if a path is not taken; a bad span falls back to the entire
original body. Differing pointer phis, actual loaded addresses, known MMIO, incompatible
alignment, calls, coprocessors, HI/LO, traps, changed return addresses and internal/back-edge
pumps retain their original paths. Memory facts are cleared at each CFG block boundary,
since topological adjacency is not an execution proof. In-block forwarding is unchanged.
The adapter nests preflight inside `entry == 0`; public interior entries bypass both helper
and preflight. Void setters also return original path accounting. The 32-instruction and
six-parameter limits, pure-only projections/pooling and whole-pass `--no-scalar` remain.
No runtime state/heap allocation, forced inline, worker, JIT or game-specific rules were added.
Full helper coverage: C3 **99 -> 113**, CB **106 -> 123**, adding 14/17 memory CFG methods.
Every full helper body/signature was audited for absence of CpuState/ctx. Full-DCE ES6 JS
grows 25,195,938 -> 25,220,891 bytes (+24,953) / 23,861,618 -> 23,892,103 (+30,485).
`ScalarMemoryCfg` runs 20 programs at every public block entry: conditional effects, aliasing
arms, old load values, partial widths, equal/different pointer phis, loaded conditions,
branch/return delay stores, nested diamonds, early returns, same-target edges, untaken FIFO
paths and reads into zero, RAM/scratchpad aliases, mirror crossings, resumption changing
registers/RAM and a due event before the first store. Two programs intentionally retain fallback.
Acceptance (`out/_memory_cfg/{gate,cross,check,validation}.log`; pinned common flags/js-es=6):
```
./scripts/test.sh
all 56988 checks passed
conformance: 50 test(s) x JS
ok ScalarMemoryCfg 995aef4a values=1227818
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarMemoryCfg ScalarCfg ScalarEffects ScalarResults
ok ScalarMemoryCfg 995aef4a values=1227818
ok ScalarCfg 2325fb2e values=159054
ok ScalarEffects 3cfb6f71 values=1136641
ok ScalarResults 9c6ba8fc values=51714
conformance: all targets agree
./scripts/check.sh
check.sh: clean
python3 out/_memory_cfg/Validate.py
c3 baseline: frames=20000 digest=36dcd8ee
c3 cfg: frames=20000 digest=36dcd8ee
cb baseline: frames=20000 digest=a9864f26
cb cfg: frames=20000 digest=a9864f26
```
All 49 pre-existing JS fixture digests are unchanged. Both game baselines were rebuilt with
the same current runtime; C++ was limited to conformance. After builds/checks/validation
completed, five alternating timing pairs (Node startup included) preserved every digest:
C3 baseline 21.4184 / 20.7346 / 20.4455 / 20.6847 / 20.6512 s;
new 21.8093 / 20.7605 / 20.3223 / 21.0797 / 21.5923 s. Medians **20.6847 -> 21.0797 (+1.9%)**.
CB baseline 4.9558 / 4.5227 / 4.2841 / 4.3747 / 4.2893 s;
new 4.5132 / 4.3387 / 4.2635 / 4.2924 / 4.3201 s. Medians **4.3747 -> 4.3201 (-1.2%)**.
Ranges overlap and load varies; no game speed gain is established. The C3 samples lean slower.
This extends the normal scalar pass's source/signature recovery, not a performance milestone.
Raw samples, source coverage and exact validated hashes: `out/_memory_cfg/bench.json`,
`coverage.json`, `validated-sources.json`. Experimental `--value-cfg` remains off and independent.
Next: simplify reach/phi and packed-accounting expressions and reduce guard/call overhead
before expanding to loaded addresses/loops; general ABI/stack recovery and CpuState removal
remain unfinished.

**2026-10-01: Checked scalar helpers reuse proved memory values (ADR-0044).**
`ScalarMemoryValues` tracks byte ranges and immutable values at generation time. Fully covered
loads reuse a preceding load/store value with exact byte/halfword sign or zero extension.
Repeated equal reads share a result ABI word. Writes invalidate overlapping values in their
own contiguous checked span and every value in other spans, including different inputs or
separate spans that map to the same RAM mirror. All stores remain emitted. Every original
access still enters preflight, including eliminated/zero-target reads; failed checks retain
the complete original MMIO stream. No runtime cache, allocation, worker, inline expansion,
guest accounting change or game-specific rule was added. A forwarded word may recover an
incoming pointer for subsequent checked accesses; a truly loaded or alias-invalidated pointer
still rejects signature recovery.
`ScalarEffects` now compares 32 programs over signed edges, partial/disjoint writes, mixed
widths, repeated reads, aliased spans, 2 MB mirrors, recovered pointers, FIFO fallback and
cooperative resumes. JS passed first; C++ exposed an unsigned intermediate from nested `>>>`
turning sign extension into a logical shift. Arithmetic extraction followed by truncation
fixes this shape; minimal reproduction and upstream limitation are recorded as defect 11 below.
Acceptance (`out/_memory_values/{final-gate,final-cross,cross,check}.log`):
```
./scripts/test.sh
all 56848 checks passed
conformance: 49 test(s) x JS
ok ScalarEffects 3cfb6f71 values=1136641
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarEffects
ok ScalarEffects 3cfb6f71 values=1136641
conformance: all targets agree
./scripts/check.sh
check.sh: clean
```
The preceding three-group cross-target run passed ScalarResults 9c6ba8fc and
ScalarMemoryCodegen 852cd0fd, but failed ScalarEffects before the signed-extraction fix.
The final focused rerun above passes the repaired emitter. All 48 unchanged JS fixtures
retain their prior digests. Final CLI regeneration of both games produces **byte-identical**
Haxe: C3 40 files / 99 full helpers, CB 38 files / 106 helpers (`final-source-compare.log`).
None of their currently eligible small helpers contains a newly reusable memory access;
no game speed gain or increased game coverage is claimed, and no timing rerun is useful for
identical generated input. This is generic optimization coverage proved on synthetic programs.
Next: recover effectful functions across control flow with path/observation proofs so explicit
values can cover more real code; general ABI/stack recovery and CpuState removal remain open.

**2026-10-01: Analyzer optimization and full DCE share one build configuration.**
`build/common.hxml` now supplies both `-D analyzer-optimize` and `-dce full`. Game/demo builds
and benchmarks already used both; their redundant DCE flags were removed. Conformance and the
remaining compiler spikes now inherit full DCE too. The `fnptr` and `ifdrop` spikes also include
the common configuration, completing coverage of every build entry point. JavaScript retains
`-D js-es=6`. This standardizes test/shipping flags; it is not a new game-performance gain.
All 49 JS conformance digests match the preceding run, and the freshly rebuilt demo JS matches
its pre-change SHA-256 byte for byte. Game C++ generation remains deferred; only the small
compiler spikes and three focused conformance groups used C++.
Acceptance (`out/_optimizer_flags/{js-gate,spike,cross,check}.log`):
```
./scripts/test.sh
all 56668 checks passed
conformance: 49 test(s) x JS
test.sh: JS-only gate passed — 329de455
./scripts/spike.sh
spike.sh: clean
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarEffects Dispatch GteOps
ok ScalarEffects af21ba89 values=351863
ok Dispatch c98a0969 values=602
ok GteOps de71ee8a values=5440
conformance: all targets agree
./scripts/check.sh
check.sh: clean
shasum -a 256 -c out/_optimizer_flags/demo-before.sha256
out/_demo/js/demo.js: OK
```
Next: continue reducing recovered-signature guard/call overhead and redundant memory work.

**2026-10-01: Scalar signatures include ordered RAM writes and multiple memory parameters (ADR-0044).**
`ScalarGraph` now retains plain-memory writes as ordered effect roots, so a store's inputs enter
the recovered signature even when no GPR result uses them. `ScalarMemory` groups affine incoming
or constant addresses into checked spans; multiple spans can alias through equal pointers,
RAM mirrors or scratchpad aliases. All spans are preflighted before any guest read/write. If one
fails, the full original body executes, preserving MMIO and never repeating a speculative RAM
update. Return loads preceding an aliasing store are materialized before the store, rather than
being delayed to the return expression. Pure setters return `Void`, with no dummy result ABI.
Input/output GPR recovery, entry/resume checkpoints and original accounting remain in place.
Memory parameters count toward the six-parameter limit; functions remain bounded linear leaves
of at most 32 instructions. No memory alias is assumed absent, no guest stack store is privatized,
and no runtime field, allocation, forced inline, worker or game-specific rule was added.
A diagnostic survey showed that memory effects, rather than large pure arithmetic bodies, excluded
most candidate functions. Full helper counts (excluding shared caller projections) grow from
30 to 99 in C3 and 32 to 106 in CB: memory helpers 12 -> 81 / 13 -> 87, including 24 / 5 Void
setters. Full-DCE ES6 JS: C3 25,149,781 -> 25,195,938 bytes (+46,157); CB 23,830,171 -> 23,861,618
(+31,447). This is recovered-signature coverage, not a claimed speedup. Existing pure pooling
and caller projections still exclude memory helpers; all such calls retain the callee's adapter.
`--no-scalar` disables them with the other recovered signatures. Experimental `--value-cfg`
remains off by default and is independent of this extension.
Acceptance (`out/_scalar_work/effects-*.log`; pinned common.hxml/analyzer-optimize/js-es=6):
```
./scripts/test.sh
all 56668 checks passed
conformance: 49 test(s) x JS
ok ScalarEffects af21ba89 values=351863
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarEffects ScalarMemoryCodegen ScalarResults Codegen
conformance: all targets agree
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarEffects
ok ScalarEffects af21ba89 values=351863
conformance: all targets agree
node out/_effects_c3/game.js web/boot.exe web/disc.bin --headless-hash 20000
frames=20000 digest=36dcd8ee
```
The initial four-group cross-target run preceded the final odd-span-base fixture; its
ScalarEffects result was d22b00f5 (325223 values). The final standalone run includes that case.
Crash Bash also retains `frames=20000 digest=a9864f26` using verified local media. Game builds and
execution remain JS; C++ is used only for the focused conformance fixtures. `ScalarEffects`
compares all registers/counters and changed memory bytes across 13 programs, signed edge inputs,
aliasing/distinct addresses, RAM/scratchpad mirrors, mirror-boundary fallback, byte/halfword/word
writes, loaded values before swaps, restored stack pointers, MMIO read/write fallback, suspension
changing source RAM, a due entry event and a forwarded Void helper. Tool checks cover the
parameter budget, distant constant spans, known I/O rejection and pure-pool exclusion.
`./scripts/check.sh` reports `check.sh: clean`. After all builds and checks, five paired runs
per game (alternating order, Node startup included) retained every digest:
C3 baseline 21.3722 / 19.2081 / 19.4298 / 19.5789 / 19.6783 s; new 21.8757 / 19.7747 / 19.2232 / 19.9309 / 19.6277 s.
Medians 19.5789 -> 19.7747 s (+1.0%).
CB baseline 4.2013 / 3.9266 / 3.8878 / 4.2369 / 4.0232 s; new 4.0808 / 4.0058 / 4.3752 / 4.4525 / 4.1398 s.
Medians 4.0232 -> 4.1398 s (+2.9%).
Ranges overlap and host load varied; no speed gain is established. These samples lean slower,
so reduced CpuState use must not be advertised as a performance win. The signature extension
is part of the normal scalar pass; further work must address guard/call overhead and redundant
memory computation. `--no-scalar` remains available for the entire recovered-signature pass.
Raw results and runner: `out/_scalar_work/effects-bench.{json,log}`, `EffectsBench.py`.
A source audit confirms all 99 C3 / 106 CB full helper signatures and bodies contain no
CpuState/core.Ctx parameter or `ctx` reference. Their entry adapters still preserve machine state.
Next: derive further computation elimination from explicit memory effects, then broaden signatures
to control flow and loaded addresses with observation/alias proofs. General ABI, stack/data-layout
recovery and whole-program CpuState removal remain unfinished.

**2026-10-01: Opt-in pure CFG local promotion verified; no established speed gain (ADR-0044).**
Experimental `--value-cfg` promotes GPRs across 2–16 pure acyclic blocks (at most 32 instructions), retaining
ordinary Haxe branches, public/interior entry routing and original per-block guest accounting.
All read or possibly written values are initialized from current CpuState; possible writes are
published at every region exit, including dispatcher/loop escapes. The linear value pass can
simplify expressions inside this scope. Calls, memory, coprocessors, HI/LO, possible traps,
`ra` writes/redirected returns and actual IR pumps/back edges reject promotion. Original span
refreshes/steps use the promoted operand at the same position. No value survives an emulated
observation, so a callee's changed register cannot be replaced with a stale local. Existing scalar
helpers and looping-leaf locals keep their previous lowering. No runtime fields, allocation,
worker, JIT, forced inline or game-specific rules were added.
The extension is **off by default**: it increases code size without an established speed gain.
Opt-in selection requires fewer state references than ordinary emission. C3 selects 414 regions and
reduces generated-Haxe GPR references 263,907 -> 263,128 (-779); CB selects 126 regions and
245,646 -> 245,337 (-309). These are small static reductions, not dynamic traffic or speed claims.
Full-DCE ES6 JS grows from 25,149,781 to 25,200,842 bytes (+51,061) for C3, and from 23,830,171
to 23,847,591 (+17,420) for CB. The default and `--no-value-cfg` preserve the linear value pass;
`--no-value-regions` disables both. Final CLI generation verifies all 40 default C3 Haxe
files are byte-identical to the preceding implementation; explicit `--value-cfg` reproduces
all 40 C3 / 38 CB already-tested Haxe files exactly.
Acceptance (gitignored `out/_scalar_work/value-cfg-*.log`; common.hxml/analyzer-optimize/js-es=6):
```
./scripts/test.sh
all 56578 checks passed
conformance: 48 test(s) x JS
ok ValueCfg 80afd5e6 values=596084
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ValueCfg ValueRegions Regions Yielding
ok ValueCfg 80afd5e6 values=596084
ok ValueRegions cdcffb6c values=57121
ok Regions 9420e9fd values=38333
ok Yielding f730beee values=7906
conformance: all targets agree
node out/_valuecfg_c3/game.js web/boot.exe web/disc.bin --headless-hash 20000
frames=20000 digest=36dcd8ee
```
Crash Bash also retains `frames=20000 digest=a9864f26` using its verified local media. Both
previous generated source trees were rebuilt with the same runtime as `out/_values_{c3,cb}/cfg-baseline.js`
and match these 20,000-frame digests, beyond ADR-0029's historical 9,898-frame regression.
The new fixture compares reference, linear-value baseline and CFG promotion at every public
block entry of 23 synthetic programs over signed edges, with joins, call mutation/observations,
stores, span updates, cooperative suspension and due-loop pumps. The negative tool test injects
unknown instructions into IR after discovery, since discovery correctly rejects malformed opcodes
before a CFG can be analyzed. Only small conformance programs used C++; game runs remain JS.
`./scripts/check.sh` reports `check.sh: clean`. After all build/check jobs completed, three paired
runs per game (alternating order, Node startup included) kept every digest. C3 baseline
20.4125 / 21.8341 / 23.2443 s vs opt-in 21.5246 / 21.0755 / 21.9028 s: median 21.8341 -> 21.5246
(-1.4%). CB baseline 4.5243 / 4.1769 / 4.0732 s vs opt-in 4.2729 / 4.4172 / 4.0937 s:
median 4.1769 -> 4.2729 (+2.3%). Both ranges overlap and system load varied; there is no established
speed gain. This is why local promotion remains an experiment rather than a default optimization.
Raw samples/load averages: `out/_scalar_work/value-cfg-bench.{json,log}`, runner `ValueCfgBench.py`.
Next: proof-driven computation/signature elimination before expanding local promotion to effects
and loops. General function signatures, stack/data-layout recovery and CpuState removal remain
unfinished; a lower field-reference count alone is not enough to enable another JS pass.

**2026-10-01: Pure value SSA reconstructs state at internal observation boundaries (ADR-0044).**
`ValueRegion` now lowers pure arithmetic intervals inside ordinary functions, up to 32 body
instructions each. Exact expression/operand versions share values; dead intermediate definitions
are omitted and constants/affine results reconstructed. Used inputs are captured before output
publication, so register swaps work. All changed final GPRs reach CpuState before memory,
coprocessors, HI/LO, possible traps, control flow or a span refresh. No value survives into the
next interval: a callee's changes cannot be overwritten with a stale register copy (ADR-0029).
Existing looping-leaf locals, delay slots, entry/resume IDs, event boundaries and guest costs
remain unchanged. Selection requires fewer GPR field references than the interval's existing
fused emission. `--no-value-regions` isolates this pass independently of whole-function helpers.
No new runtime storage, helper calls, forced inline, allocation, workers or game-specific rules.
Static generated-Haxe GPR references: C3 293,125 -> 263,907 (-29,218, about 10%); CB 276,137 ->
245,646 (-30,491, about 11%). These are unweighted code counts, not measured dynamic traffic.
Full-DCE ES6 JS: C3 25,149,781 bytes (+126,966), CB 23,830,171 (+41,800).
Acceptance (gitignored `out/_scalar_work/values-*.log`; pinned common.hxml/analyzer-optimize/js-es=6):
```
./scripts/test.sh
all 56500 checks passed
conformance: 47 test(s) x JS
ok ValueRegions cdcffb6c values=57121
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ValueRegions Codegen Regions Yielding ScalarCalls ScalarCfg ScalarResults
conformance: all targets agree
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ValueRegions
ok ValueRegions cdcffb6c values=57121
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node out/_values_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
node out/_values_c3/game.js web/boot.exe web/disc.bin --headless-hash 20000
frames=20000 digest=36dcd8ee
```
The seven-group cross-target run preceded the final due-pump fixture (ValueRegions cb1c5154,
57035 values); its final single-group run includes the halt after a reconstructed loop body.
The conformance fixture compares reference, optimized-without-regions and optimized-with-regions
forms, including callback observation traces, stale register outputs, discarded FIFO loads,
function-span resets/steps, signed overflow barriers, public interior entries and suspension.
Crash Bash, using its verified boot executable and local.json disc, retains 3000 db892c4b and
matches its baseline at 20000 a9864f26. Both pre-change generated sources were rebuilt against
the same runtime (`out/_scalar_multi_{c3,cb}/values-baseline.js`); their 20,000-frame digests match
the new builds. The longer comparison passes ADR-0029's prior 9,898-frame failure point. Only
small conformance programs used C++; game generation, execution and measurement remain JS.
After all builds and gates, three paired runs per version (alternating pair order, Node startup
included) retained every digest. C3 baseline 19.0169 / 18.9785 / 18.8846 s vs value regions
18.4249 / 18.7451 / 18.4818 s: medians 18.9785 -> 18.4818 s, about 2.6% lower in this sample,
with separated ranges. CB baseline 4.0731 / 3.8669 / 3.8931 s vs 3.8377 / 3.8685 / 3.8243 s:
medians 3.8931 -> 3.8377 s, but overlapping ranges, so no established CB speed gain. Background
system load remains a limitation; this is not a general performance guarantee. Raw samples,
load averages and runner: `out/_scalar_work/values-bench.{json,log}`, `ValuesBench.py`.
A final build-time-only cleanup rejects effect/isolated positions before allocating a graph and
bounds span lookahead to the same 32-instruction interval. Tool checks still total 56500; both
games were regenerated and SHA-256 compared with the already tested source files:
```
c3 40 generated Haxe files byte-identical
cb 38 generated Haxe files byte-identical
```
The corresponding manifests are `out/_scalar_work/values-before-search-{c3,cb}.json`.
Next: extend boundary-state reconstruction across CFG edges and then effectful/loop SSA;
whole-program signature/stack recovery and general CpuState removal remain unfinished.

**2026-10-01: Multiple-result scalar signatures and exact boundary reconstruction (ADR-0044).**
Bounded linear/read-only and pure acyclic helpers now preserve every changed GPR, not just one
output. Only unique computed values need transport: an ordinary Int return plus immediate-use
`ScalarResult.valueN` ABI words. Constants, aliases and wrapped affine incoming values are
reconstructed from captured originals; exact affine identities also prove restored registers.
These slots have no guest-register identity, and helpers cannot call out, suspend or pump.
No heap tuples, allocations, JIT, workers or game-specific assumptions. Multi-output caller
projections still take priority over full callee helpers; public entries publish all outputs.
Pooling distinguishes all computed return values, their order/arity and any CFG accounting.
Full DCE leaves at most value1..value4 in both game builds, although the fixture covers all 30
changed GPRs. Crash 3 helpers: 15 -> 33 (30 ordinary + 3 shared), 4 projected sites. Crash Bash:
22 -> 38 (32 + 6), projected sites 43 -> 46. ES6 JS grows 27,297 / 44,396 bytes respectively:
25,022,815 bytes C3, 23,788,371 CB. This is broader static coverage, not an assumed speedup.
Acceptance (gitignored `out/_scalar_work/multi-*.log`; pinned common.hxml/analyzer-optimize/js-es=6):
```
./scripts/test.sh
all 56456 checks passed
conformance: 46 test(s) x JS
ok ScalarResults 9c6ba8fc values=51714
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarResults
ok ScalarResults 9c6ba8fc values=51714
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node out/_scalar_multi_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
```
Crash Bash's regenerated `out/_scalar_multi_cb/game.js`, with its verified boot executable and
local.json disc, retains `frames=3000 digest=db892c4b`. Eight other focused JS/C++ groups also
agree: ScalarCalls ff62afe6, ScalarCfg 2325fb2e, ScalarMemoryCodegen 852cd0fd, ScalarCodegen
4ebe3340, RangeCodegen 33c5b85a, Regions 9420e9fd, Yielding f730beee, Dispatch c98a0969.
That initial nine-group command exposed an invalid unaligned `lw` in the new fixture: both
implementations agreed within each target but MemA's unsupported input differed between targets.
The corrected test executes the real generated alignment guard without dereferencing it; aligned
boundary/MMIO fallbacks remain full optimized/reference comparisons. The runtime limitation is
recorded in Blockers. Only small conformance programs used C++; the games remain JS builds.
The previous CFG sources were rebuilt against the same runtime as
`out/_scalar_cfg_{c3,cb}/multi-baseline.js` (sizes unchanged). Three paired Node runs per version,
alternating pair order and including startup, retained every game digest. C3 baseline:
18.8273 / 18.6836 / 18.9041 s; multiple results: 18.6481 / 18.6988 / 18.8918 s (medians 18.8273
vs 18.6988). CB baseline: 3.8604 / 4.1278 / 3.8380 s; multiple results: 3.8135 / 3.8546 / 3.8376 s
(medians 3.8604 vs 3.8376). Both ranges overlap. The discipline gate's generated-C++ text scan
overlapped the early samples; system background load was also present. These are exploratory
timings, not a demonstrated speedup or regression. Raw samples/load averages and the runner are
`out/_scalar_work/multi-bench.{json,log}` and `MultiBench.py`; no additional game builds ran during
the samples. The verified improvement is signature coverage, with a small JS size cost.
Next: state reconstruction at internal observations, then loops/effectful regions; the broader
CpuState-reduction objective remains in progress.

**2026-10-01: Acyclic CFGs now lower to scalar value SSA (ADR-0044).**
`ScalarGraph` shares instruction lifting with linear helpers; `ScalarCfg` carries edge predicates,
phi values and all terminal register states through a pure acyclic CFG. Predicates are captured
before delay slots. Only entry zero specializes; public interior entries retain their original
body. Calls, memory, internal pumps and possible traps remain outside this speculation proof.
The selected path's cycles/instructions/blocks return in `core.ScalarResult.accounting`, one
packed Int consumed immediately under the no-callback/no-suspension helper contract. No tuple,
runtime allocation, CpuState argument in helpers, worker, JIT or game-specific rule. CFG cost
computations participate in helper-sharing keys; equal formulas with unequal costs stay distinct.
Crash 3: 13 -> 15 helpers. Crash Bash: 16 -> 17 ordinary plus 2 -> 5 shared helpers (18 -> 22
total), and 33 -> 43 projected call sites. ES6 JS grows by 2,254 bytes for C3 (24,995,518 total)
and 19,702 for CB (23,743,975 total), because public/interior fallback bodies remain available.
Acceptance (gitignored `out/_scalar_work/cfg-*.log`; pinned common.hxml/analyzer-optimize/js-es=6):
```
./scripts/test.sh
all 56364 checks passed
conformance: 45 test(s) x JS
ok ScalarCfg 2325fb2e values=159054
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCfg ScalarCalls ScalarCodegen ScalarMemoryCodegen RangeCodegen Regions Yielding Dispatch
conformance: all targets agree
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCfg
ok ScalarCfg 2325fb2e values=159054
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node out/_scalar_cfg_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
```
The final ScalarCfg comparison includes 17 fixtures: the earlier eight-group run used its initial
15. Tests cover every ordinary conditional branch, joined/nested diamonds, same-target edges,
delay-slot predicate changes, constant results with variable costs, caller projections/public
outputs, arbitrary interior entries, consecutive calls, event halts and suspension-state traces.
Program tests also cover CFG pooling across overlays, hook changes and opt-out regeneration.
Crash Bash's regenerated `out/_scalar_cfg_cb/game.js`, with its verified boot executable and
local.json disc, retains `frames=3000 digest=db892c4b`. Only small conformance programs used C++.
Both game bundles use full DCE. Previous generated sources were rebuilt against the same runtime
as `out/_scalar_range_{c3,cb}/cfg-baseline.js` (sizes unchanged). Three paired runs per version,
alternating pair order after all compilations, include Node startup and retain every game digest:
C3 baseline 13.1325 / 13.1771 / 13.3865 s vs CFG 13.0301 / 13.0913 / 13.0655 s (medians 13.1771
vs 13.0655); CB baseline 3.0054 / 2.7533 / 2.7180 s vs CFG 2.7607 / 2.7038 / 2.7149 s (medians
2.7533 vs 2.7149). C3 samples separate, CB ranges overlap; these small samples under normal
background system load do not establish a broad speed gain. Raw samples/load averages and the
runner are `out/_scalar_work/cfg-bench.{json,log}` and `CfgBench.py`.
Next: general multiple-result signatures and state reconstruction at internal observations,
then loops/effectful regions; the broader CpuState-reduction objective remains in progress.

**2026-10-01: Block-local arithmetic range proofs feed scalar signatures (ADR-0044).**
`RegisterRanges` follows signed word bounds through constants, masks, shifts and arithmetic.
Only proved non-overflowing ADD/ADDI/SUB lose their trap effect in FunctionIR; ScalarPlan can
then lift them into CpuState-free helpers. Same-value arithmetic removes unnecessary inputs.
Every block entry starts unknown; memory/runtime effects and unproved traps clear facts.
Call delay slots retain pre-call bounds except the link register. No cross-block assumptions,
host Float, game-specific cases, runtime allocation or new overflow/load-delay emulation.
The existing unknown-overflow barrier fixture now uses an unknown input rather than zero,
which explains ScalarCalls' new digest. Existing runtime accuracy limits remain in tool.md.
Acceptance (gitignored `out/_scalar_work/range-*.log`; pinned toolchain/common.hxml/js-es=6):
```
haxe build/tests-tool.hxml
all 56218 checks passed
./scripts/conformance.sh
conformance: 44 test(s) x JS
conformance: JavaScript passed
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh RangeCodegen ScalarCalls ScalarCodegen ScalarMemoryCodegen Codegen Regions Yielding Dispatch
ok RangeCodegen 33c5b85a values=10090
ok ScalarCalls ff62afe6 values=96344
ok ScalarCodegen 4ebe3340 values=124013
ok ScalarMemoryCodegen 852cd0fd values=3830
ok Codegen 3d017147 values=15423
ok Regions 9420e9fd values=38333
ok Yielding f730beee values=7906
ok Dispatch c98a0969 values=602
conformance: all targets agree
haxe build/js-demo.hxml
node out/_demo/js/demo.js --headless-hash 300  # twice
frames=300 digest=329de455
./scripts/check.sh
check.sh: clean
node out/_scalar_range_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
```
Crash Bash's regenerated `out/_scalar_range_cb/game.js`, using its verified boot executable and
local.json disc, retains `frames=3000 digest=db892c4b`. Games were built with full DCE; only the
small conformance programs used C++. Both ES6 JS bundles are byte-identical to the pooled stage
(C3 24,993,264 bytes, CB 23,724,273 bytes); helper counts stay 13 and 18. This extends the general
proof machinery but demonstrates no game size/speed improvement; timing identical code again
would not measure the new analysis.
A temporary read-only survey (`out/_scalar_work/ScalarSurvey.hx`, `range-survey-*.log`) inspected
base/overlay universes, excluding relocatable sets: C3 1124 functions/917 multi-block, CB
1899/1701. Under the current <=32-instruction, no-effects/no-internal-pump limits, just 7/5
multi-block candidates remain. None has identical cycles/instructions/block counts on every
path. Next: CFG value SSA with path-dependent accounting and boundary-state reconstruction;
merely admitting balanced branches would add no coverage on these images. The broader clean
source/signature recovery objective is still in progress.

**2026-10-01: Equivalent caller projections now share pure Haxe methods (ADR-0044).**
`ScalarPool` interns the exact normalized parameter list and pure value-SSA calculation in
`ScalarValues.hx`. Inputs are named by argument position; live definitions are renamed without
dead-value gaps. Constants, operand order, shifts and 32-bit wrapping remain part of the key.
Each call keeps its register mapping, resident fallback callee, entry/unwind guards and original
instruction/block/cycle counts. Memory helpers stay outside the pool; no runtime allocation or
forced inline. Sharing works across shards and overlay universes, without equating guest addresses.
Regeneration resets helper/body ownership and removes unused modules on opt-out; standalone
emitters still support self-contained output. All changes are in the tool/tests/docs.
Crash Bash: 33 per-site definitions -> 2 shared definitions, still 33 specialized call sites;
49 -> 18 total helper definitions. ES6 JS 23,729,769 -> 23,724,273 bytes (-5,496).
Crash 3 stays byte-identical at 24,993,264 bytes (no eligible projected calls to share).
Acceptance (gitignored logs: `out/_scalar_work/pool-*.log`):
```
./scripts/test.sh
all 724 checks passed
conformance: 43 test(s) x JS
ok ScalarCalls 1bfb3dce values=96344
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCalls Dispatch
ok ScalarCalls 1bfb3dce values=96344
ok Dispatch c98a0969 values=602
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node out/_scalar_pool_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
```
Crash Bash's regenerated `out/_scalar_pool_cb/game.js`, with its verified BOOT.EXE and local.json
bin, retains `frames=3000 digest=db892c4b`. Builds used common.hxml/analyzer-optimize, js-es=6,
full DCE. The prior generated CB sources were rebuilt against the same current runtime as
`out/_scalar_calls_cb/pool-baseline.js` for comparison. Six alternating 3000-frame Node runs
(startup included) all retained db892c4b: baseline 2.9123 / 2.7212 / 2.7930 s, pooled
2.7958 / 2.7762 / 2.7818 s. Medians 2.7930 vs 2.7818 s overlap in range; background system CPU
activity was present. This establishes a size reduction, not a speed win. Raw samples are in
`out/_scalar_work/pool-cb-bench.json`. New fixtures cover different source/destination GPRs,
dead definitions and unequal guest counts sharing code, while changed constants/operand order
stay separate; program tests cover overlays, hook changes, repeat generation and opt-out cleanup.
Next: CFG value SSA/boundary reconstruction and arithmetic range proofs, with size/time gates.

**2026-10-01: Call summaries and caller-specific scalar outputs implemented (ADR-0044).**
`FunctionSummary` now solves semantic inputs, may-writes, effects and call edges across resident
functions/overlays, including recursion. Unknown callees and hooks stay conservative; linking
returns and checked nonlocal returns follow Discovery/Emitter's existing control-flow rules.
`BoundaryLiveness` permits a pure callee's extra GPR results to disappear only when every caller
path overwrites them before a read or observable boundary. The caller emits a CpuState-free
single-result helper; public entries and guarded fallback calls still publish all outputs.
Pumps, MMIO, other calls, traps, returns and cooperative suspension retain full state; existing
unwind tokens force the original call. No JIT, workers, runtime allocation or game-specific rule.
This is a bounded projection proof, not general ABI/stack recovery or runtime state reconstruction.
Coverage: Crash Bash adds 33 specialized call sites for two callees (16 -> 49 helper definitions);
Crash 3 remains at 13 helpers. All games retain the same original public entries.
ES6 JS size against the checked-read stage: C3 24,853,772 -> 24,993,264 bytes (+139,492),
CB 23,707,791 -> 23,729,769 (+21,978). This is not a code-size or measured speed win: arithmetic
trap effects now conservatively invalidate more span assumptions, and per-site helpers add code.
The annotation does not add arithmetic overflow exception execution; that preexisting limitation
remains. An initial treatment of checked returns as unknown calls was corrected: unwinding does
not execute another callee before the caller continues. Next: CFG value SSA/boundary reconstruction,
range proofs and sharing equivalent helper versions, with measured size/time gates before widening.
Acceptance (logs under gitignored `out/_scalar_work/call-*.log`):
```
./scripts/test.sh
all 672 checks passed
conformance: 43 test(s) x JS
ok ScalarCalls 8298013f values=78472
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCalls ScalarMemoryCodegen ScalarCodegen Codegen Regions Yielding Dispatch
ok ScalarCalls 8298013f values=78472
ok ScalarMemoryCodegen 852cd0fd values=3830
ok ScalarCodegen 4ebe3340 values=124013
ok Codegen 3d017147 values=15423
ok Regions 9420e9fd values=38333
ok Yielding f730beee values=7906
ok Dispatch c98a0969 values=602
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node out/_scalar_calls_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
```
Crash Bash's regenerated `out/_scalar_calls_cb/game.js`, its verified BOOT.EXE and local.json
bin also retain `frames=3000 digest=db892c4b`. Both game builds use common.hxml, analyzer-optimize,
js-es=6 and full DCE. Only small conformance programs were built for reflaxe.CPP, not the games.
The new fixtures exercise 17 call shapes, all GPRs, HI/LO, cycles/accounting, independent formulas,
both/one-arm overwrites, delayed branch reads, public callee entries, effects, next-call visibility,
loop/event halts, preexisting unwinds and intermediate cooperative suspension-state traces.

**2026-10-01: rev.ng's signature recovery inspected in source; no codegen change this turn.**
At revision `0f1f7d4ac301241db32552d52ab105c17aca4bdc`, register liveness/reaching definitions
feed caller/callee fixed-point summaries; EnforceABI rewrites signatures/calls (including
multiple return values), then CSV promotion exposes locals to LLVM. Stack separation and
data-layout inference are separate stages. The documented executable recompilation branches
precede ABI enforcement; decompilation also drops selected exceptional paths. Thus clean C is
not evidence of PS1 state/timing preservation. Source links and implications are recorded in
ADR-0044's upstream comparison. Next: explicit call-site summaries and boundary-state
reconstruction, before expanding ScalarPlan beyond its present single-block/single-output proof.

**2026-10-01: Scalar signatures now cover bounded read-only RAM/scratchpad leaves (ADR-0044).**
`ScalarPlan` tracks affine incoming-register/constant addresses and proves a shared read span
before invoking a CpuState-free helper taking `shim.Span`. Every load participates, including
dead results and `$zero`; alignment, range and plain-memory checks precede all reads. Failed
guards keep the original body and MMIO order. Pointer chasing, stores and multiple outputs
remain excluded. Entry pumps/resumption/accounting stay in the wrapper; memory helpers are
not called directly from callers. No game-specific logic, new runtime allocation or forced inline.
Coverage: Crash 3 5 -> 13 helpers (8 read helpers), Crash Bash 9 -> 16 (7 read helpers).
Crash 3 ES6 JS: 24,852,207 -> 24,853,772 bytes (+1,565), same current runtime and build flags.
Speed benefit is unmeasured for this extension; concurrent builds make a timing comparison
in this session unsuitable. Next for signature recovery: call-group read/output/effect analysis,
with state reconstruction at observable boundaries, before relaxing the single-output rule.
Acceptance commands/output (generated artifacts remain gitignored):
```
./scripts/test.sh
all 559 checks passed
conformance: 42 test(s) x JS
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarMemoryCodegen ScalarCodegen Codegen Regions Yielding Dispatch
ok ScalarMemoryCodegen 852cd0fd values=3830
ok ScalarCodegen 4ebe3340 values=124013
ok Codegen 3d017147 values=15423
ok Regions 9420e9fd values=38333
ok Yielding f730beee values=7906
ok Dispatch c98a0969 values=602
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node out/_scalar_read_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
```
Crash Bash's regenerated `out/_scalar_read_cb/game.js`, using its verified boot executable and
local.json disc, also retains `frames=3000 digest=db892c4b`. Both games built with common.hxml,
analyzer-optimize, js-es=6 and full DCE. New conformance covers signed/unsigned reads, wrapped
affine addresses, RAM mirrors, scratchpad aliases, boundary fallback, dead/zero-target FIFO
reads, due events and a RAM change while suspended before the callee's load. The initial FIFO
test reused the preceding CPU's scheduler owner; resetting it per run fixed the fixture.

**2026-10-01: Scalar Haxe function signatures implemented (ADR-0044), first bounded stage.**
`ScalarPlan` lifts pure one-block leaves into value SSA, recovers live input parameters and
one changed GPR as the return value, preserving every other final register (scratch registers
included). Helpers have no CpuState argument or forced inline. Existing entry wrappers keep
pumps/checkpoints; proven direct calls use helpers only when no entry work can run. Hooks,
unknown/overlay dispatch, memory, traps, HI/LO, multiple outputs and relocatable functions keep
the general path. Limits: 32 instructions, 6 inputs. `--no-scalar` isolates the pass for A/B.
Generated coverage: Crash 3 5 helpers / 4 direct sites, Crash Bash 9 / 5; no broad speedup claim.
Crash 3 ES6 JS grows 837 bytes (24,851,370 -> 24,852,207). Next: analyze live outputs across
proven call groups before widening the signature recovery; do not drop ABI scratch outputs.
Acceptance commands/output (new generated code, all local, no game artifacts committed):
```
source scripts/env.sh && haxe build/tests-tool.hxml
all 539 checks passed
./scripts/test.sh
conformance: 41 test(s) x JS
test.sh: JS-only gate passed — 329de455
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCodegen
ok ScalarCodegen 4ebe3340 values=124013
conformance: all targets agree
RECOMPSX_JS_ONLY=0 ./scripts/conformance.sh ScalarCodegen Codegen Regions Yielding Dispatch
ok ScalarCodegen 661b3b64 values=119813
ok Codegen 3d017147 values=15423
ok Regions 9420e9fd values=38333
ok Yielding f730beee values=7906
ok Dispatch c98a0969 values=602
conformance: all targets agree
./scripts/check.sh
check.sh: clean
node out/_scalar_c3/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
node out/_scalar_c3_base/game.js web/boot.exe web/disc.bin --headless-hash 9000
frames=9000 digest=4de78425
```
The five-test cross-target run preceded the added restored-scratch cases; the standalone
ScalarCodegen run above is the final version, `4ebe3340` / 124013 values.
Crash 3 generated into `out/_scalar_c3` and `out/_scalar_c3_base` (the latter with `--no-scalar`);
both built with common.hxml, analyzer-optimize and js-es=6 against the same current runtime.
Crash Bash generated into `out/_scalar_cb`, same JS settings, local.json's disc and its verified
boot executable: `frames=3000 digest=db892c4b`.
JS A/B, 9000 frames, alternating process order, one warmup per mode then three samples
(`out/scalar-benchmark.json`): no-scalar 19.5348/21.0066/23.9337 s, scalar
18.9968/22.3200/23.7078 s; medians 21.0066 vs 22.3200 s. Both series drift upwards and
their paired ordering changes; this run establishes no speed benefit. Every run retained
`4de78425`. Treat this as bounded signature-recovery infrastructure, not a measured game win.

**2026-10-01: CpuState-free function generation researched; no codegen change.**
rev.ng's `enforce-abi` promotes register communication into locals, arguments and returns
([reference](https://docs.rev.ng/references/artifacts/#enforce-abi-artifact)); its initial stack
pointer remains shared. Our FunctionIR retains machine registers and Program.computeWrites
already supplies transitive write masks for span invalidation. Proposed next experiment: add
read-before-write/output/effect summaries and value SSA, then emit parameter/return helpers
for proven functions and direct-call groups. Keep architectural-state adapters at unknown
calls, hooks, traps and scheduling/resumption boundaries; preserve cycles, delay slots and
all observable register/memory effects. ADR-0029's staleAcrossCalls regression rules out
reviving the old local-register publication scheme. Speed and coverage remain unmeasured;
validate against independent instruction semantics as well as cross-target digests.

**2026-10-01 (later): Dreamcast full speed, round 4 — the caches. Crash 3's title screen 19.46 → 18.19 ms a frame,
its gameplay demo (new window, 4700:5000) 35.47 → 29.26, Crash Bash's Ballistix 20.55 → 19.19 (work 16.03). Target
16.7; ledger E-053..E-058.** Kept:
- CpuState's machine instance at a fixed address (`recompsx_cpustate`, `CpuState.machine()`, `shim.CpuStateHome`),
  coloured with the data; RTPT one copy of the transform for real (`MemA.opaque(3)` keeps GCC from unrolling the
  loop: rtpt 2,444 → 1,064 bytes, gameplay cf −1.50);
- Crash 3's code placement from both windows' traces at once (gameplay 35.85 → 31.86 alone), Crash Bash's redone;
  the main stack 235 lines below the top of RAM (backend_kos.c); data colours for 58 variables over three windows
  (dc-data-placement.txt); each game's literal-pool halves;
- the cache model counts every instruction (RXCOUNT=1, rx_cache.cpp, `<prof>.cache.count`).
- `-fschedule-insns -fsched-pressure` for the runtime and the backend, not for the game's code (scripts/build-dc.sh,
  E-063): conflict-free −0.07 ms on both Crash 3 windows, −0.15 on Crash Bash.
Measured and not pursued: CpuState fields by heat (code does not shrink), GCC hot/cold partitioning (slow paths
already out of the hot lines), gp folding (Crash 3 uses gp as a plain register). What is left is instructions, not
caches: with no cache miss at all gameplay would be 17.2 ms (E-057). Test image: out/dc/crash3-g44-max.cdi. Next: the
GPU path's per-polygon cost (~1,500-2,000 SH-4 instructions a polygon), the generated code's per-call overhead
(prologue, pump, spans: ~45 instructions a call, 3,583 calls a frame in gameplay), RTPS/RTPT on the SH-4.

**2026-10-01: Dreamcast full speed, round 3 — Crash 3's title screen cf 17.98 → 17.23 ms, frame 19.46 with a
fresh placement (g40p2); Crash Bash's Ballistix work 16.82 → 16.05 (g41, placement pending). Target 16.7; ledger
E-047..E-052.** Owner's rule (2026-10-01): only optimisations that need no run of the game and give the same
result for everyone — profile-guided compilation measured −1.55 ms and was rejected (E-047, removed). Kept:
- RTPS/RTPT matrix rows on the SH-4's MAC unit (`GteFile.dot3`, `native/recompsx_gte.h`, packed RT at GTE word
  648; checked on the SH-4 by a KOS program, 3.6 M rows, 0 differ) — C3 −0.41, CB −0.28;
- emit_header's hit split from its compile, one-word key, cheaper hash — C3 −0.18, CB −0.27; OT clear (DMA6)
  without a test per entry;
- spans as addresses on C++ (`shim.Span`: `uint8_t*`, `@(disp,Rn)` per access) — C3 −0.09, CB −0.20;
- `lwl`/`lwr` pairs fused (`Memory.lwu`, conformance `Unaligned`), idle loops on JOY_STAT/I_STAT/I_MASK and in
  linear chains (`Memory.isIdleReadable`) — C3 −0.05;
- the cache model charges mac.w/clrmac dependencies (Flycast fork, rx_cache.cpp); the bench prints `bench rest`
  (Crash Bash's idle is the pacer's sleep) and presents by cost (both games run at 30 Hz: a light vblank then a
  heavy one; the pair must fit 33.4 ms — C3's is ~38.5 now, CB's heavy pairs ~44).
Rejected: game code at -O2 (+0.23), RTPS inline in looping leaves again (+0.08 with mac.w).
Hatchet support removed (owner, 2026-10-01): scripts/build-hatchet.sh, src/shims/hatchet and the CMake
template's transpiler switch; reflaxe.CPP is the only C++ transpiler.
Digests unchanged (C3 JS 9000 4de78425, gpu-stream 4050 5f877994a1335867, CB plain 3000 db892c4b; conformance
both targets). Test image for the owner: out/dc/crash3-g40-max.cdi (g40 + its placement). Next: finish the
placement round (C3: f_8003fc50's literal pool shares sets with the CpuState — another halves pass; CB: colours
in $SP col41-cb, then halves), then calls' register summaries (reads as well as writes) so guest registers stay
in locals across calls the summaries clear.

**2026-09-30 (later): Dreamcast full speed — Crash 3's title screen 20.34 → 19.39 ms a frame (cf
18.72 → 18.14), Crash Bash's Ballistix work 18.04 → 17.36 ms, under the cache model (target 16.7;
ledger: docs/perf/dreamcast-ledger.md, E-035..E-042).** All global; per-game data is only each
game's placement file. Kept this round:
- the last call through a register kept in the CpuState (`_callAt`/`_callFn`/`_callBlock`, FnTable
  `run`/`runFast`): Crash 3's FAST slot and the CpuState's first line had met in one cache set;
- the sound stream's split buffers 8 KB apart (`snd_stream_init_ex(2, 16 KB)`, were 32 KB: same sets);
- branch hints in generated code (`shim.MemA.likely/unlikely` on span tests, resume guards, pumps,
  unwind checks): Crash 3's 21 KB f_8003fc50 no longer evicts itself (code colours 0.89 → 0.63 M);
- the scheduler's handler re-arm is a store (`fire` clears `nextSlot`); the timers' tables in a
  register file (`recompsx_timers`, `shim.TimerFile`), a power-of-two wrap as a mask (no divides),
  `Memory.machine` a plain pointer with a sentinel CpuState;
- `ctx` is `core.Ctx`: `core::CpuState* __restrict` on C++ (spike first), generated code −0.09 ms;
- the PC sampler's symbol cached per bucket; `dc-icache-sim detail` / `opt ... fresh`;
- placement redone for both games (code colours, halves) and the data colours for both (g28 traces).
Rejected: triRecord out of line (+0.06), span-step qualification (+0.15), value-checked span
retakes (neutral, +203 KB). Digests unchanged throughout (C3 9000 4de78425, CB 3000 db892c4b, both
GPU streams); conformance unchanged on both targets. In the tree, not committed. Next: the placement
round for the current code (g33 traces), then Crash Bash's state-change cost in build_scene (401 state
records a frame from ~50 contents).

**2026-09-29: Dreamcast — the hot code placed for the instruction cache (ADR-0043): Crash 3's title
screen 35.1 → 29.5 ms a frame under the cache model.** Most instruction fills were conflicts, and
they are now placed away:
- **What was wrong:** 68 % of instruction fills were conflicts, decided by where the linker left
  each function.
- **The trace:** the model records the instruction entering each new line (`RXTRACE`).
- **The simulator:** `scripts/dc-icache-sim.c` replays a trace against a candidate placement; its
  `opt` mode gives the most fetched sections the colours that miss least.
- **The build:** `scripts/dc-layout.py` turns the colours into an ordering file with padding for
  `--section-ordering-file`. `build-dc.sh` applies `games/<SERIAL>/dc-placement.txt` at every link
  and checks it against the map: two links, the second skipped when nothing moved.

Crash 3's placement came from 48 M entries of the title screen. `opt` used the first 12 M (120
sections, two rounds). On the other 36 M, which it had not seen, misses fell 59 % and conflicts
87 %. Under the model:
- the frame went from 35.1 to 29.5 ms: emu 18.0 → 13.6, gte 4.6 → 4.1, build 5.4 → 4.8;
- instruction fills went from 10.1 to 4.1 ms, and operand fills rose 0.5 ms, because constants
  move with their code.

The data keeps its colours: .text grows by 507,904 bytes, a multiple of 16 KB, and the loaded image
is 10.97 MB. A first placement that balanced sample heat over the colours won 0.3 ms and lost 0.7.
The CDIs `out/dc/crash3-placed-max.cdi` and `crash3-unplaced-max.cdi` are the same sources, placed
and not, for a console to judge. check.sh passes.

**2026-09-29: Dreamcast — placement, not the dispatcher, decides the frame.** Two dispatcher
changes were measured under the cache model on Crash 3's title screen (presents 3300..4050), and
both were set aside:
- **Nothing inlined into the dispatchers, no diagnostic stores:** 40.2 against 39.2 ms a frame.
  Instruction fills fell 0.85 ms, and operand fills rose 1.9 ms: each switch reads its jump table
  and its callees' addresses from the code's constant pool through the operand cache.
- **FnTable's kept answers holding the function's address, called directly (C++ only):** the
  switches' own time went, but the functions LTO had inlined into them now run as separate copies
  and cost the same. The fully associative costs fell only 0.2 ms, and the frame read 39.4 against
  35.1 from placement alone.

The patches are not kept. A reflaxe.CPP fact is: a static function reaches a native splice as its
C++ name (tests/spike/fnptr, in spike.sh).

The model now also counts what fully associative LRU caches of the same sizes would miss (the
fork, `<prof>.cache.fa`; `dc-prof.py` shows `iconf`/`oconf`). At 35.1 ms, 9 ms is conflicts:
6.9 ms of instruction fills and 2.2 ms of operand fills. Two links of the same sources differed by
4.3 ms, all of it conflicts. So builds are compared per function and on the fully associative
columns, not by the frame total (src/backend/dreamcast/AGENTS.md, Measuring).

Other facts from the work:
- The title screen makes about 2,600 dynamic calls a vblank, 99.9 % FAST hits, to 33 targets.
- The Flycast scripts turn VSync off. With the window out of sight, the OpenGL swap waited forever
  on the thread that starts the game.

Next up item 00 is the placement work.

**2026-09-29: The multitap (ADR-0042) — four players, on by default.** A Multitap (SCPH-1070)
is in port 1 (`sio.Multitap`) with the host's four pads in slots A-D. It follows psx-spx:
- a read answers for slot A, so a game without tap support sees an ordinary pad;
- a third byte of 01h makes the next read the long one (80 5A, then four slots of eight bytes);
- asked again during a long read, the next is four bytes of garbage;
- 02h-04h read slots B-D directly, and 81h is the machine's card (82h-84h hold none);
- an empty slot A answers nothing, so with no pads (headless) nothing moves.

Pad 1 is also port 2 until the game uses the tap, then slot B only, so no game counts it twice.
The BIOS driver sends 00h third (OpenBIOS), so `KPads` sees slot A. The browser now reads four
gamepads; SDL2 and the Dreamcast's maple A-D already did.

Verified:
- `MultitapSio` agrees on JS and C++ (644b488d); `PadSio`, `PadBios` and the card tests are
  unchanged; Crash Bash 3000 is still `db892c4b`; check.sh passes.
- Crash Bash, headless with four scripted pads, counts four (80051600h = 4) and fills its records
  0-3; each pad's own button reached its own record. With two pads it counts two (slots A and B,
  port 2 empty).
- On the Dreamcast, in the Flycast fork with four Sega controllers, it counts four too. Each maple
  port's button (held by the fork's new `RXPAD`) reached its own record: A cross, B circle, C
  square, D triangle. CDI `out/dc/crashbash-tap-max.cdi` (mouse and onlinemenu mods).

**2026-09-28: Dreamcast — a frame drawn across a vblank is no longer shown in two halves.** The
owner saw Crash 3's first level flicker on Flycast from one point of the level on: the sky alone,
the lower half black, Crash on his log over black. The cause was ADR-0039's list walk. It takes
emulated time, so a vblank can come while the GPU is half way through a frame. VRAM does not care,
but the Dreamcast shows the primitives it received since the last present, and it split the frame.
Found by loading the owner's save state into the Flycast fork, whose new `RXWATCH_*` hook logs
`present_frame`'s arguments and chosen words at every call. 63 of 600 presents came mid-walk, and
17 of 240 screenshots were torn. The scanout now marks such a present `BP_PRESENT_DRAWING` (a new
ABI flag, `Dma.listWalking`). The Dreamcast keeps its last picture up and lets the rest of the list
join the frame, for at most three presents in a row. With the same hold applied by the hook to the
same state, 0 of 240 were torn. The attract loop's demos never cross a vblank (0 of 20000 frames on
JS, walks at most 11 ms), which is why nothing had shown it. Crash 3 9000 is still `4de78425`.

**2026-09-28: A model of the SH-4's timing — the console's frame time without a console.** No
emulator models what makes the recompiled code slow on a Dreamcast (Flycast read Crash 3's title
screen 1.6x fast, Demul 1.44x), so the profiling Flycast fork gained one
(`scripts/dc-flycast-model.sh`; core/profiler/rx_cache.h in the clone): its interpreter at the
SH-4's own rate, shadow tags for the 8 KB instruction and 16 KB operand caches, a stall for each
operand not yet ready, uncached access costs — time only, the data untouched. With its default
costs it reads the title screen (presents 3300..4050) at 39.2 ms a frame against the console's
39.3, emu+gte 27.0/26.7, gpu 5.3/5.3, build 5.5/5.6, and the console's top functions within
0-15 % but the GTE (`cmdRtps` +27 %, against one sampled window). The instruction-cache fill is
what it hangs on (+12 cycles, +19 %). `--dc-rxprof` now also names screenshots by present
(`pNNNNN`), and `scripts/dc-prof.py` splits each function's modelled time into its fills, stalls
and uncached accesses. Flycast's STRICT_MODE cache emulation was tried first: it jumps to address
zero at boot on our binaries. Details in src/backend/dreamcast/AGENTS.md, Measuring.

**2026-09-28: QUIT in Crash Bash's main menu (ADR-0041) — back to the host's own menu.** A line
under OPTIONS, added to Select Game Type's list the way ONLINE is; cross (or a click) on it has the
kernel write the memory card back and call the new `bp_exit_to_menu`: the Dreamcast's BIOS menu
(the hardware stopped where it stands, then `syscall_system_bios_menu`; KallistiOS's own exit to
the menu rebooted the disc from the running game, and a busy test program hung in it; Crash
Bash quitting during its Universal logo reached the BIOS menu and stayed there, under the Flycast
fork with a real BIOS),
the desktop (SDL2, null), the page's start screen (a reload), Node and the JVM ending. Mods call
`ModHost.exitToMenu()`; the PS1's own `exit()` still only reports. Verified headless with a
scripted pad: five downs reach QUIT with "EXIT TO THE SYSTEM MENU", up returns to OPTIONS with the
game's own "CHANGE THE OPTIONS", cross logs the request (a headless run goes on); check.sh (47 ABI
functions); test.sh (JS) with the demo at `329de455`.

**2026-09-28: Crash 3 sees its memory card — executable functions only an overlay calls are
found.** LOAD GAME said "MEMORY CARD IS NOT INSERTED IN MEMORY CARD SLOT 1.": the warp overlay's
save screens call libcard's `_card_info` and `_card_load` wrappers, BIOS stubs at 8005B618h and
8005B628h that nothing in the executable calls, so the base pass never traced them and the call
found no function. The tool now feeds every overlay `jal` target in the executable that the base
pass left unclaimed back to it as a seed (`Main.calledFromOverlays`, games/SCUS94244/notes.md):
Crash 3 +16 functions, Crash Bash +8. Verified: tools/recomp tests (496, a new one for this);
headless Crash 3 with a scripted pad reads the card directory and shows LOAD GAME with four
EMPTY slots; digests unchanged (Crash 3 9000 `4de78425`, Crash Bash 3000 `db892c4b`). Also: the
Dreamcast CDIs now carry the game's product code as the disc serial (`mkdcdisc -s`), since
Flycast keys its per-game VMU by it and a hash-derived serial gave every build an empty VMU.

**2026-09-28: The PS1's own mouse, keyboard and internet (ADR-0040) — no custom input API left.**
Mods reach three official devices on controller ports of their own (`ModHost.plugMouse`,
`plugKeyboard`, `plugIMode`; `ModHost.exchange` moves the bytes as SIO0 would): the Sony Mouse
SCPH-1030 (`sio.SonyMouse`: 5A12h, the buttons, the motion toward the host's pointer, at most 7Fh a
read, per reader), a PS/2 keyboard in the Lightspan Online Connection CD's protocol
(`sio.Ps2Keyboard`: 96h, a count and Set 2 codes — the host's typing as the presses of a US
keyboard, so any layout types right) and the i-mode adaptor SCPH-10180 (`sio.IModeAdaptor`: 41h,
commands 11h..18h, XOR checksums, 58h-byte snippets, X.25 CRC per packet; `sio.IModeWire`). The
kernel plays the host's half: `kernel.KMouse` shows the machine's pointer while a Sony Mouse is
polled (hidden on pad input, gone half a second after the polls stop), `kernel.KKeyboard` types
while a keyboard is polled, and `kernel.KIMode` is the phone and the i-mode centre — the session
messages (auth, gateway, pings), the transport's 01h,3Fh/53h, TLP connect/data/EOF/disconnect —
turning each request's absolute URL origin-form for the new `bp_http_open/read/close` (SDL2 and
Dreamcast sockets, the Dreamcast's network brought up at the first request in a thread; `fetch` in
the page). `mod.LibImode` is libimode's shape (RCV/SND/STS/ABORT/AUTH_*/GW_*, DORMANT..AUTH_ENDED).
Gone: `enableMouse`, `mouseOver/X/Y/Held/Clicks/Moves`, `pictureWidth/Height`, `textEntry`,
`typed`. Crash Bash: both mods on the Sony Mouse, the address keyboard on the PS/2 keyboard, DONE
one i-mode session (`GET http://<address>:9457/SCUS94570 HTTP/1.0`). Verified: conformance `Mouse`
`8d7276ce`, `Keyboard` `89f31197`, `IMode` `df5df22f` on JS and reflaxe.CPP, all 38 on JS;
check.sh clean (46 ABI functions); test.sh (JS) passes, demo `329de455`; Crash Bash 3000
`db892c4b` on JS, unchanged; headless, ONLINE → the address typed on the PS/2 keyboard → DONE
→ libimode AUTH_STARTING..AUTH_ENDED → "connected to" against a canned answer; the SDL2 sockets
against a local server (the raw response whole; a closed port -2); in the browser (builds
b82f94c44bde and the final 3b89dfc7646c) the pointer shown over the menu, ONLINE clicked, `127.0.0.1` typed (a stray `x`
ignored, no cross pressed), Enter → "CONNECTED TO 127.0.0.1", the server logging `GET /SCUS94570`;
with the server stopped, DONE clicked → "NO ANSWER FROM 127.0.0.1". Dreamcast: dc_net.c compiles;
`out/dc/crashbash-periph-max.cdi` built for the owner's test (its network needs Flycast's
broadband adaptor; untested at runtime). Crash 3 on JS 9000 `4de78425`, unchanged; its CDI from
the same code: `out/dc/crash3-periph-max.cdi`.

**2026-09-28: VRAM read back to the CPU (GP0 C0h) — Crash Bash's saves carry their icon.** GPUREAD
hands over a C0h rectangle two pixels a word (the first in the low halfword, wrapping within VRAM,
a zero beside an odd last pixel), GPUSTAT bit 27 is set while pixels remain, and DMA2 in block
mode with CHCR.0 = 0 reads the port into RAM (libgpu's StoreImage), where it used to report
0x6B000001. Crash Bash builds its save's title frame this way. The read returned the latch, zero,
so saves had a black palette and an empty icon, and the Dreamcast's VMU showed a blank one.
Verified: new conformance `GpuRead` `beb98405` on JS and reflaxe.CPP; `OtWalk` `e0887e11`, `GpuFill`, `Raster`
unchanged; Crash Bash 3000 `db892c4b` and Crash 3 9000 `4de78425` on JS unchanged; a save written
in the browser (build 46425ad9f336) holds a 16-colour palette and two icon frames, the CB logo
and Crash's face. The VMU package's long description is now the title alone (no "PS1 card:").

**2026-09-28: Channel 2's ordering table is walked over time (ADR-0039) — Crash Bash's pause menus
have their text.** The pause menu drew its boxes and no text (the owner's report; PCSX-ReARMed's
"slow linked list walking" names this game). The game writes the text's packets into a table it
has already handed to DMA2, which on hardware walks it a node at a time behind the GPU's FIFO.
`dma.Dma` now walks it the same way — each node read from RAM when the walk reaches it, stretches
of ~256 cycles on the scheduler's `DMA_STEP` (the unused `DMA_IRQ`), a cycle a word, a cycle a
node, plus the GPU's drawing time estimated from each primitive's geometry on every drawing path
alike (`Gpu.takeWork`: area capped by the bounding box clipped to the drawing area, 5/8 of a cycle
a textured pixel, 5/16 untextured, x1.5 semi-transparent, 16 a primitive; fills 1/8, copies 1).
At the channel's rate alone the walk overtook the game mid-text (PAUSED/CONTINUE/OPTIONS, no QUIT
GAME; "SHOW RUL"/"SHOW RU" alternating); with unclipped areas the text was whole but walks ran
13-48 ms and the hub fell to ~10 fps; clipped, walks average 2.5 ms (peak 5.6) and the first 3000
frames render 1078 flips, as with the instant walk. Verified: conformance `OtWalk` `e0887e11`,
`BulkPaths`, `GpuFill`, `Raster`, `CardBios` unchanged on JS and reflaxe.CPP, every other
conformance digest unchanged on JS; GPU words and commands over 3000 frames identical; the owner
saw the whole pause menu with the unclipped estimate (the clipped one, to confirm). Crash Bash
3000 `db892c4b` on JS and reflaxe.CPP (was `6bd7b329`: interrupt and event timing moved). Dreamcast:
`out/dc/crashbash-card-max.cdi` (memory cards, this walk, mods onlinemenu and mouse; loaded image
10,571,071 bytes) — the owner's test on Flycast/console pending. Crash 3 on JS: 9000
frames, 4026 flips, `4de78425`; it now reports "interrupt pending but SR.IEc is clear" once
(frame ~1000) — a DMA2 completion arriving while the game has interrupts off, as on hardware,
delivered when it turns them back on.

**2026-09-28: Memory cards (ADR-0037) — Crash Bash saves, and keeps 8336 bytes for it.** The
card in slot 1 (`sio.MemoryCard`) is a whole PlayStation card to the game, formatted as the BIOS
formats one; slot 2 is empty. Both roads reach it: SIO0 answers at 81h with a Sony card's read,
write and ID commands (late 5Ch acknowledge included), and the kernel's card functions are
OpenBIOS's driver, backup unit and `bu` device translated (`kernel.KCard`, `kernel.KBu`, MIT,
attributed) — InitCARD2..`_card_wait`, `_bu_init`, `_card_info`/`_load`/`_auto`, open with
create and async, read/write/close/lseek/erase/rename/format/firstfile/nextfile, a sector per
slot every second vblank, HwCARD/SwCARD events as the BIOS delivers them. The kernel's FCBs
([140h]) and device table ([150h]) are now in RAM (`kernel.KDevices`), function pointers as
BIOS-window stubs: libcard swaps bu's firstfile for its own and calls the original back, and
without the table Crash Bash waited forever for the card event only that detour makes. What is
kept is recompsx's card format under the product code (`GameInfo.SERIAL`): a 16-byte header and
each block in use with its directory frame, at its own place — no per-game config, no 128 KB
image; nothing at all for a game that saved nothing. Backends: PC/Node `<SERIAL>.card`, the
browser's localStorage, the Dreamcast `<SERIAL>.card` on /pc or /sd or a VMU package with the
game's own save icon (12 blocks fit), null none (`bp_card_load/save`). Frames presented while
sectors move carry `BP_PRESENT_FAST`, and the browser and the Dreamcast do not hold them.
Crash Bash's boot overlay calls three executable functions from its save screens the analysis
never found (8002D294h, 800150E8h, 8002D0C8h, each starting right after another's `jr ra` with
no prologue — the kind next-up 0 is about) and an
overlay entry (800923FCh): game.json hints. Verified: conformance `CardFormat` `f6536b8c`,
`CardSio` `69461681`, `CardBios` `b4d75c0b` and `CardChains` `844db8da` (files created into
each other's holes, a chain through blocks 1, 4 and 5, the card format growing and shrinking a
block at a time, two restarts through the format) on JS and reflaxe.CPP; every other conformance
digest unchanged; in the browser the owner saved to slot 1 and the page kept 8336 bytes (one
block, `BASCUS-94570`, "SC" with a two-frame icon), which came back after a reload; check.sh
clean (42 ABI functions); the Dreamcast's dc_files.c and dc_video.c compile clean with kos-cc
-Wall -Wextra. Crash Bash 3000 `6bd7b329` on JS and reflaxe.CPP (was `0e180c28`: the game finds
a card now).

**2026-09-28: The mouse (ADR-0038) — Crash Bash's menus answer to it.** `bp_mouse` in the backend
ABI (over the picture, x and y as fractions 0..65535 of it, left/right/middle/back/forward held,
quick clicks latched), implemented by SDL2 (letterbox rectangle, high-DPI points), the browser
(pointer events over the page's picture, context menu and history buttons kept from the page) and
the Dreamcast (a maple mouse on the 640 x 480 screen, its arrow drawn last in each scene); null
has none. `kernel.KMouse` samples it after the pads, turns fractions into the display's pixels and
counts moves and presses from boot so readers never take events from each other; `ModHost.mouse*`.
`mods/onlinemenu`: point, click and back on the main menu and the address keyboard; `mods/mouse`:
the game's screens by writing the index each keeps (players 8005A63Ah, OPTIONS 800B9508h, Adventure
800B9628h, P1's portrait 800BA004h, the level 8005A64Bh) with the move sound, cross added after the
pad reader (800138A4h) for a click — nine menu slots, a list live while the screen it was built
under is current (OPTIONS opens in slot 4 and is never emptied); stepping down/up only for lists not
yet known. The owner asked for the indexes: a stepping first version took several ten-frame
slides to reach a character at the far end. The pointer hides while a pad is in use and comes
back when the mouse moves (the kernel's rule, `bp_mouse_show` carries it out). On the Dreamcast a
vblank handler adds up every bus frame's motion (KallistiOS keeps only the last), and a maple
keyboard is pad 0 as well; in Flycast the host mouse and keyboard must be on the same maple port
as the Dreamcast Mouse and Keyboard devices — the owner's arrow never moved otherwise. Found on the way: onlinemenu
took OPTIONS's slot-4 build for leaving the main menu, so ONLINE (pad and mouse) stopped working
after it; fixed. Verified: conformance `Mouse` `adc65922`, `Keyboard`, `ModHooks` on JS and
reflaxe.CPP; a scripted headless walk (main menu, OPTIONS and back, Adventure submenu, the side
button); the browser with a real mouse; SDL2 and Dreamcast compile clean; check.sh (42 ABI
functions). With only this change on HEAD, Crash Bash 3000 `654669df`, 9000 `fda4764f` — the
working tree's in-progress memory card work moves them (3000 `4754e627`, 9000 `6cea1549`).

**2026-09-28: The host's keyboard types (ADR-0036); ONLINE takes an address only and tries the
game's port.** A keyboard-as-text group in the backend ABI (`bp_key_text`, `bp_key_next`: Unicode
code points as the host's layout makes them, plus Backspace/Enter/Escape), implemented by SDL2
(`SDL_TEXTINPUT`), the browser (`KeyboardEvent.key`), the Dreamcast (a maple keyboard's KOS queue)
and null; `kernel.KKeyboard` drains it once per vblank after the pads into a 64-entry queue, never
in a digest run; mods reach it through `ModHost.textEntry`/`typed`. While text entry is on, only the
arrows of a keyboard that plays pad 0 still press it. onlinemenu: the keyboard lost ':' — a player
types an IPv4 address only, the port is the game's (9457, `Online.PORT`, recorded in ADR-0035) and
DONE tries it ("no network yet" until the kernel has a network service); typed digits and '.' go
in, Backspace/Enter/Escape delete, finish, cancel, anything else is ignored. Found testing: typing
is no pad input, so the game's idle counter (80051604h) ran on and the attract demo started as the
menu came back; the keyboard holds it at zero and gives the field up if the game leaves the menu.
Verified: conformance `Keyboard` `6dc16bae` on JS and reflaxe.CPP (`Settings` now `929d4dc2`,
IP-only data); SDL2 and Dreamcast input compile clean; check.sh (39 ABI functions per backend),
tool tests 489, test.sh JS gate `329de455`; headless: 2,400 frames at the keyboard, Enter, demo
1,861 frames later; the owner typed an address in the browser. Crash Bash 3000 `654669df`, 9000
`fda4764f` unchanged.

**2026-09-28: Console settings in the HLE kernel (ADR-0034) — ONLINE remembers the last address.**
`kernel.KSettings` keeps named values for the console in `system.cfg` (`key=value`, 4 KB) through
`bp_storage_*`: shared by every game and mod, never inside a game's save (memory cards are not
emulated yet anyway), untouched by headless digest runs. `ModHost.setting`/`setSetting` for mods;
onlinemenu keeps `net.last_address` on DONE and opens the keyboard on it (CANCEL leaves it). The
browser's host now implements storage in `localStorage` (`recompsx:<name>`, base64, blobs <= 256
KB; the VRAM dump is only logged) and the shim reads it back (Node: the files it writes). The dev
server sends `Cache-Control: no-cache` for the page and build.json — the first test ran an old,
heuristically cached index.html beside the new bundle. Verified: conformance `Settings`
`90ccce70` on JS and reflaxe.CPP; in the browser 1.1.1.1 accepted, kept as
`net.last_address=1.1.1.1`, and back in the keyboard after a reload and a fresh boot. Default
builds unchanged (Crash Bash 3000 `654669df`, 9000 `fda4764f`; test.sh passes).

**2026-09-28: Cross works in Crash Bash's menus; Battle Mode and Adventure mode walked in; ONLINE's
address keyboard.** Cross on Select Game Type played its sound and stayed: the menu screen
manager's "next screen" setter (8001E848h) and its two neighbours are three-instruction leaves the
prologue sweep never finds, and the stage overlay's call reached nothing — no controller had ever
pressed cross before. Hinted (with 8001E838h, 8001E824h), then Battle Mode and Adventure mode
walked with a scripted pad (a temporary mod pressing cross on every screen), feeding the runtime's
reports back round by round (scratchpad closeloop): 11 executable functions, 4 boot and 1 stage
entries, and two new overlays — `stage4` (sector 28382, 71,680 bytes: the battle Battle Mode
starts) and `adventure` (sector 28136, 86,016 bytes: the hub, saving, ENTER NAME, credits; 14
entries). Both walks then run 14,000-16,000 frames with nothing missing; the attract loop's digests
are unchanged (3000 `654669df`, 9000 `fda4764f`, 30000 `2d1ca4b6`). Found on the way: a missing
callee skipped in Adventure mode left the frame loop's mode descriptor at 0 and it called address
0 — gone with the entries. `mods/onlinemenu`: cross on ONLINE opens an address keyboard in the
look of the game's ENTER NAME screen (the real one lives in the adventure overlay, never resident
with the menus, and is not touched): title bar ENTER IP ADDRESS, an entry box, keys 1-7 / 8 9 0 .
: and '<' (the name keyboard's delete) 40 units apart, DONE and CANCEL; d-pad, cross, triangle
back, square delete, start done; the address is validated (four numbers 0..255, optional :port)
and kept for the network service the HLE kernel will offer. Built in Select Game Type's own slot
from mod-memory records, right of the character; verified headless (typing 1.1.1.1 and DONE) and
in the browser. The sweep's blind spot — prologue-less leaves after another function's `jr ra` —
will keep surfacing one report at a time; a tool pass for it is in Next up.

**2026-09-28: The browser's WebGL renderer hears of every upload (`BP_CAP_GPU_UPLOADS`) — Crash
Bash's menu text after the cutscene.** With WebGL on, every visit to Select Game Type after the
attract loop's Uka Uka cutscene drew no text (unmodded too; software rendering was right). Measured
in the page: the text primitives were submitted, sampling the 4-bit font at VRAM rows 496..511
(x 176..335, CLUT 1008,350), and there `vramTex` held zeros (2130 of 2560 texels; 1575 differing
from emulated VRAM) — transparent, so every texel was discarded. Cause: at frame ~15060 the game
clears VRAM with one 511x511 rectangle (drawing area the whole of VRAM), which under hardware
drawing reaches only the renderer, then uploads its font again, glyph by glyph. Emulated VRAM had
never lost the font, so since 6db381f ("report a VRAM write only when it changed a pixel", for the
Dreamcast's texture cache) those uploads were never reported, and the renderer — whose drawn
pixels become texels — kept the rectangle's black. A backend answering capability 6 now hears of
every CPU-to-VRAM upload (`Gpu.reportUploads`, set by the launcher); the JS shim answers it for the
page's renderer, the C backends do not (Dreamcast unchanged). Copies stay change-only: the runtime
copies emulated VRAM, which lacks drawn pixels, so reporting an unchanged copy (Crash Bash's 2x1
self-copy every flip) would lay stale pixels over drawn ones. After: the same visit shows the text
(font area 0 mismatches), ~2.6 extra reports a frame (~1300 pixels). Headless digests unchanged
(3000 `654669df`, 9000 `fda4764f`); GpuFill/Raster agree on both targets; test.sh passes.

**2026-09-28: Mods — per-game Haxe that extends a recompiled game (ADR-0033); Crash Bash gets
ONLINE under BATTLE MODE.** A mod is `games/<SERIAL>/mods/<id>/`: `mod.json` (hooked guest
functions by address, scoped to an overlay or "exe"; optional `memory`/`heap`) and sources in
package `<id>`. `recompsx gen --mods <ids|all>` emits one line at each hooked entry — after the
entry pump, only for a real call: `if (entry == 0 [&& entryPump] && mod.ModHost.enter(ctx, a))
return;` — refuses hooks no function begins at, copies the sources and writes `ModList`. Without
`--mods` the generator's output is byte-identical to HEAD's (diffed on Crash Bash). Runtime
`mod.ModHost`: hook (pass, answer, or wrap with `callOriginal`), `call`, onFrame (from
`Kernel.onFrame`), onBoot, a heap with `cstring`/`copy`, guest memory and pads; `mod.ModRam` gives
mods memory past 2 MB at physical 1F000000h (expansion region 1, guest 9F000000h), decoded in the
memory map's slow path just before "unmapped" — all under `-D recompsx_mods`, so default builds are
unchanged: Crash Bash 3000 `654669df`, 9000 `fda4764f`. `scripts/build-web.sh <SERIAL> --mods <ids>`;
check.sh now also holds `games/*/mods` to the portable subset. Tests: tool 489 checks (5 new mod
groups), conformance `ModHooks` `02036850` on JS and reflaxe.CPP. `mods/onlinemenu`: hands the
menu builder (boot 80095BECh) a ten-record list in mod memory (ONLINE appended as widget 8,
TOURNAMENT/OPTIONS/description a line lower, panel +34) and wraps Select Game Type's frame
handler (stage 800B3CA8h) so the game's own up/down land right; cross on ONLINE shows "online
play is coming soon". Verified headless with a scripted pad (every move, highlight and
description) and in the browser (the user). The menu's structure is in games/SCUS94570/notes.md.
Found on the way, not a mod bug: with WebGL on, every visit to the menu after the Uka Uka cutscene
drew no text at all — unmodded too. Fixed the same day (next entry).

**2026-09-28: the runtime moves memory in runs (`shim.Bulk`, ADR-0032).** `shim.Bulk` — copy, equal,
fill16, prefetch; sh4zam on the Dreamcast through `native/recompsx_bulk.h`, the C library elsewhere,
`copyWithin` and typed-array loops on JavaScript — sits under VRAM-to-VRAM copies by rows (mask
bits, right-edge wraps and a row copied onto itself further right stay per pixel), uploads from RAM
by row segments (`Gpu.uploadRun`, for DMA2 blocks; a list's stay word by word), DMA3 sectors
(`Cdrom.dmaCopy`), DMA4 wave data (`Spu.dmaCopy`), DMA6 tables stored directly, and every VRAM fill
(`fill16Index` was a loop of byte stores on C++; on the Dreamcast, runs of 64 halfwords or more go
to `shz_memset8` and shorter spans to halfword stores, the routine's set-up costing more than it
saves on a primitive's spans). The ordering-table walk stays node by node: taking untouched lines
whole, with a prefetch, was tried twice and measured slower on Flycast, because Crash 3's table in
the measured window is dense (685 packets and 1,024 empty nodes a frame, runs of 14) — ADR-0032
keeps the numbers. New conformance tests BulkPaths (6e54771e) and OtWalk (e0887e11, the list walk in
both directions and uploads across list nodes): both digests taken from the per-element code, both
reproduced on both targets; the Dreamcast fill checked on the host against a stand-in for sh4zam at
every offset and length. Game digests unchanged on JavaScript — Crash 3 9000 ee91f215 / 20000
8888c37f, Crash Bash 3000 654669df / 9000 fda4764f / 30000 2d1ca4b6. The Hatchet shim gained `Bulk`
and the `MemA.likely` it lacked. On the Dreamcast the software rasterizer draws only off-screen VRAM
a game reads back (ADR-0030): Crash 3's shadow, 2.5 % of its frame; Crash Bash's arena, none.
Flycast: Crash 3 1498.8 M against round 2's 1498.3 M, 24.7 ms a frame either way — neutral in the
demo, where these paths are small (the 64x64 shadow clear got cheaper, `draw` -5.4 ms); their ground
is loading, menus and FMV. Crash Bash, whose arena uploads and clears every frame, 5775.1 -> 5705.4
M (-1.2 %; its busy time about -2.5 %, the rest now waiting on the vblank): `slowWrite32` 638 -> 217
ms, the fills in `draw` 312 -> 159, uploads (`transferWord`, `putTexel`) 165 -> 5, against 46 ms of
`memmove` and `memcmp`, of 28.5 s. Pictures checked (Crash 3's title and demo, Crash Bash's arenas),
both CDIs rebuilt with the previous round kept as `*.prev.cdi`, and the C++ build's Crash Bash
digest at 3000 is JavaScript's (654669df). The Crash 3 ELF of this build is kept with its source
patch and hashes beside the repository, for addresses a console may report.

**2026-09-28: sh4zam, second round on the Dreamcast — no pvr_prim or pvr_txr_load left, every VRAM
walk prefetched, state records one line each.** `put_hdr`/`put_vtx`/`txr_put` (sh4zam store-queue
copies) moved to `dc_internal.h` and used by every file: the full-screen quad, the no-primitive
present, the profiling overlay and the background uploads (`upload_15bpp`'s row path and
`upload_24bpp`, rows via `txr_put`) no longer call `pvr_prim`/`pvr_txr_load`. `SHZ_PREFETCH`
replaces `__builtin_prefetch` in `twid4_tiles` and is added where VRAM was read cold: `twid8_page`
and `twid15_page` (a line ahead along the row, the next tile row's first lines), both bake
decoders (the next tile row whole), the background uploads (ahead along the row, the next row).
`gstate_t` is a 32-byte aligned record appended with `movca.l` and prefetched with the command
walk. KOS holds `sq_lock(PVR_TA_INPUT)` for a whole list and texture memory shares its QACR region,
so these writes are safe mid-list. Flycast, which counts none of the misses the prefetches exist
for: Crash 3 1504.2 -> 1498.3 M, Crash Bash 5800.1 -> 5775.1 M; pictures checked (logos, the title,
a loading screen, Crash 3's demo, a Crash Bash arena). CDIs rebuilt, the previous round kept as
`out/dc/*.prev.cdi` for a side-by-side on the console.

**2026-09-28: sh4zam first on the Dreamcast; per-backend agent notes; the RAM access path laid out
straight.** The user's rule, now in `src/backend/dreamcast/AGENTS.md` and ADR-0031: on the
Dreamcast a std function with an sh4zam counterpart uses sh4zam (vendored, pinned MIT submodule
`vendor/sh4zam` @ ae8d4c1; the build takes its headers and assembles `shz_mem_sh4.s`). Applied:
every `memcpy`/`memset` in the backend; headers, restated headers and background-mark quads go to
the TA through the direct-rendering store queue (`shz_sq_memcpy32_1`) instead of `pvr_prim`; kept
headers copied with `shz_memcpy32_1`; `gcmd_t` 36 -> 32 bytes, 32-aligned (state 14 bits + kind 2),
so recording allocates its line with `movca.l` (`shz_dcache_alloc_line`) and `build_scene`
prefetches four records ahead; the clipper's vertex padded to 32 bytes (no more `__movstr_i4_odd`
in the backend). Each backend now has its own agent note (`src/backend/{dreamcast,pc,null}/AGENTS.md`,
`web/AGENTS.md`, each with a `CLAUDE.md` that imports it) and AGENTS.md says to read only the one
being worked on. Separately, `MemA.likely` (`__builtin_expect` on C++, identity elsewhere) on the
RAM test of every guest access: GCC had laid the RAM load out of line — a branch away and back
around one `mov.l` at every `lw`/`sw`. Flycast, which models neither branch penalties fully nor
anything sh4zam buys (cache misses, store queues, `movca.l`), gives: Crash 3 1536.3 -> 1510.2 M
with the hint, 1504.2 M with sh4zam too; Crash Bash 5935.9 -> 5827.0 -> 5800.1 M. The verdict on
the sh4zam work is the console's; both playable CDIs in `out/dc` are rebuilt for it. Pictures
checked in Flycast (Crash 3 demo with its shadow, a Crash Bash arena, the title).

**2026-09-27: Crash's shadow on the Dreamcast and in the browser — off-screen drawing stays in
VRAM, and a fill ignores the mask bits.** Crash 3 draws Crash's silhouette every frame into 64x64
at (0,320), which it never displays, and lays that corner on the ground as a subtractive 4-bit
texture (ADR-0030). Under `--video-hw` the Dreamcast never drew it and sampled what the level had
uploaded there (words 1111h..FFFFh): a dark square. The browser's WebGL renderer drew it, but the
game clears the corner with GP0(02h), which psx-spx says ignores the mask bits and writes bit 15
as zero; the renderer kept the old mask bit (stencil) of every pixel, and the words it converted
back read as index 8+ in every fourth texel of the right half — a hatched rectangle over half the
shadow. Now, under hardware drawing, `gpu.Gpu` rasterises into emulated VRAM itself whatever the
Dreamcast's `screen_origin` would decline (drawing area in neither of the last two displayed
rectangles and under 3/4 of the picture; `Scanout.present` feeds `Gpu.shown`) and every fill
meeting neither, reporting the rectangle through `bp_gpu_dirty` at each area change and present.
The software fill no longer obeys E6h (conformance `GpuFill` 4ac33d32 on both targets); a
backend fill is sent under `bp_gpu_mask(0, 0)`; WebGL stores the bit a write would (ZERO unless
"set", INCR in a subtracting primitive's blending pass). Measured headless: Crash 3 draws ~100
off-screen triangles and one 64x64 fill per game frame from frame 4441; Crash Bash none in 30000
frames. Digests unchanged: Crash 3 9000 ee91f215 / 20000 8888c37f, Crash Bash 3000 654669df /
9000 fda4764f / 30000 2d1ca4b6, Raster a749a71a; `RECOMPSX_JS_ONLY=0 scripts/test.sh` passes
(26 conformance tests on both targets, demo 329de455). Flycast shows the silhouette under Crash
and no square. The price, Crash 3's demo window: 1495.0 -> 1536.3 M (+2.8 %, 24.6 -> 25.3 ms a
vblank): the software triangle path (triangle/rowSpan/__sdivsi3/drawPolygon ~220 ms of 7.7 s)
and the page-4 mirror re-decoding that corner (+26 ms), less the hardware path it replaces
(-64 ms). About 3,000 cycles per 4x4 silhouette triangle — the obvious next thing to cut.

**2026-09-27: Bake patches start every 32 texels — Crash's eyebrows, Aku Aku's feathers, the life
icon.** The mixed-CLUT split above still missed primitives whose 64 texels begin on an odd
multiple of 32 (v 160..223): they fit no 64-aligned patch, so they were drawn whole, solid texels
blended, and came out see-through. Measured over Crash 3's demo window: 1,141 such triangles of
14,840 mixed-CLUT 4bpp ones, on two CLUTs. A patch may now start on any 32-texel step, the aligned
one still tried first; Flycast shows the eyebrows opaque. Crash 3 1492.4 -> 1495.0 M.

**2026-09-27: Controllers on the Dreamcast — Crash Bash's libpad handlers, Uka Uka's jaw, profiles
that ignore the host.** With a pad in the port (Flycast plugs one in) Crash Bash's libpad ran its
per-port state machine for the first time and reached three functions the analysis had never
seen (0x80040540, 0x80040584, 0x80040910); they are hints now, and the run is clean. Crash 3's
intro drew Uka Uka's jaw see-through red on the PVR: it is 4bpp with a CLUT of thirteen solid
texels and two STP ones in a 50 % blend, which dc_scene.c drew whole, every texel blended, to save
palette banks. Such primitives now take their solid and STP variants from baked patches, which
spend no bank; the bake pool is 128 (at 64 the demo window re-baked every frame, 3.5 % slower; at
128 about 1 %), and Flycast shows the jaw black as the software renderer does. A `--dc-rxprof` run
keeps its ports empty: with live controllers a key reaching Flycast's window changed what the game
did, and one Crash 3 run measured the title screen instead of the demo. New Flycast baselines, no
pads: Crash 3 **1492.4 M**, Crash Bash **5924.1 M** (the game timeline moved with SIO0, so these
are not comparable with the figures below).

**2026-09-27: Controllers — a digital pad on SIO0, the BIOS pad driver, keyboard and gamepads on JS.**
No game had input on any platform: the SDL2 and Dreamcast backends read pads and the ABI carried
them, but SIO0 was an empty port and nothing sampled the backend. Now `sio.Pads` samples it once
per vblank and SIO0 has a digital pad (ID 5A41h) on each connected port, per psx-spx: transfer
time from JOY_BAUD/JOY_MODE (1088 cycles at the BIOS's 0088h), /ACK 170 cycles after a byte (the
kernel ignores one within ~100 and clears IRQ7 in between) and low for 100, IRQ7 on its edge, no
/ACK after the last byte, SR.9 not clearable while /ACK is low. The memory card address and empty
ports answer FFh unacknowledged, as before. B0:12h-16h (InitPAD, StartPAD, StopPAD, PAD_init,
PAD_dr) are `kernel.KPads`, adapted from OpenBIOS sio0/pad.c and driver.c (MIT), buffers written
at vblank before the game's chains. JavaScript reads the keyboard (the SDL2 key map, by physical
key) and the Gamepad API through Haxe's browser externs (`shim.Input`). Headless runs keep every
port empty, so digests never depend on the host; they still moved, because the empty port now
answers a byte in 1088 cycles instead of 0 and its events count in the scheduler. New references,
JS = desktop C++: Crash 3 9,000 `ee91f215`, 20,000 `8888c37f`; Crash Bash 3,000 `654669df`,
9,000 `fda4764f`, 30,000 `2d1ca4b6`; demo `329de455` unchanged. Conformance `PadSio`, `PadBios` agree on both
targets. Played by the user on the JS build. Not yet: analog pads and config mode, the multitap
(Crash Bash's four players), memory cards.

**2026-09-27: A game's facts are keyed by its disc's product code, and a disc finds its own.**
games/crashbash is now **games/SCUS94570** and games/crash3 **games/SCUS94244** (the code upper
case with its punctuation dropped; `id` repeats it); the Spyro 3 demo's config is gone. `recompsx
gen <disc image>` reads SYSTEM.CNF (loader.SystemCnf), takes the code from the name of the
executable it boots and uses games/<SERIAL>/game.json when there is one, with no local.json
needed; without one it compiles the executable alone, which is how a new game starts. `gen
SCUS94570` names a game by its code and reads the disc its local.json names. The config's
`exeSha256` is now checked, so a different pressing under the same code stops with both hashes
instead of compiling against the wrong hints. Both games generate byte-identical trees by config,
by code and by disc, identical to the trees measured today; tool tests 438 -> 461.

**2026-09-27: build-dc.sh --max adds three SH-4 code-generation flags — Crash 3 -2.6 %, Crash Bash
-1.3 %.** `-mbranch-cost=1 -mdiv=call-fp -flto-partition=one`, each measured on the Flycast
profile, which is exact for a given binary. Flycast M cycles, Crash 3 / Crash Bash: before 1501.5 /
5984.6; branch-cost=1 1473.8 / 5989.4 (GCC's default of 2 makes if-conversion trade short branches
for longer branch-free sequences: the hottest recompiled functions lose 7 % of their instructions);
call-fp alone 1496.6 / 5945.6 (integer division through the FPU's double divide, exact for every
quotient C defines; x / 0 and INT_MIN / -1 never reach C); both 1468.8 / 5957.5; all three
**1463.1 / 5906.0** (one LTO partition: every call sees its callee's register use; the link takes
~3 minutes instead of ~1). Tried and left out: -fschedule-insns -fsched-pressure,
-fsched2-use-superblocks, -fselective-scheduling2, -fira-algorithm=priority (all +0.3 to +0.7 %),
-mpretend-cmove and -fipa-pta (-0.1 % alone, nothing on top), -mlra (GCC 15.2 ICE in reload). The
recorded reasons live beside the flags in build-dc.sh.

**2026-09-27: The Dreamcast backend is split by subsystem — no behaviour change.**
backend_kos.c (4,744 lines) is now nine files: backend_kos.c (lifecycle, launch parameters, time,
logs), dc_video.c, dc_scene.c, dc_textures.c, dc_audio.c, dc_input.c, dc_files.c, dc_prof.c and
dc_fastmem.c. They share only what dc_internal.h declares: build switches, the types more than one
file needs, and the 99 variables and functions one file defines and another uses, grouped by the
file that owns them; everything else stays `static`. Split by a line-accounting script (every
original line lands in exactly one file); the code changes are `static` dropped from the shared
definitions, g_diag given a named type, three declarations divided so their unshared names stay
`static`, and `ow`/`oh` in build_scene initialised (the new unit exposed a -Wmaybe-uninitialized;
they are never read when the state is not placed). check.sh's ABI check reads all of a backend
directory's C files together. Flycast, LTO build: Crash 3 1501.4 -> **1501.5** M, Crash Bash
5982.7 -> **5984.6** M. That is placement, not code: the profile is exact for a given binary (the
same build measures the same count every run), but any relink moves code and data, and functions
whose code did not change moved by up to 0.5 % here; the hot backend functions compile to the
same instructions apart from data addresses.

**2026-09-27: DMA list walk follows empty nodes in a loop of its own — Crash Bash -0.8 %.**
Most of an ordering table is empty nodes that only link on: 2.93 M of the 4.14 M nodes Crash Bash
walks in vblanks 18800-20300 (10.5 M words in the rest). walkList followed each through the full
step — counters, the GPU's entry, the guard — about 76 cycles a node; they now take a load and a
mask each in an inner loop, with the same order, guard and runaway exit. Flycast: Crash Bash
6030.7 -> **5982.7** M (walkList 1574 -> 1301 ms), Crash 3 1504.7 -> **1501.4** M (180 -> 163 ms).
Digests unchanged, JS = desktop C++. (Tried and dropped the same afternoon: registers in locals per
basic block in functions that call — neutral on both games, JS bundle +21 %; see ADR-0029.)

**2026-09-27: The GTE's registers are one array (shim.GteFile) — Crash 3 ~66.5 %, Crash Bash -2.3 %.**
Its 73 registers were static fields, one global each, and on the SH-4 a global is an address loaded
from the literal pool before every access: RTPS read about thirty. They are now properties over one
word array, `recompsx_gte[128]` in the C arena beside RAM (an Int32Array on JS, `int[]` on the JVM),
at constant indices, the RTPS/RTPT registers first so they fall in the sixteen words one instruction
reaches; the compiler keeps the base in a register. `Gte` includes the arena header itself, as
`Memory` does (reflaxe does not carry an extern's include along an inlining chain; the first round
failed to build and profiled the old binary — round scripts now stop on a failed build). Flycast:
Crash 3 1537.7 -> **1504.7** M (GTE 1415.7 -> 1255.5 ms), Crash Bash 6174.2 -> **6030.7** M (GTE
6345 -> 5680 ms, RTPS -463). JS unchanged in speed. Digests unchanged, JS = desktop C++; GteOps/
GteEdge/GteProject/GteSweep unchanged on both targets.

**2026-09-27: Guest registers live in CpuState (ADR-0029) — a stale-register bug fixed, Crash 3 ~65 %.**
Generated code kept each function's registers in locals, published every register it wrote before
a call and reloaded only those the continuation read (ADR-0007/0012). A register written, then
changed by a callee and never read again, was published stale before the next call: Crash 3's
f_80049774 returns a pointer in $v1, its caller at 0x800495c8 reloads only $sp and publishes its
old $v1 before the jalr to f_8004aa94, and from vblank 9898 the game ran differently (RAM hash
differs there). JS and C++ agreed, running the same code. Found by generating the program with
registers as `ctx` fields (to cut the copies the SH-4 paid at every boundary: 31 M register moves
per 300 vblanks) and bisecting the digest to the first differing call. Now registers are CpuState
fields, read and written in place; a looping leaf (no guest call or trap, a loop, <= 20 registers)
keeps locals, which cannot go stale there. RegisterPlan and dead-write elimination are gone.
Flycast M cycles, before / fields everywhere / locals in every leaf / now: Crash 3 1645.0 /
1535.3 / 1564.8 / **1537.7**, Crash Bash 6227.7 / 6282.8 / 6193.0 / **6174.2**. DC images Crash 3
11.60 -> 10.60 MB, Crash Bash 9.46 -> 9.53 MB; JS bundles 15.5 -> 11.8 and 11.4 -> 9.6 MB at the
same speed. New reference digest: Crash 3 20,000 frames `a3419ae4` (9,000 `2c8bc61d`, Crash Bash
`2ff36a18` / `288ed8d6` unchanged), JS = desktop C++. Codegen conformance gains staleAcrossCalls
(v0 = 5 before, 7 now): `c6ccf6ad`, Regions/Yielding unchanged, both targets; 438 tool checks.

**2026-09-27: Guest RAM and scratchpad accesses inline on C++ — Crash 3 on Dreamcast ~57 % -> ~61 %.**
`Memory.read32`/`write32` were 11.5 % of Crash 3's window as calls. `mem.Access` (header-only,
`@:cppInline`, `always_inline`) is now the RAM and scratchpad paths at every call site on C++;
`Memory`'s accessors forward to it, the ports stay out of line in `slowRead*`/`slowWrite*`
(noinline), and JavaScript keeps one call per access (ADR-0013 revision). Counted on JS: Crash 3
makes 7.1 M of 17.1 M accesses in vblanks 4700-5000 to the scratchpad (through a base register
holding 1F800000h), Crash Bash 13.3 M of 64 M in 18800-20300 (its stack). Flycast, Crash 3, M
cycles: 1741.8 -> 1811.5 (RAM inline only; GCC had inlined the port handlers into the out-of-line
half, so every scratchpad access ran their prologue) -> 1749.9 (slow paths noinline) -> **1645.0**
(scratchpad inline too) = 8.23 s per 5 s of game. Crash Bash 6233.1 -> 6227.7 (neutral: its
memory time left is I/O polling). DC images 10.10 -> 11.60 MB and 8.44 -> 9.46 MB, ~30 bytes a
site. Digests unchanged, JS = desktop C++: Crash 3 2c8bc61d / f05fb3ea, Crash Bash 2ff36a18 /
288ed8d6; 23 JS conformance tests unchanged, C++ Mem/Codegen/Regions agree. Measured for what is
next: the hottest generated functions are 13-20 SH-4 instructions per MIPS instruction, ~14 % of
them arithmetic and ~40 % spills and CpuState traffic; 1.5 M guest calls per 300 vblanks move 31 M
register values through CpuState (16.1 M flushes, 15.1 M reloads).

**2026-09-27: Dreamcast renders Crash 3's fades, fruit and letterbox as the PlayStation does.**
Reported on the Dreamcast image, the browser right: every transition a flat grey veil, the Wumpa
fruit see-through, the picture twelve lines high with geometry across the black bars. Measured on
JS: a transition is a full-screen GP0 2Ah quad in mode 2 (B-F), FFFFFF..121212; the fruit are 2Eh
8bpp mode 0, 645 solid texels to 42 STP (only STP texels blend); the drawing area is (0,12)-(511,227)
of a 240-line buffer, and the shadow is drawn into 64x64 at (0,320). Backend: B-F in three passes
(invert, add, invert: exact at the tile buffer's 8 bits); per-texel semi-transparency from texture
variants by STP (AM_VIS/SOLID/STP in palette banks, bake patches and page slots) — solid texels
opaque, STP ones in the state's blend — at 8bpp/15bpp; a 4bpp CLUT holding both stays whole-blended
(Crash 3 binds ~62 CLUTs a frame against 64 banks: split, the banks ran out, +10 %). Primitives are
placed from the displayed buffer that holds their drawing area (they were placed from the area's
own corner), drawing into off-screen VRAM is not shown, and triangles are clipped on the CPU to
the drawing area's edges that lie inside the picture (the PVR's user clip is 32-pixel tiles).
Semi-transparent primitives take an out-of-line path (semi_prim); the opaque loop is as it was.
Bake lookups through a hash index (bake_slot 99 -> 49 ms). Flycast: Crash 3 4700-5000 1696.4 ->
1741.8 M (+2.7 %), Crash Bash 18800-20300 6052.8 -> 6233.1 M (+3.0 %): the new passes and the
clip. Crash 3's display range is the full NTSC 240 lines (V 16..256), so its 12-line bars are the
PlayStation's own (a CRT's overscan hid them): kept, by the user's choice. Known: the shadow reads
VRAM the Dreamcast never draws into (render-to-texture), and is wrong there.

**2026-09-27: Dreamcast background kept per displayed rectangle — Crash 3 ~55 % -> ~59 % speed.**
present_frame was 537 ms of the 9.06 s window, 93 % of it one loop: the displayed VRAM (512x240)
converted into the background texture. Crash 3 double-buffers (x=0 and x=512, switching every
other vblank) and clears with a 512x216 fill that leaves the letterbox strips, so the background
is always needed; a moved rectangle marked it stale, so both pictures were uploaded again at every
flip (~3.3 ms), though nothing wrote them — no VRAM transfer or copy reaches the display area in
vblanks 4700-5000 (counted on JS). The 1 MB background texture now holds up to four slots at the
declared size (512x256 at 16 bpp is 256 KB), one per rectangle, each uploaded again only when
bp_gpu_dirty meets its rectangle; per slot the layout, UVs and clamping are as before, and no PVR
memory is added. In hardware mode VRAM changes only by transfers and copies, both of which report
(triangles, rectangles and fills go to the backend without touching VRAM). Flycast, Crash 3
4700-5000: 1811.4 -> **1696.4** M cycles = 8.48 s per 5 s of game; present_frame 537 -> 11 ms.
Crash Bash 18800-20300: 6160.4 -> 6052.8 M, present_frame 709 -> 92 ms (part of the saving is
waiting now: thd_idle +141 ms). What is left on the GPU side is polygonHw (~420 cycles a triangle) and build_scene
(~415, three vertices converted to floats and colours), 12 % together: micro-optimisation only.

**2026-09-27: GTE projection in 32 bits where that is exact — Crash 3 on Dreamcast ~53 % -> ~55 %.**
RTPS/RTPT cost ~450 / ~1160 SH-4 cycles a command (Flycast's model): each matrix row was rowShr12
(a shift, a mask and a carry per product), each screen coordinate a 64-bit multiply-add with a
five-way range check and a double-word shift. Measured on JS over both benchmark ranges: sf=1 and
lm=0 always, no row product reaches 2^28, vertices beyond +-2^14 are 2,044 of Crash 3's 687,068 and
none of Crash Bash's 2.5 M, quotients beyond 0xFFFF 1.3 % / 3.3 %. `project` now takes a row as one
32-bit sum (MAC = TR + (sum >> 12)) when every component is within +-2^14 and every translation
within +-2^30, and SX/SY/MAC0 and the depth cue as one 32-bit multiply-add when the quotient is
within 16 bits and the sum does not overflow; otherwise the general forms run, out of line
(rowsWide, screenWide, depthCueWide). The divide's tables are flat buffers. New conformance test
GteEdge (20,000 rounds on every edge of those premises): b7218499 with the old code and the new,
both targets; GteOps/GteProject/GteSweep unchanged (de71ee8a/43a78d52/8c701b20). Flycast, Crash 3
4700-5000: 1872.8 -> 1823.0 (32-bit forms) -> **1811.4** M (depth cue and command entries inline)
= 9.06 s per 5 s of game; RTPT+RTPS 1450 -> 1150 ms. Crash Bash 18800-20300: 6400.9 -> 6160.4 M
(RTPS 5303 -> 4211 ms). Digests unchanged, JS = desktop C++: Crash 3 2c8bc61d / f05fb3ea, Crash
Bash 2ff36a18 / 288ed8d6; 23 JS conformance tests. (A range test folded into one comparison per group was
tried for farColorInterpolate too and dropped: one boundary value, base 0x40000000 with IR0
-0x8000, overflows 32 bits there.)

**2026-09-27: Dynamic calls stay in the program (ADR-0028) — Crash 3 on Dreamcast ~48 % -> ~53 %.**
Crash 3 dispatches 730,308 times in vblanks 4700-5000 (450,513 calls through registers, 279,795
tail hops); on the SH-4 each passed `Runtime.call`, its out-of-line body, a `std::function` and
`FnTable.call` — about 150 instructions. Generated code now calls `FnTable.run`: a direct-mapped
cache (16-byte records, empty slots unmatchable), the tail loop, and `Runtime.callOnce` on a miss;
`Runtime.call` hands its address to the bound `FnTable.run` too (`bindRun`), which is where the
renderer's tail chains (2,444 chains of ~114 hops, entered by a static call) were going.
`OverlayMgr.watchWindows` replaces the per-call window version; `callOnce`, `badHandle` (integers
only), `buildFlat`, `Runtime.call` and `Runtime.unwinding` are `noinline` — the last two because
LTO otherwise put `call` and the `std::function` into every generated call site (2,393 copies in
Crash 3, 2,029 in Crash Bash). JS: 718,509 hits, 11,799 misses (GOOL code, never kept).
Profiling Flycast, same range, M cycles: 2080.3 before -> 1975.7 (dispatcher not copied, window
span) -> 1944.2 (cache in `call`) -> 1953.0 (+ version check, needed for correctness) -> 1909.9
(`FnTable.run`) -> 1880.2 (`bindRun`) -> **1872.8** (out of line) = 9.36 s per 5 s of game.
Dispatch was `Runtime::call` 476 + `FnTable::call` 341 + `residentAt` 208 + `std::function` 146
ms; now `FnTable::run` 166 + `FnTable::dispatch` 130 + `FnTable::call` 51 ms. Crash Bash
18800-20300: 6414.8 -> 6400.9 M (dispatch 367 -> 100 ms; LTO now inlines one more `read32` into
f_800193a8, +234 instructions, +163 ms). Digests unchanged, JS = desktop C++: Crash 3 9000
2c8bc61d / 20000 f05fb3ea, Crash Bash 9000 2ff36a18 / 30000 288ed8d6. Conformance JS all, C++
Dispatch/Overlay/Codegen/Yielding/Regions agree; 436 tool checks. DC image 9,987,375 B.

**2026-09-27: Dreamcast 8bpp textures from 64x64 patches — Crash 3 ~30 % -> ~48 % speed.**
An 8bpp page through each of its CLUTs was a whole 128 KB ARGB slot; Crash 3's medieval demo binds
17 such pairs a frame against 12 slots: 5-19 whole-page decodes a frame (`tex_decode` 37 %) and
slots evicted while the PVR still read them. Every 8bpp primitive there samples within one 64x64
patch (273/273, 293/293; ~26 patches a frame), so they now go through the bake pool with their CLUT
applied (`twid_bake8`, patch key carries the depth, invalidation by 32-halfword / 256-entry extents);
a primitive sampling across patches still gets the whole page. Host check: every texel of 64 patches
equals the full-page decoder's and the CLUT lookup (262,144 texels). Flycast, vblanks 4700-5000:
3280 -> 2080 M cycles, no page conflicts left. Crash Bash 18800-20300: 6411.5 -> 6414.8 M (noise).

**2026-09-27: Crash 3's second demo (the diving level) runs; relocatable keys cover code only.**
The fish's seven-word GOOL native routine was keyed on eight words, the eighth an entry reference
the game turns into a pointer on load: missed in RAM, the demo froze at ~10150. Keys now hash only
the instructions from the entry (ADR-0025 revision), separating words are compared only where a
function has code. Crash 3 JS: 20000 frames through both demos, nothing missing, digest f05fb3ea
(9000 unchanged, 2c8bc61d). Crash Bash unchanged (2ff36a18 / 30000 288ed8d6). 436 tool checks.
C++ for Crash 3, first time: reflaxe.CPP 6 min 19 s (74 files, 19 MB); desktop null backend equals
JS at 9000 2c8bc61d and 20000 f05fb3ea (20000 frames in 10.2 s). Dreamcast `build-dc.sh _c3 --max`:
loaded image 9,998,279 bytes; out/dc/crash3-reflaxe-max.cdi (334 MB, `--video-hw --dc-overlay
--audio-hw`). Profiling Flycast, vblanks 4700-5000 (the medieval demo): boots and runs clean, 3280 M
cycles = 16.4 s for 5 s of game, ~30 % speed; `tex_decode` 36.7 % — 5-19 texture page conflicts a
frame against 12 big slots. (A background shell once picked the system Haxe 5 and reflaxe.CPP failed
at Runtime.hx:19 "Cannot assign null"; the pinned 4.3.7 compiles it.)

**2026-09-26: Crash 3 draws boxes, enemies and objects — a helper's return to its caller's caller.**
Found with DuckStation as the oracle (GDB stub): same draw-list nodes, and Crash/camera identical
frame for frame through the demo (931 of 931 samples, 114 frames apart from our faster loading).
The per-object bounding-box test (0x8003def4) calls a helper per corner that, on a visible corner,
reloads the test's saved `$ra` from the scratchpad and jumps there; compiled as a plain return, the
test always ended "not visible". ADR-0027: a return a foreign `lw $ra` can reach is checked against
the entry `$ra`, and a mismatch unwinds (`Runtime.RETURN`) to the frame whose call continues at the
target, cooperative frames included. Crash 3: 127 checked returns, JS 9000 frames 2c8bc61d (was
7f7d8a93: now drawn). Crash Bash: 30, digests unchanged (9000 2ff36a18, 30000 288ed8d6). WebGL:
pixels drawn into VRAM are converted back into the texture VRAM before a primitive samples them
(Crash's shadow was a square); the page loads the renderer under its own version. Gate green on JS
(check.sh clean, 22 conformance tests, 423 tool checks).

**2026-09-26: Crash Bandicoot: Warped runs its whole attract loop on JS — native GOOL code compiled from the disc.**
Title, intro, DEMO gameplay and back to the title, 9000 frames with no missing code. GOOL runs MIPS
embedded in bytecode at heap addresses; per the user, no interpreter: ADR-0025 compiles it from the
NSF files (`relocatable` stanza: marker, unit, hashWords) and recognises it by content at run time
(1,313 functions, keys with separating positions where shared). ADR-0026: computed tail jumps are run
by the caller (the renderer's per-primitive hops overflowed the stack). Tool: `jalr rd, $ra` returns,
`jr $ra` after the function set `$ra` is a jump. Crash Bash codegen/digests unchanged by all of it
(9000 2ff36a18, 30000 288ed8d6); gate green, 417 tool checks.

**2026-09-26: a third game — Crash Bandicoot: Warped (games/crash3) boots on JS through its intro.**
Config: the GOOL interpreter's scratchpad-based opcode table and hand-written computed jumps via
`jumpTableHints` (now implemented: `{jrAddr, tableBase, count}` or `{jrAddr, targets[]}`), 148 entry
hints, the `warp` overlay (S0/WARPSCUS.BIN). General fixes it forced: block 0 is the function entry
even with blocks below it; `jr` through a copy of `$ra` is a return (Crash Bash codegen unchanged);
root-counter interrupts (TIMER0-2 scheduler slots, bit 10, one-shot/repeat, pulse/toggle; RCnt
events F2000000h+n); the kernel's fallback only takes lines pending when the exception was taken;
kernel handlers and event callbacks run on an exception stack (OpenBIOS vectors.s); pump-drained
event callbacks preserve the interrupted registers; rectangles clip to the drawing area; the
hardware rect colour is 24-bit as the ABI says. Crash Bash: CdRead retries 6 -> 1 (the one left is
its own SCEx check), digests move to 9000 2ff36a18 / 30000 288ed8d6 (C++ not re-measured; the user
chose JS-only for now). Crash 3 stops ~frame 2400: GOOL runs native MIPS embedded in bytecode at
heap addresses (op 0x49, `jalr $s5`), which ADR-0006's fixed-window overlays and the no-interpreter
rule do not cover — a decision is pending (games/crash3/notes.md).

**2026-09-26: GTE — RTPS/RTPT rows exact in 32 bits; the depth cue's IR0 fixed to the spec.**
RTPS/RTPT rows are 32-bit (exact while |TR| < 2^30; checked 44-bit path otherwise) and RTPT is one
body with `project`/`unrDivide` forced inline on C++. New conformance `GteProject` (12000 random
RTPS/RTPT, every edge) proved it bit-identical to the old code before the fix. Then IR0 =
sat(MAC0 >> 12) as docs/specs/runtime.md §5 says (the shift was missing): GteOps de71ee8a,
GteProject 43a78d52. Crash Bash never reads an RTPS-produced IR0, so its digests stay
(9000 ab13c60f, 30000 4b78c2de). Dreamcast: `--dc-bench=FROM:TO` and `--dc-fastmem-test`.

**2026-09-26: the Dreamcast overlay splits the emulated frame: `emu gte spu aica` / `gpu up build fin wait`.**
`emu` is now only what remains (recompiled code, kernel, memory, timers); GTE commands, GPU DMA
(list walk + primitive decode + backend recording), SPU, AICA and disc come out of it, so every
number is its own and they add up. GPU and SPU are timed; GTE (thousands a frame) is sampled by the
1 kHz TMU1 sampler, a tick = 1 ms. PVR setup is already minimal (one TR list, no autosort, depth
ALWAYS, no modifiers/fog/FSAA) and `wait` ~2 ms / 30 frames: the SH-4 is the bottleneck, not the PVR.

**2026-09-26: Dreamcast loading-screen freezes: the disc read-ahead is contiguous and adaptive.**
The multi-second freezes (the last note looping) were disc waits: one Flycast 30-vblank window on
a loading screen spent 2492 of 3007 ms in `disc`. A seek read a whole 128 KB window synchronously
and each prefetch stepped back 4 KB. Now a seek reads 16 KB and the next windows follow it back to
back, doubling to 128 KB. Simulated: worst stall -35..40 %, total -30..65 %. Flycast: the user sees a clear improvement.
reflaxe.CPP `--max` is the Dreamcast baseline (the user's measurement); Hatchet is set aside.

**2026-09-26: the game runs bit-identically through Hatchet (Haxe -> C++98), a reflaxe.CPP candidate.**
`scripts/build-hatchet.sh` (fork github.com/barisyild/hatchet, branch `recompsx`) transpiles runtime +
generated game in ~6 s instead of reflaxe.CPP's 9.5 min; every game digest matches through 70,000 frames;
with LTO it is ~5 % faster than reflaxe.CPP with LTO on the desktop; the Dreamcast image is the same size.
Not adopted: golden rule 2 still names reflaxe.CPP, and a switch needs an ADR plus the conformance suite
and a Dreamcast measurement on Hatchet.

**2026-09-25: the cutscene's sound is back on the Dreamcast; the attract loop has no missing code.**
Notes longer than an AICA channel (the intro cutscene streams 10-second notes) are declined at
their key-on and mixed by the runtime; everything else stays on the AICA. The third mini-game's
overlay was missing (its initialiser refused by an over-strict tool check); 70,000 frames clean.

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

00000. **Dreamcast full speed: the demo is what is left (2026-10-04 afternoon; ledger E-138..E-148).**
   Under the model Crash 3's title, Uka Uka scene and warp room and all three of Crash Bash's windows
   are at full speed (16.6-16.7 a present); Crash 3's gameplay demo (Toad Village) is at 20.58 (g99
   on r138's placement), and it needs ~7 ms less a 30 Hz pair (~3.2 a present). In order:
   1. **Hardware:** the tester runs out/dc/crash3-r138-max.cdi and crashbash-r138-max.cdi (the model:
      Uka Uka 16.58, warp room 16.64, demo 20.58; Ballistix and its disc load 16.6); fm136's pair is
      still unreported.
   2. **Placement round r140** for g101's code (E-150; running: out/_work/r140.sh — round6f.sh,
      round6cb.sh with every window traced at length and sliced, then round5d.sh; r139's, the same
      for g99, is installed: demo 20.02). Then install it (out/_work/install139.py as the pattern),
      the Dreamcast digests and TA hash of its p2 builds, and CDIs for the tester.
   3. **Where the demo's present goes** (Status snapshot): the graphics path is ~1,550 SH-4
      instructions a triangle and ~37 % of the instructions, and halving it alone would close the
      gap; no single change does that while the TA stream stays exactly the same (palette banks and
      the cover skip are decided over the whole frame). Medium items, measured or estimated:
      the arena's hot tables (Gpu.opCount: 0.07 ms of operand conflicts in the list walk;
      Gpu.wholeWords, FnTable's FAST) made placeable — today malloc puts them where the data
      placement cannot see (shim native header: edit when no round is building); the quad's second
      triangle in the same call into the polygon core (~0.15); the triangle record written by the
      core (~0.1-0.15); `unwindToken` returned (~0.1); the GTE's RTPT as one call (~0.1-0.2).
      ADR-0048 with a register allocator stays the largest lever for the generated code (~2.8 SH-4
      cycles a PlayStation cycle of ~7.1).
   4. Rejected this round, not to be retried as they stood: GCC's inliner given room (E-142), FAST
      in fewer slots (E-143), pre-RA scheduling for the game's code (E-144), the scene build at -O2
      (E-145, E-145b).

0000. **Dreamcast full speed after fastmem (2026-10-04; ADR-0049, ledger E-135..E-137).** Option A is
   in, with its placement round: exact on both games; Crash 3's demo 25.50 → 22.02, Crash Bash at
   full speed (16.63). In order:
   1. **Hardware:** the tester runs out/dc/crash3-fm136-max.cdi and crashbash-fm136-max.cdi
      (round r136 installed, E-137; the model: Toad Village 22.02, Uka Uka 18.38, the warp room
      16.95, Ballistix 16.63) — the first builds with the MMU on, so a crash or a stall at boot is
      the first thing to rule out; the previous CDIs (crash3-r130, crashbash-r126) stay for
      comparison.
   2. **Where Crash 3's gameplay still goes** (f7n, the model's counts): ~3.4 M SH-4 instructions a
      frame — the GPU path ~1.3 M for ~700 polygon packets (~1,900 a packet: the polygon core 456 a
      call, `Gpu.triangle` 1,112, the DMA walk 744 a call, `run_tris` 917 a run, textures ~120 K),
      the generated code 1.07 M (3.6-4.6 SH-4 instructions a guest one in the hot renderer
      functions), the GTE cores ~0.5 M (~195 a vertex). Options, the owner's approval standing:
      (C) the scene straight to the PVR — streaming alone (no record and walk) ~0.8-1 ms; a fused
      fast path for the common polygons, decode to TA vertices in one block, up to ~4 ms, a large
      assembly job held to the TA hash; (B) ADR-0048's emitter — measured on fastmem (E-136): still
      16-23 % more instructions than GCC, needs an allocator and a scheduler before it pays.
   3. Crash Bash: Ballistix is at 16.62 on r136p1 (work 12.68, the pacer idle 2.66); its traps
      (~1,000 a frame, the root counters through a pointer) are ~0.85 ms.

000. **Dreamcast full speed — what is left (2026-10-03, night; docs/perf/dreamcast-ledger.md E-113..E-129).**
   Under the cache model (round r126) the title screen fits its 30 Hz pairs (16.64 a frame, work 15.03)
   and so does Ballistix (16.72; work 13.25). Crash 3's gameplay demo is at 25.01 ms a frame (cf
   22.39): the PlayStation is ~95 % busy in both vblanks of its pairs, and what is left to take in
   place is 0.05-0.3 ms an item — the owner's decision on the architectural options (Blockers,
   2026-10-03) decides what comes after. In order:
   1. **Hardware.** 5fa9442's CDIs measured (E-130: Toad Village 25.2 ms a frame, the model 25.49;
      titles and menus at 60). Next `out/dc/crash3-r126-max.cdi` / `crashbash-r126-max.cdi`
      (E-113..E-128: model 25.01 / 16.72; their code's game digests on the Dreamcast are
      JavaScript's, its TA hash ta9's), and a Ballistix shot of either.
   1b. **Model windows of more play.** The gameplay demo matches Toad Village's overlay (E-130);
      the warp room and the intro's dark Uka Uka scene run other renderers (f_800418cc, f_800415a4,
      f_80042c58). `sio.PadScript` (`--pad-script F:B,...`, every game and target) reaches them
      from a START at 3400: bench discs out/dc/c3data-uka (6750:7050) and c3data-warp
      (15000:15300); JS digests with that script a0b9d5bc at 7050, f4e397b8 at 15300.
   2. **The owner's call** on Blockers 2026-10-03, asked again 2026-10-04 with the numbers: (A)
      guest RAM through the MMU (~2-2.5 ms, the decode's ~30 % of the generated code; not
      measurable on the model; the trap handler needs the clock, so `cyc` in a fixed register or
      stored before each access), (B) **ADR-0048** — its first step measured (E-131): exact, and a
      third more instructions than GCC's for the same functions; parity or better needs an
      allocator and spans, weeks, ~1-2.7 ms at best, (C) the scene straight to the PVR (~0.7-1.5
      ms), (D) auto frame-skip (full game speed, fewer pictures). Even A+B+C is ~4-6 of the ~8.8 ms
      Toad Village needs; the realistic target without D is ~18-20 ms a frame there.
   3. **In place, measured and not yet tried** (ledger, Not tried yet): the list walk's events
      (~0.1-0.2 ms, ADR-0039 permitting), `Gpu.opCount` off the list walk's path (~0.03 ms). Probes in
      the JavaScript build (counters spliced into the generated Haxe: span takes and their first
      uses, unspanned accesses repeating a base, slow port reads by address) found E-125 and E-126;
      the rest they showed is small (E-127, E-129).
   Done since 5fa9442: E-113/E-114/E-117 (the scene build's lookups exact and cheaper), rounds r114
   (E-116) and r117 (E-119), E-122a, E-125 (function spans where every path needs them, −0.34 ms of
   gameplay's generated code), E-126 (timer 2's reads, event delivery), round r126 (E-128,
   installed); rejected: E-115 (far-branch islands, kept opt-in), E-118, E-120, E-121, E-122b, E-123,
   E-124, E-127, E-129.

00. **Dreamcast placement, the follow-ups (ADR-0043).**
   1. Confirm it on hardware: `out/dc/crash3-placed-max.cdi` against
      `out/dc/crash3-unplaced-max.cdi`, the same sources. The model reads the title screen at 29.5
      against 35.1 ms a frame; the console read crash3-periph-max at 39.3.
   2. Crash Bash's placement: a traced model run of its bench window (18800:20300), then
      `dc-icache-sim opt` (src/backend/dreamcast/AGENTS.md, Measuring).
   3. The operand side. Constants moving with their code cost 0.5 ms, and the hot data is placed by
      nobody: 2 ms of operand conflicts a frame remain.
0. **Find prologue-less leaf functions.** A three-instruction leaf right after another function's
   `jr ra` + delay slot (Crash Bash's 8001E824h/838h/848h, 8002C290h/29Ch) is invisible to the
   prologue sweep and surfaces only as a runtime "no function at" when first called. A pass that
   tries the word after every function end as a candidate leaf (decodes cleanly, reaches its own
   `jr ra` within a few instructions, touches no unknown state) would find them at gen time.
   Those an overlay calls are found since 2026-09-28 (`Main.calledFromOverlays`: Crash 3's libcard
   stubs); what remains are the ones reached only through pointers.
**Dreamcast, sh4zam candidates (surveyed 2026-09-28; judged on hardware, not Flycast).** sh4zam is
float maths and memory/cache/store-queue routines; nothing in the runtime or the generated code is
float, and the backend has no libm call, so its maths has nothing to replace — the ground is
memory. In order of value for effort:
1-5. Done 2026-09-28 (see the snapshot): the backend's `__builtin_prefetch`, `pvr_prim` and
   `pvr_txr_load` replaced by sh4zam; source prefetch in every texture decoder; `gstate_t` as a
   movca'd, prefetched 32-byte line; background uploads through `txr_put` with prefetch; the
   runtime's VRAM copies, uploads, fills and DMA3/4/6 in runs through `shim.Bulk` (ADR-0032).
6. Codegen, patterns to hardware paths: prefetch for loads that stream with a constant stride —
   found by a JS profiling pass per load site, kept per game in game.json, emitted as
   `Bulk.prefetch` (the hot Crash 3 functions are loop-free callees; the loops are their callers);
   then Psy-Q memcpy/memset/bzero in game code recognised by content and routed to `Bulk`.
Not candidates: the GTE and all game logic (bit-exact integer), the SPU/AICA path (integer).

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

11. **Open: unsignedness leaks out of nested `>>>` into signed operations.** The minimal
    `static function f(x:Int):Int return ((x >>> 24) << 24) >> 24;` returns -1 for `f(-1)` on JS,
    but 255 on reflaxe.CPP. Generated C++ is
    `((static_cast<unsigned int>(x) >> 24) << 24) >> 24`, so the final shift is logical despite
    Haxe's signed `Int` semantics. Verified with the pinned common analyzer/full-DCE flags by
    `out/_memory_values/ShiftProbe.hx`; logs `shift-js.log` / `shift-cpp.log` retain both results.
    Scalar memory forwarding initially exposed 244 signed-byte/halfword failures. Its extraction
    now uses arithmetic `>>` before masking/sign extension, which discards the same high bits
    and passes `ScalarEffects` on both targets (3cfb6f71, 1136641 values). That transformation
    is valid for byte extraction, not a general replacement of unsigned MIPS shifts. No vendor
    compiler change was made; the defect remains an upstream/fork backlog item.

12. **FIXED by patch 0006: short-circuit RHS bindings were evaluated unconditionally.**
    Reflaxe's `EverythingIsExprSanitizer` processed both operands as ordinary values. When
    Haxe inlined a call with a reused argument, its argument binding became a preceding
    statement outside the boolean guard. This also evaluated the RHS before a side-effecting
    LHS. Minimal `ShortCircuit` reproduction with analyzer/full DCE: JS `af4a1a9e` (22 values,
    zero failures), unpatched C++ `26a99a13` (11 assertion failures). Logs:
    `out/_body_budget/short-circuit-before.log`. The expanded 53-value fixture additionally
    covers assignments, conditional branches, nested operands and while/do-while conditions.
    Patched JS/C++ agree at `157a406f`.

    The native fault was concrete: generated `Scheduler.scheduleAt` read `due[nextSlot]`
    before `nextSlot < 0` could skip it, with `nextSlot == -1` at init; `runDue` had the same
    problem under `&&`. Both macOS crash reports identified `Scheduler.init`, and their
    fault addresses were four bytes before the allocation. The old executable sometimes
    passed because those invalid bytes happened to be readable. Patch 0006 lowers only a
    statement-requiring RHS into an if/else, preserving simple native operators. Generated
    scheduler reads are now inside the appropriate branch. Runtime source and optimizer
    flags are unchanged. Setup applies the exported patch idempotently and spike.sh runs
    the cross-target regression. No submodule pin changed.

## Blockers & open questions

- **Decided (2026-10-04, the owner):** frame skipping never; the three architectural options
  below are all approved, in any order — (1) ADR-0048 accepted, (2) and (3) to be written up as
  they are started. Work order chosen from what the cache model can measure: ADR-0048's emitter
  first (its leaf functions, then loops and the GTE), the scene straight to the PVR next, guest
  RAM through the MMU last — the model maps P0 through the MMU (Flycast's on-demand full MMU,
  `--dc-fastmem-test` "ok") but took 1 of 4,096 TLB misses as a trap, so the I/O path of a
  fastmem build can only be measured on the console.
- **Open (2026-10-03): Crash 3's gameplay needs a redesign to reach full speed, not more
  increments.** At ~25.5 ms a frame under the cache model (a 30 Hz pair ~51 ms against 33.4), every
  part has to lose a third. Measured on E-112's build, a gameplay frame: 3.69 M SH-4 instructions —
  generated code 1.41 M (~290 K guest instructions, ~4.9 each), the backend 1.11 M (the scene build
  ~700 K for ~1,350 triangles, ~520 each; the GPU's polygon core 270 K, ~200 each), the GTE cores
  0.47 M, the GPU runtime 0.30 M. The generated code's 12.3 ms are 4.4 of issue and 4.3 of capacity
  fills (its hot code spans ~420 KB of lines); by construct, guest memory access is 30 % of it
  (unspanned decode 13.6 %, span tests 9.3 %, span set-up 7.4 %) and registers in CpuState 20 %.
  What is left to try in place is 0.05-0.2 ms an item (E-113..E-115: two exact backend batches,
  −36 K instructions a frame; far-branch islands, no gain on the model). What would move it by
  milliseconds is architectural — each its own ADR and the owner's call:
  1. **Guest code generated for the SH-4 directly** (guest registers allocated to the SH-4's, the
     memory decode's constants in registers, no CpuState traffic on hot paths): the generated code's
     ~10.7 ms toward ~6-7 (ADR-0048's count for one function: a quarter fewer instructions); weeks; a second code path beside reflaxe.CPP's, for the Dreamcast only.
     Written up as **ADR-0048 (proposed)**, with the measurements behind it (ledger, "Where the time
     goes (2026-10-03)": pool loads 13 % of the generated code and 0.99 ms of operand fills, CpuState
     ~20 %, span set-ups ~146 K instructions a frame, 31 % of fetched code slots never run).
  2. **The scene straight to the PVR** as the list is walked (no record and second pass; palette banks
     from the previous frame's counts): ~0.7-1.5 ms; days; the TA stream no longer comparable by hash
     to today's, so checked by pictures.
  3. **Guest RAM through the SH-4's MMU** (no decode on any access; I/O by TLB miss and a handler):
     ~2-3 ms; the cache model cannot measure it, and ~560 port accesses a frame would each pay an
     exception.
  Even (1) alone would leave gameplay near 18 ms: full speed there needs it and more of the rest.

- **Open (2026-10-02): entries for shared code no entry starts change Crash 3's picture.** On
  top of `--cut-shared`, giving a block more functions carry than the block entering it an entry
  of its own (114 such heads in Crash 3) changed the headless digest by frame 2522 (VRAM only;
  every counter and the cycle count equal), while each subset of the heads tried alone kept it.
  Not kept; the interaction is not understood (ADR-0045).

- **Open (2026-10-02): ADR-0044 recovery has no measured Dreamcast speed effect.** All of it —
  helpers, projections, value regions, now the GTE and LWL/LWR — changes the generated code's
  executed instructions by <= 0.4 % in every window (E-067, E-068); recovered functions run 1-2 %
  of them. Gameplay cf varies by +/-0.2 ms between builds with equal instructions (layout), so a
  claim inside that needs `dc-cmp.py`'s issue column. The remaining acyclic GTE/LWL candidates need
  spans anchored at computed addresses, and their CpuState share (~15 %) bounds the gain. Owner's
  decision wanted before more recovery work: loops, or the global costs measured beside it.

- **Open (2026-10-02): misaligned general-path word reads differ between targets.** JS
  `MemA.get32` reads `i32[a >> 2]`, the aligned word; C++ reads the four bytes at `a`. A draft of
  `ScalarShare` with a base of 0x80040022 agreed within each target (reference against optimized)
  but its digests differed (JS 394b5777, C++ 107f793f). The R3000A raises an address error for a
  misaligned `lw`/`lh`/`sw`/`sh`, which the runtime does not model; the fixture now avoids misaligned
  bases. Decide one semantics (the exception, or a shared definition) before relying on either.

- **Open (2026-10-02): memory projections reduce state publication but grow JS.** 73/108
  caller-specific adapters add 134,028/209,624 B. Five alternating pairs have mixed signs:
  C3 median -4.11% with three slower pairs; CB +4.10% with three faster pairs. Do not call this
  a demonstrated speedup. Identical helper/adapter pairs within owning classes collapse to
  48/69 distinct bodies; assess sharing before further specialization. Preserve the bounded
  game digests, full memory preflight, original owner fallback and public-entry state.
  Sharing now emits those 48/69 pairs (ES6 JS -41,985/-82,888 B); ten child-CPU-time pairs on a
  loaded host show no established speed change (pairwise medians C3 -0.13%, CB +1.73%).

- **Open (2026-10-02): wider whole-function recovery may cost JS execution time.** The live-body
  budget adds 11 C3/12 CB helpers without changing prior helper bodies or 20k digests. Five
  alternating pairs show C3 +5.09% by median (four slower pairs), CB -13.57% with a +30.53%
  final-pair outlier. Host load varies and ranges overlap. Treat this as a coverage/clean-source
  improvement with an unresolved performance tradeoff, not a demonstrated general speedup.
  Investigate call-entry guards and state/result publication with `out/_body_budget` as the
  preserved comparison; do not compare absolute times with another session.

- **Resolved (2026-10-02): intermittent native scheduler fault.** Compiler defect 12 above
  hoisted a guarded `due[-1]` read; patch 0006 preserves short circuiting. ShortCircuit and
  rebuilt ScalarPointers/ScalarCompose now agree on JS/C++. Original failures remain in
  `out/_body_budget/{cross,cross-final}.log`; corrected results are in `cross-fixed.log`.
  The earlier LLVM 18 sanitizer attempt stalled before main and provides no memory-safety
  evidence. Resolution rests on the deterministic before/after semantic regression and
  inspection of the corrected generated control flow, not on repeated successful launches.

- **Open (2026-10-01): general call/stack recovery remains bounded.** Checked immutable loaded
  pointers now enter whole-helper preflight, including through nested signatures. A pointer
  changed by earlier writes still needs either an exact forwarded value or continuation/state
  reconstruction after those effects; it cannot use a stale entry sample or restart a partly
  executed body. Different-pointer phis, general loops, larger signatures and stack-object/
  escape recovery remain open. The loaded-pointer proof adds 22 C3/25 CB helpers; it does not establish
  a speed benefit or complete state removal. Loaded-pointer sample medians increased 1.29%
  (C3) / 2.72% (CB), with overlapping ranges and reversed pair order. The subsequent typed-
  sample lowering removes 13/23 static body-read sites and improves its own paired sample
  medians 3.80%/1.24%. The subsequent result lowering removes unconditional known-value
  transport (40/70 static result words), with full guards and unchanged 20k game digests.
  Unconditional child result proofs now propagate too, with constant nested charges and
  exact narrow-forwarded read versions. That stage removed calls in synthetic cases and
  left both game JS files byte-identical. The following live-body budget stage admits
  another 11 C3/12 CB helpers, with a larger JS bundle and unchanged 20k game digests.
  Entry work, conditional result proofs, HI/LO values and broader function/loop coverage
  remain concrete optimization targets; no cross-session timing comparison is valid.

- **Open (2026-10-01): affine call-span reuse has no established JS speed benefit.**
  The new register-alias proof adds 13 C3 and two CB call sites and preserves both 20k digests.
  Five-pair C3 timing medians increased 7.4%, then 0.6% in a reversed-order repeat; host load
  varied and ranges overlap. CB was -0.9%. Keep both runs in `out/_scalar_alias`. The initial
  Node profiles in `out/_scalar_profile` hardly sample the shared adapters and do not isolate
  CpuState assignments inside generated bodies. Entry/state-publication and fallback costs
  therefore remain unresolved before further expansion on performance grounds.

- **Open (2026-10-01): misaligned guest wide accesses have no portable fallback semantics.**
  `Memory` uses `MemA` with an alignment precondition, while the emitter still does not raise
  AdEL/AdES (the existing tool.md limitation). A new scalar fixture's invalid `lw` at 80040001h
  exposed JS rounding the typed-array index versus C++ loading at the byte address; a strict
  alignment host may fault. This predates scalar signatures. Its guard correctly rejects the
  fast path. `ScalarResults` now tests that generated guard without violating MemA's contract;
  aligned mirror/scratchpad-boundary and MMIO fallbacks still run against the original bodies.
  The loaded-pointer fixture also keeps guest wide pointers aligned after a byte mutation;
  its invalid intermediate/source alignments are checked by guard-only probes.
  Implement guest address errors before treating misaligned wide loads/stores as supported.

- **Open (2026-09-28): the Dreamcast build diverged between identical Flycast runs.** One save
  state was run three times in the fork's interpreter, with no pad pressed and no change to the
  program. The first 203 presents matched. After that, two runs parted at present 203 and a third
  at 253, by a few hundred CPU cycles at a walk's start and then in the scene itself.
  Disc reads are synchronous and the audio path is written to leave game state alone, so the
  first suspects are host input reaching the window (Flycast maps the keyboard to the pad, and
  the fork's window takes focus) and anything else the backend returns into emulated state.
  `dc_input.c` empties the ports under `--dc-rxprof` for exactly that reason, and the watched CDI
  had no `--dc-rxprof`. The next step is a run with the fork's input cut off. If it still diverges,
  it is a golden-rule-3 leak on the Dreamcast.

- **Open: I_MASK.7 (SIO0) after `_bu_init`.** The kernel has unmasked SIO0 there since e468132
  ("_bu_init does the same for SIO0"), and games that drive their pads through SIO0 have run
  with it. OpenBIOS's card driver unmasks it only while a transfer runs and masks it again at the
  end, so after `_bu_init` it would be masked. Kept as it was (ADR-0037); a retail fixture or a
  DuckStation read of I_MASK after `_bu_init` would settle it.

- **Resolved (2026-09-28): the CDIs stopped at a black screen on a real BIOS.** Booted from the
  disc — on the console, and in Demul and Flycast with a real BIOS — the playable CDIs showed the
  Dreamcast logo and then nothing, while the same ELF ran under dcload and Flycast's HLE BIOS hid
  it. The profile overlay drew its text with KOS's bfont, which takes the BIOS font lock by polling
  `syscall_font_lock()` with no timeout, and the BIOS lends that lock only while no G1 DMA runs
  ("you can't access the BIOS font during G1 DMA", dc/syscalls.h): the disc's reads kept it away
  and the first overlay report never returned. Found by booting the CDI in Flycast with the real
  BIOS (a HOME of its own, so the profiling setup keeps its HLE BIOS), `rxprof` enabled for the
  serial console, and a PC histogram of the hang — all KOS scheduler and `bfont_lock`. Fixed: the
  overlay copies its 95 ASCII glyphs once at init, before the disc streams, taking the lock with a
  one-second limit, and draws from RAM; a busy font costs the overlay its text, not the game.
  Verified on the real BIOS in Flycast: Crash 3 reaches the hub with the overlay up.

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
2026-10-05 [claude] ADR-0054 (the owner's report: Crash 3's level transitions): the software rasteriser keeps a texel's bit 15 (psx-spx); bp_gpu_copy + BP_CAP_GPU_COPIES (7) — WebGL copies what it drew (mask bit as depth), the DC draws copies from its pictures and binds a picture as a 15-bit page (512x256, dim_v).
Digests JS = DC: C3 5000 52875c77, Crash Bash 20300 37eefb07; Raster 1bdad19d JS = C++; conformance JS 64/64; check.sh clean (52 ABI functions); C3 gpu-stream hash 5f877994a1335867 unchanged. Model E-165: C3 demo cf 17.60 → 17.73.
Both transitions verified frame by frame (JS, WebGL, Flycast with the new --dc-shots); then the browser's colour made five-bit (fbTex = (k+1/2)/32, F cut, mode 0 floored): the first transition within 0.33 of a step of the reference (was 2.1). DC transition confirmed by the owner. Then Crash Bash's hub "CONTROLLER 1-A IS UNPLUGGED" with a DualShock: the multitap answers a long read late (ADR-0042 amended); the owner verified Crash Bash and Crash 3 on Flycast. Gates: test.sh JS 329de455, conformance 64/64, pad tests JS = C++, check.sh clean; digests 52875c77/37eefb07 (standard JS). Committed and pushed at the owner's word. Next: the owner's experiment — the Dreamcast's scene drawn directly at 640x480 (tile-based), persistence by replaying records since the last cover.

2026-10-04 [claude] Development phase: the DualShock (ADR-0052) — sio.DualShock (analog mode, config 43h-4Dh, two motors), tap slot windows forwarded, BP_PAD_ANALOG_BUTTON + bp_pad_rumble on SDL2/browser/DC/null/JVM; DualShockSio a1fdfeea JS = C++, other pad digests unchanged, C3 5000 47853ef7.
Crash 3: analog mode set by the game, stick and rumble verified; reads a DualShock every 4th vblank by its own code (owner: keep it). Crash Bash: configured through the tap, menus reached.
DC pictures (ADR-0053): each display buffer rendered into a PVR picture; Crash 3's pause keeps the frozen game, Crash Bash's legal screen gone (Flycast vs JS VRAM); model E-164 cf 17.52→17.60 / work 11.40→11.47. CDIs out/dc/*-pic-max.cdi. Not committed. Next: the owner's next development item.

2026-10-04 [claude] DC: ADR-0050 (ordinary entry apart from resumes, dispatchers' gotos), E-139 shadow raster, E-141/E-147 SPU mix, E-146 PortBases (ADR-0049 amended: traps 268→2, 1,036→4), placement round r138 installed (E-148).
Model: C3 Uka 18.38→16.58, warp 16.95→16.64 (full speed), demo 22.02→20.58; CB all windows 16.6. Rejected E-142..E-145b. Exact: JS + DC digests 47853ef7/95e17b07, TA identical.
CDIs out/dc/crash3-r138-max.cdi, crashbash-r138-max.cdi. Not committed. Next: r139 round (running, sliced traces), then the demo's medium items — Next up 00000.
2026-10-04 [claude] DC fastmem (ADR-0049, option A): guest RAM/scratchpad as wired P0 pages, accesses one mov after a mask (by base and offset), the backend's own TLB-miss vector + lean trampoline for ports, Runtime.deadline volatile; build/game-cpp-dc.hxml + build-dc.sh auto RECOMPSX_FASTMEM; a Flycast copy with 4 MMU-model faults patched (owner's call). Exact (C3 47853ef7, CB 95e17b07, TA hash = ta10, conformance 63/63 both). Round r136 installed: C3 demo 25.50 → 22.02, Uka 21.08 → 18.38, warp 19.24 → 16.95, CB 16.63 (E-135..E-137). ADR-0048's emitter on fastmem still behind GCC (E-136). CDIs out/dc/crash3-fm136-max.cdi, crashbash-fm136-max.cdi.
Next: the tester's run of the fm136 CDIs (first with the MMU on); then C (the GPU path, ~1.3 M instructions a frame) or B with an allocator — Next up 0000.
2026-10-04 [claude] DC: the tester's 5fa9442 results recorded (E-130: Toad Village 25.2 ms, model 25.49; menus 60); ADR-0048's first step built and measured (E-131: 198 Crash 3 functions as SH-4 assembly, DC digest 47853ef7 = JS, but +34 % instructions and slower than GCC's — rejected as it stands, opt-in `gen --sh4`); sio.PadScript + `--vram-at` + DC CFG 16 lines + dc-digest DIGEST_ARGS (E-132: windows of real play, the intro's Uka Uka 6750:7050 and the warp room 15000:15300; scripted DC digest at 7050 a0b9d5bc = JS); round r130 from four windows installed (E-133: Uka 23.02 → 21.08, warp 20.38 → 19.24); a shared runtime/backend code placement for games without their own (E-134, ADR-0043 amended: 59 % of Crash Bash's own placement's gain from Crash 3's half; build-dc.sh's serial probe fixed for targets with no serial). CDI out/dc/crash3-r130-max.cdi. A wrong first reading of E-130 (the title's profile read as the demo's) corrected. Disk filled once (out/_x_* build intermediates cleaned; memory note).
Gates: JS digests 47853ef7 (C3 5000, no script), test.sh JS gate 329de455; check.sh clean. Not committed.
Next: the owner's choice among A (MMU fastmem), B (ADR-0048 with an allocator), C (scene to the PVR), D (frame skip) — asked 2026-10-04.

2026-10-03 [claude] DC night: the generated code measured by form (pools 13 %, 0.99 ms of operand fills; CpuState ~20 %; 31 % of fetched slots never run) -> ADR-0048 (proposed: guest code as SH-4 assembly); scripts/dc-digest.sh (the DC build's GenMain digest = JS's: C3 5000 47853ef7, CB+mods 20300 95e17b07); E-122a kept (the SPU's catch-up by a multiply), E-122b rejected (the quad's short second triangle: its fills ate its issue saving), E-121/E-123 rejected; E-124 rejected (hot guest registers in locals: GCC spills them, gameplay's generated code +0.12 ms) — so the registers need ADR-0048's allocator. Then E-125 kept (function spans taken where every path needs them: gameplay's generated code −0.34 ms cf), E-126 kept (timer 2's reads, event delivery), E-127 rejected; placement round r126 installed (E-128: gameplay 25.16 → 25.01, title work 15.44 → 15.03, Ballistix work 13.39 → 13.25), CDIs r126 (their DC digests 47853ef7 / 95e17b07 = JS, TA hash identical, test.sh both targets 329de455); next the owner's call on ADR-0048.
Gates: TA hash identical (1,889 + 2,170 + 7,974); JS digests 47853ef7/95e17b07; SPU conformance unchanged; check.sh clean. Not committed.
Next: the tester's results against 5fa9442; the owner's call on ADR-0048.

2026-10-03 [claude] DC after 5fa9442: gameplay taken apart (Blockers: full speed needs a redesign); backend E-113/E-114/E-117 (bake memo + exact index, clip steps, build_scene fast path, run_switch, palette hash index), rounds r114/r117 (E-116/E-119, installed); E-115 islands, E-118 packet keys, E-120 FnTable slots rejected.
Model: gameplay 25.49 -> 25.16 (cf 23.08 -> 22.79), Ballistix 16.76 -> 16.71 (work 13.39), title 16.64. CDIs out/dc/crash3-r117-max.cdi, crashbash-r117-max.cdi.
Gates: TA hash identical for every batch (1,889 + 2,170 + 7,974 scenes); JS digests 47853ef7/95e17b07 and gpu-stream 5f877994a1335867/07076c3751a9d204; check.sh clean. Not committed.
Next: the tester's results against 5fa9442; the owner's call on the architectural options (Blockers 2026-10-03).

2026-10-03 [claude] DC: Ballistix's slow presents named (E-108), GPUSTAT/timer-1 without divides (E-109, BeamLine), rounds r108/r109 with every Ballistix phase traced (E-110, installed), flat-triangle rows carried (E-112); E-111 rejected.
Model: Ballistix 16.87 -> 16.76 (heavy pairs 33.1, load 11.6-13.4, slow presents 17 -> 7), title 16.64, gameplay 25.88 -> 25.49 (PS1 ~95 % busy).
Gates: test.sh JS (329de455); conformance JS all, BeamLine/VideoTime/Raster JS+C++; check.sh clean; digests 88c8b426/47853ef7/95e17b07. Committed and pushed at the owner's word.
Next: the tester's run of crash3-r112-max / crashbash-r109-max against this commit; GPU walk batching, GTE core (Next up 000).

2026-10-03 [claude] DC: Ballistix heavy pairs within 33.4 (E-103 state commands skip draw, E-104 INTPL call-site form + GteInterpolate, E-105/E-106 build_scene keys and flat colours, E-107 round r100).
Model: Ballistix 17.01 -> 16.87 ms (pairs 32.9; 17/1500 presents ~37), title 16.69 (pairs 31.6-32.9), gameplay 25.86 (needs ~35 % less).
Gates: test.sh JS (61,995 checks, 62 conformance, 329de455); GteInterpolate b7f03c86 JS+C++; TA hash identical (ta0/ta1/ta2); digests 88c8b426/47853ef7/95e17b07.
Next: name Ballistix's slow presents (bench log added); gameplay's world loop is instruction-cache bound (Next up 000).

2026-10-03 [claude] DC: scheduler pump path (SchedFile/REST, pump one call; E-098), relocatable answers kept (E-099, ADR-0025 rev.), rounds r85 (E-097) and r99 with data colours (E-100); E-101/E-102 rejected.
Model: title 18.88 -> 16.69 ms (30 Hz pairs 31.6-32.8 within 33.4: full speed), gameplay 29.36 -> 25.50, Ballistix 18.25 -> 17.01 (heavy pairs ~33.4).
Gates: test.sh JS (61,995 checks, SchedulerOrder new e3bc279e, 329de455); conformance 61/61 on JS and C++; C3 4523/5000 88c8b426/47853ef7, CB 20300 95e17b07.
Next: a CDI of this build for hardware; Ballistix's last ~1 ms (list walk, scene build); gameplay needs structural work (Next up 000).

2026-10-02 [claude] DC: RTPS (ADR-0046) and the polygon packet (ADR-0047) as dc-sched-scheduled SH-4 cores; ABI bp_gpu_tri_w/bp_gpu_state_w; RTPS inline everywhere.
cf a present g76 -> g82: title 16.74 -> 15.84, gameplay 26.26 -> 24.69, Ballistix 17.45 -> 16.58 (E-083..E-088); exact: dc-shrun/dc-polyrun, check builds 0 differ.
Gates: test.sh JS gate (61,995 checks, 59 groups, 329de455); C3 5000 47853ef7, CB 20300 95e17b07; GPU-stream 5f877994a1335867; check.sh float rule (FPU CLZ replaced).
Next: placement round r81 -> CDIs; TA-list hash for backend changes; the backend's semi-transparent path (~1.5 ms a title present).

2026-10-02 [claude] DC: CpuState hot words in the SH-4 displacement (patch 0007), scratchpad span test (E-081), three placement rounds (title 19.20->17.83, gameplay 30.29->28.53, CB 19.34->18.96).
Set aside: hand-overs (ADR-0045, +0.65 ms gameplay; --cut-shared), span quotients (E-078), RTPS in assembly (E-080, timed by the new scripts/dc-issue-sim.py: no gain).
61995 tool checks; 59 conformance groups (SpanTake new) on JS, 58 + SpanTake on C++; C3 4523/5000 88c8b426/47853ef7, CB 20300 95e17b07.
Next: Next up 000 — the scene straight to the PVR (~1 ms a title pair), call overhead in generated code, gameplay's code footprint.

2026-10-02 [claude] GTE ops and LWL/LWR in scalar helpers (ordered effects, span lwl/lwr), unreachable CFG arms pruned, constant accounting at call sites.
C3/CB helpers 151->171/175->180; 61949 checks, 57 JS groups, ScalarCop 10882ef3 on JS/C++; 20k digests unchanged (36dcd8ee, CB+mods 98109571).
DC model: no speed effect (issue equal; cf moves are layout fills, E-067/E-068). Pool loads 13.3 %, CpuState 14.9 % of generated instructions.
Next: owner to choose loops vs. entry work / decode constants; indexed spans for the last acyclic GTE/LWL candidates.

2026-10-02 [claude] Shared equal memory projection pairs per emitted class (ProjectionShare): C3/CB pairs 73->48/108->69, ES6 JS -41,985/-82,888 B.
--no-projection-share reproduces prior Haxe/JS byte for byte; every site runs a text-equal pair; 61906 checks, 56 JS groups; ScalarShare+3 groups agree JS/C++.
20k digests unchanged (36dcd8ee/a9864f26). Ten CPU-time pairs on a loaded host: no established speed change (C3 -0.13%, CB +1.73% medians).
Found a JS/C++ difference in misaligned general-path word reads (blockers). Next: projection entry/guard cost; loops, conditional summaries, ABI/stack recovery.

2026-10-02 [codex] Prepared LLM handoff from verified checkout, architecture, acceptance logs and remaining work; no implementation changes.
Recorded dirty/untracked/submodule state and JS-first constraints; existing acceptance remains current.
Next: share duplicate memory helper/adapter pairs with exact semantic keys, then measure size and execution cost.

2026-10-02 [codex] Added guarded caller-specific memory results and repaired Program's pure-only integration filter; 73 C3/108 CB call sites.
61848 checks/55 JS groups and three focused JS/C++ groups pass; old/new 20k game digests agree; full helper bodies unchanged.
Static publications fall 80/125; JS grows 134,028/209,624 B. Five timing pairs are mixed (C3 median -4.11%, CB +4.10%); no general speed claim.
Verified analyzer-optimize/full DCE across 16 build entries, retaining ES6; flags were already active and fresh demo remains 329de455.
Next: share repeated memory projection bodies and investigate call cost; general loops, conditional summaries and ABI/stack recovery remain open.

2026-10-02 [codex] Validated 256-instruction analysis/96-unit live-body recovery: C3/CB helpers 140->151/163->175; prior bodies unchanged.
Fixed native due[-1] fault via reproducible reflaxe short-circuit patch 0006; setup/spike wiring and 53-value regression included.
61528 tool checks/55 JS groups; four JS/C++ groups and compiler spikes pass; fresh game JS hashes retain four validated 20k digests.
Five timing pairs: C3 +5.09%, CB -13.57% medians with overlap/outliers; no general speed claim. JS grows 44,478/43,144 B.
Next: isolate guard/publication costs and possible C3 slowdown; general loops, conditional summaries and ABI/stack recovery remain open.

2026-10-01 [codex] Reverified analyzer-optimize/full DCE in shared build settings and JS/C++ entry paths; JS retains ES6.
No flag changes required; fresh pinned JS demo retains 329de455.
Next: diagnose intermittent native Scheduler.init fault before accepting recovered-body budget expansion; general recovery remains open.

2026-10-01 [codex] Imported body-proved child result equalities and fixed nested charges; retained effects, dynamic charges and all access guards.
Narrow forwarded conversions retain exact read versions/extension. 61486 checks/54 JS groups; pointer/compose/memory-CFG agree on JS/C++.
Four baseline/new 20k runs match. Both game JS files are byte-identical; no timing or game-speed claim.
Next: conditional/numeric call recovery and wider function/loop/ABI/stack coverage; general state removal remains open.

2026-10-01 [codex] Reconstructed proved entry-sample/affine outputs at call boundaries; removed redundant result words and boundary-only parameters.
Void memory helpers retain effects/accounting; nested calls keep read versions/predicates. C3/CB helpers 140/163, transported result words 195->155/242->172.
61378 checks/54 JS groups; pointer/borrow/result fixtures agree on JS/C++; both baseline/new games retain 20k digests.
Five alternating pairs: C3 median +0.28%, CB -2.22%, overlapping ranges; no general speed claim.
Next: independently proved child-result equalities, then broader ABI/loop/stack recovery; complete state removal remains open.

2026-10-01 [codex] Reverified requested analyzer-optimize/full DCE in all build entries and script compile paths; JS keeps ES6.
Flags were already active; fresh JS demo retains 329de455 and discipline/diff checks pass. No C++ rebuild.
Next: eliminate redundant known-value result transport; general recovery remains open.

2026-10-01 [codex] Added typed preflight sample inputs, source-only span pruning and equal entry-sample reuse with per-version guards.
Static helper reads C3 114->101 / CB 161->138; helpers 139/163. 61274 checks/54 JS groups; pointer/borrow fixtures agree on JS/C++.
Both games retain baseline/new 20k digests; five-pair median times -3.80%/-1.24%, bounded JS evidence only.
Next: remove redundant known-value result transport and continue general recovery.

2026-10-01 [codex] Added checked loaded-pointer provenance and nested-call import; earlier writes require exclusions, later loads retain order.
C3 helpers 116->138; CB 138->163; previous bodies unchanged. 61178 tool checks/54 JS groups; pointer/composition fixtures agree on JS/C++.
Both games retain baseline/new 20k digests; sample medians +1.29%/+2.72%, no established speed gain.
Next: reduce preflight/duplicate-read cost; changed-pointer continuations and general ABI/loop/stack recovery remain open.

2026-10-01 [codex] Rechecked optimizer flags: all 16 build entries inherit analyzer-optimize/full DCE; JS retains ES6.
Fresh JS demo: frames=300 digest=329de455; discipline/diff checks clean. No flag changes or C++ rebuild required.
Next: finish and validate loaded-pointer recovery; the demo check does not validate that ongoing codegen work.

2026-10-01 [codex] Added precise child write summaries and guarded saved-value recovery; merged equivalent alias checks without filling holes.
61045 tool checks/53 JS groups; final ScalarCompose and SpanAlias agree on JS/C++; both games retain baseline/final 20k digests.
C3 helpers 113->116 (+5994 JS B), CB 124->138 (+23719 B); prior helper bodies unchanged; no new CpuState publication or forced inline.
Five-pair medians: C3 -0.8%, CB +0.05%, overlapping ranges; no established speed improvement.
Next: surviving entry costs and loaded-address continuation proofs; general ABI/stack recovery remains open.

2026-10-01 [codex] Composed bounded direct scalar calls with CFG memory facts, return proofs and event/deadline guards; verified optimizer flags.
59911 checks/52 JS groups; ScalarCompose and ScalarResults agree on JS/C++; CB baseline/new 20k a9864f26; C3 JS byte-identical.
CB gains one helper (+1296 B), timing median +2.3% with overlap/no speed claim; fixed two invalid continuation fixtures, not runtime alignment.
Next: precise child write/alias proofs and saved-value preservation; general ABI/stack recovery remains open.

2026-10-01 [codex] Added block-local affine call aliases with donor-span liveness and guarded rebasing; checked optimizer flags.
59782 tool checks/51 JS groups; four JS/C++ groups agree; both games retain baseline/new 20k digests.
C3 borrowed calls 187->200, CB 0->2; JS +2002/+918 B; C3 timing +7.4%, repeat +0.6%, CB -0.9%; no speed gain established.
Next: profile recovered-call entry/state costs before widening coverage; general ABI/stack recovery remains open.

2026-10-01 [codex] Shared borrowed-span entry guards/publication/accounting in per-callee adapters; fixed constant exclusion.
C3 187 calls -> 5 live adapters, JS -55066 B; CB JS identical; state-free helper bodies unchanged.
59671 checks/51 JS groups, four JS/C++ groups agree; C3 20k36dcd8ee; median -0.4% within overlapping ranges.
Next: investigate affine call-argument aliases; general ABI/stack recovery remains open.

2026-10-01 [codex] Added caller-span borrowing for direct memory scalar calls, with post-slot liveness and entry guards.
59655 checks/51 JS groups; four JS/C++ groups agree; C3 baseline/new 20k36dcd8ee; CB output byte-identical.
C3 187 borrowed sites, JS +61422 B; five-pair median -1.8%, wide overlap, no established speed gain.
Next: reduce duplicated guards and recover caller-specific memory results; general ABI/stack recovery remains open.

2026-10-01 [codex] Simplified scalar CFG reach/phi expressions and grouped original packed block charges.
59573 checks/50 JS groups; four JS/C++ groups agree; both rebuilt games retain their 20k digests.
C3/CB JS -2321/-1801 B; five-pair medians -1.9%/-9.6%, overlapping; no established speed gain.
Next: reduce span/entry-adapter overhead with caller proofs; general ABI/stack recovery remains open.

2026-10-01 [codex] Added predicated plain-memory effects to acyclic scalar signatures; retained entry/pump proofs.
C3 99->113 / CB 106->123 helpers; 56988 checks/50 JS groups; four JS/C++ groups agree, demo329de455.
20k rebuilt baseline/new digests match (C3 36dcd8ee, CB a9864f26); JS +24953/+30485 B.
Five-pair medians C3 +1.9%, CB -1.2%, overlapping; no speed claim. Next: simplify reach/accounting and guards.

2026-10-01 [codex] Added alias-safe scalar memory value reuse and exact byte/halfword extraction.
32 emitted programs; 56848 tool checks/49 JS groups; ScalarEffects JS/C++ 3cfb6f71/1136641 values.
Caught and avoided nested unsigned-shift contamination in C++ (defect11); other result/memory groups agree.
C3 40 / CB 38 Haxe files byte-identical: no game speed gain. Next: effectful CFG signature recovery.

2026-10-01 [codex] Centralized analyzer-optimize/full DCE in common.hxml; added missing spike includes.
56668 tool checks, 49 unchanged JS conformance digests, demo329de455; demo JS byte-identical.
Spikes/check clean; ScalarEffects/Dispatch/GteOps agree on JS and C++. Game builds already used both flags.
Next: reduce scalar signature guard/call overhead and redundant memory work; no speed gain claimed here.

2026-10-01 [codex] Added ordered plain-memory effects, multiple checked span parameters and Void scalar setters.
Full helpers C3 30->99 / CB 32->106; no CpuState in their bodies. 56668 checks/49 JS groups; demo329de455.
Four focused JS/C++ groups agree; final ScalarEffects af21ba89/351863 values. C3/CB 20k 36dcd8ee/a9864f26.
Five-pair timings overlap (medians +1.0%/+2.9%); no speed claim. Next: reduce guard/call costs and redundant memory work.

2026-10-01 [codex] Added opt-in pure CFG local/merge values with exact public-entry and boundary publication.
23 fixtures / 596084 values; 56578 tool checks, 48 JS groups; four JS/C++ groups agree; demo329de455.
C3/CB 20k match rebuilt baselines (36dcd8ee/a9864f26). Static GPR refs -779/-309; JS +51061/+17420 B.
Timing overlaps (C3 median -1.4%, CB +2.3%): keep --value-cfg off by default. Next: computation/signature elimination.

2026-10-01 [codex] Added observation-bounded value SSA, exact CSE and state reconstruction inside ordinary functions.
Static GPR references C3 -29,218 / CB -30,491; JS +126,966/+41,800 B. 56500 checks/47 JS groups; demo329de455.
Seven focused JS/C++ groups agree; final ValueRegions cdcffb6c. Both 20k baselines match: C3 36dcd8ee / CB a9864f26.
C3 sample median -2.6%; CB inconclusive. Bounded-search cleanup emits identical sources. Next: SSA across CFG edges.

2026-10-01 [codex] Added multiple-result scalar signatures, unique-value transport and affine boundary reconstruction.
C3 helpers 15->33; CB 22->38 (46 projections); JS +27,297/+44,396 B. 56456 checks/46 JS groups; demo329de455.
Nine focused JS/C++ groups agree after removing invalid MemA dereferences from the alignment-guard fixture.
C3 9000 4de78425 / CB 3000 db892c4b, including 12 A/B runs; no proven speed gain. Next: internal observation state.

2026-10-01 [codex] Added acyclic CFG value SSA/phi selection and allocation-free path-accounting returns.
C3 helpers 13->15; CB 18->22, projections 33->43; JS +2,254/+19,702 B. 56364 checks/45 JS groups, demo329de455.
Eight JS+C++ groups agree; final ScalarCfg2325fb2e. C3 9000 4de78425 / CB 3000 db892c4b, including 12 A/B runs.
Small timing improvements are not a broad speed claim. Next: multiple results and reconstruction at internal observations.

2026-10-01 [codex] Added signed range proofs for scalar ADD/ADDI/SUB, with conservative effect/entry barriers.
56218 tool checks, 44 JS groups, demo 329de455; eight JS+C++ groups agree (RangeCodegen 33c5b85a).
C3 9000 4de78425 / CB 3000 db892c4b; both JS bundles byte-identical to pooling, no measured speed gain.
Next: CFG value SSA with path-dependent accounting and boundary reconstruction; balanced-only survey found no candidates.

2026-10-01 [codex] Interned equivalent pure call projections across shards/universes; retained call-specific
state, guards and timing. CB 33 copies -> 2 helpers, JS -5,496 bytes; C3 output byte-identical.
724 tool checks / 43 JS groups (329de455); ScalarCalls JS+C++ 1bfb3dce; C3 9000 4de78425, CB 3000 db892c4b.
A/B times overlap: size win only. Next: CFG value SSA/boundary reconstruction and range proofs (ADR-0044).

2026-10-01 [codex] Added fixed-point function/call summaries and guarded caller-specific scalar outputs;
all results survive observation boundaries/public entries. CB adds 33 sites; C3 no new sites (ADR-0044).
672 tool checks, 43 JS groups (329de455); seven cross-target groups agree, ScalarCalls 8298013f.
C3 9000 4de78425 / CB 3000 db892c4b; size grows, no speed claim. Next: CFG SSA/range proofs and helper sharing.

2026-10-01 [claude] The shims' C files moved into Haxe (E-066, owner: C files only in backends): GTE dot3 into
gte.Gte's @:headerCode, bulk ops into shim.Bulk's; native/recompsx_gte.h and recompsx_bulk.h deleted; SH-4 code
identical, conformance unchanged. Codex's ScalarPlan on the Dreamcast (E-065): both games build and run, desktop
C++ C3 9000 4de78425 / CB 3000 db892c4b, model times unchanged (its helpers barely run). Next: GPU path per polygon.

2026-10-01 [codex] Inspected rev.ng 0f1f7d4a: ABI liveness/reaching definitions and fixed point,
signature/call rewriting, CSV promotion, stack segregation and layout recovery; sources in ADR-0044.
Distinguished decompilation assumptions from executable recompilation; no generator change/tests.
Next: per-call effects/outputs plus boundary-state reconstruction, then general signature lowering.

2026-10-01 [codex] Extended scalar signatures with checked read-only spans; preserved MMIO,
entry/resume behavior and all final GPRs. Coverage C3 5->13, CB 9->16 helpers; JS +1,565 bytes.
559 tool checks, 42 JS groups (329de455); six JS/C++ groups agree, memory scalar 852cd0fd.
C3 9000 4de78425 / CB 3000 db892c4b retained; no speed claim. Next: call-group output/effect proof.

2026-10-01 [claude] Pushed the Dreamcast rounds (ledger E-001..E-063); Crash 3's placement is g44p3's, the one
measured (round 5's colours were not built). Researched a CpuState-free translation (E-064): Crash 3's hot engine
code takes 6-21 register inputs, Crash Bash's at most 4; Crash 3's hot shards compile 21-28 % larger with registers as
statics or locals than as CpuState fields. Next: the GPU path per polygon, the per-call overhead.

2026-10-01 [codex] Added bounded scalar signature recovery/value SSA, guarded direct calls and
state-compatible wrappers (ADR-0044), --no-scalar control, hook/overlay/dedup regressions.
539 tool checks; JS gate 329de455; scalar JS/C++ 4ebe3340 (124013 values); C3 9000 4de78425,
CB 3000 db892c4b unchanged. Coverage 5/9 helpers. Next: proven call-group output/effect analysis.

2026-10-01 [codex] Researched CpuState-free Haxe generation against current FunctionIR/Emitter,
ADR-0029 and rev.ng's ABI promotion. No implementation or speed claim; existing write summaries
are a starting point, not recovered function signatures. Next: prove a small parameter/return
helper path with explicit effects and state reconstruction, including staleAcrossCalls coverage.

2026-10-01 [claude] Dreamcast perf round 4 (ledger E-053..E-058): static CpuState, RTPT one copy (MemA.opaque),
two-window code placement, stack 235 lines, data colours (58, CpuState incl.) and halves; RXCOUNT in the model.
C3 title 19.46 -> 18.19, gameplay 35.47 -> 29.26; CB 20.55 -> 19.19. Test image crash3-g44-max.cdi. Next: GPU
path per polygon, per-call overhead of generated code, RTPS/RTPT on the SH-4.

2026-10-01 [claude] Dreamcast perf round 3 (ledger E-047..E-052): PGO measured (-1.55) and rejected by the owner;
mac.w RTPS rows, emit_header split, spans as addresses, lwl/lwr fusion, JOY_STAT idle loops, bench histogram.
Model: C3 cf 17.98 -> 17.23, frame 19.46 placed; CB work 16.82 -> 16.05. Next: placement round, call summaries.

2026-09-30 [claude] Dreamcast perf round 2 (ledger E-035..E-042): CpuState last-call cache, snd split buffers,
branch hints, scheduler re-arm, timers register file, restrict ctx (core.Ctx), sampler cache, placement + data
colours. Model: C3 20.34 -> 19.39 ms (cf 18.14), CB work 18.04 -> 17.36. Next: placement for g33 code, CB states.

2026-09-30 [claude] Dreamcast perf round (ledger E-023..E-034): run_tris, semi bindings, inline RTPS (not in leaves), call
write summaries + guarded jalr, polygonHw streamed, overlay every 4th window, placement for both games, JS --gpu-hash
(= null backend's). Model: C3 title 23.13 -> 20.34 ms; CB work 18.48 -> 18.04. Rejected: quad strips, per-kind polygonHw,
OCRAM. Next: CB halves (g22/g23), then span check + SpuFile (in tree, verified on JS/conformance) and a new placement.

2026-09-30 [claude] Toolchain: .toolchain/haxe = local build of haxe-plus haxe4 (github barisyild/haxe-plus; its HAXE-PLUS.md
records every change): native eval JIT (HAXE_EVAL_JIT=0 off; native only once a compilation makes 1M calls, recompsx's
builds are recorded), exact eval caches, GC tuning. Game via reflaxe.CPP 331 -> 40.5 s, gen 6.8 -> 2.8 s, byte-identical;
CI green; haxe5 branch (5.0.0-preview.1 + the same changes) pushed, CI green. Latent: the installed binary's mbedtls stubs
saw 3.6.3 headers (eval TLS only, unused here); haxe-build.sh uses CPATH now. Next: reinstall + releases, on the owner's word.

2026-09-29 [claude] Hot code placed for the SH-4 I-cache (ADR-0043): model traces (RXTRACE), dc-icache-sim.c
(replay + colour search), dc-layout.py (ordering file + padding), build-dc.sh two-pass link from
games/SCUS94244/dc-placement.txt. Crash 3 title 35.1 -> 29.5 ms a frame under the model (I-conflicts -86 %).
Next: confirm on a console (placed/unplaced CDIs); Crash Bash's placement; the operand side.

2026-09-29 [claude] Dispatcher measured under the cache model and set aside (no-inline 40.2 vs 39.2 ms; direct
addresses neutral once inlined bodies are counted). Model gained fully associative shadows: 9 of Crash 3's 35 ms
title frame is cache conflicts, and two links of the same sources differ by 4.3 ms. dc-prof.py iconf/oconf, VSync off
in the Flycast scripts, spike fnptr. Next: hot-code placement (Next up 00).

2026-09-29 [claude] The multitap (ADR-0042): sio.Multitap in port 1, the host's pads 0-3 in slots A-D, psx-spx's
request table (slot A / long / garbage), 02h-04h and 81h-84h, pad 1 in port 2 until the tap is used; KPads through
Pads.padOnPort; four gamepads in the browser. MultitapSio on both targets; Crash Bash counts four pads headless and
on the Dreamcast, where each maple port's press reached its own record (fork RXPAD). Next: the owner's four players.

2026-09-28 [claude] Crash 3 flickered on the Dreamcast when ADR-0039's list walk crossed a vblank (the frame went
out in two halves): BP_PRESENT_DRAWING from the scanout while Dma walks a list, and the Dreamcast holds its last
picture (HOLD_MAX 3). Proven from the owner's Flycast save state (fork RXWATCH hook: 17/240 torn -> 0/240); the
owner reports it fixed. Dispatchers with nothing inlined and no lastSlot/dispatches stores, under the SH-4 model:
40.2 ms a frame against 39.2 (title 3300..4050) — not kept. Next: the Dreamcast run-to-run divergence (Blockers).

2026-09-28 [claude] SH-4 timing model in the profiling Flycast fork (rx_cache: caches, operand stalls, uncached
costs; RXCACHE=1, build-rxcache): Crash 3's title screen 39.2 ms a frame vs the console's 39.3 (Flycast 24.4,
Demul 27.3); scripts/dc-flycast-model.sh, dc-prof.py cost columns, --dc-rxprof present-named shots. Fork changes
uncommitted in the clone. Next: the dispatcher and hot-code layout, measured with the model.

2026-09-28 [claude] Crash 3 on the web again (b4a8ad4144b5): the browser kept Crash Bash's boot.exe beside Crash 3's
disc and bundle (a jump to 0 at boot) — serve-https.py now ETags every file by identity with no-cache, the page
revalidates the game files. Dreamcast GDI for Demul (it reads GDI/CHD, not our CDIs): KOS mounts /cd from a GD-ROM's
low-density area, so dc_gdrom.c remounts it from the high-density one (out/dc/crash3-periph-gdi, relinked _c3periph).
The GDI runs in Demul (full speed on a Windows PC). Measured, Crash 3's title screen, 30 frames, console
(crash3-periph-max.cdi) vs Demul: 1180 vs 818 ms; backend C code equal (gpu 159/157, build 168/147), generated
code 1.7x fast in Demul (emu 646/377), dispatch 2.6x (138/53): no emulator models the SH-4's caches
(src/backend/dreamcast/AGENTS.md, Measuring). Next: the owner's choice — a cache model in the Flycast fork
calibrated on these numbers, a one-level dispatcher, or hot-code ordering.

2026-09-28 [claude] JVM shim (src/shims/jvm, build/game-jvm.hxml; a parallel session's) committed with the
PRESENT_FAST and cardLoad/cardSave it lacked (no card kept, as null): all 38 conformance tests on the JVM give
JavaScript's digests (hxjava from a scratch haxelib repo; the project's .haxelib has none). Next: a whole game on
the JVM (backend.md §6, function splitting).

2026-09-28 [claude] Crash Bash warp room: circle froze the character — boot 8008671Ch and adventure 800C2F60h/
800C013Ch were pointer-only entries, and the boss pad's message needed boot 80090248h (now hints; headless walk
into the hub, circle, every pad, nothing unimplemented);
OverlayMgr.reportMiss compared an exclusive end with end+1 and misreported an overlay's own load as foreign;
the address keyboard copied QUIT as its list end (OnlineMenu.END_RECORD). Next: OPTIONS' mouse highlight.

2026-09-28 [claude] QUIT under OPTIONS in Crash Bash's main menu (ADR-0041): bp_exit_to_menu on every backend
(Dreamcast: KallistiOS exit path to the BIOS menu), Kernel.exitToMenu keeps the card first, ModHost.exitToMenu;
headless walk verified. Next: the owner's test of QUIT on the Dreamcast (out/dc/crashbash-periph-max.cdi).

2026-09-28 [claude] Crash 3's memory card: overlay-only callees (libcard's _card_info/_card_load stubs)
are now fed from overlay jal targets into the base analysis (Main.calledFromOverlays + tool test); CDIs
packaged with -s <SERIAL> so Flycast's per-game VMU survives rebuilds. Next: the owner's save test in
out/dc/crash3-periph-max.cdi; the pointer-reached prologue-less leaves (next-up 0).

2026-09-28 [claude] The PS1's own peripherals (ADR-0040): Sony Mouse, PS/2 keyboard (Lightspan protocol),
i-mode adaptor + libimode, KIMode as the phone/centre over new bp_http_* (SDL2/Dreamcast sockets, browser
fetch); the custom mouse/keyboard ModHost API removed, Crash Bash's mods on the official devices. Conformance
Mouse/Keyboard/IMode on JS+C++; browser: "connected to" a local server. Next: the owner's test of
out/dc/crashbash-periph-max.cdi; Crash Bash's lobby as HTTP requests over the adaptor.

2026-09-28 [claude] Mouse in Crash Bash's menus in play (PAUSED, its OPTIONS, QUIT GAME? YES/NO: mods/mouse
measures 800809A0h's definitions, writes 8009AEECh, clicks with the driving player's cross). The machine's
pointer only once a mod calls ModHost.enableMouse (bp_mouse_pointer: off/shown/hidden; art in
src/backend/api/pointer_art.h, SDL2 colour cursor); DC keyboard types by its own region (keypad under every
region; a layout option was dropped at the owner's word). Conformance Mouse b0789b91 JS+C++. Next: the owner's test of out/dc/crashbash-mouse3-max.cdi.

2026-09-28 [claude] GP0 C0h VRAM read (GPUREAD, GPUSTAT.27, DMA2 GPU->RAM); conformance GpuRead; Crash Bash's
save now carries its icon and palette (verified in the browser); VMU long description = title. Next: the owner's
look at the icon on the Dreamcast VMU, once a CDI is built with it (out/dc/crashbash-card-max.cdi predates it).

2026-09-28 [claude] Pointer hides on pad input (bp_mouse_show, KMouse.showOrHide); Dreamcast: mouse motion
summed per bus frame in a vblank handler, maple keyboard as pad 0; Flycast needs the host mouse on the DC
mouse's maple port. Next: the owner's test of out/dc/crashbash-mouse2-max.cdi.

2026-09-28 [claude] DMA2 ordering tables walked over time with the GPU's estimated drawing time (ADR-0039):
Crash Bash's pause text drawn; the first estimate (unclipped) dropped the hub to ~10 fps, clipped to the drawing
area it keeps full speed. Next: the owner's confirmation on the pause menu with the clipped estimate; Crash 3 check.

2026-09-28 [claude] Memory cards (ADR-0037): card model + card format per game (grows/shrinks by block), LLE card
on SIO0, OpenBIOS card driver/backup unit/bu device (KCard, KBu), FCB/DCB tables in RAM (KDevices), bp_card_* on
PC/null/Dreamcast (VMU package)/browser/Node, BP_PRESENT_FAST; conformance CardFormat/Sio/Bios/Chains; Crash Bash
saves in the browser. Next: Crash Bash's pause-menu text (DMA2 list walked over time).

2026-09-28 [claude] Mouse (ADR-0038): bp_mouse on SDL2, browser, Dreamcast (drawn arrow), null; kernel.KMouse;
mods/mouse drives the game's lists, onlinemenu its own screens; onlinemenu's slot bug (OPTIONS) fixed. Dreamcast
CDI with ONLINE: out/dc/crashbash-online-max.cdi (before the mouse). Next: a Dreamcast build with the mouse; the
HLE network service.

2026-09-28 [claude] HLE keyboard as text (ADR-0036: bp_key_text/next on SDL2, browser, Dreamcast, null;
kernel.KKeyboard; conformance Keyboard on both targets). onlinemenu: IP only, port 9457 per game, typing,
the demo timer held while the keyboard is open. Next: the HLE network service — first its browser transport
(WebSocket/WebRTC; a browser cannot listen), then Crash Bash's lobby.

2026-09-28 [claude] Real-BIOS black screen fixed: the Dreamcast profile overlay polled the BIOS font lock during
G1 DMA; its glyphs are now cached at init. Found in Flycast with the real BIOS (serial console via rxprof, PC
histogram of the hang). Next: memory cards (per-game blocks, a save format per target), once the mods and
settings work is committed.

2026-09-28 [claude] ADR-0034: kernel.KSettings (system.cfg via bp_storage), ModHost.setting; browser storage in
localStorage; dev server no-cache for the page. onlinemenu keeps and restores net.last_address (verified across a
reload). Next: memory card emulation on the same storage; ONLINE's HLE network service.

2026-09-28 [claude] Menus: cross did nothing (8001E848h, a prologue-less leaf, never found); hinted, then Battle
and Adventure walked by scripted pad with reports fed back (11 exe functions, boot/stage entries, overlays stage4
and adventure); attract digests unchanged. onlinemenu: ONLINE opens an ENTER NAME-style address keyboard.
Next: a sweep for prologue-less leaves after `jr ra`; ONLINE's HLE network service.

2026-09-28 [claude] WebGL lost Crash Bash's menu text after the cutscene: unchanged font uploads went unreported
(6db381f) after a 511x511 clear only the renderer drew. BP_CAP_GPU_UPLOADS (6): backends whose drawn pixels become
texels hear of every upload; JS shim answers it, C backends do not. Verified in the page (font area 0 mismatches,
text back); digests unchanged. Next: copies of drawn pixels (a bp_gpu_copy) if a game needs them.

2026-09-28 [claude] Mods (ADR-0033): gen --mods hooks, mod.ModHost/ModRam (memory past 2 MB at 9F000000h),
build-web --mods, games/SCUS94570/mods/onlinemenu (ONLINE under BATTLE MODE). Default output and digests
unchanged; ModHooks agrees on JS and reflaxe.CPP. Next: what ONLINE does; a whole-game C++ build with
-D recompsx_mods.

2026-09-28 [claude] ADR-0032 revised after Flycast: OT walk node by node again (line runs +9 % on Crash 3's
dense table), list uploads word by word (they cost the walk 12 %), short fills as halfword stores. Crash 3
1498.8 M = round 2; Crash Bash 5775.1 -> 5705.4 M; CDIs rebuilt. The console report was a dcload run with
no data: the program runs there. Next: that run with the game's files; then Next up 6.

2026-09-28 [claude] Next up 5: runtime bulk ops via shim.Bulk (ADR-0032; sh4zam on the Dreamcast) —
VRAM copies by rows, uploads by row segments, DMA3/4/6 in runs, fills; the OT walk a cache line at a
time in both directions, with prefetch. BulkPaths/OtWalk digests = the per-element code's on both
targets; game digests unchanged on JS. Next: Flycast numbers and CDIs of this version; Next up 6.

2026-09-28 [claude] sh4zam round 2 (Next up 1-4): TA/texture writes via put_hdr/put_vtx/txr_put everywhere,
prefetch in every VRAM walk, gstate_t as a movca'd 32-byte line; Flycast C3 1498.3 M, CB 5775.1 M; CDIs
rebuilt with *.prev.cdi kept. Next: the user's console A/B; then Next up 5 (runtime bulk ops via the shim).

2026-09-28 [claude] sh4zam first on the Dreamcast (ADR-0031, vendor/sh4zam): std calls replaced, header
SQ submission, 32-byte movca'd command records + prefetch; per-backend AGENTS.md notes; MemA.likely on
the RAM fast path (Flycast C3 1536.3->1504.2 M, CB 5935.9->5800.1 M; hardware is the verdict); CDIs
rebuilt. Next: hardware numbers from the user; codegen patterns (region routing, copy loops).

2026-09-27 [claude] Crash 3's shadow: off-screen drawing rasterised into VRAM under --video-hw
(ADR-0030), GP0(02h) fill ignores the mask bits on every path, WebGL stencil stores the written
mask bit; conformance GpuFill. Next: commit on request; analog/config mode, multitap, memory cards.

2026-09-27 [claude] DC bake patches on 32-texel steps (BAKE_STEP): Crash's eyebrows, Aku Aku's feathers
and the life icon no longer see-through; CDIs rebuilt. Crash 3 1495.0 M.

2026-09-27 [claude] DC with controllers: Crash Bash libpad handlers as hints, Uka Uka's jaw (mixed
4bpp CLUT blends split via bakes, pool 128), --dc-rxprof ports empty; CDIs rebuilt for both games.
Baselines Crash 3 1492.4 M, Crash Bash 5924.1 M. Next: analog/config mode, multitap, memory cards.

2026-09-27 [claude] Input: digital pad on SIO0 (psx-spx timing), BIOS pad driver B0:12h-16h from
OpenBIOS, keyboard/Gamepad API via JS externs; headless ports empty; new digests C3 ee91f215 /
8888c37f, CB fda4764f / 2d1ca4b6 (JS = C++). Next: analog + config mode, multitap, memory cards.

2026-09-27 [claude] games/ keyed by product code (SCUS94570, SCUS94244), Spyro 3 demo config
removed; `gen <disc>` finds games/<SERIAL>/ through SYSTEM.CNF, `gen <SERIAL>` through local.json;
exeSha256 checked. main renamed master, merged branches deleted. Next: PGO feasibility, GPU path.

2026-09-27 [claude] DC --max build: -mbranch-cost=1 -mdiv=call-fp -flto-partition=one (Crash 3
1501.5 -> 1463.1 M, Crash Bash 5984.6 -> 5906.0); eight other flags measured and left out. Merged
crash3-warped into main. Next: PGO feasibility (gcda over serial, partial instrumentation), GPU path.

2026-09-27 [claude] Split the Dreamcast backend into nine files + dc_internal.h, no behaviour change
(Flycast Crash 3 1501.5 M, Crash Bash 5984.6 M); check.sh checks ABI coverage per backend directory.
Next: compiler-flag experiments on the DC build (scheduling, LRA, ipa-pta), PGO feasibility.

2026-09-27 [claude] GTE registers as one array (shim.GteFile), DMA list walk following empty nodes in
its own loop: Crash 3 1537.7 -> 1501.4 M (~66.6 %), Crash Bash 6174.2 -> 5982.7. Register locals per
basic block tried and dropped (neutral). Next: split the Dreamcast backend into modules (user's ask).

2026-09-27 [claude] Registers as CpuState fields (ADR-0029), locals only in looping leaves: fixes a
stale-register publish (Crash 3 diverged from vblank 9898; digest 20,000 now a3419ae4); Crash 3
1645.0 -> 1537.7 M, Crash Bash 6227.7 -> 6174.2. History cleaned of .claude and LAN IPs, force
pushed. Next: GTE register file as one array (measuring), GPU path.

2026-09-27 [claude] Guest memory: RAM + scratchpad inline on C++ via mem.Access, ports noinline;
Crash 3 1741.8 -> 1645.0 M (~61 %), Crash Bash neutral (6227.7), DC images +1.5 / +1.0 MB. Web page
runs silent without AudioContext; preview on 0.0.0.0. Next: guest registers in a memory register
file on the SH-4 (ADR), and a JVM build, which needs function splitting (backend.md §6).

2026-09-27 [claude] DC render fixes (user report): subtractive fades in three passes, per-texel STP
at 8/15bpp, primitives placed from their displayed buffer and clipped to the drawing area, off-screen
drawing not shown; opaque loop kept as it was. Crash 3 1741.8 M, Crash Bash 6233.1 M (+~3 %).
Letterbox bars kept (the PS1's own). Next: Memory accessors inline on C++, shadow render-to-texture.

2026-09-27 [claude] DC GPU: background texture slots per displayed rectangle (Crash 3 uploaded both
buffers again at every flip); Crash 3 1811.4 -> 1696.4 M (~59 %), Crash Bash 6160.4 -> 6052.8. polygonHw and
build_scene (~12 %) left as micro-optimisation. Next: Crash 3 render bugs (the user's next ask).

2026-09-27 [claude] GTE on DC: RTPS/RTPT rows and screen coordinates in exact 32-bit forms, general
paths out of line; GteEdge conformance test (same digest before and after). Crash 3 Flycast 1872.8
-> 1811.4 M (~55 % speed), Crash Bash 6400.9 -> 6160.4 M; digests unchanged. Next: GPU hardware path
(present_frame/build_scene/polygonHw 17 %), Memory accessors (8 %).

2026-09-27 [claude] Dispatch cost on DC: generated code calls FnTable.run (cache + tail loop,
ADR-0028), Runtime.call hands over via bindRun, window changes are a callback. Crash 3 Flycast
2080.3 -> 1872.8 M cycles (~53 % speed), Crash Bash 6414.8 -> 6400.9; digests unchanged on JS and
C++. Next: GTE rtpt/rtps (15 %), GPU present/build_scene/polygonHw (17 %), Memory (8 %).

2026-09-27 [claude] DC backend: 8bpp pages drawn from 64x64 CLUT-baked patches (bake pool) instead of
whole 128 KB slots; Crash 3 demo 16.4 -> 10.4 s per 5 s of game, no conflicts; Crash Bash unchanged.
Next: Crash 3 on DC is CPU-bound now (GTE, dispatch, memory) — profile for the next step.

2026-09-27 [claude] Crash 3 diving demo froze: relocatable key reached into data the game rewrites
(EID -> pointer). Keys now code-only, variable length, masked separating rows (ADR-0025 rev.,
TestRelocatable). Crash 3 20000 frames f05fb3ea; Crash Bash unchanged. C++ = JS (9000/20000); DC CDI
built, runs in Flycast at ~30 % speed, tex_decode 37 %. Next: DC texture cache for Crash 3's pages.

2026-09-26 [claude] Crash 3 boxes/enemies culled: helper's non-local `jr $ra` compiled as a return
(ADR-0027: checked returns + RETURN unwinding, found via DuckStation GDB). WebGL render-to-texture
sync (shadow), versioned renderer load. Crash Bash unchanged; JS gate green, 423 tool checks.
Next: Crash 3 input/gameplay; JS speed with WebGL; C++/Dreamcast when the user resumes that path.

2026-09-26 [claude] Crash 3 attract loop on JS: relocatable GOOL native code (ADR-0025), tail-jump
trampoline (ADR-0026), $ra-constant jumps, jalr-through-ra returns. Crash Bash unchanged; gate green.
Next: Crash 3 input/gameplay, measure JS speed and the Dreamcast budget with relocatable code.

2026-09-26 [claude] games/crash3 (Crash Bandicoot: Warped) on JS to ~frame 2400: jumpTableHints, entry-first
block order, jr-through-ra-copy returns, timer IRQs, IRQ race/exception stack/drain fixes, rect clip +
colour; Crash Bash 9000 2ff36a18 / 30000 288ed8d6, retries 6->1; gate green (413 tool checks).
Next: decide how to run GOOL's heap-resident native code (interpreter fallback vs content-hashed blobs).

2026-09-26 [claude] Painter 716 ms (gte 207->175, rtps 134->97, build 146->121). Many-character cutscene: gte 225
(rtps 108, farColorInterpolate 54), up 39. GTE 32-bit fast paths: NCLIP (2 muls, coords within 2^14), AVSZ3/4
(|ZSF| bounds), mvmvaNormal (light/colour matrices, MVMVA; |T| < 2^30), farColorInterpolate (|FC| < 2^18,
|MAC| < 2^30). New GteSweep (every command, 16000 rounds) 8c701b20 before and after, both targets. Next: Flycast
profiling fork (user-approved, local clone ~/Desktop/Project/flycast) + background per-row mirror.

2026-09-26 [claude] Scene build: colours branch-free in one word (host: all 2^24 identical to the per-channel
forms), vertex offsets/alpha converted once per run (fmac; 66 -> 57 instr a vertex), palette_priority sorts
the few used slots once instead of 64 scans of 256 (host: 3000 random streams, same pal_bank_cached order;
a flipped tie-break is caught). fastmem: Flycast has no MMU for this disc ("BAD", no fault); check costs
~25 ns/access (D-A) -> ~5% ceiling on hardware; dropped. Next: user's bench (B1500) + profile.

2026-09-26 [claude] GTE rewrite (d19ebe4): 32-bit rows, RTPT one body; GteProject 148c8cbc before and after.
Found IR0 = sat(MAC0) where the spec says >> 12 — fixed, GteOps/GteProject digests moved (de71ee8a/43a78d52),
game digests did not: Crash Bash never reads RTPS's IR0 (0 of 28.7M reads). --dc-fastmem-test (ee16117) times
MMU-off/on loads, a P0-mapped load, today's checked load and a TLB-miss fault at boot. Next: user's fm line + bench.

2026-09-26 [claude] Menu at full speed (490 ms/61 fps); arenas ~740-800. slowWrite32 was one 9.2 KB function (LTO
inlined DMA2 -> walkList -> polygonHw); its polygon code was a third spills/constant reloads. walkList and
polygonHw now `@:specifier("__attribute__((noinline))")` (verified in the emitted headers; JS ignores it), so
the overlay names them. New `--dc-bench=FROM:TO` (recompsx.cfg): deterministic range, ms/frame on the overlay's
last line; out/dc/data has 18800:20300 (Ballistix in the attract loop). Digests + GPU-stream hash unchanged.

2026-09-26 [claude] Ballistix 723-794 ms, gpu 155 -> 126-136. "slowWrite32 ~100 ms" is the GPU list: LTO inlines
DMA2 -> walkList -> polygonHw into it (8.3 KB); JS count per frame: 15k W32, 14 slow; ~2980 OT nodes (2048
empty), 8256 words. RAM/scratch fast paths are already inlined into guest code on DC (LTO); Crash Bash's
stack is in the scratchpad (87% of sp accesses). Done: sendState inline (da671d5), RTPS clz by byte table
(no __clzsi2 call), build_scene restates a run's header from a copy. Digests unchanged. Next: user's numbers.

2026-09-26 [claude] New-texture cost: pages went VRAM -> buffer -> per-texel gather (~1.6 ms a 4bpp page on SH-4).
Now VRAM -> twiddled store-queue bursts directly, one 8x8 (4bpp) or 4x4 (16-bit) tile per burst, rearranged
with word-wide masks (8 texels an op): twid4_tiles (whole page and dirty-rect patch), twid8_page, twid15_page,
twid_bake. Host check: 200 random trials of each identical to the old paths; 3 injected bugs all caught.
Window path unchanged. Not yet measured on Flycast; next: user's Ballistix + scene-change numbers.

2026-09-26 [claude] Ballistix after page patching: 776 ms / 38.6 fps, build 139, tex_decode gone. GPU path was ~535
cycles a triangle: polygonHw reads a polygon packet from RAM into locals on the hardware path (no packet
copy, no software arrays, not the rasteriser-sized triangle()), and sendState skips gpuState when the
latched state is unchanged (ABI already latches; DC now carries it across frames). Desktop GPU-stream
hash over 21000 presents identical (2129f8ed72ec8158); state calls 10.53M -> 4.26M. Digests unchanged.

2026-09-26 [claude] Ballistix measured in JS (attract loop frames 18800-20300): every frame VRAM-copies two 16x64
scrolling strips into the 4bpp pages (768,0) and (896,0), which it draws with, plus a 16x32 upload every
other frame; palettes fit (39 avg, 48 max of 64 banks). Each write re-decoded a whole page twice a scene.
Mirror pages now keep a dirty rectangle and twid4_patch re-decodes only it (host: 400 random patches
identical to full decodes). Overlay `dec m/s/b+p` counts the patches.

2026-09-26 [claude] Ballistix after the twiddle uploader: 1098 -> ~860 ms, build 468 -> ~232; tex_decode now ~94.
Runtime reports a VRAM write to the backend only if a pixel changed (uploads and copies compare as they
write; up to 72 % of texture-area writes changed nothing), and steps upload col/row instead of two
divisions a texel. Digests and 9000-frame JS logs unchanged. Overlay line 3: dec mirror/slot/bake.

2026-09-26 [claude] Boot logos confirmed on Flycast. Ballistix arena: 1098 ms, build 468, pvr_txr_load_ex 160 +
__udivsi3 136. KOS's pvr_txr_load_ex divides twice per texel (x/min + y/min, zero for square textures)
and stores texels one uncached halfword at a time; replaced by twid_load4/16: KOS's layout produced in
video-memory order through store-queue bursts, source texels by table. Host check vs KOS: identical,
4 and 16 bpp, dim 4..256. Next: why this arena decodes textures every frame.

2026-09-26 [claude] DC boot logos 1-2 black since the start: the backend redraws a frame's kept geometry at
every present, and Crash Bash draws one 511x511 black rect (present 14) then only uploads logos until
present 1318 — the rect was painted over them (logo 2's last column showed). bp_gpu_dirty now records
a VRAM mark in the scene order; build_scene draws that part of the background there. Self-copies no
longer report dirty (~500/1000 vblanks). Digests unchanged. Awaiting Flycast.

2026-09-26 [claude] Menu 538 ms / 55.7 fps. Dull menu text on DC: PS1 modulation is texel*c/128 (up to ~2.0),
the PVR's MODULATE stops at 1.0. Colours are now recorded raw; a textured primitive with any channel
above 0x80 is drawn twice, the second pass additive (dst ONE) with max(2c-255, 0) — exact by
linearity. Overlay line 3 counts them (x2). bp_log drops INFO under the overlay (heartbeat = scif).

2026-09-26 [claude] Flycast gameplay 701 ms / 42.7 fps after the serial fix (emu 348 -> 253). Loading screen:
disc 2611 of 2987 ms, thd_idle 2602 — the drive, ~70 KB/s effective. Cause: disc FILEs were buffered,
so newlib refilled a small unaligned buffer and KOS's ISO9660 read every 2048-byte sector with its own
GD-ROM command. Now _IONBF: aligned windows reach iso_read whole and stream. Overlay: disc ms/KB.

2026-09-26 [claude] Overlay profile (Flycast, 767-824 ms): rtps ~133, f_800193a8 ~80 (the game's vertex
loop), present_frame ~65, slowWrite32 ~60 (GPU DMA, inlined), scif_write 54 (the per-window serial
line!), triangle/drawPolygon ~40 each. Serial profile lines now off while the overlay is on; GTE marks
are one store; scene-build helpers noinline in profile builds so the overlay can split present_frame.

2026-09-26 [claude] Flycast: 825 ms, 36.3 fps (emu 340 gte 203 gpu 142 build 107). DC overlay profile:
build-dc.sh writes SYMS.BIN (scripts/dc-syms.py: short function names + ranges, anchored to
samp_tick's address); copied to the disc root, the 1 kHz sampler attributes each PC by binary search
and overlay lines 4-5 show the top six functions in ms per window. disc moved to line 1. Next: read it.

2026-09-26 [claude] Flycast after the scene-build change: build 195 -> 93, 35.6 fps (841 ms; emu 324 gte 230
gpu 182). GP0 takes a DMA node's whole polygon/rectangle packet in one pass (9000-frame logs identical,
counters included; desktop channel time -25 %); RTPS skips its 44-bit checks when |TR| < 2^30 (exact:
16-bit factors). Crash Bash runs RTPS only (~850/vblank, ~2500 GTE ops). Digests unchanged both targets.

2026-09-26 [claude] Flycast after the GPU DMA change: gpu 274 -> ~186, fps 29.4-31.9 in busier scenes;
emu ~323 gte ~220 build ~195 of ~940 ms. DC scene build: pal_bank_at memoised per build (exact: VRAM
still, in-flight banks never rewritten, refusals and nearest matches stand; the steal bumps the
generation) and vertices sent by KOS direct rendering instead of pvr_prim. Awaiting Flycast.

2026-09-26 [claude] Flycast gameplay: emu 289 gte 242 gpu 274 build 189 of 1007 ms. GPU DMA now feeds GP0
straight from RAM (desktop hw-path profile: memory-map dispatch was 47 % of the channel; per-frame
channel time ~-57 %), and GTE's 44-bit wrap runs only on overflow. Digests unchanged: JS+C++ 9000
ab13c60f, 30000 4b78c2de; GteOps 1cf89aa2 both. CDI rebuilt; next: the user's gpu/gte readings.

2026-09-26 [claude] Profile sections BP_PROFILE_GTE (sampled) and BP_PROFILE_GPU (timed, per GPU DMA —
99.93 % of GP0 words); DC overlay `emu` exclusive of gte/gpu/spu/aica/disc. Digests unchanged:
JS and C++ 9000 = ab13c60f, GteOps 1cf89aa2 on both. Rebuilt out/dc/crashbash-reflaxe-max.cdi.
Next: the user's gte/gpu/build readings pick the target (build -> KOS pvr_dr direct rendering).

2026-09-26 [claude] DC disc read-ahead (backend_kos.c): seek reads 16 KB, then contiguous windows
doubling to 128 KB; reads across the seam copy from both. Cause: loading-screen overlay disc 2492 of
3007 ms. Host harness: 471 MB random + the game's 12,100 reads byte-exact. Rebuilt
out/dc/crashbash-reflaxe-max.cdi; the user reports a clear improvement on Flycast. Next if freezes
remain: a seek-time prefetch hint (CdlSetloc/ReadN) so the drive starts before the game asks.

2026-09-26 [claude] `build-dc.sh --max`: Release -O3 + LTO, -fno-exceptions -fno-rtti (neither output uses
them), own build-dc-max dir. DC images: reflaxe-max 8.02 MB, hatchet-max 7.00 MB loaded; CDIs
out/dc/crashbash-{reflaxe,hatchet}{,-max}.cdi. Same flags on desktop keep every digest; 30k frames
user s reflaxe 16.5, hatchet 15.9. Next: the user's Flycast comparison of the four images.

2026-09-26 [claude] Crash Bash through Hatchet: src/shims/hatchet (extern classes + one inline C++
header), scripts/build-hatchet.sh, CMake template RECOMPSX_TRANSPILER=hatchet (build-dc.sh detects it).
Digests identical to JS/reflaxe.CPP at 3000/9000/17500(no-audio)/30000/70000. Transpile 6 s (vs 9.5 min).
Desktop 30k frames user s: reflaxe 18.2, reflaxe+LTO 16.6, hatchet 19.2, hatchet+LTO 15.6. DC image 7.16 MB
(reflaxe 7.19); out/dc/crashbash-hatchet.cdi built, not yet run on Flycast. Fork: 8 commits, 313 tests.

2026-09-25 [claude] Hatchet fork github.com/barisyild/hatchet, branch `recompsx` (6 commits, 311
tests): negative hex literals as int, pkg.Class.x in expressions, field type inference + folded
constants as `static const int`, dropped instance initialisers emitted, expression bodies, multi-
declarators, member-level #if with -D, same-package static includes, call-site inline. Arith and
Mul now transpile from unmodified sources and match (14b7201f, b5a873d9); runtime parse errors 19
-> 0, generated 0/29. Next: a hatchet shim dir (RawBuf/RawMem/MemA/I64/Acc/Backend), then the game.

2026-09-25 [claude] Hatchet spike (github.com/andrewglind/hatchet v0.3.4, MIT, Rust, own Haxe
parser, C++98 out). With a source adapter and one literal fix, Arith 14b7201f and Mul b5a873d9
match JS/reflaxe.CPP bit for bit under g++ -std=c++98 -fwrapv. All 622k generated lines parse (~3 s).
Gaps: Int hex literals >= 0x80000000 emitted unsigned (45,060 in generated code; silent); no inference
for untyped statics (void*); pkg.Class.x emitted with dots (17,600); parser: bare-return bodies (91),
multi-declarations (57), #if around members; inline constants become mutable globals. No decision.

2026-09-25 [claude] Flycast menu with the silent-path fix: spu 366 -> 19 ms, 28.0 -> 38.6 fps
per 30 frames, but pace 53 ms while below 60 fps. The pacer wiped its debt after four frames
behind, making the next quick frame wait; it now keeps four frames of debt (both backends).
Host simulation: slow menu 37.8 -> 38.5 fps with no waiting; fast scenes still 60.0. Next:
emu (617 ms) is the cost now.

2026-09-25 [claude] Missing Dreamcast sounds traced: Crash Bash has no XA/CD-DA; its intro
cutscene streams 220,528-sample SPU notes, longer than an AICA channel. bp_spu_voice now answers
at the key-on; declined notes are mixed by the runtime into the kept stream (ADR-0024 revision,
SpuFall checks state and emitted audio). Tool: overlay entry check stops at a function's return;
stage3 mini-game + 9 hints, attract loop clean to 70,000 frames. Next: Flycast listen.

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
from `http://<lan-ip>`, whatever the bundle (old renderer, old runtime, sound off: all
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
**The phone kept the old address.** The server log showed the iPhone (<phone-ip>) loading
from `http://…:8000` again, so it still ran without the JIT. `scripts/serve-https.py 8443
--http 8000` is now the `web` launch configuration: HTTP serves localhost and redirects any
other host to `https://<host>:8443`. In WebKit, `http://<lan-ip>:8000/` lands on the HTTPS
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
