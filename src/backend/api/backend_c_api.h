/* backend_c_api.h — recompsx platform backend ABI, version 1.
 *
 * This header IS the platform boundary. Porting recompsx to a new machine means implementing
 * this file's functions against that machine's SDK and nothing else: the runtime, the generated
 * game code and all emulation logic are platform-agnostic Haxe above this line.
 *
 * Contract:
 *   - Pure C17. No structs cross this boundary; everything is pointers and plain ints, so no
 *     layout agreement is needed between Haxe and C.
 *   - Every call comes from the single emulator thread. Nothing here is thread-safe.
 *   - Pointers passed in are borrowed for the duration of the call only.
 *   - THE BACKEND NEVER AFFECTS EMULATED STATE. bp_time_us exists to pace presentation; if its
 *     value ever reaches the emulated machine, determinism is broken and the project's central
 *     guarantee with it.
 *
 * See docs/specs/backend.md for the target matrix and the rationale behind each group.
 */
#ifndef RECOMPSX_BACKEND_C_API_H
#define RECOMPSX_BACKEND_C_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- lifecycle ------------------------------------------------------------------------- */

/* Returns 0 on success, nonzero if the platform could not be brought up. */
int  bp_init(const char* title);
void bp_shutdown(void);

enum {
    BP_CAP_MAX_PADS         = 0,
    BP_CAP_HAS_AUDIO        = 1,
    BP_CAP_HAS_STORAGE      = 2,
    BP_CAP_PREFERRED_SCALE  = 3,
    BP_CAP_GPU_DRAW         = 4,   /* nonzero: this backend can rasterise primitives itself */
    BP_CAP_SPU_VOICES       = 5    /* nonzero: this backend can play the SPU's voices itself */
};
int  bp_caps(int cap_id);

/* ---- launch parameters ------------------------------------------------------------------
 * The generated _main_.cpp discards argc/argv, so builds exclude it and use our own main,
 * which records the arguments here. Console platforms that have no argv return 0 and supply
 * their launch parameters through storage instead. */
void        bp_set_args(int argc, const char** argv);  /* called by our main before bp_init */
int         bp_arg_count(void);
const char* bp_arg(int index);   /* NULL if out of range */

/* ---- video -------------------------------------------------------------------------------
 * vram points at the emulated 1024x512 halfword VRAM (row pitch 1024 halfwords, BGR555 with
 * bit15 = mask). The source rectangle is in VRAM coordinates. In 24bpp mode the row data is
 * packed RGB888 starting at byte offset src_x*2 of each row — that is how the PS1 lays out
 * MDEC video, and the backend just walks it. */
enum {
    BP_PRESENT_24BPP     = 1 << 0,
    BP_PRESENT_INTERLACE = 1 << 1,
    BP_PRESENT_PAL       = 1 << 2
};
void bp_present(const uint16_t* vram, int src_x, int src_y, int src_w, int src_h, int flags);

/* ---- hardware drawing (optional; only when bp_caps(BP_CAP_GPU_DRAW) is nonzero) -------------
 * A backend that owns a rasteriser can be handed the PlayStation's primitives instead of the
 * finished picture. The runtime keeps parsing GP0, keeps its GPUSTAT, its interrupts, its cycle
 * costs and its VRAM uploads exactly as before — the ONLY difference is that rasterised pixels
 * are drawn by the backend rather than written into emulated VRAM. It is a fork in presentation,
 * never in state, and the runtime only takes it when a host explicitly asks for it.
 *
 * Consequences a backend must accept: emulated VRAM no longer contains what was drawn, so
 * anything reading rendered pixels back (feedback effects, a VRAM dump) sees what was there
 * before. Frames that draw no primitives fall back to bp_present, so movies still work.
 *
 * Coordinates arrive with the drawing offset already applied. Colours are 24-bit BGR, exactly as
 * the GP0 command word carries them. Texture and blend state is latched by bp_gpu_state and
 * applies to every primitive until the next call. */

/* Hands over the emulated 1024x512 VRAM, borrowed until shutdown, so the backend can read
 * textures and palettes out of it. Called once, before the first primitive. */
