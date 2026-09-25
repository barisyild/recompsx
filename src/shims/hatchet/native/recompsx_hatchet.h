/* recompsx_hatchet.h — the shim's bodies for the Hatchet target (Haxe -> C++98).
 *
 * The Haxe side of `src/shims/hatchet/shim` declares `extern class`es; Hatchet emits calls to
 * them as `shim::Class::method(...)` and never a definition, so the definitions are here, as
 * inline static members: every call compiles to its body at the call site, which is what the
 * reflaxe.CPP shim's `@:nativeFunctionCode` templates achieve on that target. Each body is the
 * same expression as its reflaxe.CPP twin in `src/shims/cxx/shim`, so the two C++ targets
 * compute the same values by construction; `tests/conformance` holds them to it.
 *
 * Needs `-fwrapv` (signed overflow wraps, as on MIPS and in the JS shim's `| 0`) and
 * `-fno-strict-aliasing` (emulated memory is bytes read as halfwords and words), exactly like
 * the reflaxe.CPP build. `long long` is a C++98 extension every compiler Hatchet targets has.
 */
#ifndef RECOMPSX_HATCHET_H
#define RECOMPSX_HATCHET_H

#include <stdlib.h>
#include <string>
#include "recompsx_arena.h"
#include "backend_c_api.h"

