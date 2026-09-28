# Spec — Backend & shim layer

Normative specification for the platform boundary. Source: master plan §8, extended with the
console target matrix.

The runtime is platform-agnostic. Everything platform-specific lives behind two seams:

1. **`backend_c_api.h`** — a flat C ABI implemented once per platform, outside Haxe.
2. **`src/shims/<target>/`** — `RawMem` (raw memory + byte order), `Bulk` (whole runs of it),
   `I64`, and the externs that bind the C ABI. This is where target-specific Haxe lives; the
   runtime never has `#if` for a platform.

## 0. Target matrix

PC is what we build now; every other target must be reachable by implementing one header and one
shim directory. No runtime code changes.

| Target | Toolchain / SDK | CPU | Byte order | RAM | Notes |
|---|---|---|---|---|---|
| **macOS / Linux / Windows** | SDL2 + clang/gcc/MSVC | x86-64 / arm64 | LE | ample | First and reference implementation |
| **PS2** | ps2dev (PS2SDK, ee-gcc) | R5900 (MIPS) | LE | 32 MB | GS for present, SPU2 via audsrv, libpad, libmc. C++17 needs a current ps2dev toolchain — verify GCC version early |
| **PSP** | pspdev (PSPSDK) | Allegrex (MIPS) | LE | 32/64 MB | sceGu present, sceAudio, sceCtrl |
| **Dreamcast** | KallistiOS | SH-4 | LE | 16 MB | Tightest memory budget; binary-search FnTable mandatory |
| **GameCube / Wii** | devkitPPC + libogc | PowerPC | **BE** | 24 / 88 MB | The only current target needing the byteswap path in `RawMem` |
| **Switch** | devkitA64 + libnx | ARM64 | LE | ample | |
| **JavaScript** | Haxe JS target + Node | — | — | ample | **The development and verification target (ADR-0003).** No C ABI: `shim.Backend` is pure Haxe. Node and browser main-thread execution through optional cooperative continuations (ADR-0010) |
| **JVM family** | Haxe JVM target | — | — | ample | No C ABI either; same shape as the JS shim |

Consequences captured in the design:

- **Byte order is a shim concern, never a backend concern.** Backends always receive host-order
  data and stay dumb blitters. Only `src/shims/*/RawMem` knows about endianness.
- **Memory budget matters.** Runtime state is fixed: 2 MB emulated RAM + 1 MB VRAM + 512 KB SPU
  RAM + 1 KB scratchpad ≈ 3.5 MB. The variable is generated code size (a PS1 game with ~500 K
  instructions is expected to compile to roughly 8–15 MB of machine code) plus the dispatch
  table. The generated `FnTable` and `Overlays` already use sorted integer rows with binary
  search and direct-mapped lookup caches; there is no `fntable=binary` switch. Aligned copies
  are initialized before guest execution. Table size follows the discovered block count.
- **Old or unusual toolchains** are the main console risk, not the architecture: the generated
  C++ is plain C++17 with no dependencies, but each SDK's compiler must actually support C++17.
  Verify per target before committing to it.

## 1. `src/backend/api/backend_c_api.h` — the ABI (v1)

Contract: pure C17; all calls come from the single emulator thread; the backend never affects
emulated state (`bp_time_us` is pacing only); pointers are borrowed for the duration of the call;
no structs cross the Haxe↔C boundary (flat accessors only — this sidesteps every unverified
reflaxe.CPP extern behavior).