void bp_gpu_vram(const uint16_t* vram);

enum {
    BP_GPU_TEXTURED = 1 << 0,   /* sample a texture rather than using vertex colour alone */
    BP_GPU_SEMI     = 1 << 1,   /* blend with the framebuffer, per semi_mode */
    BP_GPU_RAW      = 1 << 2    /* use the texel as-is; do not modulate it by the vertex colour */
};
/* tex_window is GP0(E2h) raw: mask x/y in bits 0-9, offset x/y in bits 10-19. It makes a small
 * tile repeat across a page, so it changes which texel a given U,V names — a backend caching a
 * decoded page must fold it in (and key on it) or repeating textures come out wrong. */
/* draw_x/draw_y are the drawing area's top-left corner in VRAM. Primitive coordinates are
 * absolute VRAM positions, and a double-buffered game draws into the buffer it is NOT currently
 * displaying — so this, not the display origin, is what screen coordinates are relative to. */
void bp_gpu_state(int tex_base_x, int tex_base_y, int tex_depth,
                  int clut_x, int clut_y, int semi_mode, int flags, int tex_window,
                  int draw_x, int draw_y);

/* One triangle. Quads arrive as two. */
void bp_gpu_tri(int x0, int y0, int c0, int u0, int v0,
                int x1, int y1, int c1, int u1, int v1,
                int x2, int y2, int c2, int u2, int v2);

/* An axis-aligned rectangle in one flat colour: sprites and GP0(02h) fills both land here. */
void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode);

/* Emulated VRAM changed under this rectangle — an upload or a VRAM-to-VRAM copy. Anything the
 * backend cached from that region (decoded textures, palettes) is now stale. */
void bp_gpu_dirty(int x, int y, int w, int h);

/* The drawing area, both corners inclusive, as GP0(E3h)/(E4h) set it. Triangles are drawn only
 * inside it. A double-buffered game draws into the buffer it is not displaying, and its
 * geometry reaches past that buffer's edge into the one on screen: the software rasteriser
 * clips there, and a backend that does not shows the next frame's spill on this one.
 * Rectangles follow the software path and clip to VRAM alone. */
void bp_gpu_clip(int x0, int y0, int x1, int y1);

/* GP0(E6h). set_bit forces bit 15 on every pixel a primitive writes; check_bit makes a primitive
 * skip pixels whose bit 15 is already set. Uploads and VRAM-to-VRAM copies apply both in emulated
 * VRAM before bp_gpu_dirty reports them, so a backend applies them to primitives only. Crash
 * Bash's warning screen is the visible case: the text is drawn with set_bit, then a circle over
 * it with check_bit, and without the check the circle paints across the letters. */
void bp_gpu_mask(int set_bit, int check_bit);

/* ---- hardware sound (optional; only when bp_caps(BP_CAP_SPU_VOICES) is nonzero) -------------
 * A backend with a sampler of its own (the Dreamcast's AICA) can play the SPU's voices instead of
 * being handed the finished mix. The runtime keeps every piece of SPU state a game can read —
 * envelopes, block positions, ENDX, the loop flags — exactly as it does with no listener at
 * all, and describes the voices instead of mixing them. Like hardware drawing it is a fork in
 * presentation, never in state, taken only when a host asks for it (--audio-hw); what is heard
 * is the backend's approximation, not the SPU's arithmetic.
 *
 * Sample data is the SPU's own ADPCM in its 512 KB of sound RAM, which the backend decodes as
 * it likes. Blocks carry the loop flags: bit 2 of a block's second byte marks a loop start, bit
 * 0 the end, bit 1 whether the end loops back to the last loop start (or to the start address
 * when there was none) or stops. */

/* Hands over the SPU's sound RAM, borrowed until shutdown. Called once, before any voice. */
void bp_spu_ram(const uint8_t* ram);

/* Sound RAM changed from `addr` for `len` bytes: anything decoded from there is stale. Batched —
 * one call covers every write since the previous voice update. */
void bp_spu_dirty(int addr, int len);

