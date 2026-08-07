# Spec — Backend & shim layer

Normative specification for the platform boundary. Source: master plan §8, extended with the
console target matrix.

The runtime is platform-agnostic. Everything platform-specific lives behind two seams:

1. **`backend_c_api.h`** — a flat C ABI implemented once per platform, outside Haxe.
2. **`src/shims/<target>/`** — `RawBytes` (raw memory + byte order), `I64`, and the externs that
   bind the C ABI. This is where target-specific Haxe lives; the runtime never has `#if` for a
   platform.

## 0. Target matrix

PC is what we build now; every other target must be reachable by implementing one header and one
shim directory. No runtime code changes.

| Target | Toolchain / SDK | CPU | Byte order | RAM | Notes |
|---|---|---|---|---|---|
| **macOS / Linux / Windows** | SDL2 + clang/gcc/MSVC | x86-64 / arm64 | LE | ample | First and reference implementation |
| **PS2** | ps2dev (PS2SDK, ee-gcc) | R5900 (MIPS) | LE | 32 MB | GS for present, SPU2 via audsrv, libpad, libmc. C++17 needs a current ps2dev toolchain — verify GCC version early |
| **PSP** | pspdev (PSPSDK) | Allegrex (MIPS) | LE | 32/64 MB | sceGu present, sceAudio, sceCtrl |
| **Dreamcast** | KallistiOS | SH-4 | LE | 16 MB | Tightest memory budget; binary-search FnTable mandatory |
| **GameCube / Wii** | devkitPPC + libogc | PowerPC | **BE** | 24 / 88 MB | The only current target needing the byteswap path in `RawBytes` |
| **Switch** | devkitA64 + libnx | ARM64 | LE | ample | |
| **JVM family** | Haxe JVM target | — | — | ample | No C ABI at all: `JvmBackend` implements the same Haxe interface directly |

Consequences captured in the design:

- **Byte order is a shim concern, never a backend concern.** Backends always receive host-order
  data and stay dumb blitters. Only `src/shims/*/RawBytes` knows about endianness.
- **Memory budget matters.** Runtime state is fixed: 2 MB emulated RAM + 1 MB VRAM + 512 KB SPU
  RAM + 1 KB scratchpad ≈ 3.5 MB. The variable is generated code size (a PS1 game with ~500 K
  instructions is expected to compile to roughly 8–15 MB of machine code) plus the dispatch
  table. The flat FnTable (512 K entries) costs ~4 MB with 64-bit pointers and is fine on PC; the
  **sorted-array + binary-search variant is the console default** (`-D fntable=binary`, same API,
  ~8 bytes per discovered function ≈ 100 KB). The M1.5 scale spike records real binary size
  against these budgets.
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
enum { BP_CAP_MAX_PADS = 0, BP_CAP_HAS_AUDIO = 1, BP_CAP_HAS_STORAGE = 2, BP_CAP_PREFERRED_SCALE = 3 };
int  bp_caps(int cap_id);
/* video: vram = borrowed 1024x512 uint16 (pitch 1024 halfwords); src rect in VRAM coords;
   24bpp: packed RGB888 rows starting at byte offset src_x*2 */
enum { BP_PRESENT_24BPP = 1 << 0, BP_PRESENT_INTERLACE = 1 << 1, BP_PRESENT_PAL = 1 << 2 };
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
/* storage: name in [A-Za-z0-9._-]{1,64}; memcards & config */
int  bp_storage_read(const char* name, uint8_t* buf, int len);        /* bytes read, -1 none */
int  bp_storage_write(const char* name, const uint8_t* buf, int len); /* 0 ok, -1 fail */
/* disc/file streaming: the runtime CD subsystem reads the user's image through this.
   Backends stay dumb byte-servers; ALL CUE/sector/ISO logic lives in portable Haxe
   (shared/psxdisc). Slots 0..7; the host resolves paths from argv/launch config. */