```c
#ifndef RECOMPSX_BACKEND_C_API_H
#define RECOMPSX_BACKEND_C_API_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* lifecycle */
int  bp_init(const char* title);      /* 0 ok, nonzero fatal failure */
void bp_shutdown(void);
void bp_exit_to_menu(void);           /* QUIT (ADR-0041): the host's own menu — the Dreamcast's
                                         BIOS menu, the desktop, the page's start; the runtime has
                                         kept the memory card first */
enum { BP_CAP_MAX_PADS = 0, BP_CAP_HAS_AUDIO = 1, BP_CAP_HAS_STORAGE = 2, BP_CAP_PREFERRED_SCALE = 3, BP_CAP_GPU_DRAW = 4,
       BP_CAP_SPU_VOICES = 5, BP_CAP_GPU_UPLOADS = 6 };
int  bp_caps(int cap_id);
/* video: vram = borrowed 1024x512 uint16 (pitch 1024 halfwords); src rect in VRAM coords;
   24bpp: packed RGB888 rows starting at byte offset src_x*2 */
enum { BP_PRESENT_24BPP = 1 << 0, BP_PRESENT_INTERLACE = 1 << 1, BP_PRESENT_PAL = 1 << 2,
       BP_PRESENT_FAST = 1 << 3,     /* FAST: memory card sectors are moving (ADR-0037); a backend
                                        that paces at present need not hold this frame */
       BP_PRESENT_DRAWING = 1 << 4 };/* DRAWING: a DMA list is still being drawn (ADR-0039); a
                                        backend showing the primitives it was handed must not
                                        close its picture on this present */
void bp_present(const uint16_t* vram, int src_x, int src_y, int src_w, int src_h, int flags);
/* audio: 44100 Hz stereo s16 interleaved; count = stereo frames */
void bp_audio_push(const int16_t* frames, int frame_count);
int  bp_audio_buffered(void);
/* input: 4 pads (multitap). Poll once per emulated vsync. */
enum { BP_PAD_NONE = 0, BP_PAD_DIGITAL = 1, BP_PAD_ANALOG = 2 };
void bp_input_poll(void);
int  bp_pad_connected(int pad);
int  bp_pad_type(int pad);
uint32_t bp_pad_buttons(int pad);            /* PS1 bit layout, low 16 bits */
int  bp_pad_axis(int pad, int axis);         /* 0=LX 1=LY 2=RX 3=RY; 0..255 center 128 */
int  bp_quit_requested(void);
/* keyboard as text (ADR-0036, ADR-0040): typed only while text entry is on — while the machine's
   PS/2 keyboard is polled; then only the arrows of a keyboard that also plays a pad still press
   it. Next: a code point or BP_KEY_*, -1 when none */
enum { BP_KEY_BACKSPACE = 8, BP_KEY_ENTER = 10, BP_KEY_ESCAPE = 27 };
void bp_key_text(int on);
int  bp_key_next(void);
/* mouse (ADR-0038, ADR-0040): latched by bp_input_poll; over the picture, x/y as fractions
   0..65535 of it, buttons held (left, right, middle, back, forward); the machine's Sony Mouse
   follows it */
enum { BP_MOUSE_OVER = 0, BP_MOUSE_X = 1, BP_MOUSE_Y = 2, BP_MOUSE_BUTTONS = 3 };
int  bp_mouse(int field);
enum { BP_POINTER_OFF = 0, BP_POINTER_SHOWN = 1, BP_POINTER_HIDDEN = 2 };
void bp_mouse_pointer(int state); /* the machine's pointer: shown while its Sony Mouse is polled,
                                    hidden while a pad is in use; the art is pointer_art.h */
/* network (ADR-0040): the i-mode centre's way out — one HTTP request (origin form, raw bytes) to
   host:port, never blocking. open: a handle, -1 no network; read: bytes > 0, 0 not yet, -1 the
   response is complete, -2 failed; close once per handle */
int  bp_http_open(const char* host, int port, const uint8_t* request, int len);
int  bp_http_read(int handle, uint8_t* buf, int cap);
void bp_http_close(int handle);
/* storage: name in [A-Za-z0-9._-]{1,64}; config — the HLE kernel's console settings are one
   such blob, system.cfg (ADR-0034); the browser keeps them in localStorage */
int  bp_storage_read(const char* name, uint8_t* buf, int len);        /* bytes read, -1 none */
int  bp_storage_write(const char* name, const uint8_t* buf, int len); /* 0 ok, -1 fail */
/* memory cards (ADR-0037): a game's card in recompsx's card format — a 16-byte header and a
   record (directory frame + 8 KB) per block in use — under its product code; the backend keeps
   the bytes its own way. len == BP_CARD_HEADER (no blocks) removes the backend's copy. */
int  bp_card_load(const char* game, uint8_t* buf, int cap);  /* bytes, -1 none */
int  bp_card_save(const char* game, const char* title, const uint8_t* buf, int len); /* 0/-1 */
/* disc/file streaming: the runtime CD subsystem reads the user's image through this.
   Backends stay dumb byte-servers; ALL CUE/sector/ISO logic lives in portable Haxe
   (shared/psxdisc). Slots 0..7; the host resolves paths from argv/launch config. */
int  bp_file_open(int slot, const char* path);   /* 0 ok, -1 fail */
int  bp_file_size(int slot);                     /* bytes; BIN files fit int32 */
int  bp_file_read(int slot, int offset, uint8_t* buf, int len); /* bytes read */
void bp_file_close(int slot);
/* time & diagnostics */
uint64_t bp_time_us(void);            /* monotonic; PACING ONLY */
void bp_profile_mark(int section, int begin); /* optional: the runtime brackets its own work
                                      (BP_PROFILE_SPU/GTE/GPU); a backend may time or sample it,
                                      nothing returns */
enum { BP_LOG_DEBUG = 0, BP_LOG_INFO = 1, BP_LOG_WARN = 2, BP_LOG_ERROR = 3 };
void bp_log(int level, const char* msg);
void bp_fatal(const char* msg);       /* logs, tears down, exits; never returns */
#ifdef __cplusplus
}
#endif
#endif
```

