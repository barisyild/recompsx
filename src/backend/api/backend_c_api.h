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

/* Leaves the program for the host's own menu, as a console game's QUIT does: the Dreamcast's BIOS
 * menu (its hardware stopped where it stands, then the BIOS's menu call), the desktop (the program
 * exits), a page's start screen. The runtime has kept what it keeps — the memory card — before it calls this, and a
 * backend shuts itself down here as bp_shutdown does. A host that cannot leave at once (a page)
 * may return; nothing of the program runs after that. The kernel calls it for a mod
 * (ModHost.exitToMenu), and never in a headless run. */
void bp_exit_to_menu(void);

enum {
    BP_CAP_MAX_PADS         = 0,
    BP_CAP_HAS_AUDIO        = 1,
    BP_CAP_HAS_STORAGE      = 2,
    BP_CAP_PREFERRED_SCALE  = 3,
    BP_CAP_GPU_DRAW         = 4,   /* nonzero: this backend can rasterise primitives itself */
    BP_CAP_SPU_VOICES       = 5,   /* nonzero: this backend can play the SPU's voices itself */
    BP_CAP_GPU_UPLOADS      = 6    /* nonzero: report every upload through bp_gpu_dirty (below) */
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
    BP_PRESENT_PAL       = 1 << 2,
    /* The frame need not be held to the video rate: the emulated machine is moving memory card
     * sectors, a sector every second vblank as the BIOS does, and nothing else is going on that a
     * player would watch (ADR-0037). A backend that paces at present lets such a frame go at once,
     * so a save takes a fraction of a second rather than several. Emulated time is unchanged. */
    BP_PRESENT_FAST      = 1 << 3
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
 * before. Frames that draw no primitives fall back to bp_present, so movies still work. Drawing
 * no picture is made of never arrives here: a primitive whose drawing area lies in neither of
 * the last two rectangles bp_present showed (and is under three quarters of the picture either
 * way), and a GP0(02h) fill meeting neither, are rasterised by the runtime into emulated VRAM
 * and reported through bp_gpu_dirty — a texture the game makes for itself (ADR-0030).
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

/* An axis-aligned rectangle in one flat colour: sprites and GP0(02h) fills both land here. A
 * fill ignores the mask bits on the PlayStation, so it arrives under bp_gpu_mask(0, 0). */
void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode);

/* Emulated VRAM changed under this rectangle — an upload or a VRAM-to-VRAM copy. Anything the
 * backend cached from that region (decoded textures, palettes) is now stale.
 *
 * Only writes that changed a pixel are reported: games upload the same palettes and pieces again
 * and again, and a backend whose textures mirror emulated VRAM loses nothing by not hearing of
 * them. A backend whose drawn pixels become texels (the browser's: it samples what primitives
 * drew) does lose something — an upload that restores what emulated VRAM never lost still
 * replaces what the backend drew over it. Crash Bash clears nearly all of VRAM with one 511x511
 * rectangle before its menu and uploads its font again; unreported, the browser kept the
 * rectangle's black under the font and drew no text. Such a backend answers
 * bp_caps(BP_CAP_GPU_UPLOADS) nonzero and hears of every CPU-to-VRAM upload. Copies stay
 * reported only when they changed something: the runtime copies emulated VRAM, which lacks what
 * the backend drew, so an unchanged copy reported would put stale pixels over drawn ones. */
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
 * `on` set means start from `start`, a byte address in sound RAM, and such a call is made at the
 * key-on itself, with both volumes zero, after bp_spu_dirty has reported every write before it.
 * `on` is zero once the voice's envelope has finished. `pitch` is the SPU's pitch register
 * (0x1000 = 44100 Hz, capped at 0x4000). `vol_l`/`vol_r` are 0..0x7FFF and already include the
 * envelope and the main volume.
 *
 * The answer to a key-on matters: nonzero means the backend plays this note; zero means it
 * cannot (a sample longer than its channels hold, no room left), and the runtime then mixes that
 * voice itself into bp_audio_push for the rest of the note and sends nothing more about it until
 * its next key-on. A backend offering this capability therefore keeps its audio output working.
 * Answers to other calls are ignored. */