namespace shim {

typedef unsigned char* RawBufPtr;

struct IntMath {
    static inline int div(int a, int b) { return a / b; }
    static inline int mod(int a, int b) { return a % b; }
    static inline int mul(int a, int b) { return a * b; }
    static inline int divPow2Trunc(int a, int shift) { return a < 0 ? -((-a) >> shift) : (a >> shift); }
    static inline int clz32(int a) {
        return ((unsigned int)a) == 0u ? 32 : __builtin_clz((unsigned int)a);
    }
};

/* Byte-composed, endian-neutral: the same expressions as the reflaxe.CPP RawMem. */
struct RawMem {
    static inline unsigned char* alloc(int size) {
        unsigned char* m = (unsigned char*)malloc((size_t)size);
        for (int i = 0; i < size; i++) m[i] = 0;
        return m;
    }
    static inline int get8(const unsigned char* m, int a) { return m[a]; }
    static inline void set8(unsigned char* m, int a, int v) { m[a] = (unsigned char)(v & 0xFF); }
    static inline int get16(const unsigned char* m, int a) { return get8(m, a) | (get8(m, a + 1) << 8); }
    static inline int get16Index(const unsigned char* m, int index) { return get16(m, index << 1); }
    static inline int get32(const unsigned char* m, int a) {
        return get8(m, a) | (get8(m, a + 1) << 8) | (get8(m, a + 2) << 16) | (get8(m, a + 3) << 24);
    }
    static inline void set16(unsigned char* m, int a, int v) {
        set8(m, a, v);
        set8(m, a + 1, (int)((unsigned int)v >> 8));
    }
    static inline void set16Index(unsigned char* m, int index, int v) { set16(m, index << 1, v); }
    static inline void fill16Index(unsigned char* m, int index, int count, int v) {
        for (int i = 0; i < count; i++) set16(m, (index + i) << 1, v);
    }
    static inline void set32(unsigned char* m, int a, int v) {
        set8(m, a, v);
        set8(m, a + 1, (int)((unsigned int)v >> 8));
        set8(m, a + 2, (int)((unsigned int)v >> 16));
        set8(m, a + 3, (int)((unsigned int)v >> 24));
    }
};

/* Aligned access on a little-endian host: callers guarantee alignment (see the C++ twin). */
struct MemA {
    static inline int get16(const unsigned char* m, int a) { return (int)(*((const unsigned short*)(m + a))); }
    static inline int get32(const unsigned char* m, int a) { return *((const int*)(m + a)); }
    static inline void set16(unsigned char* m, int a, int v) { *((unsigned short*)(m + a)) = (unsigned short)v; }
    static inline void set32(unsigned char* m, int a, int v) { *((int*)(m + a)) = v; }
};

struct Arena {
    static inline unsigned char* ram() { return recompsx_ram; }
    static inline unsigned char* scratch() { return recompsx_scratch; }
};

/* The 64-bit spellings shared by I64 and Acc: the same expressions as the reflaxe.CPP N64. */
struct N64 {
    static inline long long ext(int v) { return (long long)v; }
    static inline long long mul(int a, int b) { return ((long long)a) * ((long long)b); }
    static inline long long shl12(int v) { return ((long long)v) << 12; }
    static inline long long pair(int ahi, int alo) {
        return (((long long)ahi) << 32) | ((long long)((unsigned int)alo));
    }
    static inline int low(long long v) { return (int)v; }
    static inline int shr12(long long v) { return (int)(v >> 12); }
    static inline int shr16(long long v) { return (int)(v >> 16); }
    static inline int check44(long long v) {
        return v > 0x7FFFFFFFFFFLL ? 1 : (v < -0x80000000000LL ? -1 : 0);
    }
    static inline int check32(long long v) {
        return v > 0x7FFFFFFFLL ? 1 : (v < -0x80000000LL ? -1 : 0);
    }
    static inline long long wrap44(long long v) {
        return ((long long)(((unsigned long long)(v & 0xFFFFFFFFFFFLL)) << 20)) >> 20;
    }
    static inline int mulRound(int a, int b) {
        return (int)((((long long)a) * ((long long)b) + 0x8000LL) >> 16);
    }
};

struct I64 {
    static long long& acc() { static long long v = 0; return v; }
    static inline void set(int v) { acc() = N64::ext(v); }
    static inline void setZero() { acc() = 0; }
    static inline void setShl12(int v) { acc() = N64::shl12(v); }
    static inline void addSmall(int p) { acc() += N64::ext(p); }
    static inline void addProduct16(int a, int b) { acc() += N64::mul(a, b); }
    static inline void addProductWide(int a, int b) { acc() += N64::mul(a, b); }
    static inline void addPair(int ahi, int alo) { acc() += N64::pair(ahi, alo); }
    static inline int check44() { return N64::check44(acc()); }
    static inline int check32() { return N64::check32(acc()); }
    static inline void wrap44() { acc() = N64::wrap44(acc()); }
    static inline int low32() { return N64::low(acc()); }
    static inline int shr12() { return N64::shr12(acc()); }
    static inline int shr16() { return N64::shr16(acc()); }
    static inline int mulShr16Round(int a, int b) { return N64::mulRound(a, b); }
};

/* A value: the accumulator lives in a local, where the compiler can keep it in registers. */
struct Acc {
    long long v;
    static inline Acc make(long long x) { Acc a; a.v = x; return a; }
    static inline Acc zero() { return make(0); }
    static inline Acc of(int x) { return make(N64::ext(x)); }
    static inline Acc shl12(int x) { return make(N64::shl12(x)); }
    static inline Acc add(const Acc& m, int p) { return make(m.v + N64::ext(p)); }
    static inline Acc mac(const Acc& m, int a, int b) { return make(m.v + N64::mul(a, b)); }
    static inline int check44(const Acc& m) { return N64::check44(m.v); }
    static inline int check32(const Acc& m) { return N64::check32(m.v); }
    static inline Acc wrap44(const Acc& m) { return make(N64::wrap44(m.v)); }
    static inline int low32(const Acc& m) { return N64::low(m.v); }
    static inline int shr12(const Acc& m) { return N64::shr12(m.v); }
    static inline int shr16(const Acc& m) { return N64::shr16(m.v); }
};

struct Backend {
    static const int LOG_DEBUG = 0;
    static const int LOG_INFO = 1;
    static const int LOG_WARN = 2;
    static const int LOG_ERROR = 3;
    static const int PRESENT_24BPP = 1;
    static const int PRESENT_INTERLACE = 2;
    static const int PRESENT_PAL = 4;
    static const int PROFILE_SPU = 0;