### 1.1 Entry point: we own `main`, not the generator

reflaxe.CPP emits `_main_.cpp` containing `int main(int, const char**) { … }` which **discards
argc/argv** — so `Sys.args()` always returns empty (verified, PROGRESS.md [M0-VERIFY] #16).

Every build therefore **excludes the generated `_main_.cpp`** from its source list and links
`src/backend/<platform>/main_<platform>.c` instead, which stores argc/argv, calls `bp_init`, and
then calls the generated entry point. Command-line access is a backend concern like everything
else, and console platforms — which have no argv at all — supply their launch parameters the same
way. Two consequences for the CMake template: the generated-source glob must filter out
`_main_.cpp`, and each backend directory owns exactly one `main_*.c`.

## 2. PC implementation — `src/backend/pc/backend_sdl2.c`

Single file, the only one that touches SDL2. `SDL_Init(VIDEO|AUDIO|GAMECONTROLLER)`; 960×720
resizable window; renderer with **vsync OFF** (the emulator core owns pacing); 1024×512 streaming
texture; `bp_present` converts the source rect (BGR555→RGBA, or a 24bpp packed walk) and
letterboxes to 4:3 with integer scaling when it fits (X-resolutions 256/320/368/512/640 all map to
4:3); `SDL_QueueAudio` for push and `SDL_GetQueuedAudioSize/4` for buffered; input = a keyboard map
for pad 0 (arrows = dpad, X/S/Z/A = face, Q/W = L/R, Return = Start, RShift = Select) merged with
up to 4 `SDL_GameController`s (hotplug); storage under `SDL_GetPrefPath("recompsx", <game>)`;
`bp_time_us` from the performance counter; `bp_fatal` = message box + `exit(1)`.

Console implementations follow the same shape against their SDK: present = framebuffer copy or a
textured quad, audio = the platform's streaming API, input = the platform's pad API, storage =
memory card / SD / HDD, file = the platform's disc or mass-storage read. Nothing else changes.

Input reaches the machine in one place: at each vblank the runtime (`sio.Pads`) calls
`bp_input_poll` and reads `bp_pad_connected`/`bp_pad_buttons` for ports 1 and 2, and the emulated
controllers (SIO0, and the BIOS pad driver under HLE) answer from that snapshot. A headless run
(`--headless-hash`) never polls: every port is empty, so a digest never depends on the host. The
JavaScript target reads the page's keyboard, with the desktop key map above matched by physical
key (`KeyboardEvent.code`), and the Gamepad API in the W3C standard mapping, through Haxe's
browser externs (`shim.Input`); under Node no pad is connected. The Dreamcast backend reads maple
controllers (`dc_input.c`); the null backend has none.

The keyboard also types, for the machine's own keyboard (`sio.Ps2Keyboard` behind
`kernel.KKeyboard`; ADR-0036, ADR-0040). While something polls that keyboard — a mod's text field,
every frame it is open — the runtime keeps text entry on (`bp_key_text(1)`), and right after
`bp_input_poll` it drains `bp_key_next` into the keyboard as the key presses that type each
character on a US keyboard (Scan Code Set 2), so typing arrives once per vblank like the
buttons. What comes out is whatever the host's layout and input method made:
SDL2's `SDL_TEXTINPUT` (UTF-8, decoded) on the desktop, `KeyboardEvent.key` in the browser, a
maple keyboard's KallistiOS queue translated by its region (ISO-8859-1, which is Unicode's first
256 code points) on the Dreamcast; Backspace, Enter and Escape come as `BP_KEY_*`. While text
entry is on, a backend whose keyboard also plays pad 0 lets only the arrows press it, so a typed
`s` is never square as well, and the desktop's Escape cancels instead of quitting; a key held when
it ends becomes a button only when pressed again. The null backend, JVM and Node type nothing,
and a headless run never drains the keyboard.

