/* dc_internal.h — what the Dreamcast backend's files share.
 *
 * The backend is one implementation of backend_c_api.h, split by subsystem (backend_kos.c lists
 * which file holds what). This header is the seam between the files: the KallistiOS includes,
 * the build switches, the types more than one file needs and, at the end, every variable and
 * function that one file defines and another uses, grouped by the file that defines it.
 * Everything not declared here is `static` to its file, so that list IS the coupling between
 * them: a name added to it is a dependency added, and worth a second look.
 *
 * Private to src/backend/dreamcast. The runtime sees only backend_c_api.h. */

#ifndef RECOMPSX_DC_INTERNAL_H
#define RECOMPSX_DC_INTERNAL_H

#include "backend_c_api.h"

#include <kos/init.h>
#include <kos/fs.h>
#include <kos/thread.h>
#include <kos/mutex.h>
#include <kos/cond.h>
#include <arch/arch.h>
#include <dc/video.h>
#include <dc/pvr.h>
#include <dc/perfctr.h>
#include <dc/sq.h>
#include <arch/timer.h>
#include <kos/irq.h>
#include <dc/maple.h>
#include <dc/maple/controller.h>
#include <dc/biosfont.h>
#include <dc/sound/sound.h>
#include <dc/sound/stream.h>
#include <dc/sound/aica_comm.h>
#include <dc/sound/sfxmgr.h>
#include <dc/spu.h>

#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#include <string.h>
#include <sys/time.h>

/* sh4zam first: a std function with an sh4zam counterpart is not called here — see AGENTS.md in
 * this directory. The memory group is what the backend needs; include others where used. */
#include <sh4zam/shz_mem.h>

/* 32 bytes to the TA through the store queue KOS direct rendering is writing — sh4zam's one-burst
 * copy: four paired 64-bit moves and the `pref` that sends them. Both types are 32-byte aligned
 * (KOS declares them so), which the paired moves need. Every header and every vertex that is not
 * written straight into the queue goes this way, never through pvr_prim. */
static inline void put_hdr(const pvr_poly_hdr_t* h) {
    shz_sq_memcpy32_1(pvr_dr_target(), h);
}
static inline void put_vtx(const pvr_vertex_t* v) {
    shz_sq_memcpy32_1(pvr_dr_target(), v);
}

/* `bytes` (a multiple of 32) from an 8-byte-aligned buffer into texture memory through the store
 * queues: sh4zam's run copy under KOS's queue lock, where pvr_txr_load was a library call. */
static inline void txr_put(const void* src, pvr_ptr_t dst, size_t bytes) {
    void* q = sq_lock((void*)(((uintptr_t)dst & 0xffffff) | PVR_TA_TEX_MEM));
    shz_sq_memcpy32(q, src, bytes);
    sq_unlock();
}

/* PS1 VRAM geometry. Fixed by the hardware, not a preference. */
#define VRAM_W 1024
#define VRAM_H 512

#define MAX_PADS   4
#define MAX_FILES  8

/* How the emulated picture is sampled when the PVR scales it to the television.
 * PVR_FILTER_NEAREST is the sharp, authentic choice; PVR_FILTER_BILINEAR is the forgiving one,
 * and it is the default because only 320x240 lands on an exact integer multiple of 640x480 —
 * 256, 368, 512 and 640 do not, and nearest-neighbour at a fractional scale produces the uneven
 * pixel columns that look like a rendering bug and are not one. */
#define RECOMPSX_DC_FILTER PVR_FILTER_BILINEAR

/* Whether the backend measures and reports where each frame went. Defined here, in the header
 * every file includes, because the counters it guards are spread over most of them, and a file
 * that saw a different value would compile some of the profiler and not the rest — which is not a
 * warning, it is an undeclared-identifier error in the half that survives. Costs a few clock
 * reads a frame; set to 0 to remove it entirely. */
#define RECOMPSX_DC_PROFILE 1

/* Whether the profiler can also paint its numbers over the picture. Needed wherever the serial
 * port is out of sight: redream does not surface it, and Flycast only prints it to the terminal
 * it was started from, which a player launching it from the Finder does not have. Compiled in,
 * and switched on per disc by a `--dc-overlay` line in recompsx.cfg: without it no texture is
 * allocated and nothing is drawn, so the only cost is the 128 KB text buffer in main RAM. */
#define RECOMPSX_DC_PROFILE_OVERLAY 1