    static inline int init(const std::string& title) { return bp_init(title.c_str()); }
    static inline void shutdown() { bp_shutdown(); }
    static inline int caps(int capId) { return bp_caps(capId); }
    static inline int argCount() { return bp_arg_count(); }
    static inline std::string arg(int i) {
        const char* s = bp_arg(i);
        return s ? std::string(s) : std::string();
    }
    static inline void present(unsigned char* vram, int sx, int sy, int sw, int sh, int flags) {
        bp_present((const uint16_t*)vram, sx, sy, sw, sh, flags);
    }
    static inline void gpuVram(unsigned char* vram) { bp_gpu_vram((const uint16_t*)vram); }
    static inline void gpuState(int texBaseX, int texBaseY, int texDepth, int clutX, int clutY,
                                int semiMode, int flags, int texWindow, int drawX, int drawY) {
        bp_gpu_state(texBaseX, texBaseY, texDepth, clutX, clutY, semiMode, flags, texWindow, drawX, drawY);
    }
    static inline void gpuTri(int x0, int y0, int c0, int u0, int v0, int x1, int y1, int c1,
                              int u1, int v1, int x2, int y2, int c2, int u2, int v2) {
        bp_gpu_tri(x0, y0, c0, u0, v0, x1, y1, c1, u1, v1, x2, y2, c2, u2, v2);
    }
    static inline void gpuRect(int x, int y, int w, int h, int bgr, int semi, int semiMode) {
        bp_gpu_rect(x, y, w, h, bgr, semi, semiMode);
    }
    static inline void gpuDirty(int x, int y, int w, int h) { bp_gpu_dirty(x, y, w, h); }
    static inline void gpuClip(int x0, int y0, int x1, int y1) { bp_gpu_clip(x0, y0, x1, y1); }
    static inline void gpuMask(int setBit, int checkBit) { bp_gpu_mask(setBit, checkBit); }
    static inline void audioPush(unsigned char* frames, int frameCount) {
        bp_audio_push((const int16_t*)frames, frameCount);
    }
    static inline int audioBuffered() { return bp_audio_buffered(); }
    static inline void profileMark(int section, int begin) { bp_profile_mark(section, begin); }
    static inline void spuRam(unsigned char* ram) { bp_spu_ram(ram); }
    static inline void spuDirty(int addr, int len) { bp_spu_dirty(addr, len); }
    static inline int spuVoice(int v, int key, int on, int start, int pitch, int volL, int volR) {
        return bp_spu_voice(v, key, on, start, pitch, volL, volR);
    }
    static inline void inputPoll() { bp_input_poll(); }
    static inline bool padConnected(int pad) { return bp_pad_connected(pad) != 0; }
    static inline int padType(int pad) { return bp_pad_type(pad); }
    static inline int padButtons(int pad) { return (int)bp_pad_buttons(pad); }
    static inline int padAxis(int pad, int axis) { return bp_pad_axis(pad, axis); }
    static inline void requestQuit() { quitting() = true; }
    static inline bool quitRequested() { return bp_quit_requested() != 0; }
    static inline int storageRead(const std::string& name, unsigned char* buf, int len) {
        return bp_storage_read(name.c_str(), buf, len);
    }
    static inline int storageWrite(const std::string& name, unsigned char* buf, int len) {
        return bp_storage_write(name.c_str(), buf, len);
    }
    static inline int fileOpen(int slot, const std::string& path) { return bp_file_open(slot, path.c_str()); }
    static inline int fileSize(int slot) { return bp_file_size(slot); }
    static inline int fileRead(int slot, int offset, unsigned char* buf, int len) {
        return bp_file_read(slot, offset, buf, len);
    }
    static inline void fileClose(int slot) { bp_file_close(slot); }
    static inline void paceFrame(int targetUs) { bp_pace_frame(targetUs); }
    static inline void log(int level, const std::string& msg) { bp_log(level, msg.c_str()); }
    static inline void fatal(const std::string& msg) { bp_fatal(msg.c_str()); }

private:
    static bool& quitting() { static bool q = false; return q; }
};

} /* namespace shim */

#endif