The pointer is what the machine's Sony Mouse follows (`kernel.KMouse`, `sio.SonyMouse`; ADR-0038,
ADR-0040): `bp_mouse` answers, after
`bp_input_poll`, whether the pointer is over the picture, where as a fraction of it (0..65535 each
way — the kernel turns that into the emulated display's pixels), and which buttons are held, a
press shorter than a poll counted for one. SDL2 keeps the letterbox rectangle `bp_present` drew
in and scales the window's points to the renderer's pixels (high-DPI); the browser reads pointer
events over the page's picture element (`recompsxHost.screen`) and keeps the right button's menu
and the side buttons' history navigation from the page; the Dreamcast integrates a maple mouse's
motion on its 640 x 480 screen (a vblank handler adds up every bus frame's) and draws the arrow
itself, last in each scene. The machine has a pointer while its mouse is polled (a mod driving
its game with it); `bp_mouse_pointer` then says shown, or hidden while a pad is in use —
the Dreamcast draws `src/backend/api/pointer_art.h`, SDL2 makes its cursor of that art (the
system's own while the machine has none, none while hidden), the page adds the class `pointer`
whose CSS cursor is the same art (`cursor: none` while hidden). A maple keyboard is the
Dreamcast's pad 0 too, with the desktop's map, and types by the keyboard's own region
(ADR-0036). Null, JVM and Node have no mouse; a headless run never samples one.

The network is the i-mode centre's way out (`kernel.KIMode`, ADR-0040): the machine's i-mode
adaptor carries HTTP/1.0 requests, and the centre hands each to `bp_http_open` in origin form, with
the host and port apart, then reads the response raw with `bp_http_read` once a vblank. SDL2 opens
a non-blocking TCP socket (POSIX, or Winsock on Windows) and sends the request as it is; the
Dreamcast does the same over KallistiOS's TCP stack, bringing the network up (`net_init`: the
broadband or LAN adaptor, DHCP) in a thread at the first request, so nothing blocks a frame; the
browser sends it with `fetch` — the method, the headers a page may set and the body — and rebuilds
the raw response (status line, headers, `Content-Length`, body), which reaches only servers that
allow the page's origin (CORS). Null, JVM and Node have no network: `bp_http_open` returns -1, and
a headless run's centre rejects every request.

## 2.1 Dreamcast and optional hardware drawing

The KallistiOS backend in `src/backend/dreamcast/`, its launcher and `scripts/build-dc.sh` are
restored from commits `25d9a5d` / `6819782`. It implements video, audio, pads and file/storage
access through the same ABI, split by subsystem over several C files (backend_kos.c lists them)
that share only what `dc_internal.h` declares; `scripts/check.sh` checks a backend's ABI coverage
over all the C files in its directory. It is built with sh4zam (`vendor/sh4zam`, pinned, MIT):
any std function with an sh4zam counterpart uses sh4zam, and hardware work — store queues,
`movca.l`, prefetching — goes through its intrinsics
([ADR-0031](../decisions/ADR-0031-sh4zam-on-the-dreamcast.md); the backend's own agent notes are
`src/backend/dreamcast/AGENTS.md`). The September reconciliation verifies the PC/null ABI and both
Haxe targets; it does not constitute a new Dreamcast hardware acceptance run.

`--video-hw` selects the optional primitive submission path only if `BP_CAP_GPU_DRAW` is
available. Headless digest runs explicitly retain software rendering, even if both flags are
passed. JS, PC and null backends report no primitive drawing capability. The extended ABI is:

```c
void bp_gpu_vram(const uint16_t* vram);
void bp_gpu_state(int tex_base_x, int tex_base_y, int tex_depth,
                  int clut_x, int clut_y, int semi_mode, int flags, int tex_window,
                  int draw_x, int draw_y);
void bp_gpu_tri(int x0,int y0,int c0,int u0,int v0,
                int x1,int y1,int c1,int u1,int v1,
                int x2,int y2,int c2,int u2,int v2);
void bp_gpu_rect(int x,int y,int w,int h,int bgr,int semi,int semi_mode);
void bp_gpu_dirty(int x,int y,int w,int h);
```

GP0 parsing, uploads, VRAM copies and device timing still run in the core. Rasterized pixels from
this optional path are absent from emulated VRAM, so feedback/readback effects can differ; this is
not a bit-exact substitute for the software renderer. The exception is drawing no picture is made
of: a primitive whose drawing area lies in neither of the last two displayed rectangles and is
under three quarters of the picture either way, and a GP0(02h) fill meeting neither, are rasterised
by the core into emulated VRAM and reported through `bp_gpu_dirty` — a game making a texture for
itself, such as Crash 3's shadow ([ADR-0030](../decisions/ADR-0030-offscreen-drawing-is-state.md)).
A fill the backend does draw arrives under `bp_gpu_mask(0, 0)`, since the hardware ignores the mask
bits for it. `bp_gpu_dirty` reports only writes that changed emulated VRAM, except to a backend
answering `BP_CAP_GPU_UPLOADS` nonzero, which hears of every CPU-to-VRAM upload: its drawn pixels
become texels (the browser's WebGL renderer), and an upload that restores what emulated VRAM never
lost still replaces what it drew — Crash Bash's menu font after the 511x511 clear, which the
browser otherwise drew as nothing. The original decision and its measurements are preserved as
[ADR-0011](../decisions/ADR-0011-hardware-presentation-fork.md) (renumbered from that branch's
ADR-0008 to preserve main's machine-IR decision).

`--audio-hw` is the same kind of fork for sound, taken only if `BP_CAP_SPU_VOICES` is nonzero
and never on a headless run. The SPU then advances every voice as it does with nobody listening
and, after each batch of 128 samples, describes the voices instead of mixing them. Only the
Dreamcast backend offers it: it decodes the ADPCM into AICA sound RAM and plays each SPU voice
on an AICA channel ([ADR-0024](../decisions/ADR-0024-spu-voices-on-the-aica.md)). JS, PC and
null backends report 0 and keep the software mix:

```c
void bp_spu_ram(const uint8_t* ram);      /* the SPU's 512 KB, borrowed; once, before any voice */
void bp_spu_dirty(int addr, int len);     /* sound RAM written since the previous voice update */
int  bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r);
/* at a key-on: nonzero = the backend plays the note; zero = the runtime mixes that voice into
   bp_audio_push until its next key-on, so a backend offering this keeps its audio output up */
```

The native memory path uses a static aligned arena and `shim.MemA` for aligned accesses;
byte-packed records stay on `RawMem`. Native builds pass `-fno-strict-aliasing` and `-fwrapv`.
Big-endian shims select byte-composed access with `recompsx_bigendian`. `Memory.machine` binds
the live CPU at boot so memory-mapped clocks see current guest cycles. `CpuState` remains a
shared machine through `@:unsafePtrType`; `CtxPass` checks writes through aliases and calls.

## 3. Haxe side — `Backend` interface + externs

`src/runtime/Backend.hx` — the only platform surface the runtime sees:
`init/shutdown/present/audioPush/audioBuffered/inputPoll/padConnected/padType/padButtons/padAxis/
keyText/keyNext/mouse/mousePointer/httpOpen/httpRead/httpClose/quitRequested/exitToMenu/storageRead/
storageWrite/fileOpen/fileSize/fileRead/fileClose/
timeUs/log/fatal`.

`src/shims/cxx/BackendNative.hx` — flat externs in the verified reflaxe.CPP form:

```haxe
@:include("backend_c_api.h") @:topLevel
extern function bp_present(vram: cxx.Ptr<cxx.num.UInt16>, sx: Int, sy: Int, sw: Int, sh: Int, flags: Int): Void;
// ... one extern per bp_* function; CxxBackend implements Backend via inline wrappers.
```

`String`→`cxx.ConstCharPtr` and RawMem-interior→`cxx.Ptr` conversion mechanics are `[M0-VERIFY]`
items with a confirmed fallback: `untyped __cpp__`. `JvmBackend implements Backend` in pure Haxe
lands at M8 and involves no C at all.

## 4. RawMem / I64 shims (the portability seam)

**Accessors are `static` methods on classes with `static` fields — never instance methods, never
an abstract.** Verified 2026-08-08 (PROGRESS.md [M0-VERIFY] #12): Haxe's inliner introduces a
receiver temporary for instance-method inlining, and reflaxe.CPP prints its name (`_this`, or
`this1` for abstracts) without uniquifying it, so **two inlined instance-method calls in the same
scope fail to compile**. Generated code performs several memory accesses per function, so this
would be fatal. Static methods have no receiver and inline flawlessly: `Mem.set32(0x1000, v)`
emits four direct `Mem::ram[4096] = …;` stores with no call.

```haxe
// src/shims/cxx/RawMem.hx — one such class per buffer, or one class with several static
// CArray fields (RAM 2MB, VRAM 1MB, SPU RAM 512KB, scratchpad 1KB).
class RawMem {
  public static var ram: cxx.CArray<cxx.num.UInt8>;      // Stdlib.malloc + ccast, zero-filled
  public static function alloc(size: Int): Void;

  public static inline function get8(a: Int): Int          return ram[a];
  public static inline function set8(a: Int, v: Int): Void  ram[a] = v & 0xFF;
  // Endian-NEUTRAL byte-composed 16/32 accessors: identical bytes on LE hosts and on BE hosts
  // (GameCube/Wii) with zero backend involvement. Per-target unaligned-load fast path added
  // later behind a define, once measured.
  public static inline function get16(a: Int): Int         return get8(a) | (get8(a + 1) << 8);
  public static inline function get32(a: Int): Int;
  public static inline function set16(a: Int, v: Int): Void;
  public static inline function set32(a: Int, v: Int): Void;
  public static inline function u16Ptr(off: Int): cxx.Ptr<cxx.num.UInt16>;  // bp_present/bp_audio
}
// src/shims/jvm/RawMem.hx — same static API over ByteBuffer.order(LITTLE_ENDIAN).
// src/shims/*/I64.hx — over cxx.num.Int64 (native int64_t) / haxe.Int64 on JVM.
//   Used ONLY in GTE MAC accumulators, mult/div hi:lo, and the cycle accumulator.
```

On big-endian targets, `u16Ptr` returns a pointer into a swizzled staging copy maintained by the
shim — the documented byteswap seam. Backends never see it.

`shim.Bulk` moves whole runs (ADR-0032): `copy` (memmove, offsets in bytes), `equal`, `fill16` and
`prefetch`, with the same static API on every target. The C++ half is a header-only class over
`native/recompsx_bulk.h`, which picks the machine's best routine — sh4zam on the Dreamcast
(ADR-0031), the C library or a compiler builtin elsewhere. JavaScript uses `copyWithin` within a
buffer and typed-array loops between two, never a view per call. The runtime calls it only where
a run is provably what the per-element code would do, and keeps that code for the rest.

## 5. Portable-subset rules ("core discipline")

Applies to `src/runtime`, `src/shims`, `shared/`, and all generated code. Enforced by
`scripts/check.sh` where grep can, by review otherwise.

1. No `Float`/`Single`, ever.
2. No `Dynamic`/`Any`/reflection/anonymous structures.
3. No closures in hot paths (they lower to `std::function`).
4. 64-bit math only via `I64`.
5. Memory via `RawMem`; Haxe `Array` only for init-time fixed-capacity storage; no
   `haxe.io.Bytes` or `StringBuf` in the runtime.
6. No `throw`/`try`; unrecoverable conditions go to `bp_fatal`.
7. All allocation happens during init; zero allocation after boot (debug builds assert).
8. Strings in cold paths only.
9. Deterministic iteration only; all state explicitly zero-initialized.

**setjmp/longjmp HLE without exceptions** (also serves HLE threads and `Exit`; the single design,
matching runtime spec §3.7): `JmpBuf` = a preallocated int struct `{ra, sp, fp, gp, s0..s7,
valid}` in BIOS layout. HLE `setjmp` captures from the emulated registers and returns 0. HLE
`longjmp(buf, v)` restores registers, sets `ctx.unwindToken`, and sets `v0 = v != 0 ? v : 1`.
Codegen emits `if (ctx.unwindToken != 0) return;` after each call that analysis marks
*can-unwind* (reaches a kernel call or an indirect call); frames peel back to the `Runtime.call`
trampoline holding the matching setjmp anchor, which clears the token and resumes at the restored
`ra`. Functions proven unwind-free carry zero cost.

## 6. JVM forward-compat notes (recorded now, built at M8)

The JVM's 64 KB bytecode-per-method limit means large recompiled functions may need splitting.
The emitter must be able to support a `-D split-threshold=N` mode later (splitting a function's
basic-block switch into part-trampolines); the block structure must not preclude it. `RawMem`
over a little-endian `ByteBuffer`; `I64` over `haxe.Int64`. No other blockers identified.