int  bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r);

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

/* ---- keyboard ------------------------------------------------------------------------------
 * The host's keyboard as text, which the runtime sends on to the machine's own keyboard as the
 * key presses that type it (kernel.KKeyboard, sio.Ps2Keyboard, ADR-0040). A target that has a
 * keyboard — a PC, a browser, a Dreamcast with its keyboard plugged in — passes on what is
 * typed; one that has none types nothing, and everything that reads it still works.
 *
 * bp_key_text(1) starts text entry, bp_key_text(0) ends it; it starts off. The runtime turns it on
 * while something polls the machine's keyboard, and off when the polls stop. While it is on the
 * keyboard types rather than plays: what it types goes to a queue, and a backend that also
 * plays a pad with the keyboard lets only the arrow keys still press the d-pad, so that a
 * letter typed is never a button pressed as well. While it is off nothing is queued, and
 * anything still queued is dropped when it changes.
 *
 * bp_key_next returns the next thing typed, or -1 when nothing is waiting: a character as a
 * Unicode code point — whatever the host's own layout and input method made of the keys — or
 * one of the three editing keys below. The runtime drains it right after bp_input_poll, so what
 * was typed reaches the machine once per vblank, as buttons do. Which characters mean anything
 * is for the runtime to decide; a backend passes on everything the host can type. */
enum { BP_KEY_BACKSPACE = 8, BP_KEY_ENTER = 10, BP_KEY_ESCAPE = 27 };

void bp_key_text(int on);
int  bp_key_next(void);

/* ---- mouse ---------------------------------------------------------------------------------
 * The host's pointer over the picture, which the machine's own mouse follows (kernel.KMouse,
 * sio.SonyMouse; ADR-0038, ADR-0040). bp_input_poll latches it with the pads; then bp_mouse
 * answers:
 *
 *   BP_MOUSE_OVER     1 while the target has a mouse and the pointer is over the picture
 *   BP_MOUSE_X, _Y    where, as a fraction of the picture: 0..65535 from its left edge across its
 *                     width, from its top edge down its height. A backend needs to know only
 *                     where it put the picture, never the emulated display's size; the kernel
 *                     turns the fraction into that display's pixels.
 *   BP_MOUSE_BUTTONS  the buttons held: bit 0 left, bit 1 right, bit 2 middle, bit 3 back and
 *                     bit 4 forward (the side buttons; a browser's history buttons, which the
 *                     backend keeps from the page). A press that began and ended between two
 *                     polls counts as held for the second, so a quick click is never lost.
 *
 * A target without a mouse answers 0 to everything.
 *
 * The machine reads the mouse as its own, a Sony Mouse (ADR-0040). bp_mouse_pointer(state) says
 * whether the machine has a pointer over the picture: it has one while something polls that mouse
 * (a mod driving its game with it), so a game nothing reads the mouse for shows none; the mouse is
 * sampled either way.
 *
 *   BP_POINTER_OFF     (the start) no pointer of the machine's: a host with a cursor of its own
 *                      shows that as over any other window, a console draws nothing.
 *   BP_POINTER_SHOWN   the machine's pointer over the picture — the art in pointer_art.h, which a
 *                      console draws and a host with a cursor takes for its cursor.
 *   BP_POINTER_HIDDEN  on, but hidden while the player is on a pad (a pad button pressed; the
 *                      mouse moving or clicking shows it again): no pointer over the picture, not
 *                      even the host's. */
enum { BP_MOUSE_OVER = 0, BP_MOUSE_X = 1, BP_MOUSE_Y = 2, BP_MOUSE_BUTTONS = 3 };
enum { BP_POINTER_OFF = 0, BP_POINTER_SHOWN = 1, BP_POINTER_HIDDEN = 2 };

int  bp_mouse(int field);
void bp_mouse_pointer(int state);