/* Diagnosis mode: every texture cache slot decodes to one solid colour instead of its real
 * texels. The picture stops being a picture and becomes a map of which slot each surface binds:
 * stable colour patches mean the binding is right and the decoded *content* is the suspect;
 * patches that flicker between frames mean slots are being re-bound or evicted mid-scene. One
 * look answers what three rounds of hypothesis could not. */
#define RECOMPSX_DC_TEX_DEBUG 0

/* ---- video ----------------------------------------------------------------------------------- */

/* The framebuffer texture's size: the largest the PS1 can ask for (g_txr, dc_video.c). */
#define TXR_MAX_W 1024
#define TXR_MAX_H 512

#if RECOMPSX_DC_PROFILE_OVERLAY
/* The profiler's numbers have to reach a person, and on this machine that is not a given: booted
 * from a disc there is no dcload, and an emulator need not surface the serial port at all —
 * redream does not. So the profiler draws itself, into a texture of its own, over the game's own
 * picture. Four short lines rather than one long one, because the BIOS font is 12 pixels wide and
 * 512 of them is 42 characters. `bp_init` allocates the texture; dc_prof.c fills it in. */
/* The PVR requires both texture dimensions to be powers of two and asserts if they are not —
 * "Invalid texture V size", from pvr_poly_compile, at init, before anything is drawn. Five lines
 * of the 24-pixel BIOS font need 120, so the texture is 128 and the bottom 8 rows go unused; the
 * quad's V runs to TXT_USED/TXT_H rather than to 1. */
#define TXT_W 512
#define TXT_H 128
#endif

/* ---- hardware drawing state -------------------------------------------------------------------
 * Primitives arrive scattered through the emulated frame, but a PVR scene is built in one go
 * between `pvr_scene_begin` and `pvr_scene_finish`. So they are recorded as they come and turned
 * into geometry inside bp_present, which is also the first moment the display window — and
 * therefore the mapping from VRAM coordinates to screen coordinates — is known.
 *
 * Storage is deliberately small and flat: this machine has about 9 MB spare and no allocator worth
 * calling on a frame path. */
#define GPU_MAX_CMDS   12288
/* One more than the command buffer, and that is a PROOF, not a guess: a state is recorded only
 * when it differs from the previous one, and each primitive latches at most one state before it,
 * so states <= primitives + 1 <= GPU_MAX_CMDS + 1. The old cap of 512 was a guess, and a fight
 * scene's 1522 primitives sailed past it: every state after the 512th was silently dropped, every
 * primitive after that bound the LAST recorded state, and everything submitted late in the frame
 * — which the ordering table makes the NEAR geometry — rendered through one wrong page and one
 * wrong palette. "Half the map right, half a single pink wash" was this integer. */
#define GPU_MAX_STATES (GPU_MAX_CMDS + 1)
/* One primitive. A rectangle borrows the triangle's slots: corner in [0], size in [1]. So does a
 * VRAM write into the picture (GCMD_VRAM, see bp_gpu_dirty): VRAM corner in [0], size in [1]. */
enum { GCMD_TRI = 0, GCMD_RECT = 1, GCMD_VRAM = 2 };
/* 32 bytes, 32-aligned: one operand-cache line a record. Recording one allocates its line without
 * reading memory (shz_dcache_alloc_line, `movca.l`: the SH-4 caches write-back, and a store that
 * misses would otherwise fetch 32 bytes only to overwrite them), and build_scene reads the buffer
 * as a stream it prefetches ahead of. It was 36 bytes, so most records straddled two lines. The
 * state index and the kind share the last halfword: states <= GPU_MAX_STATES < 2^14. */
typedef struct __attribute__((aligned(32))) {
    int16_t  x[3], y[3];
    uint32_t argb[3];
    uint8_t  u[3], v[3];
    uint16_t state   : 14;
    uint16_t is_rect : 2;
} gcmd_t;
_Static_assert(sizeof(gcmd_t) == 32, "a command record is one cache line");
_Static_assert(GPU_MAX_STATES <= (1 << 14), "a state index fits the record's 14 bits");

/* Texture and blend state, recorded once per run of primitives that share it. */
/* One cache line too, for the same reasons as gcmd_t: appended into a line allocated without a
 * read, and prefetched ahead of the command walk that reads it. 27 bytes of fields, padded. */
