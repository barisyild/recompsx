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
    BP_CAP_PREFERRED_SCALE  = 3
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

enum { BP_LOG_DEBUG = 0, BP_LOG_INFO = 1, BP_LOG_WARN = 2, BP_LOG_ERROR = 3 };
void bp_log(int level, const char* msg);

/* Logs, tears down the platform, and exits. Never returns. */
void bp_fatal(const char* msg);

#ifdef __cplusplus
}
#endif

#endif /* RECOMPSX_BACKEND_C_API_H */
