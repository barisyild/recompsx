# Spec — Runtime (`src/runtime`)

Normative specification for the PS1 hardware + kernel-HLE runtime. Source: master plan §7.
Portable subset throughout (see `docs/specs/backend.md` §5). All arithmetic is `Int` (32-bit
two's-complement) plus `I64` only where 44/64-bit intermediates are required (GTE MACs, mult/div,
timer anchors). Where a detail is flagged "consult psx-spx §…", implement from that page
verbatim rather than from this summary.

## Package layout

```
core/   Runtime.hx CpuState.hx Scheduler.hx TimeBase.hx Irq.hx Log.hx Hash.hx Fatal.hx
mem/    RawMem(shim) Memory.hx IoDispatch.hx
kernel/ Kernel.hx KEvents.hx KHeap.hx KFiles.hx KPads.hx ExeLoader.hx OverlayMgr.hx
gpu/    Gpu.hx Raster.hx Scanout.hx
gte/    Gte.hx UnrTable.hx
spu/    Spu.hx Adsr.hx Reverb.hx GaussTable.hx AudioRing.hx
cd/     Cdrom.hx CdImage.hx (uses shared/psxdisc) XaAdpcm.hx
mdec/   Mdec.hx      dma/ Dma.hx      timers/ Timers.hx
sio/    Sio0.hx Pads.hx MemCard.hx    dbg/ Trace.hx Watch.hx
```

## 1. Memory

Address map (physical, after `p = a & 0x1FFFFFFF`; KSEG2 detected on unmasked `(a >>> 29) == 7`):

| Physical range | Size | Region | Behavior |
|---|---|---|---|
| 0x00000000–0x007FFFFF | 8MB window | RAM 2MB ×4 mirrors | `ram.get*(p & 0x1FFFFF)` |
| 0x1F000000–0x1F7FFFFF | 8MB | Expansion 1 | reads 0xFF bytes, writes ignored, log-once |
| 0x1F800000–0x1F8003FF | 1KB | Scratchpad | `scratch` RawMem; no DMA; never executable |
| 0x1F801000–0x1F803FFF | 12KB | I/O + Exp2 | `IoDispatch` (0x1F802041 POST logged) |
| 0x1FC00000–0x1FC7FFFF | 512KB | BIOS window | HLE stub region (§3.6); writes ignored+log |
| KSEG2 0xFFFE0130 | 4B | Cache control | store/readback; semantics ignored (no I-cache) |

Fast path (codegen inlines): `(p & 0xFF800000) == 0` ⇔ RAM window → one AND + one branch for
~99% of accesses; `slow32` branch order: scratchpad → I/O (`p - 0x1F801000` in [0, 0x3000)) →
KSEG2 → BIOS window → Exp1 → bus error (log-once, return 0 — never host garbage; strict mode
aborts).

API (fixed by the codegen contract in `docs/specs/tool.md` §3): `read8s/read8u/read16s/read16u/
read32`, `write8/16/32`, `lwl/lwr` (return merged reg value) / `swl/swr` (RMW) implemented
exactly per tool spec Appendix A.3; bulk ops for DMA/kernel: `dmaRead32/dmaWrite32/copyRamToRam/
readBytesToRam/fillRam`. 16/32-bit accesses assumed aligned (debug builds assert).