typedef struct __attribute__((aligned(32))) {
    uint16_t tex_x, tex_y;      /* texture page origin, in VRAM halfwords */
    uint16_t clut_x, clut_y;
    uint32_t window;            /* GP0(E2h) raw: the tile-repeat mask and offset */
    int16_t  draw_x, draw_y;    /* the buffer being drawn into — NOT the one being displayed */
    int16_t  clip_x0, clip_y0, clip_x1, clip_y1;   /* the drawing area, GP0(E3h)/(E4h), inclusive */
    uint8_t  depth;             /* 0 = 4bpp indexed, 1 = 8bpp indexed, 2 = 15bpp direct */
    uint8_t  semi_mode;
    uint8_t  flags;             /* BP_GPU_TEXTURED | BP_GPU_SEMI | BP_GPU_RAW */
} gstate_t;
_Static_assert(sizeof(gstate_t) == 32, "a state record is one cache line");

/* One scene's worth of GPU diagnostics, held until it can be printed without being counted. */
typedef struct {
    int pending, prim, state, mir, tex_dec, tex_hit, tex_conf;
    int bake_live, bake_dec, bake_miss, pal_live, pal_approx, pal_conf;
    int sx, sy, sw, sh, draw_x, draw_y, v0x, v0y, scr_x, scr_y;
} gdiag_t;

/* The scene build's parts, kept out of line in profiling builds so the overlay's function profile
 * can tell them apart: inlined, they all read as `present_frame`. A call each is the price. */
#if RECOMPSX_DC_PROFILE
#define PROF_NOINLINE __attribute__((noinline))
#else
#define PROF_NOINLINE
#endif

/* ---- textures -------------------------------------------------------------------------------- */

/* Decoded textures, keyed by what the PlayStation asked for. Each slot is a full 256x256 texel
 * page in ARGB1555 — which is what U and V can address whatever the depth — at 128 KB a slot.
 * Twenty-four of them is 3 MB of the 8 MB of video RAM, beside the 1 MB the framebuffer blit
 * keeps, the framebuffers themselves and the vertex buffer — the eviction rate is what decides
 * whether that is enough, and the diagnostic line reports it. */
#define TEX_BIG_SLOTS 12   /* 128 KB ARGB slots: 8bpp-baked and 15bpp pages              */
#define TEX_SMALL_MAX 8    /* 32 KB index slots — now only the rare WINDOWED 4bpp page   */
#define TEX_SLOTS_MAX (TEX_BIG_SLOTS + TEX_SMALL_MAX)
#define TEX_DIM   256

/* The whole PlayStation VRAM, as 4bpp indices, resident forever.
 *
 * The question that produced this: a PS1 holds every texture it owns in one megabyte, so why
 * does a machine with eight need a cache with an eviction policy? It does not. VRAM is
 * 1024x512 halfwords; read as 4bpp that is 4096x512 texels, and the PlayStation's own page
 * grid cuts it into thirty-two 256x256 pages of 32 KB each — one megabyte, the source in its
 * entirety. Pages are aligned to 64 halfwords by the hardware's own texpage encoding, so no
 * page ever straddles a slot and the lookup is arithmetic on the page origin rather than a
 * search. Nothing is ever evicted, so a page conflict stops being rare and becomes impossible.
 *
 * Only the plain (unwindowed) case lives here: GP0(E2h)'s tile-repeat mask has to be baked
 * into the texels, so windowed pages keep the old dynamic slots, where they are rare enough
 * to fit. */
#define PAGE4_COLS  16
#define PAGE4_ROWS  2
#define PAGE4_N     (PAGE4_COLS * PAGE4_ROWS)

/* Baked entries for palettes that could not get one of the sixty-four hardware banks.
 *
 * Palette RAM is the one resource where a Dreamcast has LESS than a PlayStation: a PS1 CLUT is
 * just data in the same VRAM, so a scene may use a thousand, while the PVR reads a fixed
 * 1024-entry table (register base 0x1000) at render time — 64 banks of 16 at 4bpp. This arena
 * wants about a hundred. No format escapes that arithmetic, so the overflow is drawn from
 * texels with the CLUT already applied. What makes it affordable is baking the region the
 * primitive actually samples instead of the whole page: 64x64 is 8 KB, where a page is 128.
 *
 * The same patches draw a semi-transparent 4bpp primitive whose CLUT holds solid and STP texels
 * both, in two variants (semi_prim), so the pool is 128 (1 MB, and only as much as leaves the
 * floor free). At 64, Crash 3's demo window re-baked every frame and cost 3.5 %; at 128, about 1 %. */