/* A voice's audible state, sent whenever any of it changes (the runtime compares; at most once
 * per voice per batch of 128 samples). `key` counts the voice's key-ons: a different value with
 * `on` set means start from `start`, a byte address in sound RAM. `on` is zero once the voice's
 * envelope has finished. `pitch` is the SPU's pitch register (0x1000 = 44100 Hz, capped at
 * 0x4000). `vol_l`/`vol_r` are 0..0x7FFF and already include the envelope and the main volume. */
void bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r);

/* ---- audio -------------------------------------------------------------------------------
 * 44100 Hz stereo signed 16-bit, interleaved. frame_count is stereo frames, not samples.
 * bp_audio_buffered reports what the host still holds, for pacing only. */
void bp_audio_push(const int16_t* frames, int frame_count);
int  bp_audio_buffered(void);

/* ---- input -------------------------------------------------------------------------------
 * Four pads, because the multitap is not optional for the games this project targets.
 * Call bp_input_poll once per emulated vertical blank; the accessors then read a stable
 * snapshot, so a frame never sees input change underneath it. */
enum { BP_PAD_NONE = 0, BP_PAD_DIGITAL = 1, BP_PAD_ANALOG = 2 };

void     bp_input_poll(void);
int      bp_pad_connected(int pad);
int      bp_pad_type(int pad);
uint32_t bp_pad_buttons(int pad);          /* PS1 bit layout, active high, low 16 bits */
int      bp_pad_axis(int pad, int axis);   /* 0=LX 1=LY 2=RX 3=RY; 0..255, centre 128 */
int      bp_quit_requested(void);

/* ---- storage -----------------------------------------------------------------------------
 * Memory card images and configuration. `name` is restricted to [A-Za-z0-9._-]{1,64}; the
 * backend decides where that lives. Writes must be atomic from the caller's point of view:
 * a crash mid-write must not leave a half-written memory card. */
int bp_storage_read(const char* name, uint8_t* buf, int len);        /* bytes read, -1 if absent */
int bp_storage_write(const char* name, const uint8_t* buf, int len); /* 0 ok, -1 fail */

/* ---- disc / file streaming ---------------------------------------------------------------
 * The CD subsystem reads the user's disc image through these. Backends are dumb byte servers:
 * all CUE parsing, sector layout and ISO9660 logic lives in portable Haxe (shared/psxdisc), so
 * a new platform never reimplements any of it. Slots 0..7. */
int  bp_file_open(int slot, const char* path);                    /* 0 ok, -1 fail */
int  bp_file_size(int slot);                                      /* bytes; disc images fit int32 */
int  bp_file_read(int slot, int offset, uint8_t* buf, int len);   /* bytes actually read */
void bp_file_close(int slot);

/* ---- time and diagnostics ---------------------------------------------------------------- */

/* Monotonic microseconds. PACING ONLY — see the contract at the top of this file. */
uint64_t bp_time_us(void);
void     bp_sleep_us(uint64_t us);

/* Sleeps until `target_us` microseconds have passed since the previous call, then returns.
 * Frame pacing lives here rather than in the runtime on purpose: host time then has no path
 * into emulated state at all, and the Haxe side never handles a 64-bit clock. Pass 0 to reset
 * the reference point (after a pause, or when fast-forwarding). */
void bp_pace_frame(int target_us);

/* Optional instrumentation. The runtime brackets a stretch of its own work — `begin` non-zero
 * at its start, zero at its end — and a backend may time it on its own clock and show the
 * total, or do nothing at all. Nothing comes back, so host time still has no path into the
 * runtime. BP_PROFILE_SPU is the sound processor's decoding and mixing, which otherwise hides
 * inside the emulated frame. */
enum { BP_PROFILE_SPU = 0, BP_PROFILE_SECTIONS = 4 };
void bp_profile_mark(int section, int begin);

enum { BP_LOG_DEBUG = 0, BP_LOG_INFO = 1, BP_LOG_WARN = 2, BP_LOG_ERROR = 3 };
void bp_log(int level, const char* msg);

/* Logs, tears down the platform, and exits. Never returns. */
void bp_fatal(const char* msg);

#ifdef __cplusplus
}
#endif

#endif /* RECOMPSX_BACKEND_C_API_H */