**All of these are `static` methods on `Memory`, and the buffers are `static` fields** — the
emitted call is `Memory.read32(a)` — there is no `mem` parameter, and generated functions take
only `ctx`. This is forced by an upstream limitation, not preference: inlined *instance* methods
collide in reflaxe.CPP (see `docs/specs/backend.md` §4 and PROGRESS.md [M0-VERIFY] #12), and the
memory accessors must inline or the whole performance model collapses. There is exactly one
machine being emulated, so a singleton is the honest model anyway.

**RawMem endianness seam**: LE contract at every get16/get32; per-target impls per backend spec
§4. VRAM, SPU RAM, sector buffers and the BIOS stub region are all RawMem instances → hashing
and savestates see identical bytes on every platform. Entire 2MB RAM zero-filled at boot
(deterministic), then the kernel area stamped.

**Kernel work RAM (0x0000–0xFFFF)** — games peek kernel structures, so HLE materializes them at
boot: exception-vector stub at 0x0080; "table of tables" at 0x0100 (ExCB 0x100, PCB 0x108,
TCB 0x110, EvCB 0x120, FCB 0x140, DCB 0x150 — psx-spx kernelbios "Kernel Memory"); EvCB array,
TCB array + PCB → TCB[0] in 0xE000–0xFFFF like the real BIOS; A0/B0/C0 dispatch tables
materialized at 0x0200/0x0874/0x0674 filled with unique BIOS-window stub addresses (§3.6) so
games reading table pointers (GetB0Table…) see plausible values.

**Table sizing comes from SYSTEM.CNF.** The real BIOS sizes the TCB and EvCB arrays from the
disc's `SYSTEM.CNF` (`TCB = n`, `EVENT = n`), defaulting to 4 and 16 when absent. The loader
parses these and the kernel allocates accordingly; games have been observed to depend on the
resulting table addresses. (Crash Bash ships `TCB = 4`, `EVENT = 16`, `STACK = 801FFF00`.)
`STACK` overrides the initial SP when present.

## 2. TimeBase & scheduler

Constants (exact integers): `CPU_HZ = 33_868_800` (= 44100 × 768). Video clock =
CPU × **715909/451584** (NTSC 53,693,175 Hz) / × **709379/451584** (PAL). Scanline: NTSC 3413
video clocks, 263 lines/frame (progressive ≈59.83 fps); PAL 3406 clocks, 314 lines.
Cycles/scanline as exact fractions via 32-bit fractional accumulators: NTSC
`acc += 3413×451584 (=1_541_256_192); lines = acc / 715909; acc %= 715909` (fits i32 per step —
no floats ever). Dotclock = video clock / {10,8,7,5,4} for 256/320/368/512/640 modes (analytic in
Timer0). SPU tick = 768 cycles exactly. CD sector cadence 451_584 / 225_792 cycles (1x/2x).
VBlank window from GP1(07h) vertical range (NTSC default Y1=16, Y2=256): VBLANK_START at line Y2
→ present + IRQ0.

**Cycle representation**: `ctx.cycles` and `ctx.nextEvent` are **Int with wrap-safe subtraction
compares** (`ctx.cycles - ctx.nextEvent >= 0`, as emitted by codegen) — cheap on all targets;
valid because no event is ever scheduled more than 2^31 cycles (~63 s) ahead (longest constant =
ReadTOC ≈ 1 s). The scheduler keeps an `I64 totalCycles` accumulator (updated inside pump only)
for stats and pacing.

Everything a game can *read* — scanline, field, GPUSTAT bit 31, timer values — is computed from
`ctx.cycles` analytically at the moment of the read, never stepped forward by the scheduler
(ADR-0005 §1). The scheduler schedules *edges* only. A game polling GPUSTAT between two events
must not see a value that stopped moving.

Scheduler: fixed-slot event table, no allocation, no sorting: `VBLANK_START, VBLANK_END,
TIMER0/1/2, SPU_BATCH, CD_EVENT, SIO_BYTE, DMA_IRQ, MEMCARD_OP, PAD_VSYNC_POLL` — each
`{due:Int, active:Bool}`; cached `minDue` recomputed on schedule/cancel (N≤12 linear scan).
`pump()` inline: one compare; `Scheduler.run` pops due events in deadline order (ties broken by
fixed slot index — deterministic), executes side effects (I_STAT bits, CD state, SPU catch-up…),
then `Irq.dispatch(ctx)`.

**IRQ model**: I_STAT(0x1F801070)/I_MASK(0x1F801074); edge-triggered set (subsystem level lines;
raise on 0→1); I_STAT write = `stat &= value` ack. Bits: 0 VBLANK, 1 GPU, 2 CDROM, 3 DMA, 4–6
TMR0–2, 7 SIO0, 8 SIO1, 9 SPU, 10 PIO. Delivery is cooperative at pump points iff
`ctx.critDepth == 0` and SR.IEc set (mtc0 SR → `Runtime.setSr`). Per pending bit in order: HLE
housekeeping (vblank counter, InitPad buffer refresh, RCnt auto-ack per ChangeClearRCnt), then
the game-visible chain: (a) recompiled handlers installed via `SysEnqIntRP` in priority order
(Psy-Q libetc/libcd/libpad hook IRQs this way — first-class supported), then (b) `DeliverEvent`
for the matching event class. Enter/ExitCriticalSection (syscall 1/2) = `critDepth` ±1; exit with
pending → immediate dispatch. `ReturnFromException` = no-op marker under HLE.

**VSync convergence** — all three game idioms terminate on the same VBLANK_START event:
(1) polling I_STAT bit0 (back-edge pump fires the event); (2) polling GPUSTAT bit31 (computed on
read from the TimeBase line counter); (3) kernel WaitEvent / libetc VSync — an HLE wait advances
`ctx.cycles` **to `ctx.nextEvent`** and runs the scheduler, jumping to the next deadline rather
than stepping by a constant (ADR-0005 §3; this supersedes the `+= 64` written here earlier, which
was a free parameter that made delivery time depend on how it divided into deadlines).

## 3. Kernel HLE

The recompiler routes calls targeting the 0xA0/0xB0/0xC0 stubs (function number in t1) and
`syscall` to `Kernel.a0/b0/c0/sys(ctx, t1)`; args a0–a3 (+stack), result v0.

### 3.1 P0 — boot-critical

| Call | Fn | Semantics |
|---|---|---|
| A0:0E/0F | abs/labs | `v0 = \|a0\|` |
| A0:13/14 | setjmp/longjmp | BIOS jmp_buf layout {ra,sp,fp,s0–s7,gp}; longjmp → unwind protocol §3.7, v0=a1 |
| A0:15–26 | strcat…strstr, toupper/tolower | exact C semantics on RAM bytes |
| A0:27–2E | bcopy,bzero,bcmp,memcpy,memset,memmove,memcmp,memchr | byte-exact incl. memmove overlap; bcopy(src,dst) arg order! |
| A0:2F/30 | rand/srand | LCG `seed = seed*0x41C64E6D + 0x3039; v0 = (seed>>16) & 0x7FFF`; boot seed 0x3039 (deterministic) |
| A0:33/34/39 | malloc/free/InitHeap | deterministic first-fit heap on the game-provided region, 8-byte aligned |
| A0:3C/3F | putchar/printf | full integer printf (%d %u %x %X %o %c %s %p, width/pad) → Backend.log TTY |
| A0:41–43,51 | Load/Exec/LoadExec | ISO9660 lookup → copy EXE into RAM, fill EXEC struct; Exec: set gp/sp, `Runtime.call(pc0)` (the tool pre-recompiled all disc EXEs) |
| A0:44 | FlushCache | no-op + `OverlayMgr.rescan()` hook (overlay just copied → resolve resident overlay) |
| B0:07 | DeliverEvent(class,spec) | match open+enabled; EvMdINTR → call recompiled callback now; EvMdNOINTR → state=ALREADY |
| B0:08/09 | OpenEvent/CloseEvent | EvCB slot; v0 = 0xF1000000\|index |
| B0:0A/0B | WaitEvent/TestEvent | ALREADY→ACTIVE, v0=1; WaitEvent idles deterministically (§2) |
| B0:0C/0D | EnableEvent/DisableEvent | state ACTIVE/WAIT |
| B0:20 | UnDeliverEvent | ALREADY→ACTIVE for matches |
| B0:12/13/14 | InitPad/StartPad/StopPad | register buffers; vblank auto-refresh §11 |
| B0:5B | ChangeClearPad | pad handler auto-ack flag |
| B0:17/18/19 | ReturnFromException / SetDefault-/SetCustomExitFromException | no-op marker / store exception-epilogue hook (custom hook called after each dispatch batch) |
| C0:0A | ChangeClearRCnt(t,flag) | v0=old; controls kernel auto-ack during dispatch |
| C0:02/03 | SysEnqIntRP/SysDeqIntRP | maintain priority chains; handlers called as recompiled funcs at dispatch |
| SYS 01/02 | Enter/ExitCriticalSection | critDepth ±1; v0=1 if was enabled |

### 3.2 P1 — common

B0 file API (32 open, 33 lseek, 34 read, 35 write, 36 close, 37 ioctl, 39 isatty, 42/43
firstfile/nextfile, 44 rename, 45 erase, 41 format) over `cdrom:` (ISO9660 read-only) and
`bu00:/bu10:` (memcard FS: 15 dir frames, backed by the .mcd image §11); `_bu_init` A0:55,
`_96_init/_96_remove` A0:54/56 (arm the CD BIOS-event path); B0:47/48 AddDrv/DelDrv; A0:96/97
AddCDROMDevice/AddMemCardDevice; B0:4A–5D card ops (InitCard/StartCard/_card_read/_card_write/
_card_info/_card_chan/_card_status/_card_wait — async via MEMCARD_OP events delivering
F4000001/F0000011 events); A0:46–4E GPU helpers (GPU_dw, gpu_send_dma, SendGP1Command, GPU_cw,
GPU_cwp, send_gpu_linked_list, GetGPUStatus, gpu_sync) direct against `Gpu`; B0:00/01
alloc_kernel_memory/free; B0:56/57 GetC0Table/GetB0Table return the materialized table addresses;
GetSystemInfo canned (verify index semantics in psx-spx kernelbios).

### 3.3 P2 — rare

OpenTh/CloseTh/ChangeTh (B0:0E–10) cooperative HLE sketch (TCBs store register images; ChangeTh
swaps via the unwind protocol) — not needed for Crash Bash; log-fatal in strict mode.
C0:00/01/07/08/0C/12/1C no-ops with logging. Raw vector patching (writes to 0x80000080): debug
RAM watch → log + strict abort.

### 3.4 Event model

Classes 0xF0000001 VBLANK, …02 GPU, …03 CDROM, …04 DMA, …05–07 TMR0–2, …08 controller, …09 SPU,
…0B SIO, …10 exception, …11 memcard-low, 0xF2000000–03 RCnt0–3 (RCnt3 = vblank), 0xF3xxxxxx user,
0xF4000001 memcard-high (full list: psx-spx "BIOS Event Summary"). Specs: 0x0001 counter-zero,
0x0002 interrupted, 0x0004 end-of-IO, 0x0008 closed, 0x0010 ack, 0x0020 completed, 0x0040
data-ready, 0x0080 data-end, 0x0100 timeout, 0x8000 error. Modes: EvMdINTR=0x1000 (callback at
delivery), EvMdNOINTR=0x2000 (polled). States: UNUSED / WAIT 0x1000 / ACTIVE 0x2000 /
ALREADY 0x4000. Wiring: VBLANK → DeliverEvent(F0000001,2) + RCnt3; timer IRQ → F200000n spec 2
(+0x0001 at counter-zero); CD INT{3,2,1,4,5} → F0000003 spec {0x0010,0x0020,0x0040,0x0080,
0x8000} when `_96_init` armed; card ops per libcard.

### 3.5 Unimplemented-call policy

`Log.once(table<<8|index, callerPc)` → return 0; `--strict-kernel` aborts; `--report-kernel`
dumps hit counts (the coverage tool for game bring-up).

### 3.6 BIOS stub region

Each A0/B0/C0 entry gets a unique address 0x1FC01000+idx*8 written into the RAM tables; calls
landing in the BIOS window are kernel-stub invocations (games calling through read table pointers
still reach HLE). 0x1FC00108+ = canned date/version block mirroring retail layout.

### 3.7 Unwind contract (setjmp/longjmp, Exec, ChangeTh — no exceptions)

`ctx.unwindToken:Int` (0 = none). `longjmp` restores buf registers, sets the token, v0=a1, and
returns; generated code checks `if (ctx.unwindToken != 0) return;` after each call that analysis
marks *can-unwind*; frames peel back to the `Runtime.call` trampoline holding the matching setjmp
anchor, which clears the token and resumes at the restored ra. Zero cost in unwind-free
functions.

## 4. GPU

VRAM `vram:RawMem` 1024×512×u16. **Instant-draw model**: GP0 packets rasterize synchronously at
submission; GPUSTAT always reports ready; DrawSync returns immediately. Determinism: output
depends only on the packet stream and state.

**GP0 matrix**: 0x00, 0x03–0x1E, 0xE0, 0xE7–0xEF NOP · 0x01 clear-cache no-op · 0x02 Fill
(X&=0x3F0, W=((W&0x3FF)+0xF)&~0xF, absolute coords, ignores mask/clip/dither) · 0x1F GPU IRQ
(GPUSTAT.24 + I_STAT.1) · **0x20–0x3F polys** (bit28 gouraud, 27 quad, 26 textured, 25 semi,
24 raw-tex; per-vertex: [color], YyyyXxxx, [texcoord: word1 ClutVVUU, word2 PageVVUU, rest
0000VVUU]) · **0x40–0x5F lines** (28 gouraud, 27 polyline, 25 semi; terminator
`(w & 0xF000F000) == 0x50005000`) · **0x60–0x7F rects** (28–27 size: var/1×1/8×8/16×16,
26 textured+ClutVVUU, 25 semi, 24 raw; texpage from E1) · 0x80 VRAM→VRAM · 0xA0 CPU→VRAM
(X&0x3FF, Y&0x1FF, W=((W-1)&0x3FF)+1, H=((H-1)&0x1FF)+1, wraps, mask applies) · 0xC0 VRAM→CPU
(GPUREAD FIFO; GPUSTAT.27 while pending) · 0xE1 texpage (0–3 pageX×64, 4 pageY×256, 5–6 semi
mode, 7–8 depth 4/8/15bpp, 9 dither, 10 draw-to-display, 11 tex-disable, 12–13 rect flip) ·
0xE2 texture window (mask/offset ×8px: `tc = (tc & ~(m*8)) | ((o & m)*8)`) · 0xE3/E4 draw area
TL/BR (X 0–9, Y 10–18, inclusive) · 0xE5 draw offset (11-bit signed X 0–10, Y 11–21) · 0xE6 mask
(bit0 force-set bit15, bit1 skip if dest bit15).

**GP1**: 00 reset (GPUSTAT=0x14802000) · 01 reset FIFO · 02 ack IRQ · 03 display on/off · 04 DMA
direction 0–3 · 05 display VRAM start (X&~1) · 06/07 h/v display range · 08 display mode (hres1
256/320/512/640, vres 240/480, PAL, 24bpp, interlace, hres2=368, flip) · 09 ignore · 10 get-info
(texwindow/TL/BR/offset/version=2).

**GPUSTAT** (computed on read): 0–10 mirror E1; 11/12 = E6; 13 interlace field; 14 flip; 15
tex-disable; 16–19 res bits; 20 PAL; 21 24bpp; 22 interlace; 23 display-off; 24 IRQ; 25 per
GP1(04); 26 ready=1; 27 VRAM→CPU pending; 28 DMA-ready=1; 29–30 DMA dir; 31 even/odd (240p:
toggles per scanline; 480i: per frame; 0 in vblank — from the TimeBase line counter).

**Rasterizer (normative)**: vertices + draw-offset, 11-bit signed; reject if bbox w>1023 or
h>511; quads = (v0,v1,v2)+(v1,v2,v3). Fill rule: right/bottom exclusive with top-left bias (bias
−1 on non-top-left edge accumulators); integer edge functions (I64 setup, Int stepping). Lines:
PS1 DDA, endpoint-inclusive, polyline chained. Interpolation: 16.16 fixed-point gradients from
integer determinants, truncation via arithmetic shifts (identical on all targets); affine only.
Texturing: texpage base (X×64, Y×256) + window; 4bpp `clut[(v16 >> 4*(u&3)) & 0xF]`, 8bpp
`clut[byte]`, 15bpp direct; CLUT base (attr&0x3F)×16, y attr>>6; texel 0x0000 = transparent
(skip); raw skips modulation else `out = min(255, tex*col/128)` per channel. Semi-transparency
(cmd bit25; texels: only if texel bit15): modes 0 `(B+F)/2`, 1 `B+F`, 2 `B−F`, 3 `B+F/4` per
5-bit channel, clamp 0..31. Dither (E1 bit9, on 8→5 conversion): `c5 = clamp8(c8 + D[y&3][x&3])
>> 3`, D rows `{-4,0,-3,1},{2,-2,3,-1},{-3,1,-4,0},{3,-1,2,-2}`; polys if gouraud/modulated,
lines always, rects never. Mask per E6. Clip: draw-area ∩ VRAM.

**Scanout**: at VBLANK_START build `ScanoutDesc {srcX, srcY, width (from hres divider + h-range,
clamped to 256/320/368/512/640), height (240/480i), bpp15/24, interlaced, pal, dispEnabled}`;
24bpp = 3 bytes/px linear (MDEC FMV). `Backend.present(vram, desc)`; the backend never inspects
GPU state.

## 5. GTE

State: 32 data + 32 control registers as an Int vector; MAC intermediates in I64. Data r0–31:
VXY0/VZ0, VXY1/VZ1, VXY2/VZ2, RGBC, OTZ, IR0–3, SXY0/1/2/P (write SXYP = FIFO push; write SXY2 =
plain), SZ0–3, RGB0–2, RES1, MAC0–3, IRGB/ORGB(RO), LZCS/LZCR(RO). Control r32–63: RT (packed s16
pairs), TRX/Y/Z, LLM, RBK/GBK/BBK, LCM, RFC/GFC/BFC, OFX/OFY, H (u16, **reads sign-extend —
hardware bug, reproduce**), DQA/DQB, ZSF3/ZSF4, FLAG.

**FLAG bits**: 31 = OR(30..23, 18..13); 30–28 MACn > +2^43; 27–25 MACn < −2^43; 24–22 IRn
saturated; 21–19 color FIFO R/G/B; 18 SZ3/OTZ; 17 divide overflow; 16/15 MAC0 ±2^31; 14/13
SX2/SY2; 12 IR0. Cleared at the start of every command. Saturation: IR1–3 lm=0 → −0x8000..0x7FFF,
lm=1 → 0..0x7FFF; IR0 0..0x1000; SX/SY −0x400..0x3FF; SZ/OTZ 0..0xFFFF; color 0..0xFF.

**Ops** (opcode bits 5–0; fields: bit19 sf, 18–17 MVMVA mx, 16–15 v, 14–13 cv, bit10 lm) with
cycle costs charged to `ctx.cycles`: RTPS 0x01(15), NCLIP 0x06(8), OP 0x0C(6), DPCS 0x10(8),
INTPL 0x11(8), MVMVA 0x12(8), NCDS 0x13(19), CDP 0x14(13), NCDT 0x16(44), NCCS 0x1B(17),
CC 0x1C(11), NCS 0x1E(14), NCT 0x20(30), SQR 0x28(5), DCPL 0x29(8), DPCT 0x2A(17), AVSZ3 0x2D(5),
AVSZ4 0x2E(6), RTPT 0x30(23), GPF 0x3D(5), GPL 0x3E(5), NCCT 0x3F(39). Invalid → no-op +
log-once.

Core semantics: every MAC1–3 accumulation in I64 with a 44-bit overflow check per step (flags
30–25), result `>> sf*12`; IR saturation with lm. RTPS: MACn = (TR*0x1000 + RTn·V) >> sf*12;
SZ3 = sat16u(MAC3 >> ((1−sf)*12)); n = UNRdiv(H, SZ3); SX2/SY2 = satSX(sext44(OFX + IR1*n) >> 16);
MAC0 = DQB + DQA*n, IR0 = sat(MAC0 >> 12). **UNR division (exact)**:

```
if (H < SZ3*2) { z = clz16(SZ3); n = H << z; d = SZ3 << z;
  u = unr_table[(d - 0x7FC0) >> 7] + 0x101;
  d = (0x2000080 - d*u) >> 8;  d = (0x80 + d*u) >> 8;
  n = min(0x1FFFF, (n*d + 0x8000) >> 16); }
else { n = 0x1FFFF; FLAG.17 = FLAG.31 = 1; }
unr_table[i] (0x101 entries) = max(0, (0x40000/(i+0x100)+1)/2 - 0x101); [0x100] = 0
```

NCLIP: MAC0 = SX0(SY1−SY2)+SX1(SY2−SY0)+SX2(SY0−SY1) in I64. AVSZ3/4: OTZ = sat(ZSFn·ΣSZ >> 12).
Lighting family (NCS/NCT/NCCS/NCCT/NCDS/NCDT/CC/CDP/DPCS/DPCT/DCPL/INTPL/GPF/GPL/MVMVA/SQR/OP):
implement per psx-spx "GTE Operations Summary" formula blocks with shared helpers (mulMat, satIR,
pushColor); **reproduce the documented buggy cv=FC MVMVA path exactly**. FIFOs: SXY/SZ/RGB
shift-push. Accessor side effects: IRGB write → IR1–3 = field*0x80; ORGB read = clamp5(IRn/0x80)
packed; LZCS write → LZCR = leading zeros/ones; H reads sign-extend. Hardware GTE read-delay
slots are irrelevant under recompilation (amidog delay-probe subtests excluded by a committed
list).

`Gte.execute(ctx, cmd)` is a single switch with zero allocation. Tests: per-op golden vectors
(inputs + full post-state incl. FLAG) as data files; gate = amidog psxtest_gte, 0 failures.

## 6. SPU

`spuram:RawMem` 512KB (capture buffers 0x000–0xFFF implemented — cheap, and streamers IRQ on
them). Batched catch-up: one stereo frame per 768-cycle tick since the last catch-up; forced at
SPU register access, DMA4, CD sector feed, VBLANK, and the SPU_BATCH event every 32 ticks.

**Registers** (16-bit): per-voice N at 0x1F801C00+N*0x10: +0/+2 volL/R (bit15 → sweep mode:
exp/dec/phase/shift/step fields), +4 pitch (0x1000 = 44100), +6 start addr ×8, +8 ADSR-lo (bit15
attack-exp, 14–10 attack shift, 9–8 attack step, 7–4 decay shift, 3–0 sustain level (N+1)*0x800),
+A ADSR-hi (15 sustain-exp, 14 dir, 12–8 sustain shift, 7–6 step, 5 release-exp, 4–0 release
shift), +C current ADSR vol (R/W), +E repeat addr ×8. Globals: 0x1D80–86 main volL/R + reverb
vLOUT/vROUT, 0x1D88 KON, 0x1D8C KOFF, 0x1D90 PMON, 0x1D94 NON, 0x1D98 EON, 0x1D9C ENDX(RO),
0x1DA2 reverb mBASE ×8, 0x1DA4 IRQ addr ×8, 0x1DA6 transfer addr ×8, 0x1DA8 FIFO, 0x1DAA SPUCNT
(15 enable, 14 unmute, 13–8 noise shift/step, 7 reverb-enable [gates work-area writes only],
6 IRQ enable/ack, 5–4 transfer mode, 3–0 ext/CD reverb+enable), 0x1DAC transfer ctrl (0x0004),
0x1DAE SPUSTAT (echo CNT 5–0, 6 IRQ flag, 8/9 DMA req, 10 busy=0, 11 capture-half), 0x1DB0 CD vol
L/R, 0x1DB8 current main vol, 0x1DC0–0x1DFF reverb block.

**Voice pipeline per tick** (integer only): (1) ADPCM 16-byte blocks — byte0 shift(s>12→9)/filter
f; byte1 flags (bit0 loop-end → jump repeat, set ENDX, +bit1=0 → release env=0; bit2 loop-start →
repeat=current); `t = sext4(nib) << (12−s); sample = clamp16(t + ((old*F0[f] + older*F1[f] + 32)
>> 6))`, coefficient pairs (0,0),(60,0),(115,−52),(98,−55),(122,−60). (2) Pitch: `step = pitch`
(+PMON modulation by the previous voice's output), clamp 0x3FFF; counter bits 12+ advance, bits
4–11 = gauss index. (3) Gaussian 4-tap per the psx-spx table (512 entries → generated
`GaussTable.hx`, never hand-inlined). (4) NON → noise LFSR (shared generator, documented
step/shift). (5) ADSR exact: `cycles = 1 << max(0, shift−11); step = baseStep << max(0, 11−shift);
expInc && level > 0x6000 → cycles *= 4; expDec → step = step*level >> 15`; phases attack→0x7FFF,
decay(exp-dec, −8)→(susLvl+1)*0x800, sustain(dir), release→0; KON: env=0/attack/cur=start/clear
voice ENDX; KOFF → release. (6) out L/R = `((sample*env >> 15) * volL/R) >> 15`; sweep envelopes
reuse the ADSR step machinery.

**Mixing order per tick** (frozen for determinism; verify saturation points against psx-spx "SPU
Mixer" during bring-up): dry s32 = Σ voices (+CD input × CD vol if CNT.0); wetIn = Σ EON voices
(+CD if CNT.2) sat16; reverb consumes wetIn → wetOut × vLOUT/vROUT >> 15; `out = sat16(sat16(dry)
*mainVol >> 15) + wet → sat16`; unmute gates dry+wet. Voice1/3 + CD L/R → capture buffers at
`tick & 0x1FF`.

**Reverb** at 22050 Hz (even tick = left, odd = right). Registers dAPF1/2, vIIR, vCOMB1–4, vWALL,
vAPF1/2, mLSAME/mRSAME, mLCOMB1–4/mR…, dLSAME/dRSAME, mLDIFF/mRDIFF, dLDIFF/dRDIFF,
mLAPF1/2/mRAPF1/2, vLIN/vRIN. Algorithm (s16 buffer ops in SPU RAM, saturated, addresses ×8
relative to mBASE, wrapping to 0x7FFFE):

```
Lin = vLIN*in
[mLSAME] = sat((Lin + [dLSAME]*vWALL − [mLSAME−2])*vIIR + [mLSAME−2])
[mLDIFF] = sat((Lin + [dRDIFF]*vWALL − [mLDIFF−2])*vIIR + [mLDIFF−2])
L = vCOMB1*[mLCOMB1] + … + vCOMB4*[mLCOMB4]
L = L − vAPF1*[mLAPF1−dAPF1]; [mLAPF1] = sat(L); L = L*vAPF1 + [mLAPF1−dAPF1]
L = L − vAPF2*[mLAPF2−dAPF2]; [mLAPF2] = sat(L); L = L*vAPF2 + [mLAPF2−dAPF2]
out = L; bufAddr = max(mBASE, (bufAddr+2) & 0x7FFFE)      // mirrored for R
```

(products >> 15; exact rounding per psx-spx "SPU Reverb Formula"). CNT.7=0 disables buffer
*writes* only.

**Transfers & IRQ9**: transfer addr ×8; manual FIFO halfword commits; DMA4 instant at trigger.
IRQ compare (voice fetch, transfer, capture writes) against IRQ addr ×8 → SPUSTAT.6 + I_STAT.9
when CNT.6; ack = clear CNT.6; compare at exact tick granularity (streaming engines depend on it).

**Output contract**: exactly one s16 pair per tick → `AudioRing` (SPSC, 4096 pairs, u32 monotonic
indices); the backend drains at its own pace; underrun pads silence backend-side only; the
emulated timeline never reads host consumption. The frame hash taps the producer stream.

## 7. CD-ROM

Backed by `shared/psxdisc` through `bp_file_*`. All latencies are **defined constants**
(deterministic; config-overridable if a game proves latency-sensitive; real figures in psx-spx
"CDROM Response Timings"): ACK = 50_000; SEEK(d) = 564_480 + d*7 (capped ≈0.5 s);
PAUSE = 1_000_000; INIT = 2_000_000; STOP = 1_500_000; GETID = 451_584; sector cadence
451_584/225_792 (1x/2x); INT re-raise after ack = 2_000.

**Registers** (0x1F801800–3, bank via index bits): 1800 status (0–1 index, 2 ADPBUSY, 3 PRMEMPT,
4 PRMWRDY, 5 RSLRRDY, 6 DRQSTS, 7 BUSYSTS) / index write · 1801.0 response FIFO / command ·
1802.0 data FIFO / param FIFO (16 deep) · 1802.1 IRQ enable · 1803.0 IRQ enable readback /
request (bit7 BFRD loads sector→FIFO; 0 clears) · 1803.1 IRQ flags (0–2 INT#, 3 BFEMPT, 4 BFWRDY)
/ write-1-ack (+bit6 clear param FIFO) · volume regs ATV0–3 + apply latch on other banks. One
pending INT at a time; successors queue until ack.

**Command table** (params → responses; errors INT5(stat|0x01, code)):

| Cmd | Name | Sequence |
|---|---|---|
| 0x01 | Getstat | INT3(stat); clears shell-open latch |
| 0x02 | Setloc mm,ss,ff BCD | INT3; bad BCD → INT5(0x10) |
| 0x03/04/05 | Play/Forward/Backward | INT3; CDDA; Report-mode INT1(track,index,MSF/peak) at fixed cadence |
| 0x06/0x1B | ReadN/ReadS | INT3(stat), then INT1(stat) per sector at cadence |
| 0x07/08/09 | MotorOn/Stop/Pause | INT3, INT2 after constant |
| 0x0A | Init | INT3, INT2 after INIT; mode reset, aborts transfers |
| 0x0B/0C | Mute/Demute | INT3; gates CD input (XA+CDDA) |
| 0x0D | Setfilter file,chan | INT3 |
| 0x0E | Setmode | INT3. Bits: 0 CDDA, 1 AutoPause, 2 Report, 3 XA-filter, 5 sector size (0=0x800@24, 1=0x924@12), 6 XA→SPU, 7 double speed |
| 0x0F | Getparam | INT3(stat,mode,0,file,chan) |
| 0x10/0x11 | GetlocL/GetlocP | INT3(last data header) / INT3(track,index,mm,ss,sect,amm,ass,asect BCD from computed subQ); GetlocL on audio → INT5 |
| 0x12 | SetSession | session 1 only; else INT5(0x10) |
| 0x13/0x14 | GetTN/GetTD | INT3 BCD from CUE TOC |
| 0x15/0x16 | SeekL/SeekP | INT3, INT2 after SEEK(d) |
| 0x19 | Test 0x20 | INT3(0x94,0x09,0x19,0xC0) canned version; other subs log-once + INT5 |
| 0x1A | GetID | INT3(stat) then INT2(0x02,0x00,0x20,0x00,'S','C','E','A') licensed (region char from config); audio disc INT5(0x0A,0x90); no disc INT5(0x08,0x40) |
| 0x1C | Reset | INT3; full reset after constant |
| 0x1E | ReadTOC | INT3, INT2 after ~1 s constant |

Status byte: 0 error, 1 motor, 2 seek-err, 3 id-err, 4 shell-open (latched), 5 read, 6 seek,
7 play (5/6/7 exclusive). States: Idle/SeekPending/Reading/Playing/Paused/Stopped — transitions
only via scheduled CD_EVENTs.

**Data path**: per sector event: fetch raw 2352 at LBA++; XA-ADPCM realtime Form2 audio + mode.6
(+filter) → XA decoder (no INT1, no buffer); else stage into double-buffered sector slots +
INT1(stat). BFRD → slot → data FIFO; read via port or DMA3. mode.5: 0 → 0x800 bytes @ offset 24;
1 → 0x924 @ offset 12.

**XA-ADPCM**: subheader file/channel/submode/coding; payload 18 groups × 128 bytes (16 hdr + 112
data); 4-bit: 8 blocks × 28 samples/group; same filter/shift math as SPU ADPCM (filters 0–3,
shift>12→9), per-channel old/older. Output 37800 Hz (18900 → each sample twice). **Resample to
44100 = psx-spx zigzag interpolation verbatim** (0x20-entry ring per channel, 7 output phases per
6 inputs, six 29-tap integer tables — copy from the "37800Hz → 44100Hz" section). → CD-input FIFO
consumed 1/tick by the SPU, scaled by the ATV matrix (L' = satL((l*ATV0 + r*ATV2) >> 7), R'
analogous).

**CDDA**: Playing pulls 588 pairs per sector event from audio track raw data (s16LE, 75×588 =
44100 exactly) → the same CD input path. AutoPause at track end → INT4(stat)+pause; Report INT1
at fixed cadence.

## 8. MDEC

Registers: 0x1F801820 cmd/params (W), data FIFO (R); 0x1F801824 status (31 out-empty, 30 in-full,
29 busy, 28/27 DMA0/1 req gated by ctrl bits, 26–25 depth, 24 signed, 23 bit15, 18–16 current
block Y1–4/Cr/Cb, 15–0 remaining-1) / control (31 reset → 0x80040000, 30/29 DMA enables).
Commands (bits 31–29): 1 = decode (28–27 depth 4/8/24/15bpp, 26 signed, 25 bit15, 15–0 param
words); 2 = set quant (bit0 +color; 64[+64] bytes); 3 = set IDCT scale table (64×s16).

Pipeline per block: halfwords → DC (bits 15–10 qscale, 9–0 signed DC) then RLE (15–10 zero-run,
9–0 AC) until 0xFE00 EOB; de-zigzag; dequant: DC `val = sext10(dc)*qt[0]`, AC
`val = (sext10(ac)*qt[zz]*qscale + 4) >> 3`, qscale==0 → `val = sext10*2`; saturate s11; 8×8.
**IDCT = psx-spx bit-exact two-pass integer reference** (`dst = (Σ src*(scaletable/8) + 0xFFF)
>> 13` with pass-transposed indexing — copy verbatim from "MDEC Decompression", do not
re-derive). Macroblock: mono 8×8 Y; color Cr,Cb,Y1–4 → 16×16, chroma 2×2 upsample. YUV→RGB frozen
integer constants: `r = (359*Cr) >> 8; g = (−88*Cb − 183*Cr) >> 8; b = (454*Cb) >> 8`, each
`clamp(−128,127, Y + c)`, `+128` iff unsigned (verify against psx-spx "MDEC Colorspace
Conversion" at bring-up; the frozen constants guarantee determinism regardless). Output: 15bpp
BGR555+bit15 two px/word; 24bpp packed RGB; 4/8bpp luma. DMA ch0 in (32-word slices) / ch1 out
(block mode; BS lays 16-wide strips into VRAM). Status current-block/remaining emulated so polling
loops behave. Test: golden macroblock stream (synthetic gradient + one real STR block) → output
hash.

## 9. DMA

Channels 0 MDECin, 1 MDECout, 2 GPU (modes 1/2), 3 CDROM (0), 4 SPU (1), 5 PIO (log), 6 OTC (0).
MADR bits 0–23; BCR mode0 BC words (0=0x10000) / mode1 BS|BA; CHCR: 0 direction, 1 step(−4),
8 chopping (accepted, ignored), 9–10 sync mode, 24 busy, 28 trigger. DPCR (reset 0x07654321)
nibble bit3 = master enable per channel; priority is irrelevant under the instant model
(program-order). DICR: 0–5 scratch, 15 force-IRQ, 16–22 per-channel enable, 23 master, 24–30 flags
(W1C), 31 RO = `b15 || (b23 && flags&enables)`; 0→1 of bit31 → I_STAT.3.

**Instant-transfer model**: at (enabled && busy && (mode≠0 || trigger)) with the device ready →
the full transfer executes synchronously: burst BC words; slice BS×BA; linked-list (ch2 RAM→GPU)
walks `{count<<24 | next}` headers, submits payload to GP0, terminates on addr bit23, iteration
cap 1<<20 → log+abort. OTC: back-chain BCR words ending 0xFFFFFF (CHCR fixed except bits
24/28/30). CHCR.24 clears at completion; DICR flag + IRQ scheduled at `+64 + (words >> 4)` cycles
(word-scaled — long GPU lists complete after short ones). MADR updates to the end value. Future
config knob `dmaPacing=cycles-per-word` reuses the same completion path for DMA-racing titles.

## 10. Timers

Three counters at 0x1F801100+N*0x10: value (R/W), mode (R/W; write resets value + sets bit10),
target. Mode: 0 sync enable, 1–2 sync mode, 3 reset@target, 4 IRQ@target, 5 IRQ@0xFFFF, 6 repeat,
7 toggle-vs-pulse (bit10), 8–9 source, 10 IRQ-request (inverted, R), 11/12 reached target/overflow
(read-reset). Sources: T0 sysclk/dotclock (exact rational 11/(7·div)); T1 sysclk/hblank;
T2 sysclk / sysclk÷8. Sync modes T0/T1: pause-in-blank / reset-at-blank / reset+pause-outside /
pause-until-first; T2: 0/3 stop, 1/2 free-run. **No per-tick stepping**: `{anchorCycle,
anchorValue, fracRem}` per counter; reads compute closed-form; target/overflow solved exactly and
scheduled as TIMERn events (set bits 11/12, drive bit10 pulse/toggle, raise I_STAT 4–6, wrap/reset
per bit3; one-shot suppresses further IRQs until mode rewrite). The kernel RCnt API (B0:02–06,
C0:0A) maps onto the same registers (spec F2000000+n events).

## 11. SIO0 — pads & memory cards

**Registers**: 0x1F801040 JOY_DATA (R FIFO / W TX), 0x1044 JOY_STAT (0 TX-ready1, 1 RX-not-empty,
2 TX-ready2, 7 /ACK level, 9 IRQ), 0x1048 JOY_MODE, 0x104A JOY_CTRL (0 TX en, 1 /JOYn select,
4 ack, 6 reset, 10–12 IRQ enables, 13 slot), 0x104E JOY_BAUD (0x88). Byte model: write with select
→ SIO_BYTE event at +1088 cycles; at the event: response byte → RX FIFO; if the device continues,
/ACK pulses → I_STAT.7 (the last byte of a transaction does NOT ack). Deselect resets device
protocol state. ISR-driven (libpad) and busy-poll loops both ride these events.

**Controller protocol**: digital `01 42 00 00 00` ⇄ `HiZ 41 5A lo hi` (ID 0x5A41; buttons
active-low: 0 Sel, 1 L3, 2 R3, 3 Start, 4–7 Up/Right/Down/Left, 8 L2, 9 R2, 10 L1, 11 R1, 12 △,
13 ○, 14 ✕, 15 □). Analog ID 0x5A73 + RX,RY,LX,LY (center 0x80). Config mode: 0x43 (ID 0xF3),
0x44 LED, 0x45 status, 0x46/47/4C constants, 0x4D rumble map; P0 scope = digital + analog reads.

**Multitap (required — 4-player games)**: the console sets byte index 2 of the 0x42 frame to 0x01
→ the multitap block is returned **on the following poll** (previous-tap addressing; `tapArmed`
latched per port per frame). Tap frame = 34 bytes: header `80 5A`, then 4 slots × 8 bytes (digital
`41 5A lo hi FF FF FF FF`; analog `73 5A lo hi rx ry lx ly`; empty `FF FF…`). Non-armed polls
return slot A in normal format. Per-slot padding byte values: verify against psx-spx "Multitap"
before lock-in. `Pads.hx` is the single state source: 4 × `PadState{id, buttons, sticks, rumble}`
latched once per vblank, consumed by BOTH the raw-SIO and kernel paths.

**Kernel pad path (primary — Psy-Q libpad uses BIOS buffers)**: InitPad(buf1,0x22,buf2,0x22) +
StartPad → at each VBLANK dispatch (before game callbacks) HLE writes the 0x22-byte buffers:
byte0 status, byte1 `(type<<4)|halfwords`, payload (multitap: the full 4×8 block; exact layout:
psx-spx "BIOS Pad Functions" — verify before lock-in). Games driving SIO0 directly get the raw
path above; both read the same Pads snapshot.

**Memory card protocol**: select 0x81; ID `81 53` → `FLAG 5A 5D 5C 5D 04 00 00 80`; read sector
`81 52 00 00 MSB LSB …` ⇄ `… 5C 5D MSB LSB data×128 CHK 47` (CHK = XOR); write
`81 57 … data×128 CHK` ⇄ end byte 0x47 good / 0x4E bad-checksum / 0xFF bad-sector (full per-byte
duplex table: psx-spx "Memory Card Read/Write Commands" — implement verbatim). FLAG: bit3
fresh-card (cleared by the first successful write), bit2 last-error. A sector write commits after
the end byte + a 4_000_000-cycle MEMCARD_OP latency (libcard async events ride on it).

**Persistence**: raw 128KB `.mcd` (1024×128B, emulator-compatible). Loaded at boot (absent → a
freshly formatted image); journaled writes flushed sector-granular via atomic replace (temp +
rename through bp_storage) at write-latency completion and at shutdown. Two slots (bu00/bu10),
presence config-driven.

## 12. Debug & diagnostics

`#if psx_debug` strips tracing from release builds. Runtime `DebugFlags`: trace-kernel (name +
args + ret), trace-cd, trace-gpu (packets + per-prim summaries), trace-dispatch, trace-irq,
dispatch-miss (indirect target not in table → log pc+target; strict aborts). `Log.once(key, msg)`
fixed-capacity registry; `--report` dumps the registry + kernel coverage at exit. Headless runner
(null backend): `--headless --frames N --hash` → per-frame FNV-1a-32 over (scanout bytes ∥ frame
audio pairs ∥ optional `--hash-vram`) folded into a running digest, printed per frame and at the
end — the determinism gate, compared across C++ and JVM builds. `--dump-bmp N`, `--dump-wav`.
Address watchpoints (debug builds): fixed `{lo,hi,onRead,onWrite}` array in `Memory.slow*` plus an
optional `--watch-ram` slow mode. Error convention: no exceptions; cold paths return status codes;
unrecoverable → `Fatal.raise(code, detail)` → backend fatal (prints last-dispatch context +
cycles) → clean exit; hot paths only `Log.once` + defined values.

## 13. Bring-up order & acceptance (feeds milestones M2–M5)

| # | Stage | Artifact | Pass criterion |
|---|---|---|---|
| 1 | Memory+TimeBase+kernel-min TTY | PSn00bSDK hello.exe | exact TTY bytes; clean exit; empty log-once report |
| 2 | GTE | unit vectors per op, then amidog psxtest_gte | vectors bit-exact; psxtest_gte 0 failures (delay probes excluded by committed list) |
| 3 | GPU raster+scanout | PSn00bSDK gpu examples | frame FNV hashes match locked goldens (visually reviewed once); identical C++ vs JVM |
| 4 | DMA+timers+IRQ | OTC+linked-list scene; timer-IRQ counter test | scene hash; expected tick counts at frames 60/120 |
| 5 | CPU conformance | amidog psxtest_cpu | all non-excluded groups pass; exclusion list committed with rationale (cache isolation — no I-cache; precise exception traps — recompiled code can't fault; adversarial load-delay — resolved at build time) |
| 6 | SPU | ADPCM fixture + ADSR vectors + reverb fixture | ring hash golden; IRQ9 streaming fires at exact ticks |
| 7 | CD | fixture CUE/BIN (data + audio + XA) | GetTN/TD/ID bytes exact; kernel file read byte-identical; XA + CDDA hashes |
| 8 | MDEC | STR macroblock fixture | frame hash; DMA path ≡ FIFO path |
| 9 | Pads+multitap | scripted input replay; raw-SIO ROM + InitPad path | both paths identical 4-pad frames; arming rule verified (frame N arms, N+1 delivers) |
| 10 | Memcard | save/load loop + BIOS file API | .mcd golden hash; atomic-write kill test leaves a valid image; FLAG/end bytes exact |

After stage 10: boot the bring-up game to attract mode under `--headless --hash` and lock the
digest as the regression anchor.