/* ---- network ---------------------------------------------------------------------------------
 * The host's side of the i-mode adaptor (ADR-0040): the machine goes online the PS1's own way, an
 * i-mode phone on a controller port, and the phone's i-mode centre — the HLE kernel's
 * (kernel.KIMode) — takes the HTTP requests it carries out to the host's network. So this is
 * HTTP, one request at a time, and never blocks.
 *
 * bp_http_open sends one request: `request` is the whole of it, `len` bytes — request line,
 * headers, blank line, body — in origin form ("GET /path HTTP/1.0", a Host: header), for `host`
 * (a name or dotted address) at `port`. It returns a handle, or -1 when the target has no network
 * or cannot start one. bp_http_read then hands over the response as it arrives, raw — status
 * line, headers, body, as a server sends them over HTTP/1.0 — into `buf`: the bytes written
 * (> 0), 0 when nothing more has come yet, -1 when the response is complete, -2 when it failed.
 * bp_http_close ends it, answered or not; every handle is closed once. The runtime reads once a
 * vblank. A target without a network returns -1 from bp_http_open and is still correct. */
int  bp_http_open(const char* host, int port, const uint8_t* request, int len);
int  bp_http_read(int handle, uint8_t* buf, int cap);
void bp_http_close(int handle);

/* ---- storage -----------------------------------------------------------------------------
 * Configuration and other small blobs. `name` is restricted to [A-Za-z0-9._-]{1,64}; the
 * backend decides where that lives. Writes must be atomic from the caller's point of view:
 * a crash mid-write must not leave a half-written file. */
int bp_storage_read(const char* name, uint8_t* buf, int len);        /* bytes read, -1 if absent */
int bp_storage_write(const char* name, const uint8_t* buf, int len); /* 0 ok, -1 fail */

/* ---- memory cards ------------------------------------------------------------------------
 * A game's memory card, in recompsx's card format (ADR-0037), never as a raw 128 KB image: a
 * 16-byte header and, for each block the game's saves occupy, that block's directory frame and
 * its 8 KB. A card is as large as what the game keeps on it — 8336 bytes for one block, 16 more
 * with nothing on it — and it grows and shrinks as the game saves and deletes. The runtime
 * builds and reads the format; the backend keeps the bytes under the game's product code
 * (`game`, [A-Z0-9]{1,16}, e.g. SCUS94570) in whatever its target keeps things in. `title` is
 * the game's name, for the host's own save manager; a backend that shows an icon may take the
 * game's own from the card (ADR-0037 has the layout).
 * Load returns the bytes read, or -1 when there is no card for this game. Save returns 0 or -1,
 * and must be atomic as bp_storage_write is, or else detectably damaged when interrupted (the
 * runtime then finds no card, and the game a blank one). Saving a card with no blocks on it —
 * len == BP_CARD_HEADER — removes the backend's copy: a game that keeps nothing takes no space. */
#define BP_CARD_HEADER 16
#define BP_CARD_RECORD (128 + 8192)
#define BP_CARD_MAX    (BP_CARD_HEADER + 15 * BP_CARD_RECORD)
int bp_card_load(const char* game, uint8_t* buf, int cap);
int bp_card_save(const char* game, const char* title, const uint8_t* buf, int len);

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
 * runtime. Brackets nest properly but may nest; all three sections hide inside the emulated
 * frame otherwise:
 *   BP_PROFILE_SPU  the sound processor's decoding and mixing, a batch at a time;
 *   BP_PROFILE_GTE  one GTE command — entered thousands of times a frame, so a backend should
 *                   note where the emulation is and sample it, never read a clock here;
 *   BP_PROFILE_GPU  one GPU DMA transfer: the ordering table walked and each primitive decoded
 *                   and handed to the backend (bp_gpu_*), including the backend's own share. */
enum { BP_PROFILE_SPU = 0, BP_PROFILE_GTE = 1, BP_PROFILE_GPU = 2, BP_PROFILE_SECTIONS = 4 };
void bp_profile_mark(int section, int begin);

enum { BP_LOG_DEBUG = 0, BP_LOG_INFO = 1, BP_LOG_WARN = 2, BP_LOG_ERROR = 3 };
void bp_log(int level, const char* msg);

/* Logs, tears down the platform, and exits. Never returns. */
void bp_fatal(const char* msg);

#ifdef __cplusplus
}
#endif

#endif /* RECOMPSX_BACKEND_C_API_H */