#define BAKE_DIM   64
#define BAKE_MAX   128
/* Where a patch may start, in texels: every 32, not every 64. A primitive whose 64 texels begin on
 * an odd multiple of 32 — Crash's eyebrows and Aku Aku's feathers in Crash 3 sample v 160..223 —
 * fits no aligned patch, and without one it fell back to being drawn whole, its solid texels
 * blended. The aligned patch is still the first choice (one_patch), so neighbours keep sharing. */
#define BAKE_STEP  32

typedef struct {
    pvr_ptr_t mem;
    uint16_t  tex_x, tex_y;
    uint16_t  clut_x, clut_y;   /* part of the key ONLY at 8bpp — see the note at g_pal4 */
    uint32_t  window;
    uint32_t  bound_frame;      /* the last frame a primitive bound this slot */
    uint8_t   depth;
    uint8_t   used;             /* holds a decoded page */
    uint8_t   amode;            /* which texels it shows (AM_*); always AM_VIS at 4bpp */
} gtex_t;

/* `part`: the page is valid except inside [dx0,dx1) x [dy0,dy1), in VRAM halfwords and rows
 * relative to the page, which page4_mirror patches in place before the page is next used. */
typedef struct {
    pvr_ptr_t mem;
    uint32_t  bound_frame;
    uint8_t   valid, defer, part;
    int16_t   dx0, dy0, dx1, dy1;
} gpage4_t;

typedef struct {
    pvr_ptr_t mem;
    uint16_t  tex_x, tex_y, clut_x, clut_y;
    uint8_t   tu, tv, used;
    uint8_t   depth;            /* 0: a 4bpp page's patch, 1: an 8bpp page's — see bake_slot */
    uint8_t   amode;            /* which texels it shows (AM_*) */
    uint32_t  bound_frame;
} gbake_t;

/* Which texels a decoded texture shows, for semi-transparency — which on the PlayStation is per
 * texel: in a semi-transparent textured primitive only the texels with STP (bit 15) blend, the
 * others are drawn opaque, and 0x0000 is a hole either way (psx-spx, "Semi-Transparency").
 * AM_VIS shows every texel but 0x0000: opaque primitives, and semi-transparent ones whose CLUT
 * holds one kind only. AM_SOLID shows the texels without STP, AM_STP those with it; for AM_STP
 * the others are black as well as transparent, so that an additive blend, which reads no alpha,
 * adds nothing for them. Crash Bandicoot: Warped's fruit is 645 solid texels to 42 STP ones, and
 * drawn with every texel blended it was see-through. */
enum { AM_VIS = 0, AM_SOLID = 1, AM_STP = 2, AM_N = 3 };

/* The background: the displayed rectangle of emulated VRAM, as a texture behind the geometry.
 *
 * Kept per rectangle, in slots carved out of the one megabyte g_txr: a slot is a whole texture at
 * the declared size (512x256 at 16 bpp is 256 KB, so four), and it holds the picture of one VRAM
 * rectangle until something writes that rectangle. In hardware mode the only things that write
 * VRAM are uploads and blits, and both announce themselves through bp_gpu_dirty. A single slot
 * was stale at every buffer flip — the rectangle moves — so a double-buffered game paid the whole
 * upload, 512x240 converted through the store queues (~3.3 ms), every other frame for two
 * pictures that had not changed: Crash Bandicoot: Warped's demo, 93 % of present_frame. With a
 * slot per buffer it uploads each once. */
#define BG_SLOTS 4
typedef struct {
    int x, y, w, h;    /* the displayed rectangle */
    int d24;           /* uploaded as 24bpp (MDEC video): three bytes a pixel read from VRAM */
    int valid;
    uint32_t used;     /* g_tex_frame of its last use: the least recently used goes first */
} gbg_t;

/* ---- audio ----------------------------------------------------------------------------------- */

#define STREAM_BYTES_PER_CHANNEL 8192          /* 4096 samples => ~93 ms in the AICA */

/* ---- defined in one file, used in another ------------------------------------------------- */

/* dc_video.c */
extern pvr_ptr_t g_txr;
extern pvr_poly_hdr_t g_hdr;
extern int g_txw;
extern int g_txh;
extern int g_ready;
extern int g_inited;
extern gbg_t g_bgs[BG_SLOTS];
extern int g_bg_slots;
void draw_quad(int sw, int sh);