int  bp_file_open(int slot, const char* path);   /* 0 ok, -1 fail */
int  bp_file_size(int slot);                     /* bytes; BIN files fit int32 */
int  bp_file_read(int slot, int offset, uint8_t* buf, int len); /* bytes read */
void bp_file_close(int slot);
/* time & diagnostics */
uint64_t bp_time_us(void);            /* monotonic; PACING ONLY */
enum { BP_LOG_DEBUG = 0, BP_LOG_INFO = 1, BP_LOG_WARN = 2, BP_LOG_ERROR = 3 };
void bp_log(int level, const char* msg);
void bp_fatal(const char* msg);       /* logs, tears down, exits; never returns */
#ifdef __cplusplus
}
#endif
#endif
```

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

## 3. Haxe side — `Backend` interface + externs

`src/runtime/Backend.hx` — the only platform surface the runtime sees:
`init/shutdown/present/audioPush/audioBuffered/inputPoll/padConnected/padType/padButtons/padAxis/
quitRequested/storageRead/storageWrite/fileOpen/fileSize/fileRead/fileClose/timeUs/log/fatal`.

`src/shims/cxx/BackendNative.hx` — flat externs in the verified reflaxe.CPP form:

```haxe
@:include("backend_c_api.h") @:topLevel
extern function bp_present(vram: cxx.Ptr<cxx.num.UInt16>, sx: Int, sy: Int, sw: Int, sh: Int, flags: Int): Void;
// ... one extern per bp_* function; CxxBackend implements Backend via inline wrappers.
```

`String`→`cxx.ConstCharPtr` and RawBytes-interior→`cxx.Ptr` conversion mechanics are `[M0-VERIFY]`
items with a confirmed fallback: `untyped __cpp__`. `JvmBackend implements Backend` in pure Haxe
lands at M8 and involves no C at all.

## 4. RawBytes / I64 shims (the portability seam)

```haxe
// src/shims/cxx/RawBytes.hx — emulated RAM 2MB, VRAM 1MB, SPU RAM 512KB, scratchpad.
abstract RawBytes(cxx.CArray<cxx.num.UInt8>) {
  public static function alloc(size: Int): RawBytes;   // Stdlib.malloc + ccast + memset 0
  public inline function get8(a: Int): Int;            // this[a]
  public inline function set8(a: Int, v: Int): Void;
  // Endian-NEUTRAL byte-composed 16/32 accessors: correct on LE hosts and on BE hosts
  // (GameCube/Wii) with zero backend involvement. Per-target unaligned-load fast path
  // added later behind a define, once measured.
  public inline function get16(a: Int): Int;  public inline function get32(a: Int): Int;
  public inline function set16(a: Int, v: Int): Void;  public inline function set32(a: Int, v: Int): Void;
  public function u16Ptr(offsetBytes: Int): cxx.Ptr<cxx.num.UInt16>;  // for bp_present/bp_audio
}
// src/shims/jvm/RawBytes.hx — same API over ByteBuffer.order(LITTLE_ENDIAN).
// src/shims/*/I64.hx — abstract over cxx.num.Int64 (native int64_t) / haxe.Int64 on JVM.
//   Used ONLY in GTE MAC accumulators, mult/div hi:lo, and the cycle accumulator.
```

On big-endian targets, `u16Ptr` returns a pointer into a swizzled staging copy maintained by the
shim — the documented byteswap seam. Backends never see it.

## 5. Portable-subset rules ("core discipline")

Applies to `src/runtime`, `src/shims`, `shared/`, and all generated code. Enforced by
`scripts/check.sh` where grep can, by review otherwise.

1. No `Float`/`Single`, ever.
2. No `Dynamic`/`Any`/reflection/anonymous structures.
3. No closures in hot paths (they lower to `std::function`).
4. 64-bit math only via `I64`.
5. Memory via `RawBytes`; Haxe `Array` only for init-time fixed-capacity storage; no
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
basic-block switch into part-trampolines); the block structure must not preclude it. `RawBytes`
over a little-endian `ByteBuffer`; `I64` over `haxe.Int64`. No other blockers identified.