/* dc_scene.c */
extern const uint16_t* g_vram;
extern gcmd_t g_cmds[GPU_MAX_CMDS];
extern int g_cmd_count;
extern gstate_t g_states[GPU_MAX_STATES];
extern int g_frame_shown;
extern int g_scene_dirty;
extern int g_hdr_hits;
extern int g_hdr_compiles;
extern gdiag_t g_diag;
extern int g_disp[2][4];
int inside(int ax, int ay, int aw, int ah, int bx, int by, int bw, int bh);
int last_cover(int sw, int sh);
int marks_from(int first, int sx, int sy, int sw, int sh);
PROF_NOINLINE void build_scene(int sx, int sy, int sw, int sh, int with_background, int first);

/* dc_textures.c */
extern gpage4_t g_page4[PAGE4_N];
extern int g_mir_decodes;
extern gbake_t g_bake[BAKE_MAX];
extern int g_bake_n;
extern int g_bake_live;
extern int g_bake_decodes;
extern int g_bake_miss;
extern gtex_t g_tex[TEX_SLOTS_MAX];
extern int g_tex_big_n;
extern int g_tex_small_n;
extern int g_tex_decodes;
extern int g_tex_hits;
extern int g_tex_conflicts;
extern int g_pal_live;
extern int g_pal_stale;
extern int g_pal_conflicts;
extern uint32_t g_tex_frame;
void twid_init(void);
extern uint32_t g_pal_memo_gen;
PROF_NOINLINE int pal_bank_cached(int clut_x, int clut_y, int allow_approx, int amode);
PROF_NOINLINE int tex_slot(const gstate_t* s, int amode);
PROF_NOINLINE pvr_ptr_t page4_mirror(const gstate_t* s);
PROF_NOINLINE int bake_slot(const gstate_t* s, int tu, int tv, int amode);
PROF_NOINLINE void palette_priority(void);

/* dc_audio.c */
extern snd_stream_hnd_t g_stream;
extern int g_snd_up;
extern uint64_t g_prof_audio;
extern int g_prof_polls;
extern int g_hw_voices;
void pump_audio(void);
#if RECOMPSX_DC_PROFILE
extern uint64_t g_prof_aica;
extern int g_prof_aica_decodes;
extern int g_prof_aica_declined;
#endif
void spu_voices_off(void);
void* audio_pull(snd_stream_hnd_t hnd, int req, int* got);

/* dc_input.c */
void reset_combo(uint8_t addr, uint32_t btns);

/* dc_files.c */
extern const char* g_storage_root;
#if RECOMPSX_DC_PROFILE
extern uint64_t g_prof_disc_us;
extern uint32_t g_prof_disc_bytes;
extern int g_prof_reads;
extern int g_prof_misses;
#endif
void find_storage(void);

/* dc_prof.c */
#if RECOMPSX_DC_PROFILE_OVERLAY
extern pvr_ptr_t g_txt;
extern pvr_poly_hdr_t g_txt_hdr;
#endif
extern int g_empty_presents;
extern int g_prof_skipped;
extern uint64_t g_prof_build;
extern int g_bright_prims;
extern int g_win_mir;
extern int g_win_slot;
extern int g_win_bake;
extern int g_win_patch;
#if RECOMPSX_DC_PROFILE
extern int g_bench_from;
extern int g_bench_to;
extern int g_rxprof;
#endif
extern kthread_t* g_emu_thread;
#if RECOMPSX_DC_PROFILE
extern uint64_t g_prof_emu;
extern uint64_t g_prof_wait;
extern uint64_t g_prof_upload;
extern uint64_t g_prof_submit;
extern uint64_t g_prof_end;
extern uint64_t g_prof_pace;
extern int g_pc_frames;
extern int g_pc_armed;
void perf_window_close(uint64_t emu_us);
extern uint32_t g_samp_frames;
void syms_load(void);
void glyphs_load(void);
void samp_start(void);
void samp_report(void);
void perf_window_open(void);
extern uint64_t g_prof_log_us;
extern int g_prof_logs;
void profile_report(void);
#if RECOMPSX_DC_PROFILE_OVERLAY
void draw_profile_overlay(void);
#endif
#endif

/* dc_fastmem.c */
#if RECOMPSX_DC_PROFILE
extern char g_fm_line[48];
void fastmem_test(void);
#endif

#endif /* RECOMPSX_DC_INTERNAL_H */
