/* backend_kos.c — the Sega Dreamcast implementation of backend_c_api.h.
 *
 * This is the ONLY file in the project that includes KallistiOS. It is the second machine the
 * emulator has ever run on, and the first console, so it is also the proof that the boundary
 * drawn in docs/specs/backend.md is real: nothing above this line changed to make it exist —
 * not the runtime, not the shims, not a single line of generated code.
 *
 * Written against KallistiOS as documented at https://kos-docs.dreamcast.wiki/. Every call here
 * was checked against the upstream headers of both the current release (v2.2.2) and the
 * development branch, and only the intersection is used: `timer_us_gettime64`, for one, exists
 * in the release and has been removed from master, so time comes from `gettimeofday` — which is
 * standard C, present in every version, and backed by the same 80 ns timer underneath.
 *
 * Keep it boring: no emulation logic belongs here, and nothing here may influence emulated state.
 */

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

/* What KallistiOS should bring up before main() runs. INIT_DEFAULT covers the maple bus (so
 * controllers and the VMU filesystem exist), the GD-ROM with its ISO9660 driver (so /cd exists)
 * and dcload (so /pc exists when launched over a coder's cable or BBA).
 *
 * This macro has to live in a C file. It expands to definitions of ordinary global function
 * pointers whose *names* are what the kernel's weak symbols resolve against; compiled as C++
 * those names would be mangled, the overrides would silently not take, and the console would
 * boot with no controller and no disc. */
KOS_INIT_FLAGS(INIT_DEFAULT);

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

/* Whether the backend measures and reports where each frame went. Defined here, at the top,
 * because the counters it guards are declared in several sections below and a `#define` placed
 * after the first of them compiles some of the profiler and not the rest — which is not a warning,
 * it is an undeclared-identifier error in the half that survives. Costs a few clock reads a frame;
 * set to 0 to remove it entirely. */
#define RECOMPSX_DC_PROFILE 1

/* Defined far below, beside the rest of the profiling apparatus; started from bp_init, which
 * comes first in the file. */
#if RECOMPSX_DC_PROFILE
static void samp_start(void);
static void syms_load(void);
#endif
static void twid_init(void);   /* the twiddled texture upload's tables, built in bp_init */

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

/* ---- video state ---------------------------------------------------------------------------
 * One texture, allocated once at the largest size the PS1 can ask for and never freed. VRAM on
 * this machine is 8 MB and a full 1024x512 sheet at 16 bpp is 1 MB of it, which is cheap next to
 * the alternative: reallocating whenever a game changes resolution would fragment the PVR heap
 * over a play session, and a fragmented heap fails at the least convenient moment. Only the
 * dimensions the hardware is *told* about change with the mode. */
#define TXR_MAX_W 1024
#define TXR_MAX_H 512

static pvr_ptr_t      g_txr;
static pvr_poly_hdr_t g_hdr;
static int            g_txw, g_txh;      /* power-of-two dimensions currently declared */
static int            g_ready;           /* video is up */
static int            g_inited;          /* bp_init has run; a second call is a no-op */

#if RECOMPSX_DC_PROFILE_OVERLAY
/* The profiler's numbers have to reach a person, and on this machine that is not a given: booted
 * from a disc there is no dcload, and an emulator need not surface the serial port at all —
 * redream does not. So the profiler draws itself, into a texture of its own, over the game's own
 * picture. Four short lines rather than one long one, because the BIOS font is 12 pixels wide and
 * 512 of them is 42 characters.
 *
 * Declared up here with the rest of the video state, not down beside the code that fills it in:
 * `bp_init` allocates this texture, and in C a file is read from the top. */
/* The PVR requires both texture dimensions to be powers of two and asserts if they are not —
 * "Invalid texture V size", from pvr_poly_compile, at init, before anything is drawn. Five lines
 * of the 24-pixel BIOS font need 120, so the texture is 128 and the bottom 8 rows go unused; the
 * quad's V runs to TXT_USED/TXT_H rather than to 1. */
#define TXT_W 512
#define TXT_H 128
#define TXT_USED 120
#define TXT_LINE 24
static pvr_ptr_t      g_txt;
static pvr_poly_hdr_t g_txt_hdr;
static uint16_t g_txt_buf[TXT_W * TXT_H] __attribute__((aligned(32)));
static int      g_txt_ready;
#endif

/* One converted scanline on its way to the PVR. 32-byte aligned because the store queues that
 * carry it there require it. */
static uint16_t g_line[TXR_MAX_W + 16] __attribute__((aligned(32)));

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
typedef struct {
    int16_t  x[3], y[3];
    uint8_t  u[3], v[3];
    uint32_t argb[3];
    uint16_t state;
    uint8_t  is_rect;
} gcmd_t;

/* Texture and blend state, recorded once per run of primitives that share it. */
typedef struct {
    uint16_t tex_x, tex_y;      /* texture page origin, in VRAM halfwords */
    uint16_t clut_x, clut_y;
    uint32_t window;            /* GP0(E2h) raw: the tile-repeat mask and offset */
    int16_t  draw_x, draw_y;    /* the buffer being drawn into — NOT the one being displayed */
    int16_t  clip_x0, clip_y0, clip_x1, clip_y1;   /* the drawing area, GP0(E3h)/(E4h), inclusive */
    uint8_t  depth;             /* 0 = 4bpp indexed, 1 = 8bpp indexed, 2 = 15bpp direct */
    uint8_t  semi_mode;
    uint8_t  flags;             /* BP_GPU_TEXTURED | BP_GPU_SEMI | BP_GPU_RAW */
} gstate_t;

static const uint16_t* g_vram;          /* emulated VRAM, borrowed; NULL until armed */
static gcmd_t   g_cmds[GPU_MAX_CMDS];
static int      g_cmd_count;
static gstate_t g_states[GPU_MAX_STATES];
static int      g_state_count;
static int      g_cmd_overflowed;
/* Set when a frame has been presented, cleared by the next primitive to arrive. It is what makes
 * the geometry persist: a PlayStation's framebuffer keeps what was drawn into it until something
 * overwrites it, and a game drawing at thirty frames a second submits nothing at all on every
 * other vblank. Clearing the buffer at present time instead would show that game its background
 * on one frame and its world on the next, alternating — which is exactly what it did. */
static int      g_frame_shown;
/* Whether anything the picture is made of has changed since the last scene went to the PVR: a
 * primitive, a VRAM write, the display window. When nothing has, the scene is not built at all —
 * the PVR keeps showing the last one it rendered. A game at thirty frames a second presents
 * every frame twice, and building the same list the second time cost as much as the first. */
static int      g_scene_dirty = 1;
/* How many presents arrived with no primitives submitted since the last one. The theory that
 * half of them are redundant comes from the game flipping every second vblank — but it submits
 * ~772 primitives on every vblank in this scene, which would mean it draws each frame across
 * two of them and this counter stays at zero. Measure before skipping anything: presenting a
 * half-built scene and presenting nothing are different mistakes. */
static int      g_empty_presents;
static int      g_prof_skipped;
/* `submit` covers two very different things — walking the command buffer into TA commands, and
 * handing the finished scene to the hardware — and its spikes have now survived two confident
 * explanations of mine. Splitting it is cheaper than a third guess. */
static uint64_t g_prof_build;
/* Textured primitives drawn twice this window, for colours above the PVR's 1.0 (put_tri). */
static int      g_bright_prims;
/* Texture decodes this window, by cache: 4bpp page mirrors, pool slots, baked palette patches.
 * The overlay's `dec m/s/b`: what tells an invalidated texture from a cache that is too small. */
static int      g_win_mir, g_win_slot, g_win_bake, g_win_patch;

/* `--dc-bench=FROM:TO`, read at init; the benchmark itself is with profile_report. With
 * `--dc-rxprof` as well, the range is also announced on the serial port — "@@rxprof start" as it
 * begins, "@@rxprof stop" and "@@rxprof exit" when it ends — for the profiling Flycast build
 * (branch recompsx-prof), which records the guest's PCs between the two and then quits. */
#if RECOMPSX_DC_PROFILE
static int g_bench_from = -1, g_bench_to = -1;
static int g_rxprof;
#endif

/* The scene build's parts, kept out of line in profiling builds so the overlay's function profile
 * can tell them apart: inlined, they all read as `present_frame`. A call each is the price. */
#if RECOMPSX_DC_PROFILE
#define PROF_NOINLINE __attribute__((noinline))
#else
#define PROF_NOINLINE
#endif

/* Compiled polygon headers, kept.
 *
 * Splitting `submit` settled where its spikes lived: entirely in scene building, never in
 * handing the scene over — 12.4 ms a frame in the busy scenes against 3 in the calm ones, and
 * the difference is the number of `pvr_poly_compile` calls, one per binding change. But a header
 * is a pure function of its binding: the same texture, format, size and blend produce the same
 * thirty-two bytes every time, and a scene re-derives the same bindings frame after frame. So
 * compile once and keep it. The UV origin is deliberately NOT part of the key — it moves the
 * texture coordinates, not the header. */
/* 1024 direct-mapped slots, chosen by the multiplicative hash's top bits. 128 were too few for a
 * scene's texture page x palette bank x blend combinations: in gameplay the overlay counted
 * 2,005 hits against 14,707 compiles in thirty vblanks — pairs of bindings sharing a slot and
 * alternating, each evicting the other at every primitive. About 57 KB of main RAM. */
#define HDRC_BITS 10
#define HDRC_N (1 << HDRC_BITS)
typedef struct {
    pvr_ptr_t mem;
    int       fmt, dim;
    uint8_t   flags, semi_mode, used, over, kind;
    float     alpha;
    pvr_poly_hdr_t hdr;
} ghdr_t;
static ghdr_t g_hdrc[HDRC_N];
static int    g_hdr_hits, g_hdr_compiles;

/* What one pass of a primitive does to the picture — see build_scene's semi-transparency.
 * HK_NORMAL blends as the state says; HK_OPAQUE draws a semi-transparent state's solid texels
 * as an opaque primitive would; HK_ADD adds the source (B + F, reading no alpha); HK_INVERT is
 * untextured white turning each pixel under it into its complement (1 - B). */
enum { HK_NORMAL = 0, HK_OPAQUE = 1, HK_ADD = 2, HK_INVERT = 3 };

static int hdr_slot(pvr_ptr_t mem, int fmt, int dim, const gstate_t* s, int over, int kind) {
    uint32_t h = (uint32_t)(uintptr_t)mem + (uint32_t)over * 0x9E3779B9u + (uint32_t)kind * 0x85EBCA6Bu;
    h = h * 2654435761u + (uint32_t)fmt;
    h = h * 2654435761u + (uint32_t)dim;
    h = h * 2654435761u + ((uint32_t)s->flags << 8) + (uint32_t)s->semi_mode;
    return (int)(h >> (32 - HDRC_BITS));
}

/* One scene's worth of GPU diagnostics, held until it can be printed without being counted. */
static struct {
    int pending, prim, state, mir, tex_dec, tex_hit, tex_conf;
    int bake_live, bake_dec, bake_miss, pal_live, pal_approx, pal_conf;
    int sx, sy, sw, sh, draw_x, draw_y, v0x, v0y, scr_x, scr_y;
} g_diag;
static int      g_warned_sub;           /* the one blend mode the PVR cannot express */

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
#define PAGE4_BYTES (TEX_DIM * TEX_DIM / 2)

/* Baked entries for palettes that could not get one of the sixty-four hardware banks.
 *
 * Palette RAM is the one resource where a Dreamcast has LESS than a PlayStation: a PS1 CLUT is
 * just data in the same VRAM, so a scene may use a thousand, while the PVR reads a fixed
 * 1024-entry table (register base 0x1000) at render time — 64 banks of 16 at 4bpp. This arena
 * wants about a hundred. No format escapes that arithmetic, so the overflow is drawn from
 * texels with the CLUT already applied. What makes it affordable is baking the region the
 * primitive actually samples instead of the whole page: 64x64 is 8 KB, where a page is 128. */
#define BAKE_DIM   64
#define BAKE_MAX   64
#define BAKE_BYTES (BAKE_DIM * BAKE_DIM * 2)

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

/* The palettes, separated from the pages at last. The diagnosis disc measured a fight scene's
 * working set at ~60 (page x CLUT x window) keys — two and a half times any cache this machine
 * can hold, thirty-plus conflicts a frame, seconds of decode. But the *pages* were few; it was
 * the CLUTs multiplying them. The PVR has palette hardware for exactly this: a 4bpp texture
 * names one of sixty-four 16-entry banks in its header, so a CLUT stops being "another copy of
 * the page" and becomes sixteen register writes. All sixty-four banks serve 4bpp.
 *
 * 8bpp deliberately does NOT use palette banks, and the arithmetic is the reason: palette RAM is
 * 1024 entries total and an 8bpp CLUT is 256 of them — at most four can be live, and one row of
 * UI banners alone wants more (which is precisely what a row of blank-white banners with one
 * garbled one looks like: every 8bpp texture rendered through whichever palette was written
 * last). So 8bpp keeps the old baked path — CLUT in the cache key, colours applied at decode —
 * which its rarity affords. A CLUT repaint at 4bpp invalidates a bank, not a page, which turns
 * palette animation from an eviction storm into a no-op. */
#define PAL_BANKS_4BPP 64
typedef struct {
    uint16_t entry[16];         /* the palette itself, ARGB1555 — the content IS the key */
    uint32_t hash;
    uint32_t bound_frame;
    uint8_t  used;
} gpal_t;
static gpal_t g_pal4[PAL_BANKS_4BPP];
static int    g_pal_next;

/* `part`: the page is valid except inside [dx0,dx1) x [dy0,dy1), in VRAM halfwords and rows
 * relative to the page, which page4_mirror patches in place before the page is next used. */
typedef struct {
    pvr_ptr_t mem;
    uint32_t  bound_frame;
    uint8_t   valid, defer, part;
    int16_t   dx0, dy0, dx1, dy1;
} gpage4_t;
static gpage4_t  g_page4[PAGE4_N];
static pvr_ptr_t g_mir_base;
static int       g_mir_decodes;

typedef struct {
    pvr_ptr_t mem;
    uint16_t  tex_x, tex_y, clut_x, clut_y;
    uint8_t   tu, tv, used;
    uint8_t   depth;            /* 0: a 4bpp page's patch, 1: an 8bpp page's — see bake_slot */
    uint8_t   amode;            /* which texels it shows (AM_*) */
    uint32_t  bound_frame;
} gbake_t;
static gbake_t g_bake[BAKE_MAX];
static int     g_bake_n, g_bake_next, g_bake_live, g_bake_decodes, g_bake_miss;

static gtex_t g_tex[TEX_SLOTS_MAX]; /* [0, big_n) ARGB pool, [big_n, big_n+small_n) 4bpp pool */
static int    g_tex_big_n, g_tex_small_n;        /* allocated at arming time, floor-checked   */
static int    g_tex_big_next, g_tex_small_next;  /* round-robin eviction cursor, one per pool */
/* Decodes and hits per frame. A 256x256 page is 65,536 texels through a palette, so a scene that
 * misses more than a handful of times is not using a cache, it is rebuilding one. */
static int    g_tex_decodes, g_tex_hits;
/* A conflict is the cache's cardinal sin: evicting a slot that a primitive EARLIER IN THIS SAME
 * SCENE already bound. The PVR reads textures at render time, not at submit time, so that
 * earlier primitive will be drawn with the newcomer's texels — unrelated content, changing with
 * the round-robin phase, exactly what per-frame-shifting corruption looks like. */
static int      g_tex_conflicts;
/* Bank pressure gets its own numbers: how many 4bpp palettes this frame actually bound, and how
 * many times one was repainted while an earlier primitive of the same scene still named it. The
 * hardware ceiling is sixty-four; a scene living above it recolours its losers with whichever
 * palette was written last — the whole-screen single-tint wash. */
static int      g_pal_live, g_pal_stale, g_pal_conflicts;
/* Counts scenes, and starts at ONE. Zero is the value every cache entry has before it is ever
 * bound, and the in-flight rule reads it as "virgin, take it freely" — so with a zeroth frame,
 * everything bound during it stayed forever indistinguishable from unused, and could be
 * overwritten while the PVR was still rendering from it. That is precisely a first-frames
 * corruption that heals itself as entries acquire honest numbers. */
static uint32_t g_tex_frame = 1;

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
static gbg_t          g_bgs[BG_SLOTS];
static pvr_poly_hdr_t g_bg_hdr[BG_SLOTS];
static int            g_bg_slots = 1;     /* how many fit at the declared size */

/* ---- audio state ----------------------------------------------------------------------------
 * The ABI is push-shaped and the AICA's stream driver is pull-shaped, so a ring sits between
 * them. Both ends run on the emulator thread — `snd_stream_poll` invokes the callback inline —
 * so there is nothing to lock, and this file would be wrong if that ever stopped being true. */
#define RING_FRAMES 8192                       /* stereo frames; 32 KB, ~186 ms of headroom */
#define STREAM_BYTES_PER_CHANNEL 8192          /* 4096 samples => ~93 ms in the AICA */

static snd_stream_hnd_t g_stream = SND_STREAM_INVALID;
static int     g_snd_up;                       /* snd_stream_init succeeded */
static int16_t g_ring[RING_FRAMES * 2];
static int     g_ring_head, g_ring_tail;       /* in stereo frames; head == tail means empty */
static int16_t g_pull[STREAM_BYTES_PER_CHANNEL] __attribute__((aligned(32)));

/* ---- input state ---------------------------------------------------------------------------- */

static uint32_t g_pad_buttons[MAX_PADS];
static uint8_t  g_pad_axes[MAX_PADS][4];
static int      g_pad_present[MAX_PADS];
/* Written from the maple driver's button callback, which runs on an interrupt. */
static volatile int g_quit;

/* PS1 controller bit layout, active high on this side of the API.
 * (The runtime inverts when it builds the SIO0 response — that is emulation, not platform.) */
enum {
    PAD_SELECT = 1 << 0,  PAD_L3     = 1 << 1,  PAD_R3    = 1 << 2,  PAD_START = 1 << 3,
    PAD_UP     = 1 << 4,  PAD_RIGHT  = 1 << 5,  PAD_DOWN  = 1 << 6,  PAD_LEFT  = 1 << 7,
    PAD_L2     = 1 << 8,  PAD_R2     = 1 << 9,  PAD_L1    = 1 << 10, PAD_R1    = 1 << 11,
    PAD_TRIANGLE = 1 << 12, PAD_CIRCLE = 1 << 13, PAD_CROSS = 1 << 14, PAD_SQUARE = 1 << 15
};

/* Where a light trigger press becomes a shoulder button, and where a hard one becomes the second
 * shoulder button instead. The Dreamcast pad has two analogue triggers where the PlayStation has
 * four digital shoulders, so each trigger carries two of them along its travel. */
#define TRIG_L1 40
#define TRIG_L2 200

/* ---- storage / launch state ------------------------------------------------------------------ */

#define MAX_ARGS 8
#define ARG_LEN  128

static char g_args[MAX_ARGS][ARG_LEN];
static int  g_argc;

static const char* g_storage_root;   /* NULL until a writable one is found */
static int         g_storage_is_vmu;

/* ---- files ---------------------------------------------------------------------------------- */

static FILE* g_files[MAX_FILES];
static int   g_file_size[MAX_FILES];

/* ---- the disc read-ahead ----------------------------------------------------------------------
 * The PlayStation's drive hands over a sector at a time and the emulation asks for exactly that:
 * a couple of kilobytes, at a monotonically rising offset, three hundred times a second. Served
 * literally, each one is an fseek and an fread through KOS's ISO9660 driver onto a GD-ROM — and a
 * disc is not a thing you want to touch three hundred times a second on any machine.
 *
 * So reads are served out of a window instead, and the window after it is read in the background
 * while the emulation uses this one. The drive was the largest cost of a loading screen: 1018 ms
 * of every 1762 spent with the whole machine stopped in fread. A thread of its own does the
 * reading; KOS's CD driver sleeps on a semaphore through each DMA, so the emulation runs while
 * the drive works, and waits only when it catches up with it.
 *
 * Two windows of 128 KB, each starting on a 2048-byte boundary of the file: an image file starts
 * on a sector of the disc, so an aligned window of whole sectors is one multi-sector DMA read in
 * KOS's ISO9660 driver, where an unaligned one was three commands. Only the I/O thread touches a
 * FILE while it is working; the emulation reaches the file through it, or directly only while
 * it is idle and the lock is held, which is also how open, close and oversized reads go.
 *
 * None of it can affect what the emulated machine sees: this side of the ABI is a byte server,
 * the file does not change while it is open, and a slot's windows are dropped with the slot. */
/* Audio is the one backend call the runtime makes from INSIDE the emulated frame, so its cost
 * has always been hiding inside `emu`. PC sampling put 24% of the machine in KOS's idle task,
 * which means something is blocking rather than computing, and snd_stream_poll waits on a G2 DMA
 * into sound RAM. This column says whether that is the 24%. Declared up here, before its only
 * writer, because C reads top-down — a lesson this file has now taught three times. */
static uint64_t g_prof_audio;
static int      g_prof_polls;

/* The runtime's own brackets (bp_profile_mark), timed on this side of the ABI: the SPU's decoding
 * and mixing, and each GPU DMA transfer. Taken out of `emu` and printed beside it, and the runtime
 * never sees the clock, only says where the stretch begins and ends. */
static uint64_t g_prof_section_us[BP_PROFILE_SECTIONS];
static uint64_t g_prof_section_at[BP_PROFILE_SECTIONS];

/* Where the emulation is, for the sampler (samp_tick): the innermost open bracket, or -1, and the
 * ones it sits inside. A GTE command is too short and too frequent to time — two clock reads cost
 * more than most commands do — so it is only noted here, and the 1 kHz sampler counts the ticks
 * that land inside one: a tick is a millisecond, the unit of every other number. Only ticks that
 * interrupt the emulation thread count; the disc and audio threads can run while it is preempted
 * in the middle of a command. */
#define WHERE_DEPTH 4
static volatile int      g_where = -1;
static int               g_where_outer[WHERE_DEPTH];
static int               g_where_depth;
static kthread_t*        g_emu_thread;
static volatile uint32_t g_samp_where[BP_PROFILE_SECTIONS];

void bp_profile_mark(int section, int begin) {
    /* A GTE command is entered ~2500 times a vblank and never runs inside another bracket or
     * holds one, so it is a single store: the stack below cost ~20 instructions a mark, which
     * across a window was ~15 ms of the profile measuring itself. */
    if(section == BP_PROFILE_GTE) { g_where = begin ? BP_PROFILE_GTE : -1; return; }
    if(section < 0 || section >= BP_PROFILE_SECTIONS) return;
    if(begin) {
        if(g_where_depth < WHERE_DEPTH) g_where_outer[g_where_depth++] = g_where;
        g_where = section;
    } else {
        g_where = g_where_depth > 0 ? g_where_outer[--g_where_depth] : -1;
    }
    const uint64_t now = bp_time_us();
    if(begin) {
        g_prof_section_at[section] = now;
    } else if(g_prof_section_at[section]) {
        g_prof_section_us[section] += now - g_prof_section_at[section];
        g_prof_section_at[section] = 0;
    }
}

#define DISC_WINDOW (128 * 1024)
/* After a seek, the first read is this small and each following one twice the last, up to a
 * window. A load in Crash Bash jumps between files a few times and then reads on, and every jump
 * used to read a whole 128 KB window before the game had its sector: two of those were most of
 * a 2.5-second freeze on a loading screen, with the last note of the music looping on the AICA
 * because nothing reached it while the emulator waited. Replayed against the reads of 30,000
 * frames on a modelled drive, this and contiguous windows (below) cut the worst 30-frame stall
 * by 35-40 % and the total by 30-65 % across 300-1200 KB/s. */
#define DISC_FIRST  (16 * 1024)
enum { WIN_EMPTY, WIN_LOADING, WIN_READY };
typedef struct {
    int slot;   /* which file */
    int at;     /* file offset of the first byte */
    int size;   /* bytes asked for */
    int got;    /* bytes read; -1 after a failed read */
    int state;
} disc_win_t;
static uint8_t    g_winbuf[2][DISC_WINDOW] __attribute__((aligned(32)));
static disc_win_t g_win[2] = { { -1, 0, 0, 0, WIN_EMPTY }, { -1, 0, 0, 0, WIN_EMPTY } };
static int        g_ra_size = DISC_FIRST;   /* the next read-ahead's size; doubles while sequential */
static int        g_win_cur;            /* the window reads are served from; the other is next */
static int        g_io_request = -1;    /* a window for the I/O thread to fill, or -1 */
static mutex_t    g_io_lock = MUTEX_INITIALIZER;
static condvar_t  g_io_cv = COND_INITIALIZER;
static kthread_t* g_io_thread;

#if RECOMPSX_DC_PROFILE
static uint64_t g_prof_disc_us;
static uint32_t g_prof_disc_bytes;   /* fetched from the drive this window, read-ahead included */
static int      g_prof_reads, g_prof_misses;
#endif

/* ---- helpers --------------------------------------------------------------------------------- */

static int dir_exists(const char* path) {
    const file_t h = fs_open(path, O_RDONLY | O_DIR);
    if(h == FILEHND_INVALID) return 0;
    fs_close(h);
    return 1;
}

static int file_exists(const char* path) {
    FILE* f = fopen(path, "rb");
    if(!f) return 0;
    fclose(f);
    return 1;
}

/* Hands the AICA whatever has accumulated. Must be called often enough that the stream buffer
 * never runs dry — and it is called from the waiting paths too, because a frame spent waiting is
 * exactly when a stream left unattended would starve.
 *
 * Rate-limited, because the runtime's pacing asks `bp_audio_buffered` roughly six times a frame
 * (the SPU batches 128 samples at a time) and `snd_stream_poll` is not a cheap read — it walks
 * the AICA's play position and can copy and de-interleave a block. Polling cannot simply move to
 * `bp_present` either: a machine running at five frames a second would present five times a
 * second, and the buffer holds 93 ms. Four milliseconds is far below the half-buffer that decides
 * an underrun, and far above the rate the SPU asks at. */
static int g_hw_voices;   /* the AICA plays the SPU's voices; the stream carries the ones it declines */

static void pump_audio(void) {
    static uint64_t last_us;
    if(g_stream == SND_STREAM_INVALID) return;

    const uint64_t now = bp_time_us();
    if(now - last_us < 4000ull) return;
    last_us = now;

    snd_stream_poll(g_stream);
#if RECOMPSX_DC_PROFILE
    g_prof_audio += bp_time_us() - now;
    g_prof_polls++;
#endif
}

/* ---- the SPU's voices on the AICA (BP_CAP_SPU_VOICES, --audio-hw; ADR-0024) ----------------
 * The runtime's SPU keeps every state a game can read, as it does with no listener, and says
 * which voices sound, from where, at what pitch and how loud. Here each of its twenty-four voices
 * is an AICA channel. A sample is the PlayStation's ADPCM from where the voice starts to the
 * block that ends it, decoded once to 16-bit PCM with the SPU's own arithmetic and kept in sound
 * RAM, keyed by its start address; the loop point is found the way the SPU finds it, from the
 * block flags. Envelopes are the SPU's, arriving as volumes once a batch (every 2.9 ms), because
 * the AICA's own ADSR has other curves. What is heard is an approximation: no reverb, no noise
 * voices, no pitch modulation, and a loop's seam restarts the ADPCM filter from the first pass.
 * The mixing that cost 8 ms a vblank of SH-4 time is the AICA's now.
 *
 * A note the AICA cannot hold is declined at its key-on and the runtime mixes that one voice into
 * the ordinary stream, which therefore stays up. The case that forced it: Crash Bash's intro
 * cutscene streams its sound through two halves of sound RAM, each played as one ten-second note
 * of 220,528 samples, and an AICA channel's loop registers are sixteen bits. Cut at 65,534 the
 * cutscene went silent for seven seconds in every ten. */

#define SPU_RAM_BYTES   (512 * 1024)
#define SPU_VOICES      24
#define SPU_SAMPLES      192
#define SPU_SAMPLE_MAX    65534          /* an AICA channel's loop registers are sixteen bits */

typedef struct {
    int      start;       /* byte address in sound RAM; -1 for an empty slot */
    int      bytes;       /* sound RAM the decode read, for invalidation */
    uint32_t aica;        /* sound RAM address on the AICA side */
    int      len;         /* samples */
    int      loop_start;  /* sample index the end jumps back to */
    int      loops;
    int      stale;       /* the PlayStation RAM under it changed: never found again, freed when idle */
    int      refs;        /* voices playing it */
    uint32_t used_at;
} spu_samp_t;

static const uint8_t* g_spu_ram;
static spu_samp_t g_spu_samp[SPU_SAMPLES];
static uint32_t   g_spu_samp_clock;
static int        g_vchn[SPU_VOICES];
static int        g_vkey[SPU_VOICES];
static int        g_vsamp[SPU_VOICES];
static int        g_vvol[SPU_VOICES], g_vpan[SPU_VOICES], g_vfreq[SPU_VOICES];
static int16_t    g_spu_pcm[SPU_SAMPLE_MAX + 64] __attribute__((aligned(32)));
#if RECOMPSX_DC_PROFILE
static uint64_t   g_prof_aica;        /* decoding, uploading and commanding, inside `emu` */
static int        g_prof_aica_decodes;
static int        g_prof_aica_declined;
#endif

/* Blocks from `start` through the one that ends the sample, or -1 if none does within what a
 * channel holds: read from the flags alone, so a note that will be declined costs no decode. */
static int spu_sample_blocks(int start) {
    int at = start & (SPU_RAM_BYTES - 1);
    for(int b = 1; b * 28 <= SPU_SAMPLE_MAX; b++) {
        if(g_spu_ram[(at + 1) & (SPU_RAM_BYTES - 1)] & 0x01) return b;
        at = (at + 16) & (SPU_RAM_BYTES - 1);
    }
    return -1;
}

static inline int spu_sat16(int v) { return v > 32767 ? 32767 : (v < -32768 ? -32768 : v); }

/* The SPU's decode (Spu.decodeBlock) and its loop rule (Spu.advanceBlock), over a whole sample:
 * blocks from `start` until one carries the end flag, the most recent loop-start block (or the
 * start, as a key-on leaves the repeat address) being where a looping end goes back to. */
static int spu_decode(int start, int* len, int* loop_start, int* loops, int* bytes) {
    static const int f0[5] = { 0, 60, 115, 98, 122 };
    static const int f1[5] = { 0, 0, -52, -55, -60 };
    int at = start & (SPU_RAM_BYTES - 1);
    int old = 0, older = 0, n = 0, read = 0, loop_at = 0;
    *loops = 0;
    for(;;) {
        const int header = g_spu_ram[at];
        const int flags = g_spu_ram[(at + 1) & (SPU_RAM_BYTES - 1)];
        int shift = header & 0x0F;
        if(shift > 12) shift = 9;
        int f = (header >> 4) & 0x0F;
        if(f > 4) f = 4;
        if(flags & 0x04) loop_at = n;
        for(int i = 0; i < 28; i++) {
            const int byte = g_spu_ram[(at + 2 + (i >> 1)) & (SPU_RAM_BYTES - 1)];
            const int nib = (i & 1) == 0 ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
            const int t = ((nib > 7 ? nib - 16 : nib) << 12) >> shift;
            const int smp = spu_sat16(t + ((old * f0[f] + older * f1[f] + 32) >> 6));
            g_spu_pcm[n + i] = (int16_t)smp;
            older = old;
            old = smp;
        }
        n += 28;
        read += 16;
        if(flags & 0x01) { *loops = (flags & 0x02) != 0; break; }
        if(n + 28 > SPU_SAMPLE_MAX) break;           /* longer than a channel can hold: cut */
        at = (at + 16) & (SPU_RAM_BYTES - 1);
    }
    *len = n;
    *loop_start = loop_at;
    *bytes = read;
    return n;
}

static void spu_samp_release(int s) {
    if(s < 0) return;
    if(g_spu_samp[s].refs > 0) g_spu_samp[s].refs--;
    if(g_spu_samp[s].stale && g_spu_samp[s].refs == 0) {
        if(g_spu_samp[s].aica) snd_mem_free(g_spu_samp[s].aica);
        g_spu_samp[s].aica = 0;
        g_spu_samp[s].start = -1;
        g_spu_samp[s].stale = 0;
    }
}

/* Frees the least recently used idle sample; 0 if there was none to free. */
static int spu_evict_one(void) {
    int best = -1;
    for(int i = 0; i < SPU_SAMPLES; i++) {
        if(g_spu_samp[i].start < 0 || g_spu_samp[i].refs > 0) continue;
        if(best < 0 || g_spu_samp[i].used_at < g_spu_samp[best].used_at) best = i;
    }
    if(best < 0) return 0;
    if(g_spu_samp[best].aica) snd_mem_free(g_spu_samp[best].aica);
    g_spu_samp[best].aica = 0;
    g_spu_samp[best].start = -1;
    g_spu_samp[best].stale = 0;
    return 1;
}

/* The sample a voice starting at `start` plays: kept, or decoded and uploaded now. -1 when it
 * cannot be had: longer than a channel holds, or no sound RAM to put it in. */
static int spu_samp_for(int start) {
    for(int i = 0; i < SPU_SAMPLES; i++)
        if(g_spu_samp[i].start == start && !g_spu_samp[i].stale) {
            g_spu_samp[i].used_at = ++g_spu_samp_clock;
            return i;
        }
    if(spu_sample_blocks(start) < 0) return -1;
    int slot = -1;
    for(int i = 0; i < SPU_SAMPLES && slot < 0; i++) if(g_spu_samp[i].start < 0) slot = i;
    while(slot < 0) {
        if(!spu_evict_one()) return -1;
        for(int i = 0; i < SPU_SAMPLES && slot < 0; i++) if(g_spu_samp[i].start < 0) slot = i;
    }
    int len, loop_start, loops, bytes;
    spu_decode(start, &len, &loop_start, &loops, &bytes);
    const size_t size = ((size_t)len * 2 + 31) & ~(size_t)31;
    uint32_t mem = snd_mem_malloc(size);
    while(!mem) {
        if(!spu_evict_one()) return -1;
        mem = snd_mem_malloc(size);
    }
    spu_memload_sq(mem, g_spu_pcm, size);
#if RECOMPSX_DC_PROFILE
    g_prof_aica_decodes++;
#endif
    spu_samp_t* e = &g_spu_samp[slot];
    e->start = start; e->bytes = bytes; e->aica = mem; e->len = len;
    e->loop_start = loop_start; e->loops = loops; e->stale = 0; e->refs = 0;
    e->used_at = ++g_spu_samp_clock;
    return slot;
}

static void aica_chan(int chn, uint32_t what, uint32_t base, int len, int loops, int loop_start,
                      int freq, int vol, int pan) {
    AICA_CMDSTR_CHANNEL(tmp, cmd, chan);
    cmd->cmd = AICA_CMD_CHAN;
    cmd->timestamp = 0;
    cmd->size = AICA_CMDSTR_CHANNEL_SIZE;
    cmd->cmd_id = (uint32_t)chn;
    chan->cmd = what;
    chan->base = base;
    chan->type = AICA_SM_16BIT;
    chan->length = (uint32_t)len;
    chan->loop = (uint32_t)loops;
    chan->loopstart = (uint32_t)loop_start;
    chan->loopend = (uint32_t)len;
    chan->freq = (uint32_t)freq;
    chan->vol = (uint32_t)vol;
    chan->pan = (uint32_t)pan;
    snd_sh4_to_aica(tmp, cmd->size);
}

/* Silences and gives back every channel the voices hold; their samples go with the sound RAM
 * allocator when the sound system shuts down. */
static void spu_voices_off(void) {
    if(!g_hw_voices) return;
    for(int v = 0; v < SPU_VOICES; v++) {
        if(g_vchn[v] < 0) continue;
        snd_sfx_stop(g_vchn[v]);
        snd_sfx_chn_free(g_vchn[v]);
        g_vchn[v] = -1;
    }
    g_spu_ram = 0;
    g_hw_voices = 0;
}

void bp_spu_ram(const uint8_t* ram) {
    if(!g_snd_up || g_hw_voices) return;       /* no sound system, or already handed over */
    g_spu_ram = ram;
    for(int i = 0; i < SPU_SAMPLES; i++) { g_spu_samp[i].start = -1; g_spu_samp[i].aica = 0; g_spu_samp[i].refs = 0; }
    int got = 0;
    for(int v = 0; v < SPU_VOICES; v++) {
        g_vchn[v] = snd_sfx_chn_alloc();
        if(g_vchn[v] >= 0) got++;
        g_vkey[v] = -1; g_vsamp[v] = -1; g_vvol[v] = g_vpan[v] = g_vfreq[v] = -1;
    }
    /* The stream stays: it carries the voices declined at their key-on (see above), and is
     * silent the rest of the time. */
    g_hw_voices = 1;
    char msg[96];
    snprintf(msg, sizeof(msg), "audio: %d of %d SPU voices on AICA channels", got, SPU_VOICES);
    bp_log(got == SPU_VOICES ? BP_LOG_INFO : BP_LOG_WARN, msg);
}

void bp_spu_dirty(int addr, int len) {
    if(!g_spu_ram) return;
    for(int i = 0; i < SPU_SAMPLES; i++) {
        spu_samp_t* e = &g_spu_samp[i];
        if(e->start < 0 || e->stale) continue;
        if(e->start + e->bytes <= addr || addr + len <= e->start) continue;
        if(e->refs == 0) {
            if(e->aica) snd_mem_free(e->aica);
            e->aica = 0;
            e->start = -1;
        } else {
            e->stale = 1;
        }
    }
}

int bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r) {
    if(!g_spu_ram || v < 0 || v >= SPU_VOICES || g_vchn[v] < 0) return 0;
#if RECOMPSX_DC_PROFILE
    const uint64_t t0 = bp_time_us();
#endif
    const int chn = g_vchn[v];
    const int loud = vol_l > vol_r ? vol_l : vol_r;
    const int vol = loud >> 7;                                  /* 0..0x7FFF to 0..255 */
    const int pan = (vol_l + vol_r) > 0 ? (vol_r * 255) / (vol_l + vol_r) : 128;
    const int freq = (int)(((uint32_t)pitch * 44100u) >> 12);  /* 0x1000 is the recorded rate */

    if(on && key != g_vkey[v]) {
        g_vkey[v] = key;
        spu_samp_release(g_vsamp[v]);
        g_vsamp[v] = -1;
        const int s = spu_samp_for(start);
        if(s < 0) {
            /* Declined: the runtime mixes this note, and the channel falls silent for it. */
            snd_sfx_stop(chn);
#if RECOMPSX_DC_PROFILE
            g_prof_aica += bp_time_us() - t0;
            g_prof_aica_declined++;
#endif
            return 0;
        } else {
            g_spu_samp[s].refs++;
            g_vsamp[v] = s;
            aica_chan(chn, AICA_CH_CMD_START, g_spu_samp[s].aica, g_spu_samp[s].len, g_spu_samp[s].loops,
                      g_spu_samp[s].loop_start, freq, vol, pan);
            g_vvol[v] = vol; g_vpan[v] = pan; g_vfreq[v] = freq;
        }
    } else if(!on) {
        g_vkey[v] = key;
        if(g_vsamp[v] >= 0) {
            snd_sfx_stop(chn);
            spu_samp_release(g_vsamp[v]);
            g_vsamp[v] = -1;
        }
    } else if(g_vsamp[v] >= 0) {
        uint32_t what = 0;
        if(vol != g_vvol[v]) what |= AICA_CH_UPDATE_SET_VOL;
        if(pan != g_vpan[v]) what |= AICA_CH_UPDATE_SET_PAN;
        if(freq != g_vfreq[v]) what |= AICA_CH_UPDATE_SET_FREQ;
        if(what) {
            const spu_samp_t* e = &g_spu_samp[g_vsamp[v]];
            aica_chan(chn, AICA_CH_CMD_UPDATE | what, e->aica, e->len, e->loops, e->loop_start,
                      freq, vol, pan);
            g_vvol[v] = vol; g_vpan[v] = pan; g_vfreq[v] = freq;
        }
    }
#if RECOMPSX_DC_PROFILE
    g_prof_aica += bp_time_us() - t0;
#endif
    return 1;
}

static int ring_count(void) {
    const int n = g_ring_head - g_ring_tail;
    return n >= 0 ? n : n + RING_FRAMES;
}

/* The AICA asking for its next block. `req` is in bytes across both channels, interleaved, which
 * is the shape the emulator produces, so this is a copy and nothing more.
 *
 * A shortfall is filled with silence rather than reported: the stream keeps its cadence, and
 * silence is what an underrun sounds like anyway. */
static void* audio_pull(snd_stream_hnd_t hnd, int req, int* got) {
    (void)hnd;

    int want = req / 4;                          /* stereo frames */
    if(want > (int)(sizeof(g_pull) / 4)) want = (int)(sizeof(g_pull) / 4);

    int have = ring_count();
    if(have > want) have = want;

    for(int i = 0; i < have; i++) {
        g_pull[i * 2 + 0] = g_ring[g_ring_tail * 2 + 0];
        g_pull[i * 2 + 1] = g_ring[g_ring_tail * 2 + 1];
        g_ring_tail = (g_ring_tail + 1) % RING_FRAMES;
    }
    for(int i = have; i < want; i++) {
        g_pull[i * 2 + 0] = 0;
        g_pull[i * 2 + 1] = 0;
    }

    *got = want * 4;
    return g_pull;
}

/* ---- launch parameters -----------------------------------------------------------------------
 * A Dreamcast has no command line unless one is running under dcload, so the arguments arrive
 * the way the ABI says console arguments arrive: out of storage. One argument per line of a text
 * file, which keeps paths with spaces intact and needs no quoting rules. */

static void arg_add(const char* s) {
    if(g_argc >= MAX_ARGS || !s || !*s) return;
    snprintf(g_args[g_argc], ARG_LEN, "%s", s);
    g_argc++;
}

static int has_arg(const char* s) {
    for(int i = 0; i < g_argc; i++) if(strcmp(g_args[i], s) == 0) return 1;
    return 0;
}

/* What follows `prefix` in the first argument that starts with it (`--name=value`), or NULL. */
static const char* arg_value(const char* prefix) {
    const size_t n = strlen(prefix);
    for(int i = 0; i < g_argc; i++) if(strncmp(g_args[i], prefix, n) == 0) return g_args[i] + n;
    return NULL;
}

static int args_from_file(const char* path) {
    FILE* f = fopen(path, "rb");
    if(!f) return 0;

    char line[ARG_LEN];
    int  n = 0;
    while(g_argc < MAX_ARGS && fgets(line, sizeof(line), f)) {
        size_t len = strlen(line);
        while(len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r' || line[len - 1] == ' '))
            line[--len] = '\0';
        if(len == 0 || line[0] == '#') continue;
        arg_add(line);
        n++;
    }
    fclose(f);
    return n;
}

static void load_args(void) {
    if(g_argc > 0) return;    /* dcload passed a command line; it wins */

    static const char* candidates[] = {
        "/pc/recompsx.cfg", "/cd/RECOMPSX.CFG", "/cd/recompsx.cfg"
    };
    char msg[64];
    for(size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if(args_from_file(candidates[i]) > 0) {
            snprintf(msg, sizeof(msg), "launch parameters from %s", candidates[i]);
            bp_log(BP_LOG_INFO, msg);
            return;
        }
    }

    /* Nothing configured: assume the conventional names on the disc that booted us. ISO9660
     * level 1 stores them upper-case; a disc mastered with Joliet or Rock Ridge may not. */
    static const char* exes[]  = { "/cd/BOOT.EXE",  "/cd/boot.exe"  };
    static const char* discs[] = { "/cd/DISC.BIN",  "/cd/disc.bin"  };
    for(size_t i = 0; i < 2; i++) if(file_exists(exes[i]))  { arg_add(exes[i]);  break; }
    for(size_t i = 0; i < 2; i++) if(file_exists(discs[i])) { arg_add(discs[i]); break; }

    if(g_argc == 0)
        bp_log(BP_LOG_WARN, "no recompsx.cfg and no /cd/BOOT.EXE — nothing to run");
}

void bp_set_args(int argc, const char** argv) {
    g_argc = 0;
    for(int i = 0; i < argc; i++) arg_add(argv[i]);
}

int bp_arg_count(void) { return g_argc; }

const char* bp_arg(int index) {
    if(index < 0 || index >= g_argc) return NULL;
    return g_args[index];
}

/* ---- lifecycle ------------------------------------------------------------------------------- */

/* Where a save may go, in the order we would rather use them. /pc is the development machine
 * over dcload; /sd is a mass-storage card if the running build mounted one; /vmu/a1 is what a
 * console actually has in front of it. */
static void find_storage(void) {
    /* No trailing slashes: these are handed to fs_open as directories, and how tolerant a given
     * VFS is of "/pc/" versus "/pc" is not a question worth having an opinion about. */
    static const char* roots[] = { "/pc", "/sd", "/vmu/a1" };
    char msg[64];
    for(size_t i = 0; i < sizeof(roots) / sizeof(roots[0]); i++) {
        if(!dir_exists(roots[i])) continue;
        g_storage_root = roots[i];
        g_storage_is_vmu = (i == 2);
        snprintf(msg, sizeof(msg), "saves go to %s", roots[i]);
        bp_log(BP_LOG_INFO, msg);
        return;
    }
    bp_log(BP_LOG_WARN, "no writable storage found — saves will not persist");
}

/* The console's universal "put this down": A+B+X+Y+Start. The maple driver calls this from its
 * own interrupt, which is what makes it worth having on top of the same check in bp_input_poll —
 * the gesture keeps working during a long disc read, when nothing is polling pads at all. */
static void reset_combo(uint8_t addr, uint32_t btns) {
    (void)addr; (void)btns;
    g_quit = 1;
}

#if RECOMPSX_DC_PROFILE
/* ---- fastmem feasibility (`--dc-fastmem-test`) --------------------------------------------------
 * A measurement, not a feature. "Fastmem" would map the emulated RAM with the SH-4's MMU at the
 * PlayStation's own addresses, so a guest access becomes one masked load, and let the MMU's miss
 * exception catch the rare access that is a hardware register. On a real Dreamcast the MMU costs
 * nothing; under an emulator it may cost everything — Flycast can run MMU-enabled code on a slower
 * path — and the exception is the price of every register access. So before anything is built,
 * this measures, at boot, what each of those costs where the numbers are read:
 *
 *   base  a load from ordinary memory, MMU off
 *   on    the same load with the MMU on (it only translates P0; this is the emulator's tax)
 *   p0    a load through a static 64 KB P0 mapping of that memory (what fastmem would do)
 *   chk   the check-then-load the generated code does today, RAM case
 *   flt   one TLB-miss exception, handled by emulating the faulting `mov.l`
 *
 * in nanoseconds per access, plus whether the mapping read back what was written (`ok`/`BAD`:
 * an emulator without MMU translation reads whatever is at the physical address). The MMU is off
 * again before the game starts. */
#include <arch/mmu.h>
static char g_fm_line[48];
static volatile uint32_t g_fm_faults;

static void fm_miss_read(irq_t code, irq_context_t* cx, void* data) {
    (void)code; (void)data;
    const uint16_t op = *(const uint16_t*)cx->pc;     /* mov.l @Rm,Rn: 0110nnnnmmmm0010 */
    cx->r[(op >> 8) & 15] = 0x5A5A5A5Au;
    cx->pc += 2;
    g_fm_faults++;
}

/* Today's fast path, as the generated code has it inline: RAM, else scratchpad, else a call. */
static uint32_t g_fm_ram_base;
__attribute__((noinline)) static uint32_t fm_slow(uint32_t a) { return a; }
static inline uint32_t fm_checked(uint32_t a) {
    const uint32_t p = a & 0x1FFFFFFFu;
    if((p & 0x1F9FFFFFu) < 0x200000u) return *(volatile uint32_t*)(g_fm_ram_base + (p & 0x1FFFFCu));
    else if((p & 0x1FFFFC00u) == 0x1F800000u) return *(volatile uint32_t*)(g_fm_ram_base + (p & 0x3FCu));
    else return fm_slow(p);
}

static void fastmem_test(void) {
    enum { N = 1 << 18, FAULTS = 4096 };
    uint32_t* buf = (uint32_t*)memalign(65536, 65536);
    if(!buf) { snprintf(g_fm_line, sizeof(g_fm_line), "fm: no aligned 64K"); return; }
    for(int i = 0; i < 16384; i++) buf[i] = 0x1000u + (uint32_t)i;
    g_fm_ram_base = (uint32_t)(uintptr_t)buf;
    uint32_t sink = 0;
    uint64_t t0, t[5];

#define FM_LOOP(expr) do { t0 = bp_time_us(); \
        for(int i = 0; i < N; i++) { const uint32_t o = (uint32_t)(i * 4) & 0xFFFCu; sink += (expr); } } while(0)

    FM_LOOP(*(volatile uint32_t*)((uintptr_t)buf + o));
    t[0] = bp_time_us() - t0;

    mmu_init_basic();
    const uintptr_t virt = 0x00100000u;
    const int mapped = mmu_page_map_static(virt, (uintptr_t)buf & 0x1FFFFFFFu, PAGE_SIZE_64K,
                                           MMU_ALL_RDWR, true);
    FM_LOOP(*(volatile uint32_t*)((uintptr_t)buf + o));
    t[1] = bp_time_us() - t0;
    FM_LOOP(*(volatile uint32_t*)(virt + o));
    t[2] = bp_time_us() - t0;
    int ok = mapped == 0;
    for(int i = 0; i < 16384 && ok; i += 97) ok = ((volatile uint32_t*)virt)[i] == 0x1000u + (uint32_t)i;
    FM_LOOP(fm_checked(0x80000000u + o));
    t[3] = bp_time_us() - t0;

    irq_set_handler(EXC_DTLB_MISS_READ, fm_miss_read, NULL);
    g_fm_faults = 0;
    t0 = bp_time_us();
    for(int i = 0; i < FAULTS; i++) {
        uint32_t v;
        __asm__ __volatile__("mov.l @%1,%0" : "=r"(v) : "r"(0x00800000u) : "memory");
        sink += v;
    }
    t[4] = bp_time_us() - t0;
    irq_set_handler(EXC_DTLB_MISS_READ, NULL, NULL);
    mmu_shutdown_basic();
#undef FM_LOOP

    free(buf);
    /* Nanoseconds per access; the fault in whole nanoseconds. */
    unsigned long ns[4];
    for(int i = 0; i < 4; i++) ns[i] = (unsigned long)(t[i] * 1000u * 10u / N);   /* tenths */
    snprintf(g_fm_line, sizeof(g_fm_line), "fm %lu.%lu %lu.%lu %lu.%lu %lu.%lu f%lu %s%s",
             ns[0] / 10, ns[0] % 10, ns[1] / 10, ns[1] % 10, ns[2] / 10, ns[2] % 10,
             ns[3] / 10, ns[3] % 10, (unsigned long)(t[4] * 1000u / FAULTS),
             ok ? "ok" : "BAD", g_fm_faults == FAULTS ? "" : "!");
    char msg[128];
    snprintf(msg, sizeof(msg), "fastmem test (ns/access: base on p0 chk, fault): %s (sink %lu)",
             g_fm_line, (unsigned long)sink);
    bp_log(BP_LOG_WARN, msg);
}
#endif

int bp_init(const char* title) {
    (void)title;

    /* Idempotent on purpose. On a console the entry point must bring the platform up before the
     * program starts — there is no window server to do it lazily — and the runtime's own
     * skeleton also calls this on its way in. Bringing the PVR up twice fails; noticing that we
     * are already up costs nothing. */
    if(g_inited) return 0;
    g_inited = 1;

    /* A 2D mode has to exist before the PVR will initialise. 640x480 is what the tile
     * accelerator wants and what every cable can show: with a VGA box this is 60 Hz progressive,
     * on composite or RGB it is the interlaced television mode, and vid_set_mode picks between
     * them by looking at what is plugged in. */
    vid_set_mode(DM_640x480, PM_RGB565);

    /* Three lists, not the default two: opaque, translucent, and punch-through — the last is what
     * makes a texel the PlayStation calls "nothing" actually disappear, rather than being drawn as
     * black. Autosorting is off because the order is not ours to choose: a PlayStation draws in
     * submission order and the Z values built in build_scene encode exactly that. */
    /* The vertex buffer is sized to the command buffer, not to a habit. A triangle costs one
     * 32-byte header plus three 32-byte vertices, so 12,288 primitives need about 1.5 MB — and a
     * scene that overruns this is not reported by anything, it simply loses its last polygons.
     * That is what "most of the model, and one arm missing" looks like from the inside.
     *
     * But it is bought from the same 8 MB the textures live in, and **KOS allocates the vertex
     * buffer twice** — one being filled while the other renders — so this number costs double.
     * Asking for 1.5 MB here once cost 3 MB, pushed the total to 9 MB on an 8 MB machine, and
     * left a third of the texture slots unallocated: the model came back wearing garbage.
     * The budget, honestly: framebuffers 1.17 + vertex 2x0.75 + OPB 0.44 + textures 2 + the
     * framebuffer blit 1 = 6.99 MB with the object pointer buffers at 1.32, and the count below
     * is checked rather than assumed. */
    pvr_init_params_t params = {
        /* The object pointer buffers are per 32x32 screen tile, and a tile that runs out drops
         * the geometry that would not fit — silently, and only where the picture is busy. A
         * character model occupying a third of the screen puts hundreds of polygons into a
         * handful of tiles while the background puts one into each of the rest, which is why the
         * missing surfaces were all on the model and never on the backdrop. Doubled, with five
         * overflow blocks rather than three; the budget below is checked, not hoped for. */
        /* 32-word tile bins. Dense geometry — a character model filling a handful of tiles —
         * overflows a 16-word bin and the accelerator drops what did not fit, silently and
         * exactly where the picture is busiest, which is what "the mouth is missing, now the
         * leg" looks like. Tried once before, untestable then: the slot-conflict corruption was
         * sitting on top of everything. Texture budget: two pools, floor-checked at arming time rather than promised here. */
        /* ONE list — translucent, autosort off — because that is what a PlayStation is: a
         * painter's-algorithm machine, later-submitted wins, no depth anywhere. The previous
         * design split submission order across three hardware lists and rebuilt it with a
         * per-primitive depth ramp; surfaces of the character model went missing under it and
         * survived every other fix, which is exactly what a cross-list depth subtlety looks
         * like. This shape has no depth to be subtle about: submission order in, submission
         * order out. Opacity is a blend mode (ONE/ZERO), texel transparency is alpha reaching
         * a blend that keeps the destination — no punch-through list, no alpha threshold. */
        .opb_sizes = { PVR_BINSIZE_0, PVR_BINSIZE_0, PVR_BINSIZE_32, PVR_BINSIZE_0,
                       PVR_BINSIZE_0 },
        .vertex_buf_size = 768 * 1024,
        .dma_enabled = 0,
        .fsaa_enabled = 0,
        .autosort_disabled = 1,
        .opb_overflow_count = 3
    };
    if(pvr_init(&params) < 0) {
        bp_log(BP_LOG_ERROR, "pvr_init failed");
        return 1;
    }
    pvr_set_bg_color(0.0f, 0.0f, 0.0f);
    /* Punch-through keeps a pixel only if its alpha clears this. Texels decode to alpha 0 or 255,
     * so anything off the floor separates them. */
    PVR_SET(PVR_PT_ALPHA_REF, 0x20);
    /* Palette RAM holds ARGB1555, matching the page decode; set once, format is global. */
    pvr_set_pal_format(PVR_PAL_ARGB1555);

    g_txr = pvr_mem_malloc(TXR_MAX_W * TXR_MAX_H * 2);
    if(!g_txr) {
        bp_log(BP_LOG_ERROR, "no PVR memory for the framebuffer texture");
        return 2;
    }
    g_ready = 1;
#if RECOMPSX_DC_PROFILE
    g_emu_thread = thd_get_current();        /* bp_init runs on the thread that emulates */
    samp_start();
#endif
    twid_init();

    if(snd_stream_init() == 0) {
        g_snd_up = 1;
        g_stream = snd_stream_alloc(audio_pull, STREAM_BYTES_PER_CHANNEL);
        if(g_stream != SND_STREAM_INVALID) {
            snd_stream_volume(g_stream, 255);
            snd_stream_start(g_stream, 44100, 1);
        } else {
            bp_log(BP_LOG_WARN, "no sound stream available");
        }
    } else {
        bp_log(BP_LOG_WARN, "snd_stream_init failed — running silent");
    }

    cont_btn_callback(0, CONT_RESET_BUTTONS, reset_combo);

    find_storage();
    load_args();

#if RECOMPSX_DC_PROFILE
    if(has_arg("--dc-fastmem-test")) fastmem_test();
    else {}
    g_rxprof = has_arg("--dc-rxprof");
    {
        const char* b = arg_value("--dc-bench=");
        int from, to;
        if(b && sscanf(b, "%d:%d", &from, &to) == 2 && from >= 0 && to > from) {
            g_bench_from = from;
            g_bench_to = to;
        } else if(b) {
            bp_log(BP_LOG_WARN, "--dc-bench=FROM:TO wants two present counts, FROM below TO");
        } else {}
    }
#endif

#if RECOMPSX_DC_PROFILE_OVERLAY
    /* After the arguments, because they are what asks for it. */
    if(has_arg("--dc-overlay")) {
        g_txt = pvr_mem_malloc(TXT_W * TXT_H * 2);
        if(g_txt) {
            pvr_poly_cxt_t tc;
            pvr_poly_cxt_txr(&tc, PVR_LIST_TR_POLY,
                             PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_NONTWIDDLED,
                             TXT_W, TXT_H, g_txt, PVR_FILTER_NONE);
            tc.gen.culling = PVR_CULLING_NONE;
            tc.txr.uv_clamp = PVR_UVCLAMP_UV;
            tc.txr.env = PVR_TXRENV_REPLACE;
            pvr_poly_compile(&g_txt_hdr, &tc);
            bp_log(BP_LOG_INFO, "profile overlay on");
#if RECOMPSX_DC_PROFILE
            syms_load();
#endif
        } else {
            bp_log(BP_LOG_WARN, "--dc-overlay: no PVR memory for the text texture");
        }
    }
#endif
    return 0;
}

void bp_shutdown(void) {
    for(int i = 0; i < MAX_FILES; i++) bp_file_close(i);

    if(g_stream != SND_STREAM_INVALID) {
        snd_stream_stop(g_stream);
        snd_stream_destroy(g_stream);
        g_stream = SND_STREAM_INVALID;
    }
    spu_voices_off();
    if(g_snd_up) { snd_stream_shutdown(); g_snd_up = 0; }

    if(g_ready) {
        if(g_txr) { pvr_mem_free(g_txr); g_txr = NULL; }
        pvr_shutdown();
        g_ready = 0;
    }
    g_inited = 0;
}

int bp_caps(int cap_id) {
    switch(cap_id) {
        case BP_CAP_MAX_PADS:        return MAX_PADS;
        case BP_CAP_HAS_AUDIO:       return g_stream != SND_STREAM_INVALID;
        case BP_CAP_HAS_STORAGE:     return g_storage_root != NULL;
        case BP_CAP_PREFERRED_SCALE: return 2;
        /* This machine has a rasteriser of its own and would rather use it. Whether the runtime
         * takes the offer is the host's decision, not ours — see --video-hw and ADR-0011. */
        case BP_CAP_GPU_DRAW:        return 1;
        /* And a sampler of its own: the AICA plays the SPU's voices (--audio-hw, ADR-0024). */
        case BP_CAP_SPU_VOICES:      return g_snd_up;
        default:                     return 0;
    }
}

/* ---- video ------------------------------------------------------------------------------------
 * The PS1 draws into a 1024x512 sheet of BGR555 and shows a rectangle of it. The PowerVR can
 * sample ARGB1555 directly, and the two formats differ only by which end of the halfword holds
 * red — so a frame costs one shift-and-or per pixel and no colour is lost. Bit 15 is the PS1's
 * mask bit, not an alpha, and it stays harmless because the quad goes in the opaque list where
 * the hardware never looks at alpha.
 *
 * Scaling is the hardware's problem: the emulated rectangle becomes a textured quad covering the
 * screen. Every PS1 horizontal resolution occupies the same physical width on a television, so
 * that quad is 4:3 whatever the game chose, and 640x480 is 4:3 — no letterboxing arithmetic, and
 * no per-pixel scaling on a 200 MHz CPU that has an emulator to run. */

/* The next power of two at or above `v`, never below 32. The floor is not about the PVR, which
 * is happy from 8 pixels up — it is about the store queues: a row of the texture must be a whole
 * number of 32-byte transfers, and 32 pixels at 16 bpp is the first width that is. */
static int pot(int v, int max) {
    int p = 32;
    while(p < v && p < max) p <<= 1;
    return p;
}

/* Slot k's texture: the k-th whole texture of the declared size inside g_txr. */
static pvr_ptr_t bg_mem(int k) {
    return (pvr_ptr_t)((uint8_t*)g_txr + (size_t)k * (size_t)g_txw * (size_t)g_txh * 2);
}

static void declare_texture(int w, int h) {
    if(w == g_txw && h == g_txh) return;
    g_txw = w;
    g_txh = h;
    g_bg_slots = (TXR_MAX_W * TXR_MAX_H) / (w * h);
    if(g_bg_slots > BG_SLOTS) g_bg_slots = BG_SLOTS;
    else {}
    for(int k = 0; k < BG_SLOTS; k++) g_bgs[k].valid = 0;

    pvr_poly_cxt_t cxt;
    /* The scene has exactly one hardware list — translucent, submission-ordered — so this header
     * must be compiled for it. It was compiled for the opaque list once, which no longer exists:
     * a header naming a disabled list wedges the tile accelerator mid-scene, the scene never
     * finishes, and the next wait-for-ready blocks forever. That was a black screen at boot,
     * because the boot screens are exactly the zero-primitive path that leads with this header. */
    pvr_poly_cxt_txr(&cxt, PVR_LIST_TR_POLY,
                     PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_NONTWIDDLED,
                     w, h, bg_mem(0), RECOMPSX_DC_FILTER);
    cxt.blend.src = PVR_BLEND_ONE;
    cxt.blend.dst = PVR_BLEND_ZERO;
    cxt.depth.comparison = PVR_DEPTHCMP_ALWAYS;
    cxt.depth.write = false;
    /* The quad is drawn front-facing by construction, but saying so costs nothing and a culled
     * frame is an invisible bug. */
    cxt.gen.culling = PVR_CULLING_NONE;
    /* The used area of the texture is a corner of it, so a bilinear tap at the right or bottom
     * edge would otherwise reach into whatever the last mode left behind. */
    cxt.txr.uv_clamp = PVR_UVCLAMP_UV;
    /* The texture is the picture; there is no vertex colour to modulate it with. */
    cxt.txr.env = PVR_TXRENV_REPLACE;
    /* One header per slot, the same but for where its texture starts. */
    for(int k = 0; k < g_bg_slots; k++) {
        cxt.txr.base = bg_mem(k);
        pvr_poly_compile(&g_bg_hdr[k], &cxt);
    }
    g_hdr = g_bg_hdr[0];
}

/* The slot holding this rectangle as it is now, or the one to upload it into: an empty slot
 * first, else the least recently used. Any may be overwritten — present_frame has waited for the
 * PVR to finish the previous scene before it asks. */
static int bg_slot(int x, int y, int w, int h, int d24) {
    int empty = -1, lru = -1;
    for(int k = 0; k < g_bg_slots; k++) {
        const gbg_t* b = &g_bgs[k];
        if(!b->valid) {
            if(empty < 0) empty = k;
            else {}
            continue;
        } else {}
        if(b->x == x && b->y == y && b->w == w && b->h == h && b->d24 == d24) return k;
        else {}
        if(lru < 0 || b->used < g_bgs[lru].used) lru = k;
        else {}
    }
    return empty >= 0 ? empty : lru;
}

/* BGR555 to ARGB1555 is red and blue exchanged, green in place and bit 15 dropped (the quad
 * replaces, so alpha is never read). Done two texels to a 32-bit word and written straight into
 * the store queues, eight words a flush: one pass over the row. It used to be a 16-bit loop
 * into a staging line and then a second pass to copy that line out, about 11 ms for a 512x240
 * picture — and the picture is uploaded at every buffer flip of every menu. */
static inline uint32_t bgr555x2_to_argb1555x2(uint32_t p) {
    return (p & 0x03E003E0u) | ((p & 0x001F001Fu) << 10) | ((p >> 10) & 0x001F001Fu);
}

static void upload_15bpp(const uint16_t* vram, int sx, int sy, int sw, int sh, pvr_ptr_t base) {
    const int row_bytes = (sw * 2 + 31) & ~31;
    const int row_words = row_bytes >> 2;
    uint8_t* dst = (uint8_t*)base;
    const uintptr_t tex = ((uintptr_t)base & 0xffffff) | PVR_TA_TEX_MEM;
    /* The fast path reads whole words up to the store-queue boundary, so the row must start on a
     * word and the words it reads must still be inside this row of VRAM. */
    const int fast = (sx & 1) == 0 && sx + row_words * 2 <= VRAM_W;

    for(int y = 0; y < sh; y++) {
        const uint16_t* src = vram + (size_t)((sy + y) & (VRAM_H - 1)) * VRAM_W;
        if(fast) {
            const uint32_t* s32 = (const uint32_t*)(const void*)(src + sx);
            uint32_t* d = sq_lock((void*)(tex + (size_t)y * g_txw * 2));
            for(int w = 0; w < row_words; w += 8) {
                d[0] = bgr555x2_to_argb1555x2(s32[w]);
                d[1] = bgr555x2_to_argb1555x2(s32[w + 1]);
                d[2] = bgr555x2_to_argb1555x2(s32[w + 2]);
                d[3] = bgr555x2_to_argb1555x2(s32[w + 3]);
                d[4] = bgr555x2_to_argb1555x2(s32[w + 4]);
                d[5] = bgr555x2_to_argb1555x2(s32[w + 5]);
                d[6] = bgr555x2_to_argb1555x2(s32[w + 6]);
                d[7] = bgr555x2_to_argb1555x2(s32[w + 7]);
                sq_flush(d);
                d += 8;
            }
            sq_unlock();
        } else {
            for(int x = 0; x < sw; x++) {
                const uint16_t p = src[(sx + x) & (VRAM_W - 1)];
                g_line[x] = (uint16_t)((p & 0x03E0u) | ((p & 0x001Fu) << 10) | ((p >> 10) & 0x001Fu));
            }
            pvr_txr_load(g_line, (pvr_ptr_t)(dst + (size_t)y * g_txw * 2), row_bytes);
        }
    }
    if(fast) sq_wait();
}

/* 24bpp is how the PS1 shows MDEC video: the row is packed RGB888 starting at byte offset sx*2,
 * and the display hardware simply reinterprets the same memory. Nine bits per pixel are dropped
 * on the way to 15bpp, which is what the console's own output did to them too. */
static void upload_24bpp(const uint16_t* vram, int sx, int sy, int sw, int sh, pvr_ptr_t base) {
    const int row_bytes = (sw * 2 + 31) & ~31;
    uint8_t* dst = (uint8_t*)base;

    for(int y = 0; y < sh; y++) {
        const uint8_t* src = (const uint8_t*)(vram + (size_t)((sy + y) & (VRAM_H - 1)) * VRAM_W)
                           + (size_t)sx * 2;
        for(int x = 0; x < sw; x++) {
            g_line[x] = (uint16_t)(((src[0] >> 3) << 10) | ((src[1] >> 3) << 5) | (src[2] >> 3));
            src += 3;
        }
        pvr_txr_load(g_line, (pvr_ptr_t)(dst + (size_t)y * g_txw * 2), row_bytes);
    }
}

static void draw_quad(int sw, int sh) {
    const float u1 = 0.0f, v1 = 0.0f;
    const float u2 = (float)sw / (float)g_txw;
    const float v2 = (float)sh / (float)g_txh;
    const float x1 = 0.0f, y1 = 0.0f, x2 = 640.0f, y2 = 480.0f;

    pvr_vertex_t vert;
    vert.flags = PVR_CMD_VERTEX;
    vert.argb  = 0xFFFFFFFFu;
    vert.oargb = 0;
    vert.z     = 1.0f;

    vert.x = x1; vert.y = y1; vert.u = u1; vert.v = v1; pvr_prim(&vert, sizeof(vert));
    vert.x = x2; vert.y = y1; vert.u = u2; vert.v = v1; pvr_prim(&vert, sizeof(vert));
    vert.x = x1; vert.y = y2; vert.u = u1; vert.v = v2; pvr_prim(&vert, sizeof(vert));
    vert.flags = PVR_CMD_VERTEX_EOL;
    vert.x = x2; vert.y = y2; vert.u = u2; vert.v = v2; pvr_prim(&vert, sizeof(vert));
}

/* ---- where the frame went ---------------------------------------------------------------------
 * A frame rate that is the same on a still title card and on a spinning character model is not a
 * frame rate set by how much work the emulated machine is doing — it is set by something that
 * costs the same every frame, and everything of that shape lives in this file. So this file is
 * what has to answer for itself.
 *
 * Four numbers, one line every 30 presents: the time NOT inside bp_present (which is the emulator
 * proper, plus everything else the runtime does), and the three phases inside it. Whichever is
 * largest is where to work next, and the answer is no longer a guess. */

#if RECOMPSX_DC_PROFILE
static uint64_t g_prof_emu, g_prof_wait, g_prof_upload, g_prof_submit, g_prof_end;
static uint64_t g_prof_pace;   /* held back to the video rate: not work, but part of the frame */


/* The SH-4's own performance counters, aimed at the one window that matters: everything between
 * the end of one present and the start of the next, which is the emulated frame.
 *
 * They are here because guessing has already cost this project two rounds. Removing a quarter of
 * .text measured nothing on the console, which is only explicable if instruction COUNT is not
 * what the machine is short of — and the candidates that remain (instruction cache, data cache,
 * branches, load-use interlocks) are indistinguishable from the disassembly and trivially
 * distinguishable from these registers. One counter, rotating through the modes a few seconds
 * apiece; cycles come from the wall clock at 200 MHz, so PRFC0 stays untouched for KOS. */
static const struct { perf_cntr_event_t ev; const char* name; uint8_t is_cycles; } g_pc_modes[] = {
    { PMCR_INSTRUCTION_ISSUED_MODE,              "instructions issued",   0 },
    { PMCR_PIPELINE_FREEZE_BY_ICACHE_MISS_MODE,  "stall: I-cache",        1 },
    { PMCR_PIPELINE_FREEZE_BY_DCACHE_MISS_MODE,  "stall: D-cache",        1 },
    { PMCR_PIPELINE_FREEZE_BY_BRANCH_MODE,       "stall: branch",         1 },
    { PMCR_PIPELINE_FREEZE_BY_CPU_REGISTER_MODE, "stall: load-use",       1 },
    { PMCR_INSTRUCTION_CACHE_MISS_MODE,          "I-cache misses",        0 },
    { PMCR_OPERAND_CACHE_MISS_MODE,              "D-cache misses",        0 },
    { PMCR_SUBROUTINE_ISSUED_MODE,               "calls issued",          0 },
};
#define PC_MODES   ((int)(sizeof(g_pc_modes) / sizeof(g_pc_modes[0])))
#define PC_WINDOW  60
static int      g_pc_mode, g_pc_frames, g_pc_armed;
static uint64_t g_pc_total, g_pc_us;

static void perf_window_close(uint64_t emu_us) {
    if(!g_pc_armed) return;
    g_pc_total += perf_cntr_count(PRFC1);
    g_pc_us += emu_us;
    if(++g_pc_frames < PC_WINDOW) return;

    /* A counter that stayed at zero across a whole window of real work is not measuring; it is
     * absent. Flycast does not implement the SH-4's performance registers, so the honest move is
     * to say it once and stop printing rows of zeroes that look like findings. */
    if(g_pc_total == 0) {
        static int said;
        if(!said) {
            said = 1;
            bp_log(BP_LOG_WARN,
                   "perf: SH-4 counters read zero — not implemented here (emulator); "
                   "PC sampling below is the measurement that works");
        } else {}
        g_pc_armed = 0;
        return;
    } else {}

    /* 200 MHz, so a microsecond of emulated frame is two hundred cycles. Percentages are of the
     * frame's whole cycle budget, which is what makes them comparable across modes. */
    const uint64_t cycles = g_pc_us * 200ull;
    const unsigned long per_frame = (unsigned long)(g_pc_total / (uint64_t)g_pc_frames);
    const unsigned long cyc_frame = (unsigned long)(cycles / (uint64_t)g_pc_frames);
    char msg[144];
    if(g_pc_modes[g_pc_mode].is_cycles)
        snprintf(msg, sizeof(msg), "perf: %-20s %10lu /frame = %2lu%% of %lu cycles",
                 g_pc_modes[g_pc_mode].name, per_frame,
                 cycles ? (unsigned long)(g_pc_total * 100ull / cycles) : 0ul, cyc_frame);
    else if(g_pc_mode == 0)
        snprintf(msg, sizeof(msg), "perf: %-20s %10lu /frame, IPC %lu.%02lu of %lu cycles",
                 g_pc_modes[g_pc_mode].name, per_frame,
                 cycles ? (unsigned long)(g_pc_total / cycles) : 0ul,
                 cycles ? (unsigned long)((g_pc_total * 100ull / cycles) % 100ull) : 0ul, cyc_frame);
    else
        snprintf(msg, sizeof(msg), "perf: %-20s %10lu /frame (%lu cycles/frame)",
                 g_pc_modes[g_pc_mode].name, per_frame, cyc_frame);
    bp_log(BP_LOG_INFO, msg);

    g_pc_mode = (g_pc_mode + 1) % PC_MODES;
    g_pc_frames = 0;
    g_pc_total = 0;
    g_pc_us = 0;
}

/* Where the time actually goes, sampled rather than reasoned about.
 *
 * The SH-4's performance counters answer this exactly — and read zero under Flycast, which does
 * not implement them, so on the machine this project is actually tested on they answer nothing.
 * A timer interrupt does work anywhere: TMU1 is documented free (TMU0 is the scheduler's, TMU2
 * backs every gettime function), it fires a thousand times a second, and the handler is handed
 * the interrupted context. Bucket its PC and after a minute the histogram names the hot code
 * without a single assumption about caches, expansion factors or instruction counts.
 *
 * Addresses are reported raw, at 1 KB granularity, and resolved off-device against the ELF —
 * carrying a symbol table on the disc to print names would change what is being measured. */
/* 128-byte granules, not kilobyte ones: at a kilobyte the hottest bucket held a KOS idle task,
 * a stack tracer and a dozen syscall thunks at once, and no amount of staring could say which of
 * them was burning fourteen percent. A granule has to be smaller than the functions it means to
 * name. */
#define SAMP_SLOTS 1024
#define SAMP_GRAN  7
static uint32_t g_samp_key[SAMP_SLOTS], g_samp_hit[SAMP_SLOTS];
static uint32_t g_samp_total, g_samp_lost, g_samp_frames;

/* Function names for the overlay, from SYMS.BIN (scripts/dc-syms.py, written by build-dc.sh):
 * each sample's PC is looked up here, in the interrupt, and the overlay prints the functions with
 * the most samples in the window — a sample is a millisecond, as everywhere else. Loaded once at
 * init and only with the overlay on; without the file the overlay says so and nothing is counted.
 * A file from another build is refused by its anchor, samp_tick's own address. */
#define SYM_NAME 12
static uint32_t*          g_sym_range;          /* count x (start, end), sorted */
static char             (*g_sym_name)[SYM_NAME];
static volatile uint32_t* g_sym_hits;           /* samples per function this window */
static volatile int       g_sym_count;          /* set last: the interrupt reads it */
static volatile uint32_t  g_sym_other;          /* samples in no listed function */
static const char*        g_sym_state = "no SYMS.BIN on the disc";

static void samp_tick(irq_t code, irq_context_t* ctx, void* data);

static void syms_load(void) {
    static const char* paths[] = { "/pc/SYMS.BIN", "/cd/SYMS.BIN", "/cd/syms.bin" };
    FILE* f = NULL;
    for(size_t i = 0; i < sizeof(paths) / sizeof(paths[0]) && !f; i++) f = fopen(paths[i], "rb");
    if(!f) { bp_log(BP_LOG_INFO, "syms: no SYMS.BIN — the overlay profile is off"); return; }
    uint8_t head[12];
    uint32_t count = 0, anchor = 0;
    if(fread(head, 1, sizeof(head), f) == sizeof(head) && memcmp(head, "RSY1", 4) == 0) {
        memcpy(&count, head + 4, 4);
        memcpy(&anchor, head + 8, 4);
    } else {}
    if(count == 0 || count > 16384) {
        g_sym_state = "SYMS.BIN unreadable";
    } else if(anchor != (uint32_t)(uintptr_t)samp_tick) {
        g_sym_state = "SYMS.BIN is from another build";
    } else {
        uint32_t* range = malloc(count * 8u);
        char (*name)[SYM_NAME] = malloc(count * (size_t)SYM_NAME);
        uint32_t* hits = calloc(count, 4u);
        if(range && name && hits && fread(range, 8, count, f) == count
           && fread(name, SYM_NAME, count, f) == count) {
            for(uint32_t i = 0; i < count; i++) name[i][SYM_NAME - 1] = '\0';
            g_sym_range = range;
            g_sym_name = name;
            g_sym_hits = hits;
            g_sym_count = (int)count;
            g_sym_state = NULL;
        } else {
            free(range); free(name); free(hits);
            g_sym_state = "SYMS.BIN unreadable";
        }
    }
    fclose(f);
    char msg[80];
    snprintf(msg, sizeof(msg), "syms: %s", g_sym_state ? g_sym_state : "function names loaded");
    bp_log(g_sym_state ? BP_LOG_WARN : BP_LOG_INFO, msg);
}

/* The function holding `pc`, or -1. Binary search, in the interrupt: a dozen steps a millisecond. */
static int sym_find(uint32_t pc) {
    int lo = 0, hi = g_sym_count - 1;
    while(lo <= hi) {
        const int mid = (lo + hi) >> 1;
        if(pc < g_sym_range[mid * 2]) hi = mid - 1;
        else if(pc >= g_sym_range[mid * 2 + 1]) lo = mid + 1;
        else return mid;
    }
    return -1;
}

/* The two overlay lines: the six functions with the most samples in the window, three a line,
 * then the window's counts are cleared. */
static void syms_top(char* a, char* b, size_t len) {
    if(g_sym_count <= 0) {
        snprintf(a, len, "prof: %s", g_sym_state ? g_sym_state : "-");
        b[0] = '\0';
        return;
    }
    int top[6];
    for(int k = 0; k < 6; k++) {
        top[k] = -1;
        for(int i = 0; i < g_sym_count; i++) {
            int taken = 0;
            for(int j = 0; j < k; j++) if(top[j] == i) taken = 1;
            if(!taken && g_sym_hits[i] > 0 && (top[k] < 0 || g_sym_hits[i] > g_sym_hits[top[k]])) top[k] = i;
        }
    }
    char* out[2] = { a, b };
    for(int line = 0; line < 2; line++) {
        int n = 0;
        out[line][0] = '\0';
        for(int k = line * 3; k < line * 3 + 3; k++) {
            if(top[k] < 0) break;
            n += snprintf(out[line] + n, len - (size_t)n, "%-10.10s%3lu ",
                          g_sym_name[top[k]], (unsigned long)g_sym_hits[top[k]]);
            if(n >= (int)len) break;
        }
    }
    for(int i = 0; i < g_sym_count; i++) g_sym_hits[i] = 0;
    g_sym_other = 0;
}

static void samp_tick(irq_t code, irq_context_t* ctx, void* data) {
    (void)code; (void)data;
    /* Acknowledge FIRST and unconditionally. An SH-4 timer holds its underflow flag until
     * software clears it, so a handler that returns without clearing is re-entered immediately,
     * forever: the machine stops making progress and the symptom is simply "it does not boot".
     * KOS's own millisecond handler clears the same bit for the same reason. */
    timer_clear(TMU1);
    const int where = g_where;
    if(where >= 0 && thd_get_current() == g_emu_thread) g_samp_where[where]++;
    if(g_sym_count > 0) {
        const int fn = sym_find(CONTEXT_PC(*ctx));
        if(fn >= 0) g_sym_hits[fn]++;
        else g_sym_other++;
    } else {}
    const uint32_t k = CONTEXT_PC(*ctx) >> SAMP_GRAN;
    const uint32_t h = (k * 2654435761u) & (SAMP_SLOTS - 1);
    for(int i = 0; i < 8; i++) {
        const uint32_t c = (h + (uint32_t)i) & (SAMP_SLOTS - 1);
        if(g_samp_hit[c] == 0) {
            g_samp_key[c] = k; g_samp_hit[c] = 1; g_samp_total++; return;
        }
        if(g_samp_key[c] == k) { g_samp_hit[c]++; g_samp_total++; return; }
    }
    g_samp_lost++;
}

static void samp_start(void) {
    if(timer_prime(TMU1, 1000, 1) < 0) {
        bp_log(BP_LOG_WARN, "samp: TMU1 unavailable — no PC sampling");
        return;
    }
    irq_set_handler(EXC_TMU1_TUNI1, samp_tick, NULL);
    timer_enable_ints(TMU1);
    timer_start(TMU1);
}

/** The histogram, in MILLISECONDS PER FRAME rather than percentages.
 *
 *  The conversion is free and exact: the timer fires a thousand times a second, so one sample IS
 *  one millisecond of wall clock. Divide a bucket's samples by the frames that elapsed while it
 *  was collecting and the answer is what that code costs a frame — the number an optimisation is
 *  actually judged by, where a percentage only says how the cake was cut.
 *
 *  Windowed, not cumulative: a running total blends a loading screen into a fight and reports
 *  neither. Each report describes the period since the last one, so the numbers belong to the
 *  scene on screen when they are printed. */
static void samp_report(void) {
    if(g_samp_total < 200 || g_samp_frames < 10) return;
    uint8_t taken[SAMP_SLOTS];
    memset(taken, 0, sizeof(taken));
    char msg[260];
    /* Tenths of a millisecond, because the interesting buckets are under 10 ms and integers
     * would round most of them to the same number. */
    int n = snprintf(msg, sizeof(msg), "samp: %lu ms/frame over %lu frames (%lu lost) |",
                     (unsigned long)(g_samp_total / g_samp_frames),
                     (unsigned long)g_samp_frames, (unsigned long)g_samp_lost);
    for(int k = 0; k < 10; k++) {
        int best = -1;
        for(int i = 0; i < SAMP_SLOTS; i++)
            if(!taken[i] && g_samp_hit[i] && (best < 0 || g_samp_hit[i] > g_samp_hit[best])) best = i;
        if(best < 0) break;
        taken[best] = 1;
        const unsigned tenths =
            (unsigned)((uint64_t)g_samp_hit[best] * 10ull / (uint64_t)g_samp_frames);
        if(tenths == 0) break;
        n += snprintf(msg + n, sizeof(msg) - (size_t)n, " %08lx:%u.%ums",
                      (unsigned long)g_samp_key[best] << SAMP_GRAN, tenths / 10, tenths % 10);
        if(n >= (int)sizeof(msg) - 16) break;
    }
    bp_log(BP_LOG_INFO, msg);

    /* The window closes with the report. */
    memset(g_samp_key, 0, sizeof(g_samp_key));
    memset(g_samp_hit, 0, sizeof(g_samp_hit));
    g_samp_total = 0;
    g_samp_lost = 0;
    g_samp_frames = 0;
}

static void perf_window_open(void) {
    perf_cntr_stop(PRFC1);
    perf_cntr_clear(PRFC1);
    perf_cntr_start(PRFC1, g_pc_modes[g_pc_mode].ev, PMCR_COUNT_CPU_CYCLES);
    g_pc_armed = 1;
}
static int      g_prof_frames;
/* Logging is measured too, and not as an afterthought: on a console booted from a disc, stdout
 * goes to the serial port, and a line nobody is listening to still costs a spin on the transmit
 * FIFO. If that is where the frames are going, it would look exactly like an emulator that is
 * slow for no reason. */
static uint64_t g_prof_log_us;
static int      g_prof_logs;

/* Every ten presents, not thirty. The period is counted in frames because that is what the numbers
 * are about, but it is *read* in seconds by a person watching a log — and on a machine managing a
 * couple of frames a second, thirty of them is half a minute between signs of life. */
#define PROFILE_EVERY 30

/* ---- the benchmark range ------------------------------------------------------------------------
 * `--dc-bench=FROM:TO` in recompsx.cfg measures presents FROM..TO counted from boot as one block and
 * leaves the result on the overlay's last line. There is one present per emulated frame and the
 * emulation is deterministic, so a game left in its attract loop replays the same frames on every
 * boot: two builds measured over the same range differ by what changed between them. The rolling
 * window cannot promise that — it moves by five percent with whatever is on screen, which is as
 * much as most single optimisations are worth. The range is measured in whole windows, starting
 * with a fresh one at FROM. */
static int      g_bench_state;        /* 0 waiting, 1 on, 2 done; the range is g_bench_from/to */
static uint32_t g_presents;
static uint64_t g_bench_sum[5];       /* total, emu, gte, gpu, build — microseconds */
static uint32_t g_bench_frames;
static char     g_bench_line[48];

static void profile_reset(void);

static void bench_add(uint64_t total, uint64_t emu, uint64_t gte, uint64_t gpu, uint64_t build) {
    g_bench_sum[0] += total; g_bench_sum[1] += emu; g_bench_sum[2] += gte;
    g_bench_sum[3] += gpu;   g_bench_sum[4] += build;
    g_bench_frames += (uint32_t)g_prof_frames;
    if(g_presents < (uint32_t)g_bench_to) return;
    g_bench_state = 2;
    /* Milliseconds per frame, tenths: full speed is 16.7. */
    unsigned long t[5];
    for(int i = 0; i < 5; i++) t[i] = (unsigned long)(g_bench_sum[i] / ((uint64_t)g_bench_frames * 100u));
    snprintf(g_bench_line, sizeof(g_bench_line), "B%lu %lu.%lu emu %lu.%lu gte %lu.%lu gpu %lu.%lu bld %lu.%lu",
             (unsigned long)g_bench_frames, t[0] / 10, t[0] % 10, t[1] / 10, t[1] % 10,
             t[2] / 10, t[2] % 10, t[3] / 10, t[3] % 10, t[4] / 10, t[4] % 10);
    char msg[96];
    snprintf(msg, sizeof(msg), "bench %d..%d: %s (ms a frame)", g_bench_from, g_bench_to, g_bench_line);
    bp_log(BP_LOG_WARN, msg);   /* WARN: the overlay silences INFO, and this line is the point */
    if(g_rxprof) { printf("@@rxprof stop\n@@rxprof exit\n"); fflush(stdout); }
    else {}
}

static void profile_report(void) {
    g_presents++;
    if(g_bench_state == 0 && g_bench_from >= 0 && g_presents == (uint32_t)g_bench_from) {
        profile_reset();        /* the range starts with a window of its own */
        g_bench_state = 1;
        if(g_rxprof) { printf("@@rxprof start\n"); fflush(stdout); }
        else {}
        return;
    } else {}
    if(++g_prof_frames < PROFILE_EVERY) return;

    const uint64_t total = g_prof_emu + g_prof_wait + g_prof_upload + g_prof_submit + g_prof_pace;
    /* Everything the emulated frame contains that has a column of its own is taken out of `emu`
     * rather than left inside it: the disc's reads, the SPU, the AICA, the GTE and the GPU's
     * drawing. Leaving the disc in credited the CPU with the drive's bill, and leaving the drawing
     * in read as if the CPU were slow when the GPU was — so `emu` is what remains, the recompiled
     * code with the kernel, memory and timers it calls, and every number on the overlay is its own
     * and they add up to the total. GTE time is sampled (a tick is a millisecond), the rest timed,
     * so the remainder is clamped rather than trusted to the last millisecond. */
    const uint64_t spu_us = g_prof_section_us[BP_PROFILE_SPU];
    const uint64_t gpu_us = g_prof_section_us[BP_PROFILE_GPU];
    const uint64_t gte_us = (uint64_t)g_samp_where[BP_PROFILE_GTE] * 1000ull;
    const uint64_t inside = g_prof_disc_us + spu_us + gpu_us + gte_us + g_prof_aica;
    const uint64_t emu = g_prof_emu > inside ? g_prof_emu - inside : 0;
    if(g_bench_state == 1) bench_add(total, emu, gte_us, gpu_us, g_prof_build);
    else {}

    char msg[300];
    snprintf(msg, sizeof(msg),
             "dc: %d frames in %lu ms | emu %lu | gte %lu | gpu %lu | spu %lu | aica %lu/%d/%d | disc %lu (%d rd, %d miss)"
             " | pvr-wait %lu | audio %lu (%d) | upload %lu | build %lu (%d hdr, %d cc) | submit %lu | pace %lu | empty %d | log %d in %lu",
             g_prof_frames,
             (unsigned long)(total / 1000),
             (unsigned long)(emu / 1000), (unsigned long)(gte_us / 1000), (unsigned long)(gpu_us / 1000),
             (unsigned long)(spu_us / 1000),
             (unsigned long)(g_prof_aica / 1000), g_prof_aica_decodes, g_prof_aica_declined,
             (unsigned long)(g_prof_disc_us / 1000), g_prof_reads, g_prof_misses,
             (unsigned long)(g_prof_wait / 1000),
             (unsigned long)(g_prof_audio / 1000), g_prof_polls,
             (unsigned long)(g_prof_upload / 1000),
             (unsigned long)(g_prof_build / 1000), g_hdr_hits, g_hdr_compiles,
             (unsigned long)((g_prof_submit - g_prof_build) / 1000),
             (unsigned long)(g_prof_pace / 1000), g_empty_presents,
             g_prof_logs,
             (unsigned long)(g_prof_log_us / 1000));

#if RECOMPSX_DC_PROFILE_OVERLAY
    /* The on-screen copy is built before the serial one is written, so the log counters describe
     * the period they belong to rather than including the cost of reporting themselves. */
    char l0[48], l1[48], l2[48], l3[48], l4[48];
    const unsigned long tenths = total ? (unsigned long)((uint64_t)g_prof_frames * 10000000u / total) : 0;
    /* The window is always PROFILE_EVERY presents, so it is not printed; the disc's wait is
     * followed by what the drive delivered in it, which is what tells a slow drive from a busy
     * one. */
    snprintf(l0, sizeof(l0), "%lu ms %lu.%lu fps pace %lu disc %lu/%luk",
             (unsigned long)(total / 1000), tenths / 10, tenths % 10,
             (unsigned long)(g_prof_pace / 1000), (unsigned long)(g_prof_disc_us / 1000),
             (unsigned long)(g_prof_disc_bytes / 1024));
    /* Line 1 is the emulated frame, line 2 the drawing: the GPU's share of the frame, then the
     * texture uploads, the scene build and hand-over at present, and the wait for the PVR. */
    if(g_hw_voices)
        snprintf(l1, sizeof(l1), "emu %lu gte %lu spu %lu aica %lu/%d/%d",
                 (unsigned long)(emu / 1000), (unsigned long)(gte_us / 1000),
                 (unsigned long)(spu_us / 1000),
                 (unsigned long)(g_prof_aica / 1000), g_prof_aica_decodes, g_prof_aica_declined);
    else
        snprintf(l1, sizeof(l1), "emu %lu gte %lu spu %lu",
                 (unsigned long)(emu / 1000), (unsigned long)(gte_us / 1000),
                 (unsigned long)(spu_us / 1000));
    /* fin and wait (hand-over and the PVR's wait) have read 0 for a long while; they stay in the
     * serial line, and their room goes to the texture decodes. */
    snprintf(l2, sizeof(l2), "gpu %lu up %lu build %lu x2 %d dec %d/%d/%d+%d",
             (unsigned long)(gpu_us / 1000),
             (unsigned long)(g_prof_upload / 1000), (unsigned long)(g_prof_build / 1000),
             g_bright_prims, g_win_mir, g_win_slot, g_win_bake, g_win_patch);
    /* Lines 3 and 4: where the samples landed, by function, in ms of this window. The skip and
     * header counts that were here are in the serial line. */
    syms_top(l3, l4, sizeof(l3));
    if(g_bench_state == 2) memcpy(l4, g_bench_line, sizeof(l4));
    else if(g_fm_line[0]) memcpy(l4, g_fm_line, sizeof(l4));
    else {}

    if(g_txt) {
        memset(g_txt_buf, 0, sizeof(g_txt_buf));
        bfont_draw_str_ex(g_txt_buf,                        TXT_W, 0xFFFF, 0, 16, true, l0);
        bfont_draw_str_ex(g_txt_buf + TXT_W * TXT_LINE,     TXT_W, 0xFFFF, 0, 16, true, l1);
        bfont_draw_str_ex(g_txt_buf + TXT_W * TXT_LINE * 2, TXT_W, 0xFFFF, 0, 16, true, l2);
        bfont_draw_str_ex(g_txt_buf + TXT_W * TXT_LINE * 3, TXT_W, 0xFFFF, 0, 16, true, l3);
        bfont_draw_str_ex(g_txt_buf + TXT_W * TXT_LINE * 4, TXT_W, 0xFFFF, 0, 16, true, l4);
        pvr_txr_load(g_txt_buf, g_txt, sizeof(g_txt_buf));
        g_txt_ready = 1;
    }
#endif

    g_prof_logs = 0;
    g_prof_log_us = 0;
    /* Not while the overlay shows the same numbers. A line of this length is ~280 characters
     * spun out of the serial port a byte at a time whether or not anything listens, and the
     * overlay's own profile put that spin (scif_write) at 54 ms of an 824 ms window. */
#if RECOMPSX_DC_PROFILE_OVERLAY
    if(!g_txt) bp_log(BP_LOG_INFO, msg);
    else {}
#else
    bp_log(BP_LOG_INFO, msg);
#endif

    profile_reset();
}

/** A new window: every per-window counter back to zero. */
static void profile_reset(void) {
    g_prof_frames = 0;
    g_prof_emu = g_prof_wait = g_prof_upload = g_prof_submit = g_prof_audio = 0;
    g_prof_pace = 0;
    g_prof_polls = 0;
    g_empty_presents = 0;
    g_prof_build = 0;
    g_prof_skipped = 0;
    g_bright_prims = 0;
    g_win_mir = g_win_slot = g_win_bake = g_win_patch = 0;
    for(int i = 0; i < BP_PROFILE_SECTIONS; i++) { g_prof_section_us[i] = 0; g_samp_where[i] = 0; }
    g_prof_aica = 0;
    g_prof_aica_decodes = 0;
    g_prof_aica_declined = 0;
    g_hdr_hits = g_hdr_compiles = 0;
    g_prof_disc_us = 0;
    g_prof_disc_bytes = 0;
    g_prof_reads = g_prof_misses = 0;
}

#if RECOMPSX_DC_PROFILE_OVERLAY
/** The overlay quad, bottom-left, drawn in front of the picture (larger z is nearer on a PVR). */
static void draw_profile_overlay(void) {
    if(!g_txt_ready) return;

    pvr_prim(&g_txt_hdr, sizeof(g_txt_hdr));

    pvr_vertex_t v;
    v.flags = PVR_CMD_VERTEX;
    v.argb = 0xFFFFFFFFu;
    v.oargb = 0;
    v.z = 2.0f;

    const float vmax = (float)TXT_USED / (float)TXT_H;
    v.x = 0.0f;   v.y = 480.0f - TXT_USED; v.u = 0.0f; v.v = 0.0f; pvr_prim(&v, sizeof(v));
    v.x = 512.0f; v.y = 480.0f - TXT_USED; v.u = 1.0f; v.v = 0.0f; pvr_prim(&v, sizeof(v));
    v.x = 0.0f;   v.y = 480.0f; v.u = 0.0f; v.v = vmax; pvr_prim(&v, sizeof(v));
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = 512.0f; v.y = 480.0f; v.u = 1.0f; v.v = vmax; pvr_prim(&v, sizeof(v));
}
#endif
#endif

/* ---- hardware drawing ---------------------------------------------------------------------- */

/* ---- colour conversion ------------------------------------------------------------------------
 * A primitive's colour is the PlayStation's 24-bit BGR; the PVR wants ARGB. These run for every
 * vertex of every scene, so all three channels are done at once in one word, without branches:
 * clamping a doubled channel is a matter of whether its top bit was set, and that bit can be
 * spread over its byte with a shift and a subtraction. The host test checks each against the
 * per-channel form it replaced, for every one of the 2^24 colours. */

/** BGR to ARGB8888, alpha 0xFF: bytes 0 and 2 change places. */
static inline uint32_t bgr_to_argb(uint32_t c) {
    return 0xFF000000u | ((c & 0xFFu) << 16) | (c & 0xFF00u) | ((c >> 16) & 0xFFu);
}

/* 0xFF in every byte of `c` whose top bit is set, 0 elsewhere (c's other bits must be clear). */
static inline uint32_t byte_mask(uint32_t top_bits) {
    return (top_bits << 1) - (top_bits >> 7);
}

/** The same, doubled: PlayStation modulation is texel*colour/128, so 0x80 means "unchanged",
 *  where the PVR's multiply wants 0xFF for that — min(2c, 255) per channel. What the clamp
 *  loses is bgr_to_argb_over's. */
static inline uint32_t bgr_to_argb_mod(uint32_t c) {
    const uint32_t d = ((c << 1) & 0x00FEFEFEu) | byte_mask(c & 0x00808080u);
    return bgr_to_argb(d);
}

/** What the doubled colour loses to the clamp: 2c - 255 per channel, floored at zero. Drawn as a
 *  second, additive pass it restores PlayStation modulation above 1.0 — texel*(2c) is
 *  texel*min(2c, 1) + texel*max(2c - 1, 0), and blending is linear in the source. For a channel
 *  of 0x80 or more, 2c - 255 is 2(c - 0x80) + 1. */
static inline uint32_t bgr_to_argb_over(uint32_t c) {
    const uint32_t v = ((c & 0x007F7F7Fu) << 1) | 0x00010101u;
    return bgr_to_argb(v & byte_mask(c & 0x00808080u));
}

/** Whether any channel brightens: above 0x80, the PlayStation's 1.0 — top bit set and some other
 *  bit too. Adding 0x7F to a byte's low seven bits sets its top bit exactly when they are not all
 *  zero, and cannot carry into the next byte. */
static inline int bgr_brightens(uint32_t c) {
    return (c & ((c & 0x007F7F7Fu) + 0x007F7F7Fu) & 0x00808080u) != 0;
}
/* ---- end of colour conversion ---- */

/** BGR555 as VRAM holds it, to the ARGB1555 the PVR samples. Texel zero is the PlayStation's
 *  "nothing here", and becomes alpha 0 so punch-through drops it. */
static uint16_t texel_to_argb1555(uint16_t p) {
    if(p == 0) return 0;
    return (uint16_t)(0x8000u | (p & 0x03E0u) | ((p & 0x001Fu) << 10) | ((p >> 10) & 0x001Fu));
}

/* Which texels a decoded texture shows, for semi-transparency — which on the PlayStation is per
 * texel: in a semi-transparent textured primitive only the texels with STP (bit 15) blend, the
 * others are drawn opaque, and 0x0000 is a hole either way (psx-spx, "Semi-Transparency").
 * AM_VIS shows every texel but 0x0000: opaque primitives, and semi-transparent ones whose CLUT
 * holds one kind only. AM_SOLID shows the texels without STP, AM_STP those with it; for AM_STP
 * the others are black as well as transparent, so that an additive blend, which reads no alpha,
 * adds nothing for them. Crash Bandicoot: Warped's fruit is 645 solid texels to 42 STP ones, and
 * drawn with every texel blended it was see-through. */
enum { AM_VIS = 0, AM_SOLID = 1, AM_STP = 2, AM_N = 3 };

static inline uint16_t texel_argb(uint16_t p, int amode) {
    if(amode == AM_SOLID && (p & 0x8000u)) return 0;
    else {}
    if(amode == AM_STP && !(p & 0x8000u)) return 0;
    else {}
    return texel_to_argb1555(p);
}

/**
	Decodes a whole 256x256 texel page out of emulated VRAM into a cache slot.

	Written twice on purpose. The general path handles the texture window — GP0(E2h), which makes
	a small tile repeat by masking off the high bits of U and V — and pays for it: the source
	texel is a function of the destination one, so nothing can be assumed about what comes next.
	The disassembly of that path was **27 SH-4 instructions per texel**, and 65,536 of those is
	11 ms a page, which is what made hardware drawing slower than software.

	The fast path is for `window == 0`, which is nearly every texture: source and destination run
	together, so **one VRAM halfword feeds four texels at 4bpp** and two at 8bpp. The variable
	shift disappears into constants, the wrap check happens once per group instead of once per
	texel, and the window mask stops being spilled to the stack for want of a register.
**/
/* ---- twiddled texture upload -----------------------------------------------------------------
 * KOS's pvr_txr_load_ex, same layout, without its cost. It computes `x / min + y / min` for every
 * texel — two software divisions on a CPU with no divide instruction, for a term that is zero
 * whenever the texture is square, which every one here is — and stores each texel into video
 * memory with an uncached 16-bit write. A 256x256 page was 65,536 of those; in an arena whose
 * textures change every frame the overlay read pvr_txr_load_ex 160 ms and __udivsi3 136 ms of a
 * 1098 ms window.
 *
 * Here the output is produced in the order video memory holds it, 32 bytes at a time, and written
 * through the store queues to the same TA texture path pvr_txr_load uses; each burst finds its
 * source texels by table. The layout is KOS's exactly (twid_check in the host test compares them):
 * a 16-bit texel (x, y) sits at index TWID(y) | TWID(x) << 1, and a 4-bit texture packs the 2x2
 * block at (2X, 2Y) into one 16-bit word at TWID(Y) | TWID(X) << 1, nibbles (x,y), (x,y+1),
 * (x+1,y), (x+1,y+1). So an index's even bits are y and its odd bits x. */
static uint8_t  g_even4[256];             /* bits 0, 2, 4, 6 of a byte, gathered into four */
static uint16_t g_spread[256];            /* a byte's bits spread to the even positions: TWID */

static void twid_init(void) {
    for(int b = 0; b < 256; b++) {
        int v = 0, w = 0;
        for(int k = 0; k < 4; k++) v |= ((b >> (2 * k)) & 1) << k;
        for(int k = 0; k < 8; k++) w |= ((b >> k) & 1) << (2 * k);
        g_even4[b] = (uint8_t)v;
        g_spread[b] = (uint16_t)w;
    }
}

/* The even bits of a 16-bit index, gathered: y for an index, x for the index shifted right. */
static inline int twid_even(uint32_t i) {
    return g_even4[i & 0xFF] | (g_even4[(i >> 8) & 0xFF] << 4);
}

/* A dim x dim 16-bit texture into `d`, eight words at a time; `sq` flushes each burst out of the
 * store queue. dim is a power of two from 4 to 256: a burst is 16 texels, and a smaller texture
 * would be written past its end. (The 4-bit fill below needs dim >= 8 for the same reason.) */
static void twid16_fill(const uint16_t* src, int dim, uint32_t* d, int sq) {
    const int n = dim * dim;
    for(int i = 0; i < n; i += 16) {
        const int yb = twid_even((uint32_t)i), xb = twid_even((uint32_t)i >> 1);
        for(int k = 0; k < 8; k++) {
            const int j0 = 2 * k, j1 = 2 * k + 1;
            const uint16_t a = src[(yb + g_even4[j0]) * dim + xb + g_even4[j0 >> 1]];
            const uint16_t b = src[(yb + g_even4[j1]) * dim + xb + g_even4[j1 >> 1]];
            d[k] = (uint32_t)a | ((uint32_t)b << 16);
        }
        if(sq) sq_flush(d);
        else {}
        d += 8;
    }
}

/* A dim x dim 4-bit texture (two texels a byte, low nibble first) into `d`, the same way. */
static void twid4_fill(const uint8_t* src, int dim, uint32_t* d, int sq) {
    const int n = dim * dim / 4;          /* 16-bit words, one 2x2 block each */
    for(int w = 0; w < n; w += 16) {
        const int yb = twid_even((uint32_t)w), xb = twid_even((uint32_t)w >> 1);
        for(int k = 0; k < 8; k++) {
            uint32_t pair = 0;
            for(int h = 0; h < 2; h++) {
                const int j = 2 * k + h;
                const int x = 2 * (xb + g_even4[j >> 1]), y = 2 * (yb + g_even4[j]);
                const int b0 = src[(x + y * dim) >> 1], b1 = src[(x + (y + 1) * dim) >> 1];
                const uint32_t word = (uint32_t)((b0 & 15) | ((b1 & 15) << 4)
                                               | ((b0 >> 4) << 8) | ((b1 >> 4) << 12));
                pair |= word << (16 * h);
            }
            d[k] = pair;
        }
        if(sq) sq_flush(d);
        else {}
        d += 8;
    }
}

static void twid_load16(const uint16_t* src, pvr_ptr_t dst, int dim) {
    uint32_t* d = sq_lock((void*)(((uintptr_t)dst & 0xffffff) | PVR_TA_TEX_MEM));
    twid16_fill(src, dim, d, 1);
    sq_unlock();
    sq_wait();
}

static void twid_load4(const uint8_t* src, pvr_ptr_t dst, int dim) {
    uint32_t* d = sq_lock((void*)(((uintptr_t)dst & 0xffffff) | PVR_TA_TEX_MEM));
    twid4_fill(src, dim, d, 1);
    sq_unlock();
    sq_wait();
}

/* ---- direct decode: emulated VRAM straight into a twiddled texture ----------------------------
 * The fills above take a linear source, so every page used to be copied out of VRAM into a buffer
 * first and then gathered out of it one texel at a time: a 4bpp page is 32 KB copied, then 16,384
 * words each assembled from two byte loads at computed addresses — about 1.6 ms of SH-4 time, and
 * a page that arrives new pays it in full. There is no hardware for this step: the PVR samples
 * palettes itself (which is why a 4bpp page uploads as indices) and the store queues are already
 * the fastest way in, but the reordering into the twiddled layout is the CPU's.
 *
 * So the reordering here works on whole words. One burst of the output is a TILE — 8x8 texels at
 * 4bpp, 4x4 at 16 bits — and the tile's rows are read from VRAM as 32-bit words and rearranged
 * with masks and shifts, eight texels per operation instead of one, into the burst's eight words,
 * which go straight to the store queue. No intermediate buffer, no per-texel address. Tiles are
 * visited row by row, so the VRAM a tile row reads (8 rows x 128 bytes for a 4bpp page) sits in
 * the direct-mapped operand cache once: a second tile row of a 4bpp page would be 16 KB away and
 * evict the first, so 4bpp takes one tile row at a time, and the 16-bit paths two, which lets
 * consecutive bursts alternate between the two store queues (address bit 5 is the tile row's
 * parity).
 *
 * Each routine takes `d`, the store-queue address of the texture's first byte (twid_open), and
 * writes only whole bursts. The host test checks every one against the fills above. */

/* A burst of a 4-bit texture from one 8x8 tile: `s` is the tile's first row, four bytes (eight
 * texels) a row, rows VRAM_W / 2 words apart. The burst holds the tile's 4x4 blocks of 2x2
 * texels in the order twid4_fill writes them: word k is blocks (x, y) and (x, y + 1), with
 * x = (k & 1) | (k >> 2 & 1) << 1 and y = (k & 2). A block's 16-bit word is nibbles (x,y),
 * (x,y+1), (x+1,y), (x+1,y+1): per row pair, the low nibbles of both rows make its low byte (lo)
 * and the high nibbles its high byte (hi), for all four blocks of the pair at once; a byte
 * transpose of two row pairs' lo and hi then gives the four words holding them. */
static inline void tile4(uint32_t* d, const uint32_t* s) {
    uint32_t lo[4], hi[4];
    for(int p = 0; p < 4; p++) {
        const uint32_t a = s[(2 * p) * (VRAM_W / 2)], b = s[(2 * p + 1) * (VRAM_W / 2)];
        lo[p] = (a & 0x0F0F0F0Fu) | ((b & 0x0F0F0F0Fu) << 4);
        hi[p] = ((a >> 4) & 0x0F0F0F0Fu) | (b & 0xF0F0F0F0u);
    }
    for(int q = 0; q < 2; q++) {
        /* Halfword h of `even` is block (2h, 2q) and of `odd` block (2h + 1, 2q); the same for
         * the row pair below with 2q + 1. */
        const uint32_t e0 = (lo[2 * q] & 0x00FF00FFu) | ((hi[2 * q] & 0x00FF00FFu) << 8);
        const uint32_t o0 = ((lo[2 * q] >> 8) & 0x00FF00FFu) | (hi[2 * q] & 0xFF00FF00u);
        const uint32_t e1 = (lo[2 * q + 1] & 0x00FF00FFu) | ((hi[2 * q + 1] & 0x00FF00FFu) << 8);
        const uint32_t o1 = ((lo[2 * q + 1] >> 8) & 0x00FF00FFu) | (hi[2 * q + 1] & 0xFF00FF00u);
        d[2 * q    ] = (e0 & 0xFFFFu) | (e1 << 16);
        d[2 * q + 1] = (o0 & 0xFFFFu) | (o1 << 16);
        d[2 * q + 4] = (e0 >> 16) | (e1 & 0xFFFF0000u);
        d[2 * q + 5] = (o0 >> 16) | (o1 & 0xFFFF0000u);
    }
}

/* A burst of a 16-bit texture from one 4x4 tile, given as two words a row: p[2y] is texels
 * (0, y) and (1, y), p[2y + 1] texels (2, y) and (3, y). Word k of the burst is texels (x, y) and
 * (x, y + 1), with x and y as in tile4. */
static inline void tile16(uint32_t* d, const uint32_t* p) {
    for(int q = 0; q < 2; q++) {
        const uint32_t a0 = p[4 * q], b0 = p[4 * q + 1], a1 = p[4 * q + 2], b1 = p[4 * q + 3];
        d[2 * q    ] = (a0 & 0xFFFFu) | (a1 << 16);
        d[2 * q + 1] = (a0 >> 16) | (a1 & 0xFFFF0000u);
        d[2 * q + 4] = (b0 & 0xFFFFu) | (b1 << 16);
        d[2 * q + 5] = (b0 >> 16) | (b1 & 0xFFFF0000u);
    }
}

/* Two BGR555 texels to ARGB1555 at once, each exactly as texel_to_argb1555: red and blue swap,
 * and alpha is set unless the texel is zero. The alpha test is an add that carries into bit 15
 * of each half when its low fifteen bits are not zero — it cannot carry further — with the
 * texel's own bit 15 ORed in, since 0x8000 is not zero either. */
static inline uint32_t argb2(uint32_t v) {
    const uint32_t c = (v & 0x03E003E0u) | ((v & 0x001F001Fu) << 10) | ((v >> 10) & 0x001F001Fu);
    return c | ((((v & 0x7FFF7FFFu) + 0x7FFF7FFFu) | v) & 0x80008000u);
}

/** Tiles [tx0,tx1) x [ty0,ty1) of the 4bpp page at VRAM (px, py) — a 32x32-tile page, px a
 *  multiple of 64 halfwords and py of 256 rows — into its twiddled texture: the whole page, or
 *  the tiles a write touched (a rectangle is re-read whole from VRAM, which holds the truth). */
static void twid4_tiles(uint32_t* d, int px, int py, int tx0, int ty0, int tx1, int ty1) {
    for(int ty = ty0; ty < ty1; ty++) {
        const uint32_t* row = (const uint32_t*)(g_vram + (size_t)((py + 8 * ty) & 511) * VRAM_W + px);
        const uint32_t ybits = g_spread[4 * ty];
        for(int tx = tx0; tx < tx1; tx++) {
            const uint32_t* s = row + tx;
            /* A cache line is eight tiles of a row; ask for the next eight while these run. */
            if((tx & 7) == 0 && tx + 8 < tx1)
                for(int r = 0; r < 8; r++) __builtin_prefetch(s + 8 + r * (VRAM_W / 2));
            uint32_t* o = d + ((ybits | ((uint32_t)g_spread[4 * tx] << 1)) >> 1);
            tile4(o, s);
            sq_flush(o);
        }
    }
}

/** A 256x256 8bpp page at VRAM (px, py) through a CLUT given as two tables — lo[i] the colour,
 *  hi[i] the colour shifted up 16 — so a pair of texels is one OR. The page is 128 halfwords
 *  wide and wraps at the right edge of VRAM like the PlayStation's U; a tile never straddles
 *  the wrap. */
static void twid8_page(uint32_t* d, int px, int py, const uint32_t* lo, const uint32_t* hi) {
    for(int ty = 0; ty < 64; ty += 2) {
        const uint16_t* r0 = g_vram + (size_t)((py + 4 * ty) & 511) * VRAM_W;
        for(int tx = 0; tx < 64; tx++) {
            const uint32_t* s = (const uint32_t*)(r0 + ((px + 2 * tx) & 1023));
            const uint32_t xbits = (uint32_t)g_spread[4 * tx] << 1;
            for(int h = 0; h < 2; h++) {
                uint32_t p[8];
                for(int y = 0; y < 4; y++) {
                    const uint32_t v = s[(4 * h + y) * (VRAM_W / 2)];
                    p[2 * y]     = lo[v & 0xFF] | hi[(v >> 8) & 0xFF];
                    p[2 * y + 1] = lo[(v >> 16) & 0xFF] | hi[v >> 24];
                }
                uint32_t* o = d + ((g_spread[4 * (ty + h)] | xbits) >> 1);
                tile16(o, p);
                sq_flush(o);
            }
        }
    }
}

static inline uint32_t argb2_am(uint32_t v, int amode) {
    if(amode == AM_VIS) return argb2(v);
    else {}
    return (uint32_t)texel_argb((uint16_t)v, amode) | ((uint32_t)texel_argb((uint16_t)(v >> 16), amode) << 16);
}

/** A 256x256 15bpp page at VRAM (px, py), 256 halfwords wide, wrapping like twid8_page. */
static void twid15_page(uint32_t* d, int px, int py, int amode) {
    for(int ty = 0; ty < 64; ty += 2) {
        const uint16_t* r0 = g_vram + (size_t)((py + 4 * ty) & 511) * VRAM_W;
        for(int tx = 0; tx < 64; tx++) {
            const uint32_t* s = (const uint32_t*)(r0 + ((px + 4 * tx) & 1023));
            const uint32_t xbits = (uint32_t)g_spread[4 * tx] << 1;
            for(int h = 0; h < 2; h++) {
                uint32_t p[8];
                for(int y = 0; y < 4; y++) {
                    const uint32_t* t = s + (4 * h + y) * (VRAM_W / 2);
                    p[2 * y]     = argb2_am(t[0], amode);
                    p[2 * y + 1] = argb2_am(t[1], amode);
                }
                uint32_t* o = d + ((g_spread[4 * (ty + h)] | xbits) >> 1);
                tile16(o, p);
                sq_flush(o);
            }
        }
    }
}

/** A 64x64 patch of a 4bpp page with its CLUT applied (tables as twid8_page, sixteen entries):
 *  VRAM halfword column px, row py, one halfword per tile row. */
static void twid_bake(uint32_t* d, int px, int py, const uint32_t* lo, const uint32_t* hi) {
    for(int ty = 0; ty < 16; ty += 2) {
        const uint16_t* r0 = g_vram + (size_t)((py + 4 * ty) & 511) * VRAM_W;
        for(int tx = 0; tx < 16; tx++) {
            const uint16_t* s = r0 + ((px + tx) & 1023);
            const uint32_t xbits = (uint32_t)g_spread[4 * tx] << 1;
            for(int h = 0; h < 2; h++) {
                uint32_t p[8];
                for(int y = 0; y < 4; y++) {
                    const uint32_t v = s[(4 * h + y) * VRAM_W];
                    p[2 * y]     = lo[v & 15] | hi[(v >> 4) & 15];
                    p[2 * y + 1] = lo[(v >> 8) & 15] | hi[v >> 12];
                }
                uint32_t* o = d + ((g_spread[4 * (ty + h)] | xbits) >> 1);
                tile16(o, p);
                sq_flush(o);
            }
        }
    }
}

/** A 64x64 patch of an 8bpp page with its CLUT applied (tables as twid8_page, 256 entries):
 *  VRAM halfword column px, row py, two halfwords — four texels — per tile row. */
static void twid_bake8(uint32_t* d, int px, int py, const uint32_t* lo, const uint32_t* hi) {
    for(int ty = 0; ty < 16; ty += 2) {
        const uint16_t* r0 = g_vram + (size_t)((py + 4 * ty) & 511) * VRAM_W;
        for(int tx = 0; tx < 16; tx++) {
            const uint32_t* s = (const uint32_t*)(r0 + ((px + 2 * tx) & 1023));
            const uint32_t xbits = (uint32_t)g_spread[4 * tx] << 1;
            for(int h = 0; h < 2; h++) {
                uint32_t p[8];
                for(int y = 0; y < 4; y++) {
                    const uint32_t v = s[(4 * h + y) * (VRAM_W / 2)];
                    p[2 * y]     = lo[v & 0xFF] | hi[(v >> 8) & 0xFF];
                    p[2 * y + 1] = lo[(v >> 16) & 0xFF] | hi[v >> 24];
                }
                uint32_t* o = d + ((g_spread[4 * (ty + h)] | xbits) >> 1);
                tile16(o, p);
                sq_flush(o);
            }
        }
    }
}

/* The store-queue address of a texture, for the routines above, and the end of a batch of them. */
static uint32_t* twid_open(pvr_ptr_t dst) {
    return sq_lock((void*)(((uintptr_t)dst & 0xffffff) | PVR_TA_TEX_MEM));
}
static void twid_close(void) {
    sq_unlock();
    sq_wait();
}
/* ---- end of twiddled texture upload ---- */

static void tex_decode(pvr_ptr_t dst, const gstate_t* s, int amode) {
    /* 4bpp pages upload as INDICES, so no CLUT is applied here at all; 8bpp goes through its
     * CLUT to ARGB, 15bpp converts. With no texture window — nearly every texture — the page
     * goes straight from VRAM into the texture (twid4_tiles and friends). The window path below
     * gathers per texel into a buffer; it is the rare case. */
    static uint8_t page[TEX_DIM * TEX_DIM] __attribute__((aligned(32)));
    static uint16_t page16[TEX_DIM * TEX_DIM] __attribute__((aligned(32)));
    static uint16_t clut8[256];
    static uint32_t clut_lo[256], clut_hi[256];

    if((s->window & 0x3FF) == 0 && (s->tex_x & 63) == 0 && (s->tex_y & 255) == 0) {
        if(s->depth == 1)
            for(int i = 0; i < 256; i++) {
                clut_lo[i] = texel_argb(g_vram[(s->clut_y & 511) * VRAM_W + ((s->clut_x + i) & 1023)], amode);
                clut_hi[i] = clut_lo[i] << 16;
            }
        else {}
        uint32_t* d = twid_open(dst);
        if(s->depth == 0)      twid4_tiles(d, s->tex_x, s->tex_y, 0, 0, TEX_DIM / 8, TEX_DIM / 8);
        else if(s->depth == 1) twid8_page(d, s->tex_x, s->tex_y, clut_lo, clut_hi);
        else                   twid15_page(d, s->tex_x, s->tex_y, amode);
        twid_close();
        return;
    }

    if(s->depth == 1)
        for(int i = 0; i < 256; i++)
            clut8[i] = texel_argb(g_vram[(s->clut_y & 511) * VRAM_W + ((s->clut_x + i) & 1023)], amode);

    const int mx = (int)(s->window & 0x1F), my = (int)((s->window >> 5) & 0x1F);
    const int ox = (int)((s->window >> 10) & 0x1F) & mx, oy = (int)((s->window >> 15) & 0x1F) & my;
    const int plain = (s->window & 0x3FF) == 0;

    for(int ty = 0; ty < TEX_DIM; ty++) {
        const int sv = plain ? ty : (((ty & ~(my << 3)) | (oy << 3)) & 0xFF);
        const uint16_t* src = g_vram + (size_t)((s->tex_y + sv) & 511) * VRAM_W;

        if(s->depth == 0) {
            uint8_t* dst = page + (size_t)ty * (TEX_DIM / 2);
            if(plain && s->tex_x + TEX_DIM / 4 <= VRAM_W) {
                memcpy(dst, src + s->tex_x, TEX_DIM / 2);
            } else {
                for(int tx = 0; tx < TEX_DIM; tx += 2) {
                    const int su0 = plain ? tx : (((tx & ~(mx << 3)) | (ox << 3)) & 0xFF);
                    const int su1 = plain ? tx + 1 : ((((tx + 1) & ~(mx << 3)) | (ox << 3)) & 0xFF);
                    const uint16_t h0 = src[(s->tex_x + (su0 >> 2)) & 1023];
                    const uint16_t h1 = src[(s->tex_x + (su1 >> 2)) & 1023];
                    dst[tx >> 1] = (uint8_t)(((h0 >> ((su0 & 3) * 4)) & 0xF)
                                           | (((h1 >> ((su1 & 3) * 4)) & 0xF) << 4));
                }
            }
        } else if(s->depth == 1) {
            uint16_t* dst = page16 + (size_t)ty * TEX_DIM;
            if(plain) {
                for(int tx = 0; tx < TEX_DIM; tx += 2) {
                    const uint16_t hw = src[(s->tex_x + (tx >> 1)) & 1023];
                    dst[tx    ] = clut8[hw & 0xFF];
                    dst[tx + 1] = clut8[(hw >> 8) & 0xFF];
                }
            } else {
                for(int tx = 0; tx < TEX_DIM; tx++) {
                    const int su = (((tx & ~(mx << 3)) | (ox << 3)) & 0xFF);
                    const uint16_t hw = src[(s->tex_x + (su >> 1)) & 1023];
                    dst[tx] = clut8[(hw >> ((su & 1) * 8)) & 0xFF];
                }
            }
        } else {
            uint16_t* dst = page16 + (size_t)ty * TEX_DIM;
            for(int tx = 0; tx < TEX_DIM; tx++) {
                const int su = plain ? tx : (((tx & ~(mx << 3)) | (ox << 3)) & 0xFF);
                dst[tx] = texel_argb(src[(s->tex_x + su) & 1023], amode);
            }
        }
    }
    if(s->depth == 0)
        twid_load4(page, dst, TEX_DIM);
    else
        twid_load16(page16, dst, TEX_DIM);
}

/** The palette bank holding these sixteen colours, writing them into palette RAM first if no
 *  bank does yet. Banks are addressed by CONTENT — the colours are the key, not the CLUT's VRAM
 *  position — and three things fall out. CLUTs sharing a palette share a bank, so the live count
 *  drops below the count of CLUT positions. Palette animation ping-pongs between the banks its
 *  steps already occupy, writing palette RAM only when a genuinely new palette appears. And a
 *  CLUT repainted MID-FRAME resolves to a different bank for the primitives submitted after the
 *  repaint, so each renders through the palette it was submitted with — which is what the
 *  PlayStation did. Staleness cannot exist: content cannot drift from itself, which is why
 *  bp_gpu_dirty has no palette work at all. */
static uint32_t g_pal_memo_gen = 1;
PROF_NOINLINE static int pal_bank_at(int clut_x, int clut_y, int allow_approx, int amode) {
    uint16_t want[16];
    uint32_t h = 2166136261u;
    for(int i = 0; i < 16; i++) {
        want[i] = texel_argb(g_vram[(clut_y & 511) * VRAM_W + ((clut_x + i) & 1023)], amode);
        h = (h ^ want[i]) * 16777619u;
    }
    for(int i = 0; i < PAL_BANKS_4BPP; i++) {
        if(g_pal4[i].used && g_pal4[i].hash == h
           && memcmp(g_pal4[i].entry, want, sizeof(want)) == 0) {
            if(g_pal4[i].bound_frame != g_tex_frame) g_pal_live++;
            g_pal4[i].bound_frame = g_tex_frame;
            return i;
        }
    }
    /* In-flight rule, as for the texture slots: the PVR is still rendering the previous scene
     * out of palette RAM, so nothing bound this frame or the last may be rewritten. bound_frame
     * zero means never bound — eligible from the first frame without a false conflict. */
    int bank = -1;
    for(int i = 0; i < PAL_BANKS_4BPP; i++) {
        const int c = (g_pal_next + i) % PAL_BANKS_4BPP;
        if(!g_pal4[c].used
           && (g_pal4[c].bound_frame == 0 || g_pal4[c].bound_frame + 1 < g_tex_frame)) {
            bank = c; break;
        }
    }
    if(bank < 0) {
        for(int i = 0; i < PAL_BANKS_4BPP; i++) {
            const int c = (g_pal_next + i) % PAL_BANKS_4BPP;
            if(g_pal4[c].bound_frame + 1 < g_tex_frame) { bank = c; break; }
        }
    }
    /* The caller decides whether an approximation is acceptable. When a baked entry can carry
     * this palette exactly, it says no, and the scene keeps its true colours. */
    if(bank < 0 && !allow_approx) return -1;
    if(bank < 0) {
        /* Capacity truth, remeasured with the state table uncapped: the crate arena runs about
         * a hundred distinct palettes a frame — a hundred CLUT POSITIONS, the flash phases
         * pre-baked side by side in VRAM, not mid-frame repaints (a first fallback keyed on
         * position never fired once: zero overlap) — against the hardware's sixty-four banks.
         * 1024 palette entries is the wall, and no format escapes the arithmetic.
         *
         * Stealing an in-flight bank is worse than it looks: the stolen content misses next
         * frame and steals in turn, so one overflow cascades into ~97 thefts a frame and a
         * four-percent hit rate — the population never stabilises. The graceful loss is the
         * NEAREST banked palette by summed channel distance: a tile's flash phase lands on its
         * sibling phase and loses a little contrast, nothing turns a foreign colour, and
         * palette RAM stops being rewritten mid-scene at all. Long-lived palettes (characters,
         * HUD) keep their banks across frames by content hits, so the approximation
         * concentrates on whatever arrived after the room filled. */
        int best = -1;
        uint32_t best_d = 0xFFFFFFFFu;
        for(int i = 0; i < PAL_BANKS_4BPP; i++) {
            if(!g_pal4[i].used) continue;
            uint32_t d = 0;
            for(int e = 0; e < 16; e++) {
                const int a = g_pal4[i].entry[e], b = want[e];
                int t = ((a >> 10) & 31) - ((b >> 10) & 31); d += (uint32_t)(t < 0 ? -t : t);
                t = ((a >> 5) & 31) - ((b >> 5) & 31);       d += (uint32_t)(t < 0 ? -t : t);
                t = (a & 31) - (b & 31);                     d += (uint32_t)(t < 0 ? -t : t);
                /* A transparency flip is worse than any tint: a hole must never become a
                 * colour, nor a colour a hole. */
                t = ((a >> 15) & 1) - ((b >> 15) & 1);       d += (uint32_t)(t < 0 ? -t : t) << 9;
            }
            if(d < best_d) { best_d = d; best = i; }
        }
        if(best >= 0) {
            g_pal_stale++;
            if(g_pal4[best].bound_frame != g_tex_frame) g_pal_live++;
            g_pal4[best].bound_frame = g_tex_frame;
            return best;
        }
        bank = g_pal_next;   /* zero banks in use — unreachable once anything has rendered */
        g_pal_conflicts++;
    }
    /* Only the steal above can rewrite a bank this scene has already handed out; the memo
     * below must then forget what it said about it. */
    if(g_pal4[bank].bound_frame == g_tex_frame) g_pal_memo_gen++;
    g_pal_next = (bank + 1) % PAL_BANKS_4BPP;
    g_pal4[bank].used = 1;
    g_pal4[bank].hash = h;
    memcpy(g_pal4[bank].entry, want, sizeof(want));
    if(g_pal4[bank].bound_frame != g_tex_frame) g_pal_live++;
    g_pal4[bank].bound_frame = g_tex_frame;
    for(int i = 0; i < 16; i++)
        pvr_set_pal_entry(bank * 16 + i, want[i]);
    return bank;
}

/** pal_bank_at's answers, remembered for one scene build.
 *
 *  Almost every primitive of a gameplay scene changes the texture state, and each change asked
 *  pal_bank_at again: sixteen colours read and converted, a hash, a walk of sixty-four banks —
 *  and, once the banks are full, a nearest-palette search of sixty-four by sixteen colours. A
 *  scene asks about the same few dozen CLUT positions a thousand times. Within one build the
 *  answer cannot change: VRAM is still (the emulation is not running), a bank handed out this
 *  frame is never rewritten this frame (the in-flight rule), and once no bank is eligible none
 *  becomes eligible, so a refusal and a nearest match both stand. The one exception, the steal
 *  when no bank is in use at all, bumps the generation. Keyed by position and by whether an
 *  approximation was allowed, since the two can answer differently. */
#define PAL_MEMO 512
static struct { uint32_t gen; uint16_t cx, cy; int16_t bank; uint8_t approx, amode; } g_pal_memo[PAL_MEMO];

PROF_NOINLINE static int pal_bank_cached(int clut_x, int clut_y, int allow_approx, int amode) {
    const uint32_t k = (((uint32_t)clut_x >> 4) ^ ((uint32_t)clut_y * 0x9E5u)
                        ^ ((uint32_t)allow_approx << 8) ^ ((uint32_t)amode << 6)) & (PAL_MEMO - 1);
    if(g_pal_memo[k].gen == g_pal_memo_gen && g_pal_memo[k].cx == clut_x
       && g_pal_memo[k].cy == clut_y && g_pal_memo[k].approx == allow_approx
       && g_pal_memo[k].amode == amode)
        return g_pal_memo[k].bank;
    const int bank = pal_bank_at(clut_x, clut_y, allow_approx, amode);
    g_pal_memo[k].gen = g_pal_memo_gen;
    g_pal_memo[k].cx = (uint16_t)clut_x;
    g_pal_memo[k].cy = (uint16_t)clut_y;
    g_pal_memo[k].approx = (uint8_t)allow_approx;
    g_pal_memo[k].amode = (uint8_t)amode;
    g_pal_memo[k].bank = (int16_t)bank;
    return bank;
}

/** The slot holding this page, decoding it first if nobody has. Round-robin eviction: a scene
 *  using more than sixteen pages will thrash, and the profiler is what would say so. */
PROF_NOINLINE static int tex_slot(const gstate_t* s, int amode) {
    /* A 4bpp slot holds indices: its variant is in the palette bank, not here. */
    if(s->depth == 0) amode = AM_VIS;
    else {}
    for(int i = 0; i < g_tex_big_n + g_tex_small_n; i++) {
        if(g_tex[i].used && g_tex[i].tex_x == s->tex_x && g_tex[i].tex_y == s->tex_y
           && g_tex[i].depth == s->depth && g_tex[i].window == s->window
           && g_tex[i].amode == amode
           && (s->depth != 1 || (g_tex[i].clut_x == s->clut_x && g_tex[i].clut_y == s->clut_y))) {
            g_tex_hits++;
            return i;
        }
    }
    /* Two pools, because the bytes differ fourfold: a 4bpp page uploads as indices into a
     * 32 KB slot, everything else needs 128 KB of ARGB. Gameplay lives in the small pool —
     * walls, floors, characters are 4bpp — and quartering their cost is what makes it deep
     * enough for TWO frames' working set, which the in-flight rule below demands.
     *
     * Eviction, in order of preference: a virgin slot; then one whose last binding is older
     * than the PREVIOUS frame — the renderer is one frame behind the builder, so anything
     * bound this frame or the last is still being read by the PVR, and rewriting it repaints
     * geometry already on its way to the screen: one-frame flashes of foreign texels,
     * "textures swapping places". Only when the whole pool is that recent, the round-robin
     * victim — counted, because that one IS corruption on screen. */
    const int is4  = s->depth == 0;
    const int base = is4 ? g_tex_big_n : 0;
    const int n    = is4 ? g_tex_small_n : g_tex_big_n;
    int* next      = is4 ? &g_tex_small_next : &g_tex_big_next;
    if(n <= 0) return -1;   /* pool never allocated — announced at arming time */
    int slot = -1;
    for(int i = 0; i < n; i++) {
        const int c = base + (*next + i) % n;
        if(!g_tex[c].used
           && (g_tex[c].bound_frame == 0 || g_tex[c].bound_frame + 1 < g_tex_frame)) {
            slot = c; break;
        }
    }
    if(slot < 0) {
        for(int i = 0; i < n; i++) {
            const int c = base + (*next + i) % n;
            if(g_tex[c].bound_frame + 1 < g_tex_frame) { slot = c; break; }
        }
    }
    if(slot < 0) {
        slot = base + *next;
        g_tex_conflicts++;
    }
    *next = (slot - base + 1) % n;
    g_tex[slot].used = 1;
    g_tex[slot].tex_x = s->tex_x;
    g_tex[slot].tex_y = s->tex_y;
    g_tex[slot].clut_x = s->clut_x;
    g_tex[slot].clut_y = s->clut_y;
    g_tex[slot].depth = s->depth;
    g_tex[slot].window = s->window;
    g_tex[slot].amode = (uint8_t)amode;
    g_tex_decodes++;
    g_win_slot++;
    tex_decode(g_tex[slot].mem, s, amode);
    return slot;
}

/** The permanent 4bpp mirror slot for a texture page, decoded on first use and after any write
 *  to the VRAM it covers. Never evicted: the slot IS the page, so nothing else can want it. */
PROF_NOINLINE static pvr_ptr_t page4_mirror(const gstate_t* s) {
    gpage4_t* pg = &g_page4[((s->tex_y >> 8) & 1) * PAGE4_COLS + ((s->tex_x >> 6) & 15)];
    if(!pg->mem) return NULL;
    if(!pg->valid) {
        /* The slot is permanent, but its CONTENTS are not: a VRAM write invalidates the page and
         * the next use re-decodes it — into memory the PVR may still be reading for the previous
         * scene, which tears the picture already on its way out. During a level load, where
         * uploads arrive in floods, that is a whole run of torn frames. One frame of the
         * previous texels is the better loss, so an in-flight page defers once; a page the game
         * rewrites every single frame still updates, because the deferral is granted only
         * once. */
        if(pg->bound_frame != 0 && pg->bound_frame + 1 >= g_tex_frame && pg->defer == 0) {
            pg->defer = 1;
        } else {
            tex_decode(pg->mem, s, AM_VIS);   /* indices: the variant is the palette's */
            pg->valid = 1;
            pg->part = 0;
            pg->defer = 0;
            g_mir_decodes++;
            g_win_mir++;
        }
    } else if(pg->part) {
        /* Patched now, not deferred: a strip of one frame's scroll on its way out tears less
         * visibly than the whole strip arriving a frame late. */
        uint32_t* d = twid_open(pg->mem);
        twid4_tiles(d, s->tex_x & ~63, s->tex_y & 256,
                    pg->dx0 >> 1, pg->dy0 >> 3, (pg->dx1 + 1) >> 1, (pg->dy1 + 7) >> 3);
        twid_close();
        pg->part = 0;
        g_win_patch++;
    } else {}
    pg->bound_frame = g_tex_frame;
    return pg->mem;
}

/** One 64x64 patch of a page with its CLUT already applied: a 4bpp page's, for palettes that
 *  got no bank, or an 8bpp page's (bake_slot). */
static void bake_decode(pvr_ptr_t dst, const gstate_t* s, int tu, int tv, int amode) {
    static uint32_t lo[256], hi[256];
    const int n = s->depth == 1 ? 256 : 16;
    for(int i = 0; i < n; i++) {
        lo[i] = texel_argb(g_vram[(s->clut_y & 511) * VRAM_W + ((s->clut_x + i) & 1023)], amode);
        hi[i] = lo[i] << 16;
    }
    /* The patch origin is a multiple of four texels, so each tile row is one VRAM halfword at
     * 4bpp and two at 8bpp. */
    uint32_t* d = twid_open(dst);
    if(s->depth == 1)
        twid_bake8(d, s->tex_x + tu * (BAKE_DIM / 2), s->tex_y + tv * BAKE_DIM, lo, hi);
    else
        twid_bake(d, s->tex_x + tu * (BAKE_DIM / 4), s->tex_y + tv * BAKE_DIM, lo, hi);
    twid_close();
}

/** The patch holding this 64x64 part of a page through its CLUT, baking it first if needed.
 *  4bpp pages come here only when their palette got no bank; 8bpp pages always do when a
 *  primitive samples within one patch. An 8bpp page through each of its CLUTs was a whole
 *  128 KB ARGB slot, and Crash Bandicoot: Warped binds seventeen such pairs a frame — every one
 *  of them sampling a single 64x64 corner — against twelve slots: five whole-page decodes a
 *  frame and slots evicted while the PVR still read them. As patches it is ~26 x 8 KB. */
/* Where each key was last found, direct-mapped: a hit is one compare where the walk over the
 * pool was sixty-four, and the walk was four fifths of bake_slot — before the semi-transparency
 * variants doubled the lookups. An entry is a hint, checked against the slot it names. */
#define BAKE_INDEX 256
static int16_t g_bake_index[BAKE_INDEX];   /* slot + 1; 0 for none */

static inline int bake_hash(const gstate_t* s, int tu, int tv, int amode) {
    uint32_t h = (uint32_t)s->tex_x * 0x9E3779B1u ^ (uint32_t)s->tex_y * 0x85EBCA77u;
    h ^= (((uint32_t)s->clut_x << 16) | (uint32_t)s->clut_y) * 0xC2B2AE3Du;
    h ^= ((uint32_t)tu | ((uint32_t)tv << 8) | ((uint32_t)s->depth << 16)
          | ((uint32_t)amode << 18)) * 0x27D4EB2Fu;
    return (int)(h >> 24) & (BAKE_INDEX - 1);
}

static inline int bake_is(int i, const gstate_t* s, int tu, int tv, int amode) {
    return g_bake[i].used && g_bake[i].tex_x == s->tex_x && g_bake[i].tex_y == s->tex_y
        && g_bake[i].clut_x == s->clut_x && g_bake[i].clut_y == s->clut_y
        && g_bake[i].tu == tu && g_bake[i].tv == tv && g_bake[i].depth == s->depth
        && g_bake[i].amode == amode;
}

PROF_NOINLINE static int bake_slot(const gstate_t* s, int tu, int tv, int amode) {
    const int h = bake_hash(s, tu, tv, amode);
    int found = g_bake_index[h] - 1;
    if(found < 0 || !bake_is(found, s, tu, tv, amode)) {
        found = -1;
        for(int i = 0; i < g_bake_n; i++) {
            if(bake_is(i, s, tu, tv, amode)) { found = i; break; }
        }
        if(found >= 0) g_bake_index[h] = (int16_t)(found + 1);
    }
    if(found >= 0) {
        if(g_bake[found].bound_frame != g_tex_frame) g_bake_live++;
        g_bake[found].bound_frame = g_tex_frame;
        return found;
    }
    /* Same in-flight rule as everywhere else: the PVR is still reading the previous scene. */
    int slot = -1;
    for(int i = 0; i < g_bake_n; i++) {
        const int c = (g_bake_next + i) % g_bake_n;
        if(!g_bake[c].used
           && (g_bake[c].bound_frame == 0 || g_bake[c].bound_frame + 1 < g_tex_frame)) {
            slot = c; break;
        }
    }
    if(slot < 0) {
        for(int i = 0; i < g_bake_n; i++) {
            const int c = (g_bake_next + i) % g_bake_n;
            if(g_bake[c].bound_frame + 1 < g_tex_frame) { slot = c; break; }
        }
    }
    if(slot < 0) return -1;   /* every entry in flight — the caller approximates, and counts it */
    g_bake_next = (slot + 1) % g_bake_n;
    g_bake[slot].used = 1;
    g_bake[slot].tex_x = s->tex_x;
    g_bake[slot].tex_y = s->tex_y;
    g_bake[slot].clut_x = s->clut_x;
    g_bake[slot].clut_y = s->clut_y;
    g_bake[slot].tu = (uint8_t)tu;
    g_bake[slot].tv = (uint8_t)tv;
    g_bake[slot].depth = (uint8_t)s->depth;
    g_bake[slot].amode = (uint8_t)amode;
    g_bake[slot].bound_frame = g_tex_frame;
    g_bake_index[h] = (int16_t)(slot + 1);
    g_bake_live++;
    g_bake_decodes++;
    g_win_bake++;
    bake_decode(g_bake[slot].mem, s, tu, tv, amode);
    return slot;
}

/** Hands the sixty-four banks to the palettes that draw the most primitives, before anything is
 *  submitted. Arrival order would give them to the backdrop — submitted first because the
 *  ordering table runs far-to-near — and leave the characters to be baked. Both are exact; this
 *  is about which path is cheaper for the majority of the picture. Counting is a direct-mapped
 *  table with four probes: a collision costs a palette its count, never its correctness. */
#define PRIO_SLOTS 256
static struct { uint16_t cx, cy; uint32_t n; uint8_t used; } g_prio[PRIO_SLOTS];

PROF_NOINLINE static void palette_priority(void) {
    memset(g_prio, 0, sizeof(g_prio));
    /* The slots in use, collected as they fill: the ranking below then sorts a few dozen entries
     * where it used to scan all 256 slots once per bank — sixty-four passes, some sixteen
     * thousand iterations a scene, for a list that is sorted once. And primitives arrive in runs
     * sharing a state, so a run's palette is looked up once and counted by increment. */
    int used[PRIO_SLOTS];
    int n_used = 0, last_state = -1, last_slot = -1;
    for(int i = 0; i < g_cmd_count; i++) {
        const gcmd_t* c = &g_cmds[i];
        if(c->is_rect) continue;
        if((int)c->state == last_state) {
            if(last_slot >= 0) g_prio[last_slot].n++;
            else {}
            continue;
        } else {}
        last_state = (int)c->state;
        last_slot = -1;
        const gstate_t* s = &g_states[c->state];
        if(!(s->flags & BP_GPU_TEXTURED) || s->depth != 0) continue;
        const uint32_t base = (uint32_t)s->clut_x * 31u + (uint32_t)s->clut_y * 17u;
        for(int probe = 0; probe < 4; probe++) {
            const int hh = (int)((base + (uint32_t)probe) & (PRIO_SLOTS - 1));
            if(!g_prio[hh].used) {
                g_prio[hh].used = 1;
                g_prio[hh].cx = s->clut_x;
                g_prio[hh].cy = s->clut_y;
                g_prio[hh].n = 1;
                used[n_used++] = hh;
                last_slot = hh;
                break;
            }
            if(g_prio[hh].cx == s->clut_x && g_prio[hh].cy == s->clut_y) {
                g_prio[hh].n++;
                last_slot = hh;
                break;
            }
        }
    }
    /* Most primitives first; a tie goes to the lower slot, the order the scan gave. */
    for(int a = 1; a < n_used; a++) {
        const int v = used[a];
        int b = a - 1;
        while(b >= 0 && (g_prio[used[b]].n < g_prio[v].n
                         || (g_prio[used[b]].n == g_prio[v].n && used[b] > v))) {
            used[b + 1] = used[b];
            b--;
        }
        used[b + 1] = v;
    }
    /* A refusal means no bank is free for THIS palette; a later one may still be resident and
     * want its lease refreshed, so the pass continues rather than abandoning the list. */
    for(int k = 0; k < n_used && k < PAL_BANKS_4BPP; k++)
        pal_bank_cached(g_prio[used[k]].cx, g_prio[used[k]].cy, 0, AM_VIS);
}

void bp_gpu_vram(const uint16_t* vram) {
    g_vram = vram;
    g_scene_dirty = 1;
    if(!g_mir_base) {
        /* One megabyte, taken first and in one piece, because it is the entire PlayStation
         * VRAM and every other allocation here is a luxury next to it. */
        g_mir_base = pvr_mem_malloc(PAGE4_N * PAGE4_BYTES);
        for(int i = 0; i < PAGE4_N; i++) {
            g_page4[i].mem = g_mir_base
                ? (pvr_ptr_t)((uint8_t*)g_mir_base + (size_t)i * PAGE4_BYTES) : NULL;
            g_page4[i].valid = 0;
        }
    }
    for(int i = 0; i < PAGE4_N; i++) g_page4[i].valid = 0;
    if(g_tex_big_n == 0 && g_tex_small_n == 0) {
        /* Big pool first, then small slots until the floor: every remaining 32 KB buys another
         * 4bpp page, and the floor keeps a margin so this can never silently starve a later
         * allocation — the lesson of the 9 MB night. */
        while(g_tex_big_n < TEX_BIG_SLOTS) {
            pvr_ptr_t m = pvr_mem_malloc(TEX_DIM * TEX_DIM * 2);
            if(!m) break;
            g_tex[g_tex_big_n++].mem = m;
        }
        while(g_tex_small_n < TEX_SMALL_MAX
              && pvr_mem_available() >= TEX_DIM * TEX_DIM / 2 + 192 * 1024) {
            pvr_ptr_t m = pvr_mem_malloc(TEX_DIM * TEX_DIM / 2);
            if(!m) break;
            g_tex[g_tex_big_n + g_tex_small_n].mem = m;
            g_tex_small_n++;
        }
    }
    while(g_bake_n < BAKE_MAX && pvr_mem_available() >= BAKE_BYTES + 128 * 1024) {
        pvr_ptr_t m = pvr_mem_malloc(BAKE_BYTES);
        if(!m) break;
        g_bake[g_bake_n++].mem = m;
    }
    for(int i = 0; i < g_tex_big_n + g_tex_small_n; i++) g_tex[i].used = 0;
    for(int i = 0; i < g_bake_n; i++) g_bake[i].used = 0;
    /* Said out loud, because the failure mode is silent and looks like a rendering bug: a pool
     * that came up short makes its primitives disappear and the survivors thrash harder. A short
     * count here is a budget error, not a graphics one. */
    char msg[160];
    snprintf(msg, sizeof(msg),
             "gpu: PVR draws the primitives — VRAM mirror %s, %d big + %d small slots, "
             "%d bake patches, %u KB free",
             g_mir_base ? "resident" : "MISSING",
             g_tex_big_n, g_tex_small_n, g_bake_n, (unsigned)(pvr_mem_available() / 1024));
    bp_log(g_mir_base && g_tex_big_n == TEX_BIG_SLOTS && g_bake_n >= 32
           ? BP_LOG_INFO : BP_LOG_WARN, msg);
}

/** Drops the presented frame's geometry, the moment anything belonging to the next one arrives.
 *  Both entry points call it, and both must: state is latched before the primitive that uses it,
 *  so resetting in one place only would dedup a new frame's state against a dead table and then
 *  index into the emptied one. */
static int g_clip_x0, g_clip_y0, g_clip_x1 = 1023, g_clip_y1 = 511;

static inline void begin_frame_if_needed(void) {
    if(!g_frame_shown) return;
    g_frame_shown = 0;
    g_cmd_count = 0;
    /* The latched state carries over as the new frame's first entry: the ABI latches it until
     * the next bp_gpu_state, and the runtime now sends one only when it changes, so the first
     * primitive of a frame may well arrive under the last frame's state. */
    if(g_state_count > 0) {
        g_states[0] = g_states[g_state_count - 1];
        g_state_count = 1;
    } else {}
}

void bp_gpu_state(int tex_base_x, int tex_base_y, int tex_depth,
                  int clut_x, int clut_y, int semi_mode, int flags, int tex_window,
                  int draw_x, int draw_y) {
    begin_frame_if_needed();
    /* Recorded only when it differs from the last one: primitives arrive in runs that share a
     * page, so the table stays a fraction of the command count. */
    if(g_state_count > 0) {
        const gstate_t* p = &g_states[g_state_count - 1];
        if(p->tex_x == tex_base_x && p->tex_y == tex_base_y && p->depth == tex_depth
           && p->clut_x == clut_x && p->clut_y == clut_y && p->semi_mode == semi_mode
           && p->flags == flags && p->window == (uint32_t)tex_window
           && p->draw_x == draw_x && p->draw_y == draw_y
           && p->clip_x0 == g_clip_x0 && p->clip_y0 == g_clip_y0
           && p->clip_x1 == g_clip_x1 && p->clip_y1 == g_clip_y1)
            return;
    }
    if(g_state_count >= GPU_MAX_STATES) {
        /* Unreachable by the bound above; if it ever fires, the bound's reasoning broke. */
        static int warned;
        if(!warned) { warned = 1; bp_log(BP_LOG_WARN, "gpu: state table overflow — impossible"); }
        return;
    }
    gstate_t* s = &g_states[g_state_count++];
    s->tex_x = (uint16_t)tex_base_x;
    s->tex_y = (uint16_t)tex_base_y;
    s->depth = (uint8_t)tex_depth;
    s->clut_x = (uint16_t)clut_x;
    s->clut_y = (uint16_t)clut_y;
    s->semi_mode = (uint8_t)semi_mode;
    s->flags = (uint8_t)flags;
    s->window = (uint32_t)tex_window;
    s->draw_x = (int16_t)draw_x;
    s->draw_y = (int16_t)draw_y;
    s->clip_x0 = (int16_t)g_clip_x0; s->clip_y0 = (int16_t)g_clip_y0;
    s->clip_x1 = (int16_t)g_clip_x1; s->clip_y1 = (int16_t)g_clip_y1;
}

static inline gcmd_t* cmd_new(void) {
    begin_frame_if_needed();
    g_scene_dirty = 1;
    if(g_cmd_count >= GPU_MAX_CMDS) { g_cmd_overflowed = 1; return NULL; }
    gcmd_t* c = &g_cmds[g_cmd_count++];
    c->state = (uint16_t)(g_state_count > 0 ? g_state_count - 1 : 0);
    return c;
}

void bp_gpu_tri(int x0, int y0, int c0, int u0, int v0,
                int x1, int y1, int c1, int u1, int v1,
                int x2, int y2, int c2, int u2, int v2) {
    gcmd_t* c = cmd_new();
    if(!c) return;
    c->is_rect = GCMD_TRI;
    c->x[0] = (int16_t)x0; c->y[0] = (int16_t)y0; c->u[0] = (uint8_t)u0; c->v[0] = (uint8_t)v0;
    c->x[1] = (int16_t)x1; c->y[1] = (int16_t)y1; c->u[1] = (uint8_t)u1; c->v[1] = (uint8_t)v1;
    c->x[2] = (int16_t)x2; c->y[2] = (int16_t)y2; c->u[2] = (uint8_t)u2; c->v[2] = (uint8_t)v2;
    /* As the PlayStation gave them, BGR: a textured primitive's colour becomes one or two passes
     * at build time (put_modulated), and clamping it here would lose the second. */
    c->argb[0] = (uint32_t)c0 & 0x00FFFFFFu;
    c->argb[1] = (uint32_t)c1 & 0x00FFFFFFu;
    c->argb[2] = (uint32_t)c2 & 0x00FFFFFFu;
}

void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode) {
    /* Blend state arrived through bp_gpu_state, which the runtime calls first and which knows the
     * drawing area; these two say the same thing and are kept in the signature because the ABI
     * describes a rectangle completely rather than half-completely. */
    (void)semi; (void)semi_mode;
    gcmd_t* c = cmd_new();
    if(!c) return;
    c->is_rect = GCMD_RECT;
    c->x[0] = (int16_t)x; c->y[0] = (int16_t)y;
    c->x[1] = (int16_t)w; c->y[1] = (int16_t)h;
    c->argb[0] = (uint32_t)bgr & 0x00FFFFFFu;   /* BGR, converted at build time */
}

/* The last two display rectangles presented: a double-buffered game shows one and writes the
 * other, and a write into either is a write into a picture this backend draws. */
static int g_disp[2][4];

static int meets(const int* r, int x, int y, int w, int h) {
    return r[2] > 0 && !(r[0] + r[2] <= x || x + w <= r[0] || r[1] + r[3] <= y || y + h <= r[1]);
}

/* Where the buffer a state draws into sits in VRAM, as the top-left corner of the picture: the
 * displayed rectangle holding its drawing area's corner — the one on screen now, or the one before
 * it, which is where a double-buffered game draws. A primitive's place on screen is its VRAM
 * position less this. It used to be less the drawing area's own corner, which is the same only
 * when the area is the whole buffer: Crash Bandicoot: Warped draws into y 12..227 of a 240-line
 * buffer, and its picture sat twelve lines high. In neither rectangle, the drawing is either a
 * buffer not shown yet — as large as the picture, placed at its own corner as before — or VRAM
 * that a later primitive samples (Crash 3 draws its shadow into 64x64 at 0,320), which the
 * PlayStation never shows, so neither is it drawn here: returns 0. */
static int screen_origin(const gstate_t* s, int* ox, int* oy, int* ow, int* oh) {
    for(int k = 0; k < 2; k++) {
        const int* d = g_disp[k];
        if(d[2] > 0 && d[3] > 0 && s->draw_x >= d[0] && s->draw_x < d[0] + d[2]
           && s->draw_y >= d[1] && s->draw_y < d[1] + d[3]) {
            *ox = d[0]; *oy = d[1];
            *ow = d[2]; *oh = d[3];
            return 1;
        }
    }
    const int w = s->clip_x1 - s->clip_x0 + 1, h = s->clip_y1 - s->clip_y0 + 1;
    if(w * 4 >= g_disp[0][2] * 3 && h * 4 >= g_disp[0][3] * 3) {
        *ox = s->draw_x; *oy = s->draw_y;
        *ow = g_disp[0][2]; *oh = g_disp[0][3];
        return 1;
    }
    return 0;
}

/* True when rectangle a lies inside rectangle b (corner, size). */
static int inside(int ax, int ay, int aw, int ah, int bx, int by, int bw, int bh) {
    return ax >= bx && ay >= by && ax + aw <= bx + bw && ay + ah <= by + bh;
}

/** Records that VRAM changed under the picture, at this point in the order of drawing.
 *
 *  This backend keeps a frame's geometry and draws it again at every present until the game draws
 *  something new, over the VRAM picture as background. That is right until the game writes VRAM
 *  after drawing: on a PlayStation the primitive went into VRAM once and the write replaced it,
 *  but here the primitive was drawn again on top of the new picture. Crash Bash clears its screen
 *  with one 511x511 black rectangle before the boot logos and then only uploads pictures, so the
 *  logos were drawn and painted over, all but their last column. The mark says "the background is
 *  on top from here, inside this rectangle"; build_scene draws that part of the background
 *  texture at its place in the order. Not a frame boundary: the kept geometry stays, because
 *  outside the rectangle it is still the picture.
 *
 *  Only runs of marks with no primitive between them are compacted — among those the order does
 *  not matter, and a mark inside another adds nothing — which keeps a screen that only uploads
 *  (a logo, a movie) from growing the list at every frame. */
static void mark_vram(int x, int y, int w, int h) {
    if(w <= 0 || h <= 0) return;
    if(!meets(g_disp[0], x, y, w, h) && !meets(g_disp[1], x, y, w, h)) return;
    int i = g_cmd_count;
    while(i > 0 && g_cmds[i - 1].is_rect == GCMD_VRAM) i--;
    for(int k = i; k < g_cmd_count; k++) {
        const gcmd_t* m = &g_cmds[k];
        if(inside(x, y, w, h, m->x[0], m->y[0], m->x[1], m->y[1])) return;
    }
    int out = i;
    for(int k = i; k < g_cmd_count; k++) {
        const gcmd_t* m = &g_cmds[k];
        if(!inside(m->x[0], m->y[0], m->x[1], m->y[1], x, y, w, h)) g_cmds[out++] = *m;
    }
    g_cmd_count = out;
    if(g_cmd_count >= GPU_MAX_CMDS) { g_cmd_overflowed = 1; return; }
    gcmd_t* c = &g_cmds[g_cmd_count++];
    c->is_rect = GCMD_VRAM;
    c->state = 0;
    c->x[0] = (int16_t)x; c->y[0] = (int16_t)y;
    c->x[1] = (int16_t)w; c->y[1] = (int16_t)h;
}

/* The drawing area a primitive is clipped to: latched like the rest of the state, and entered in
 * the state table when it changes on its own — the runtime sends bp_gpu_state only when its own
 * fields change, and a new bottom-right corner leaves them all as they were. */
void bp_gpu_clip(int x0, int y0, int x1, int y1) {
    g_clip_x0 = x0; g_clip_y0 = y0; g_clip_x1 = x1; g_clip_y1 = y1;
    begin_frame_if_needed();
    if(g_state_count <= 0 || g_state_count >= GPU_MAX_STATES) return;
    const gstate_t* p = &g_states[g_state_count - 1];
    if(p->clip_x0 == x0 && p->clip_y0 == y0 && p->clip_x1 == x1 && p->clip_y1 == y1) return;
    gstate_t* n = &g_states[g_state_count++];
    *n = *p;
    n->clip_x0 = (int16_t)x0; n->clip_y0 = (int16_t)y0;
    n->clip_x1 = (int16_t)x1; n->clip_y1 = (int16_t)y1;
}

/* Recorded, not yet applied. The PVR has no stencil; the browser backend models these with one. */
static int g_mask_set, g_mask_check;
void bp_gpu_mask(int set_bit, int check_bit) {
    g_mask_set = set_bit; g_mask_check = check_bit;
}

void bp_gpu_dirty(int x, int y, int w, int h) {
    g_scene_dirty = 1;
    /* Only the background slots whose rectangle the write meets: games blit into their back
     * buffer every frame while displaying the front one, and treating any write anywhere as "the
     * picture changed" made that 5.5 ms a frame for a picture that had not. A 24bpp slot read
     * three bytes a pixel, half as many halfwords again as it shows. */
    for(int k = 0; k < g_bg_slots; k++) {
        gbg_t* b = &g_bgs[k];
        const int bw = b->d24 ? (b->w * 3 + 1) / 2 : b->w;
        if(b->valid && !(b->x + bw <= x || x + w <= b->x || b->y + b->h <= y || y + h <= b->y))
            b->valid = 0;
        else {}
    }
    mark_vram(x, y, w, h);
    /* Anything decoded out of this rectangle is now a copy of what used to be there. Evict by
     * page and by palette: a CLUT is sixteen or two hundred and fifty-six halfwords on one line,
     * and repainting it changes every texture that reads through it. */
    for(int i = 0; i < g_tex_big_n + g_tex_small_n; i++) {
        if(!g_tex[i].used) continue;
        const int page_hit = !(g_tex[i].tex_x + 256 <= x || x + w <= g_tex[i].tex_x
                            || g_tex[i].tex_y + 256 <= y || y + h <= g_tex[i].tex_y);
        const int clut_hit = g_tex[i].depth == 1
                          && g_tex[i].clut_y >= y && g_tex[i].clut_y < y + h
                          && g_tex[i].clut_x < x + w && g_tex[i].clut_x + 256 > x;
        if(page_hit || clut_hit) g_tex[i].used = 0;
    }
    /* The mirror: a 4bpp page is 64 VRAM halfwords wide and 256 rows tall, and its slot is
     * permanent, so "evict" here means only "decode it again next time it is asked for" — and
     * for a write that covers a small part of the page, only that part. Ballistix scrolls two
     * 16x64 strips through two of the pages it draws with at every frame (VRAM copies), and each
     * cost a whole page decode, twice a scene: tex_decode ~94 ms of an ~860 ms window. A page's
     * dirty rectangle grows by union; past a quarter of the page it is decoded whole. */
    for(int i = 0; i < PAGE4_N; i++) {
        gpage4_t* pg = &g_page4[i];
        if(!pg->valid) continue;
        const int px = (i % PAGE4_COLS) * 64, py = (i / PAGE4_COLS) * 256;
        if(px + 64 <= x || x + w <= px || py + 256 <= y || y + h <= py) continue;
        int x0 = x - px, y0 = y - py, x1 = x + w - px, y1 = y + h - py;
        if(x0 < 0) x0 = 0;
        if(y0 < 0) y0 = 0;
        if(x1 > 64) x1 = 64;
        if(y1 > 256) y1 = 256;
        if(pg->part) {
            if(pg->dx0 < x0) x0 = pg->dx0;
            if(pg->dy0 < y0) y0 = pg->dy0;
            if(pg->dx1 > x1) x1 = pg->dx1;
            if(pg->dy1 > y1) y1 = pg->dy1;
        } else {}
        if((x1 - x0) * (y1 - y0) > 64 * 256 / 4) {
            pg->valid = 0;
            pg->part = 0;
        } else {
            pg->part = 1;
            pg->dx0 = (int16_t)x0; pg->dy0 = (int16_t)y0;
            pg->dx1 = (int16_t)x1; pg->dy1 = (int16_t)y1;
        }
    }
    /* A baked patch has the CLUT inside it, so it goes stale from either direction. */
    for(int i = 0; i < g_bake_n; i++) {
        if(!g_bake[i].used) continue;
        /* A patch is 64 texels: 16 halfwords at 4bpp, 32 at 8bpp; its CLUT 16 or 256. */
        const int bw = g_bake[i].depth == 1 ? BAKE_DIM / 2 : BAKE_DIM / 4;
        const int cw = g_bake[i].depth == 1 ? 256 : 16;
        const int bx = g_bake[i].tex_x + g_bake[i].tu * bw;
        const int by = g_bake[i].tex_y + g_bake[i].tv * BAKE_DIM;
        const int page_hit = !(bx + bw <= x || x + w <= bx
                            || by + BAKE_DIM <= y || y + h <= by);
        const int clut_hit = g_bake[i].clut_y >= y && g_bake[i].clut_y < y + h
                          && g_bake[i].clut_x < x + w && g_bake[i].clut_x + cw > x;
        if(page_hit || clut_hit) g_bake[i].used = 0;
    }
    /* No palette-bank work here, and that is the point of content-addressed banks: sixteen
     * colours cannot go stale against themselves. A repainted CLUT resolves to a different bank
     * on its next bind, and the old colours keep serving whatever still names them. */
}

/** The vertex alpha a blend mode needs, and the factors that go with it. */
static float blend_setup(pvr_poly_cxt_t* cxt, const gstate_t* s) {
    if(!(s->flags & BP_GPU_SEMI)) return 1.0f;
    switch(s->semi_mode) {
        case 1:   /* B + F — every spark and flame on the machine */
            cxt->blend.src = PVR_BLEND_ONE;
            cxt->blend.dst = PVR_BLEND_ONE;
            return 1.0f;
        case 3:   /* B + F/4 */
            cxt->blend.src = PVR_BLEND_SRCALPHA;
            cxt->blend.dst = PVR_BLEND_ONE;
            return 0.25f;
        case 2:   /* B - F: build_scene draws it as three passes (subtract_passes), and never
                   * asks here. Half-and-half remains only as the nearest single blend. */
            if(!g_warned_sub) {
                g_warned_sub = 1;
                bp_log(BP_LOG_WARN, "gpu: a subtractive blend reached the single-pass path");
            }
            /* fall through */
        default:  /* 0: B/2 + F/2 */
            cxt->blend.src = PVR_BLEND_SRCALPHA;
            cxt->blend.dst = PVR_BLEND_INVSRCALPHA;
            return 0.5f;
    }
}

/**
	Turns the frame's primitives into one PVR scene.

	Order is the whole difficulty. A PlayStation draws strictly in submission order; a PVR sorts
	into three lists and renders opaque, then punch-through, then translucent. The bridge is depth:
	every primitive gets a Z one step nearer than the one before it and the test is
	greater-or-equal, so a later primitive always wins against an earlier one whatever list either
	landed in. Autosorting is off for the same reason — the order is already decided.
**/
/* The last opaque fill rectangle that covers the whole picture, or -1. The list draws in
 * submission order, so everything before it — the VRAM background included — is painted over:
 * none of it has to be uploaded or built. A game that clears its buffer with a fill every frame
 * (Crash Bash does, 512x240, from its first 3D scene on) otherwise paid for a full background
 * upload at every buffer flip, to be hidden by the first primitive. */
static int last_cover(int sw, int sh) {
    for(int i = g_cmd_count - 1; i >= 0; i--) {
        const gcmd_t* c = &g_cmds[i];
        if(c->is_rect != GCMD_RECT) continue;
        const gstate_t* s = &g_states[c->state];
        if(s->flags & BP_GPU_SEMI) continue;
        int ox, oy, ow, oh;
        if(!screen_origin(s, &ox, &oy, &ow, &oh)) continue;
        const int x0 = c->x[0] - ox, y0 = c->y[0] - oy;
        if(x0 <= 0 && y0 <= 0 && x0 + c->x[1] >= sw && y0 + c->y[1] >= sh) return i;
    }
    return -1;
}

/* Whether a VRAM mark from `first` on falls inside the picture (sx, sy, sw, sh): if so the
 * background texture is needed even under a covering fill. */
static int marks_from(int first, int sx, int sy, int sw, int sh) {
    const int disp[4] = { sx, sy, sw, sh };
    for(int i = first < 0 ? 0 : first; i < g_cmd_count; i++) {
        const gcmd_t* c = &g_cmds[i];
        if(c->is_rect == GCMD_VRAM && meets(disp, c->x[0], c->y[0], c->x[1], c->y[1])) return 1;
    }
    return 0;
}

/** The part of the background texture a VRAM mark covers, drawn where the mark sits in the order.
 *  Returns 1 when something was drawn, so the caller restates its own header after it. */
static int draw_mark(const gcmd_t* c, int sx, int sy, int sw, int sh, float scale_x, float scale_y) {
    int x0 = c->x[0], y0 = c->y[0], x1 = c->x[0] + c->x[1], y1 = c->y[0] + c->y[1];
    if(x0 < sx) x0 = sx;
    if(y0 < sy) y0 = sy;
    if(x1 > sx + sw) x1 = sx + sw;
    if(y1 > sy + sh) y1 = sy + sh;
    if(x0 >= x1 || y0 >= y1) return 0;
    pvr_prim(&g_hdr, sizeof(g_hdr));
    pvr_vertex_t v;
    v.argb = 0xFFFFFFFFu;
    v.oargb = 0;
    v.z = 1.0f;
    const float u0 = (float)(x0 - sx) / (float)g_txw, u1 = (float)(x1 - sx) / (float)g_txw;
    const float w0 = (float)(y0 - sy) / (float)g_txh, w1 = (float)(y1 - sy) / (float)g_txh;
    const float px0 = (float)(x0 - sx) * scale_x, px1 = (float)(x1 - sx) * scale_x;
    const float py0 = (float)(y0 - sy) * scale_y, py1 = (float)(y1 - sy) * scale_y;
    v.flags = PVR_CMD_VERTEX;
    v.x = px0; v.y = py0; v.u = u0; v.v = w0; pvr_prim(&v, sizeof(v));
    v.x = px1; v.y = py0; v.u = u1; v.v = w0; pvr_prim(&v, sizeof(v));
    v.x = px0; v.y = py1; v.u = u0; v.v = w1; pvr_prim(&v, sizeof(v));
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = px1; v.y = py1; v.u = u1; v.v = w1; pvr_prim(&v, sizeof(v));
    return 1;
}

/** Submits the header for this binding, compiled once and kept (see g_hdrc), and returns the
 *  vertex alpha its blend needs. `over` is the second pass of a brightened primitive: the same
 *  texture and source factor, but added to what is there (dst ONE) instead of replacing it. */
/* `keep`, when given, receives a copy of the header emitted, for build_scene to restate without
 * asking the cache again (the slot itself may be taken by the next header that hashes there). */
static float emit_header(pvr_ptr_t mem, int fmt, int dim, const gstate_t* s, int over, int kind,
                         pvr_poly_hdr_t* keep) {
    const int hs = hdr_slot(mem, fmt, dim, s, over, kind);
    if(g_hdrc[hs].used && g_hdrc[hs].mem == mem && g_hdrc[hs].fmt == fmt
       && g_hdrc[hs].dim == dim && g_hdrc[hs].flags == s->flags
       && g_hdrc[hs].semi_mode == s->semi_mode && g_hdrc[hs].over == over
       && g_hdrc[hs].kind == kind) {
        g_hdr_hits++;
        pvr_prim(&g_hdrc[hs].hdr, sizeof(pvr_poly_hdr_t));
        if(keep) *keep = g_hdrc[hs].hdr;
        else {}
        return g_hdrc[hs].alpha;
    }
    float alpha;
    pvr_poly_cxt_t cxt;
    const int blends = (s->flags & BP_GPU_SEMI) && kind == HK_NORMAL;
    if(mem && kind != HK_INVERT) {
        pvr_poly_cxt_txr(&cxt, PVR_LIST_TR_POLY, fmt, dim, dim, mem, PVR_FILTER_NONE);
        /* MODULATE keeps the texel's own alpha: a transparent texel reaches the blender with
         * alpha 0 and the blend below keeps the destination, which is what the PlayStation's
         * "texel zero draws nothing" means. */
        cxt.txr.env = (s->flags & BP_GPU_RAW) ? PVR_TXRENV_REPLACE
                    : (blends ? PVR_TXRENV_MODULATEALPHA : PVR_TXRENV_MODULATE);
        cxt.txr.uv_clamp = PVR_UVCLAMP_NONE;
    } else {
        pvr_poly_cxt_col(&cxt, PVR_LIST_TR_POLY);
    }
    cxt.gen.culling = PVR_CULLING_NONE;
    /* No depth. The list renders in submission order; nothing may re-decide it. */
    cxt.depth.comparison = PVR_DEPTHCMP_ALWAYS;
    cxt.depth.write = false;
    if(kind == HK_INVERT) {
        /* White times one minus the destination, and nothing of the destination kept. */
        cxt.blend.src = PVR_BLEND_INVDESTCOLOR;
        cxt.blend.dst = PVR_BLEND_ZERO;
        alpha = 1.0f;
    } else if(kind == HK_ADD) {
        cxt.blend.src = PVR_BLEND_ONE;
        cxt.blend.dst = PVR_BLEND_ONE;
        alpha = 1.0f;
    } else if(blends) {
        alpha = blend_setup(&cxt, s);
    } else if(mem) {
        /* Opaque textured: solid texels replace, transparent texels keep what is there. */
        cxt.blend.src = PVR_BLEND_SRCALPHA;
        cxt.blend.dst = PVR_BLEND_INVSRCALPHA;
        alpha = 1.0f;
    } else {
        cxt.blend.src = PVR_BLEND_ONE;
        cxt.blend.dst = PVR_BLEND_ZERO;
        alpha = 1.0f;
    }
    if(over) cxt.blend.dst = PVR_BLEND_ONE;
    pvr_poly_compile(&g_hdrc[hs].hdr, &cxt);
    g_hdrc[hs].used = 1;
    g_hdrc[hs].mem = mem;
    g_hdrc[hs].fmt = fmt;
    g_hdrc[hs].dim = dim;
    g_hdrc[hs].flags = s->flags;
    g_hdrc[hs].semi_mode = s->semi_mode;
    g_hdrc[hs].over = (uint8_t)over;
    g_hdrc[hs].kind = (uint8_t)kind;
    g_hdrc[hs].alpha = alpha;
    g_hdr_compiles++;
    pvr_prim(&g_hdrc[hs].hdr, sizeof(pvr_poly_hdr_t));
    if(keep) *keep = g_hdrc[hs].hdr;
    else {}
    return alpha;
}

/** One triangle's vertices, written straight into a store queue and flushed to the TA (KOS direct
 *  rendering). Every field is written: the queue holds whatever went before.
 *
 *  Each coordinate is one conversion and one multiply-add: the offsets — the drawing area's
 *  origin in screen units, the texel centre and patch origin in texture units — are the caller's,
 *  converted once per run. They were converted again at every vertex, six int-to-float
 *  conversions and ten float operations where four and four do. */
static inline void put_tri(const gcmd_t* c, const uint32_t* col, float scale_x, float scale_y,
                           float xo, float yo, float rdim, float uo, float vo) {
    for(int k = 0; k < 3; k++) {
        pvr_vertex_t* v = (pvr_vertex_t*)pvr_dr_target();
        v->flags = (k == 2) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX;
        v->x = (float)c->x[k] * scale_x + xo;
        v->y = (float)c->y[k] * scale_y + yo;
        v->z = 1.0f;
        v->u = (float)c->u[k] * rdim + uo;
        v->v = (float)c->v[k] * rdim + vo;
        v->argb = col[k];
        v->oargb = 0;
        pvr_dr_commit(v);
    }
}

/* The current run's header and its brightening header, as build_scene last emitted them. */
static pvr_poly_hdr_t g_run_hdr __attribute__((aligned(32)));
static pvr_poly_hdr_t g_run_over __attribute__((aligned(32)));

/* The scene's binding as build_scene last emitted it, and what put_tri adds after scaling. */
typedef struct {
    float     scale_x, scale_y;
    int       state, fmt, dim, ou, ov, kind;
    pvr_ptr_t mem;
    /* The reciprocal of the bound texture's size, so the vertex loop multiplies where it used to
     * divide. The divisor is constant for a whole run of primitives and SH-4's FDIV is expensive
     * and poorly pipelined; at three vertices and two coordinates each, a busy scene was asking
     * for nine thousand divisions a frame to compute a number that changes a few dozen times. */
    float     rdim, xo, yo, uo, vo;
    uint32_t  a;              /* the vertex alpha the header's blend wants, in place */
    /* The current state's buffer corner in VRAM (screen_origin) and its drawing area, both in
     * VRAM units: the area as integers for the inside test, and as the edges the clipper cuts
     * at — the right and bottom one past the last pixel, since pixel x covers [x, x + 1). */
    int       ox, oy, clx0, cly0, clx1, cly1;
    int       cut_x, cut_y;   /* whether an edge of that axis lies inside the picture at all */
    /* A brightening pass or a VRAM mark puts another header on the list in the middle of a run,
     * and the run's next primitive must say its own again. That used to be a full lookup — the
     * state compared, the cache hashed and searched — twice per brightened primitive, and a busy
     * arena brightens a quarter of them. Now the run's header is kept when first emitted and
     * copied back (`restate`), and the brightening header is looked up once per run. */
    int       restate, over_ready;
} gscene_t;

/* A texture, bound: where it is, its format and size, and the patch origin in texels. */
typedef struct { pvr_ptr_t mem; int fmt, dim, ou, ov; } gbind_t;

/* Which kinds of texel a state's CLUT holds: bit 0 solid, bit 1 STP, none when only holes. A
 * 15bpp page has no CLUT to ask and answers both, which is always right and costs one more
 * pass. Conservative: a primitive may sample only one kind of a mixed CLUT. */
enum { CLS_NONE = 0, CLS_SOLID = 1, CLS_STP = 2, CLS_MIXED = 3 };

#define CLS_MEMO 256
static struct { uint32_t gen; uint16_t cx, cy; uint8_t depth, cls; } g_cls_memo[CLS_MEMO];

/* Remembered for one scene build, as pal_bank_cached's answers are: VRAM is still while the scene
 * is built, and a semi-transparent state's CLUT was scanned again at every run that used it — an
 * 8bpp one is 256 reads. */
static int clut_class_scan(const gstate_t* s);
static int clut_class(const gstate_t* s) {
    if(s->depth == 2) return CLS_MIXED;
    const uint32_t k = (((uint32_t)s->clut_x >> 4) ^ ((uint32_t)s->clut_y * 0x9E5u)
                        ^ ((uint32_t)s->depth << 7)) & (CLS_MEMO - 1);
    if(g_cls_memo[k].gen == g_pal_memo_gen && g_cls_memo[k].cx == s->clut_x
       && g_cls_memo[k].cy == s->clut_y && g_cls_memo[k].depth == s->depth)
        return g_cls_memo[k].cls;
    const int cls = clut_class_scan(s);
    g_cls_memo[k].gen = g_pal_memo_gen;
    g_cls_memo[k].cx = s->clut_x;
    g_cls_memo[k].cy = s->clut_y;
    g_cls_memo[k].depth = s->depth;
    g_cls_memo[k].cls = (uint8_t)cls;
    return cls;
}

static int clut_class_scan(const gstate_t* s) {
    const int n = s->depth == 1 ? 256 : 16;
    const uint16_t* row = g_vram + (size_t)(s->clut_y & 511) * VRAM_W;
    int cls = CLS_NONE;
    for(int i = 0; i < n && cls != CLS_MIXED; i++) {
        const uint16_t p = row[(s->clut_x + i) & 1023];
        if(p != 0) cls |= (p & 0x8000u) ? CLS_STP : CLS_SOLID;
    }
    return cls;
}

/* The texture answers for a run of primitives sharing a state — which is how they arrive — per
 * variant (AM_*), each asked for on first use: most runs only ever want one. */
typedef struct {
    int       state;
    int       bank[AM_N], slot[AM_N];   /* -2: not asked yet */
    int       patch8, cls;
    pvr_ptr_t mir;
} grun_t;

static void run_begin(grun_t* r, const gstate_t* s, int state) {
    r->state = state;
    for(int k = 0; k < AM_N; k++) { r->bank[k] = -2; r->slot[k] = -2; }
    /* The page grid is the mirror's index, so a page origin that is not on the grid would
     * silently read a neighbour. The texpage encoding cannot produce one; the guard costs a
     * compare and removes the assumption. */
    const int plain = (s->window & 0x3FF) == 0 && (s->tex_x & 63) == 0 && (s->tex_y & 255) == 0;
    r->mir = (s->depth == 0 && plain) ? page4_mirror(s) : NULL;
    /* An unwindowed 8bpp page is drawn from 64x64 patches through its CLUT (bake_slot); the
     * whole page is decoded only for a primitive sampling across patches. */
    r->patch8 = s->depth == 1 && plain;
    r->cls = (s->flags & BP_GPU_SEMI) ? clut_class(s) : CLS_SOLID;
}

/* The 64x64 patch a primitive samples within, if it samples within one. */
static int one_patch(const gcmd_t* c, int* tu, int* tv) {
    int umin = c->u[0], umax = c->u[0], vmin = c->v[0], vmax = c->v[0];
    for(int k = 1; k < 3; k++) {
        if(c->u[k] < umin) umin = c->u[k];
        if(c->u[k] > umax) umax = c->u[k];
        if(c->v[k] < vmin) vmin = c->v[k];
        if(c->v[k] > vmax) vmax = c->v[k];
    }
    *tu = umin / BAKE_DIM;
    *tv = vmin / BAKE_DIM;
    return umax / BAKE_DIM == *tu && vmax / BAKE_DIM == *tv;
}

/** Where primitive c's texels come from in variant `am`, into b; 0 when nowhere, and then the
 *  primitive is skipped — drawing it untextured would be worse. */
__attribute__((noinline))
static int bind_texture_slow(const gcmd_t* c, const gstate_t* s, int am, grun_t* r, gbind_t* b) {
    int tu, tv;
    b->ou = 0; b->ov = 0; b->dim = TEX_DIM;
    if(r->mir) {
        if(r->bank[am] == -2) r->bank[am] = pal_bank_cached(s->clut_x, s->clut_y, 0, am);
        if(r->bank[am] >= 0) {
            b->mem = r->mir;
            b->fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(r->bank[am]) | PVR_TXRFMT_TWIDDLED;
            return 1;
        }
        /* No bank was left for this palette, so draw it from texels that already have the CLUT
         * in them — exact, and only as large as this primitive samples. */
        const int k = one_patch(c, &tu, &tv) ? bake_slot(s, tu, tv, am) : -1;
        if(k >= 0) {
            b->mem = g_bake[k].mem;
            b->fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
            b->dim = BAKE_DIM; b->ou = tu * BAKE_DIM; b->ov = tv * BAKE_DIM;
            return 1;
        }
        /* Sampling wider than one patch, or the patch pool is all in flight: the nearest banked
         * palette, which is the only lossy path left in the scene. */
        g_bake_miss++;
        const int nb = pal_bank_cached(s->clut_x, s->clut_y, 1, am);
        b->mem = r->mir;
        b->fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(nb < 0 ? 0 : nb) | PVR_TXRFMT_TWIDDLED;
        return 1;
    }
    if(r->patch8) {
        const int k = one_patch(c, &tu, &tv) ? bake_slot(s, tu, tv, am) : -1;
        if(k >= 0) {
            b->mem = g_bake[k].mem;
            b->fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
            b->dim = BAKE_DIM; b->ou = tu * BAKE_DIM; b->ov = tv * BAKE_DIM;
            return 1;
        }
        /* Sampling wider than one patch, or every patch in flight: the page. */
        if(r->slot[am] == -2) r->slot[am] = tex_slot(s, am);
        if(r->slot[am] < 0) return 0;
        g_tex[r->slot[am]].bound_frame = g_tex_frame;
        b->mem = g_tex[r->slot[am]].mem;
        b->fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
        return 1;
    }
    if(r->slot[am] == -2) {
        r->slot[am] = tex_slot(s, am);
        if(r->slot[am] >= 0 && s->depth == 0)
            r->bank[am] = pal_bank_cached(s->clut_x, s->clut_y, 1, am);
    }
    if(r->slot[am] < 0) return 0;
    g_tex[r->slot[am]].bound_frame = g_tex_frame;
    b->mem = g_tex[r->slot[am]].mem;
    b->fmt = s->depth == 0
        ? (PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(r->bank[am] < 0 ? 0 : r->bank[am])
           | PVR_TXRFMT_TWIDDLED)
        : (PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED);
    return 1;
}

/* A vertex of a clipped polygon, in VRAM units, with what is interpolated along an edge. */
typedef struct { float x, y, u, v, r, g, b; } cvert_t;

/* One Sutherland-Hodgman step: keeps the part of polygon v (n vertices) on the inner side of an
 * edge — coordinate `axis` (0 x, 1 y) at least `lim` when `lower`, at most it otherwise. */
static int clip_step(const cvert_t* v, int n, cvert_t* out, int axis, float lim, int lower) {
    int m = 0;
    for(int i = 0; i < n; i++) {
        const cvert_t* a = &v[i];
        const cvert_t* b = &v[i + 1 == n ? 0 : i + 1];
        const float ca = axis ? a->y : a->x, cb = axis ? b->y : b->x;
        const float da = lower ? ca - lim : lim - ca, db = lower ? cb - lim : lim - cb;
        if(da >= 0.0f) out[m++] = *a;
        if((da >= 0.0f) != (db >= 0.0f)) {
            const float t = da / (da - db);
            cvert_t* o = &out[m++];
            o->x = a->x + (b->x - a->x) * t;
            o->y = a->y + (b->y - a->y) * t;
            o->u = a->u + (b->u - a->u) * t;
            o->v = a->v + (b->v - a->v) * t;
            o->r = a->r + (b->r - a->r) * t;
            o->g = a->g + (b->g - a->g) * t;
            o->b = a->b + (b->b - a->b) * t;
        }
    }
    return m;
}

/** A triangle cut to its state's drawing area and sent as one strip: texture coordinates and
 *  colour interpolated along the cut edges, alpha the state's. At most seven vertices — three,
 *  and one more per edge of the area. */
static void put_clipped(const gcmd_t* c, const uint32_t* col, const gscene_t* g) {
    cvert_t buf[2][8];
    cvert_t* v = buf[0];
    cvert_t* w = buf[1];
    for(int k = 0; k < 3; k++) {
        v[k].x = (float)c->x[k]; v[k].y = (float)c->y[k];
        v[k].u = (float)c->u[k]; v[k].v = (float)c->v[k];
        v[k].r = (float)((col[k] >> 16) & 0xFF);
        v[k].g = (float)((col[k] >> 8) & 0xFF);
        v[k].b = (float)(col[k] & 0xFF);
    }
    /* Only the edges that lie inside the picture, each step writing the other buffer. */
    int n = 3;
    cvert_t* t;
    if(g->cut_x) {
        n = clip_step(v, n, w, 0, (float)g->clx0, 1);          t = v; v = w; w = t;
        if(n) { n = clip_step(v, n, w, 0, (float)(g->clx1 + 1), 0); t = v; v = w; w = t; }
    }
    if(g->cut_y && n) {
        n = clip_step(v, n, w, 1, (float)g->cly0, 1);          t = v; v = w; w = t;
        if(n) { n = clip_step(v, n, w, 1, (float)(g->cly1 + 1), 0); t = v; v = w; w = t; }
    }
    if(n < 3) return;
    /* A convex polygon as a strip: v0, v1, v(n-1), v2, v(n-2), ... */
    int order[8], m = 0, lo = 1, hi = n - 1;
    order[m++] = 0;
    while(lo <= hi) {
        order[m++] = lo++;
        if(lo <= hi) order[m++] = hi--;
    }
    const uint32_t a = col[0] & 0xFF000000u;
    for(int i = 0; i < n; i++) {
        const cvert_t* q = &v[order[i]];
        pvr_vertex_t* d = (pvr_vertex_t*)pvr_dr_target();
        d->flags = (i == n - 1) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX;
        d->x = q->x * g->scale_x + g->xo;
        d->y = q->y * g->scale_y + g->yo;
        d->z = 1.0f;
        d->u = q->u * g->rdim + g->uo;
        d->v = q->v * g->rdim + g->vo;
        d->argb = a | ((uint32_t)(q->r + 0.5f) << 16) | ((uint32_t)(q->g + 0.5f) << 8)
                | (uint32_t)(q->b + 0.5f);
        d->oargb = 0;
        pvr_dr_commit(d);
    }
}

/** A triangle within its state's drawing area as it is, one reaching past it cut to it, and one
 *  wholly outside not at all — what the PlayStation's rasteriser draws of it (GP0 E3h/E4h).
 *  Nearly every triangle is inside, and pays four compares. */
/* Inside means every coordinate at or past the low edge and at or before the high one: all six
 * differences non-negative, one OR and one sign test an axis — and nothing at all for an axis
 * whose edges are the picture's own. The clipper sorts out the rest, including a triangle wholly
 * outside (nothing survives it). */
static inline int tri_inside(const gcmd_t* c, const gscene_t* g) {
    if(g->cut_y) {
        const int lo = g->cly0, hi = g->cly1 + 1;
        const int y0 = c->y[0], y1 = c->y[1], y2 = c->y[2];
        if(((y0 - lo) | (y1 - lo) | (y2 - lo) | (hi - y0) | (hi - y1) | (hi - y2)) < 0) return 0;
    }
    if(g->cut_x) {
        const int lo = g->clx0, hi = g->clx1 + 1;
        const int x0 = c->x[0], x1 = c->x[1], x2 = c->x[2];
        if(((x0 - lo) | (x1 - lo) | (x2 - lo) | (hi - x0) | (hi - x1) | (hi - x2)) < 0) return 0;
    }
    return 1;
}

static inline void emit_tri(const gcmd_t* c, const uint32_t* col, const gscene_t* g) {
    if(tri_inside(c, g))
        put_tri(c, col, g->scale_x, g->scale_y, g->xo, g->yo, g->rdim, g->uo, g->vo);
    else
        put_clipped(c, col, g);
}

/* The passes of a semi-transparent primitive (semi_prim), and their parts. Opaque primitives —
 * nearly all of them — keep build_scene's own loop, which is where this machinery first lived:
 * spread over calls, it cost Crash Bash a second of its 32 s window and Crash 3 a fifth of its
 * scene build. */

/** A new binding: its header, and the offsets put_tri adds under it. */
__attribute__((noinline))
static void scene_header(gscene_t* g, int state, const gstate_t* s, const gbind_t* b, int kind) {
    g->state = state; g->mem = b->mem; g->fmt = b->fmt; g->dim = b->dim;
    g->ou = b->ou; g->ov = b->ov; g->kind = kind;
    g->rdim = 1.0f / (float)b->dim;
    const float alpha = emit_header(b->mem, b->fmt, b->dim, s, 0, kind, &g_run_hdr);
    g->restate = 0;
    g->over_ready = 0;
    /* What put_tri adds after scaling: the buffer's corner on screen, and in the texture the
     * texel centre less the patch origin. rdim is a power of two, so the texture terms are exact
     * either way round. */
    g->xo = -(float)g->ox * g->scale_x;
    g->yo = -(float)g->oy * g->scale_y;
    g->uo = (0.5f - (float)b->ou) * g->rdim;
    g->vo = (0.5f - (float)b->ov) * g->rdim;
    g->a = (uint32_t)(alpha * 255.0f) << 24;
}

/** A rectangle: four vertices, untextured (the runtime clipped it already). */
__attribute__((noinline))
static void scene_rect(const gscene_t* g, const gcmd_t* c, int kind) {
    const float x0 = (float)c->x[0] * g->scale_x + g->xo;
    const float y0 = (float)c->y[0] * g->scale_y + g->yo;
    const float x1 = (float)(c->x[0] + c->x[1]) * g->scale_x + g->xo;
    const float y1 = (float)(c->y[0] + c->y[1]) * g->scale_y + g->yo;
    const uint32_t argb = kind == HK_INVERT ? 0xFFFFFFFFu
                        : ((bgr_to_argb(c->argb[0]) & 0x00FFFFFFu) | g->a);
    for(int k = 0; k < 4; k++) {
        pvr_vertex_t* v = (pvr_vertex_t*)pvr_dr_target();
        v->flags = (k == 3) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX;
        v->x = (k & 1) ? x1 : x0;
        v->y = (k & 2) ? y1 : y0;
        v->z = 1.0f;
        v->u = 0.0f; v->v = 0.0f;
        v->argb = argb;
        v->oargb = 0;
        pvr_dr_commit(v);
    }
}

/** A textured primitive's colour multiplies the texel, 0x80 meaning 1.0, and can go to nearly
 *  2.0 — which the PVR's modulate cannot, so a menu's text drawn in a bright gradient over a grey
 *  font came out at half its brightness, dull and olive. The part above 1.0 is drawn as a
 *  second, additive pass of the same triangle (emit_header's `over`); only primitives that
 *  brighten pay for it. */
__attribute__((noinline))
static void scene_bright(gscene_t* g, const gcmd_t* c, const gstate_t* s, const gbind_t* b,
                         int kind) {
    if(g->over_ready) pvr_prim(&g_run_over, sizeof(g_run_over));
    else {
        emit_header(b->mem, b->fmt, b->dim, s, 1, kind, &g_run_over);
        g->over_ready = 1;
    }
    uint32_t col[3];
    for(int k = 0; k < 3; k++)
        col[k] = (bgr_to_argb_over(c->argb[k]) & 0x00FFFFFFu) | g->a;
    emit_tri(c, col, g);
    g->restate = 1;      /* the next primitive of the run restates its header */
#if RECOMPSX_DC_PROFILE
    g_bright_prims++;
#endif
}

/** Where primitive c's texels come from, the common cases inline in the scene loop: a page
 *  mirror whose palette already has its bank, and a page slot already bound this run. The
 *  rest — a first ask, a baked patch, a fallback — goes the full way. */
static inline int bind_texture(const gcmd_t* c, const gstate_t* s, int am, grun_t* r, gbind_t* b) {
    if(r->mir) {
        if(r->bank[am] >= 0) {
            b->mem = r->mir;
            b->fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(r->bank[am]) | PVR_TXRFMT_TWIDDLED;
            b->dim = TEX_DIM; b->ou = 0; b->ov = 0;
            return 1;
        }
    } else if(!r->patch8 && r->slot[am] >= 0) {
        g_tex[r->slot[am]].bound_frame = g_tex_frame;
        b->mem = g_tex[r->slot[am]].mem;
        b->fmt = s->depth == 0
            ? (PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(r->bank[am] < 0 ? 0 : r->bank[am])
               | PVR_TXRFMT_TWIDDLED)
            : (PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED);
        b->dim = TEX_DIM; b->ou = 0; b->ov = 0;
        return 1;
    }
    return bind_texture_slow(c, s, am, r, b);
}

/** One pass of one primitive: its header when the binding changed, then its vertices by KOS
 *  direct rendering (put_tri), where pvr_prim built each one on the stack and copied it through
 *  a call. */
static void scene_pass(gscene_t* g, const gcmd_t* c, int state, const gstate_t* s,
                       const gbind_t* b, int kind) {
    if(state != g->state || b->mem != g->mem || b->fmt != g->fmt || b->dim != g->dim
       || b->ou != g->ou || b->ov != g->ov || kind != g->kind) {
        scene_header(g, state, s, b, kind);
    } else if(g->restate) {
        pvr_prim(&g_run_hdr, sizeof(g_run_hdr));
        g->restate = 0;
    }
    if(c->is_rect) {
        scene_rect(g, c, kind);
        return;
    }
    uint32_t col[3];
    int bright = 0;
    if(kind == HK_INVERT) {
        col[0] = col[1] = col[2] = 0xFFFFFFFFu;     /* an inverting pass is white */
    } else {
        const uint32_t a = g->a;
        for(int k = 0; k < 3; k++) {
            col[k] = ((b->mem ? bgr_to_argb_mod(c->argb[k]) : bgr_to_argb(c->argb[k]))
                      & 0x00FFFFFFu) | a;
            if(b->mem && bgr_brightens(c->argb[k])) bright = 1;
        }
    }
    emit_tri(c, col, g);
    if(bright && kind != HK_ADD && !(s->flags & BP_GPU_RAW)) scene_bright(g, c, s, b, kind);
}

/** B - F, which the PVR's blender cannot subtract, as 1 - ((1 - B) + F) in three passes of the
 *  same primitive: invert what is under it, add F — clamping at white is the PlayStation's
 *  clamp at zero, seen inverted — and invert back. The tile buffer blends at eight bits a
 *  channel, so each pass is exact. Where F is a texture the STP variant is black wherever a
 *  texel must not subtract, so the whole primitive can be inverted twice. Crash Bandicoot:
 *  Warped fades every transition with a full-screen quad in this mode, its colour stepping from
 *  FFFFFF (black) to 121212; drawn half-and-half, the screen went a flat grey instead. */
static void subtract_passes(gscene_t* g, const gcmd_t* c, int state, const gstate_t* s,
                            const gbind_t* b) {
    const gbind_t none = { NULL, 0, TEX_DIM, 0, 0 };
    scene_pass(g, c, state, s, &none, HK_INVERT);
    scene_pass(g, c, state, s, b, HK_ADD);
    scene_pass(g, c, state, s, &none, HK_INVERT);
}

/** A semi-transparent primitive, as the PlayStation draws it: per texel for a textured one —
 *  where the CLUT holds both kinds, the solid texels first as an opaque primitive draws them, then
 *  the STP ones in the state's blend, at 8bpp and 15bpp (a 4bpp CLUT holding both is drawn whole,
 *  every visible texel blended: its variants would be two more palette banks per CLUT, and Crash
 *  Bandicoot: Warped already binds sixty-odd CLUTs a frame against the hardware's sixty-four;
 *  split, the banks ran out and the frame went 10 % slower) — and B - F in three passes. */
__attribute__((noinline))
static void semi_prim(gscene_t* g, grun_t* r, const gcmd_t* c, int state, const gstate_t* s) {
    static const gbind_t none = { NULL, 0, TEX_DIM, 0, 0 };
    const int sub = s->semi_mode == 2;
    if(!(s->flags & BP_GPU_TEXTURED) || c->is_rect) {
        if(sub) subtract_passes(g, c, state, s, &none);
        else scene_pass(g, c, state, s, &none, HK_NORMAL);
        return;
    }
    if(state != r->state) run_begin(r, s, state);
    if(r->cls == CLS_NONE) return;                /* holes only */
    gbind_t b;
    if(r->cls == CLS_SOLID) {
        /* No texel blends: drawn as the opaque primitive it is. */
        if(bind_texture(c, s, AM_VIS, r, &b)) scene_pass(g, c, state, s, &b, HK_OPAQUE);
        return;
    }
    const int split = r->cls == CLS_MIXED && s->depth != 0;
    if(split && bind_texture(c, s, AM_SOLID, r, &b)) scene_pass(g, c, state, s, &b, HK_OPAQUE);
    if(!bind_texture(c, s, split ? AM_STP : AM_VIS, r, &b)) return;
    if(sub) subtract_passes(g, c, state, s, &b);
    else scene_pass(g, c, state, s, &b, HK_NORMAL);
}

PROF_NOINLINE static void build_scene(int sx, int sy, int sw, int sh, int with_background, int first) {
    if(sw <= 0 || sh <= 0) return;
    const float scale_x = 640.0f / (float)sw;
    const float scale_y = 480.0f / (float)sh;

    pvr_list_begin(PVR_LIST_TR_POLY);

    if(with_background) {
        pvr_prim(&g_hdr, sizeof(g_hdr));
        draw_quad(sw, sh);
    }

    g_pal_memo_gen++;         /* VRAM may have changed since the last build */
    palette_priority();

    /* The semi-transparent path's own binding and texture answers (semi_prim), and what both
     * paths share: the scale, and the current state's buffer corner and drawing area. */
    gscene_t g;
    g.scale_x = scale_x; g.scale_y = scale_y;
    g.state = -1; g.fmt = -1; g.dim = 0; g.ou = 0; g.ov = 0; g.kind = -1;
    g.mem = NULL;
    g.rdim = 1.0f / (float)TEX_DIM;
    g.xo = 0.0f; g.yo = 0.0f; g.uo = 0.0f; g.vo = 0.0f;
    g.a = 0xFF000000u;
    g.restate = 0; g.over_ready = 0;
    g.ox = 0; g.oy = 0; g.clx0 = 0; g.cly0 = 0; g.clx1 = 1023; g.cly1 = 511;
    g.cut_x = 0; g.cut_y = 0;
    grun_t semi_run;
    semi_run.state = -1;
    int placed_state = -1, placed = 0;
    int area[6] = { -1, -1, -1, -1, -1, -1 };

    int cur_state = -1, cur_fmt = -1, cur_dim = 0, cur_ou = 0, cur_ov = 0;
    /* The reciprocal of the bound texture's size, so the vertex loop multiplies where it used to
     * divide. The divisor is constant for a whole run of primitives and SH-4's FDIV is expensive
     * and poorly pipelined; at three vertices and two coordinates each, a busy scene was asking
     * for nine thousand divisions a frame to compute a number that changes a few dozen times. */
    float cur_rdim = 1.0f / (float)TEX_DIM;
    pvr_ptr_t cur_mem = NULL;
    /* Resolved once per run of primitives sharing a state — which is how they arrive. */
    int run_state = -1, run_bank = -1, run_slot = -1, run_patch8 = 0;
    pvr_ptr_t run_mir = NULL;
    float alpha = 1.0f;
    /* A brightening pass or a VRAM mark puts another header on the list in the middle of a run,
     * and the run's next primitive must say its own again. That used to be a full lookup — the
     * state compared, the cache hashed and searched — twice per brightened primitive, and a busy
     * arena brightens a quarter of them. Now the run's header is kept when first emitted and
     * copied back (`restate`), and the brightening header is looked up once per run. */
    int restate = 0, over_ready = 0;
    float cur_xo = 0.0f, cur_yo = 0.0f, cur_uo = 0.0f, cur_vo = 0.0f;
    uint32_t cur_a = 0xFF000000u;
    for(int i = first; i < g_cmd_count; i++) {
        const gcmd_t* c = &g_cmds[i];
        if(c->is_rect == GCMD_VRAM) {
            if(draw_mark(c, sx, sy, sw, sh, scale_x, scale_y)) { restate = 1; g.state = -1; }
            else {}
            continue;
        } else {}
        const gstate_t* s = &g_states[c->state];
        /* Where the state's buffer is on screen, and which edges of its drawing area to cut at:
         * a function of the drawing area alone, which changes a few times a frame, where the
         * state changes at nearly every primitive. A new origin reaches the header's offsets
         * because a new state always re-emits the header. */
        if((int)c->state != placed_state) {
            placed_state = (int)c->state;
            if(s->draw_x != area[0] || s->draw_y != area[1] || s->clip_x0 != area[2]
               || s->clip_y0 != area[3] || s->clip_x1 != area[4] || s->clip_y1 != area[5]) {
                area[0] = s->draw_x; area[1] = s->draw_y; area[2] = s->clip_x0;
                area[3] = s->clip_y0; area[4] = s->clip_x1; area[5] = s->clip_y1;
                int ow, oh;
                placed = screen_origin(s, &g.ox, &g.oy, &ow, &oh);
                /* Only the edges of the drawing area that lie inside the picture are cut here;
                 * one at or past the picture's own edge is where the screen ends anyway. Crash
                 * 3's area is its buffer's whole width, and cutting every triangle that crossed
                 * the side of the screen cost 200 ms of the window for nothing. */
                g.clx0 = s->clip_x0 > g.ox ? s->clip_x0 : -32768;
                g.clx1 = s->clip_x1 + 1 < g.ox + ow ? s->clip_x1 : 32766;
                g.cly0 = s->clip_y0 > g.oy ? s->clip_y0 : -32768;
                g.cly1 = s->clip_y1 + 1 < g.oy + oh ? s->clip_y1 : 32766;
                g.cut_x = g.clx0 != -32768 || g.clx1 != 32766;
                g.cut_y = g.cly0 != -32768 || g.cly1 != 32766;
            }
        }
        if(!placed) continue;       /* drawn into VRAM off screen: not a picture */
        if(s->flags & BP_GPU_SEMI) {
            semi_prim(&g, &semi_run, c, (int)c->state, s);
            cur_state = -1;         /* its headers went out after this loop's */
            continue;
        }

        const int textured = (s->flags & BP_GPU_TEXTURED) && !c->is_rect;
        pvr_ptr_t mem = NULL;
        int fmt = 0, dim = TEX_DIM, ou = 0, ov = 0;

        if(textured) {
            if((int)c->state != run_state) {
                run_state = (int)c->state;
                run_bank = -1; run_slot = -1; run_mir = NULL;
                /* The page grid is the mirror's index, so a page origin that is not on
                 * the grid would silently read a neighbour. The texpage encoding cannot
                 * produce one; the guard costs a compare and removes the assumption. */
                if(s->depth == 0 && (s->window & 0x3FF) == 0
                   && (s->tex_x & 63) == 0 && (s->tex_y & 255) == 0)
                    run_mir = page4_mirror(s);
                else {}
                /* An unwindowed 8bpp page is drawn from 64x64 patches through its CLUT
                 * (bake_slot); the whole page is decoded only for a primitive sampling across
                 * patches, below. */
                run_patch8 = s->depth == 1 && (s->window & 0x3FF) == 0
                          && (s->tex_x & 63) == 0 && (s->tex_y & 255) == 0;
                if(run_mir) {
                    run_bank = pal_bank_cached(s->clut_x, s->clut_y, 0, AM_VIS);
                } else if(!run_patch8) {
                    run_slot = tex_slot(s, AM_VIS);
                    if(run_slot >= 0 && s->depth == 0)
                        run_bank = pal_bank_cached(s->clut_x, s->clut_y, 1, AM_VIS);
                } else {}
            }
            if(run_mir && run_bank >= 0) {
                mem = run_mir;
                fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(run_bank) | PVR_TXRFMT_TWIDDLED;
            } else if(run_mir || run_patch8) {
                /* No bank was left for this palette, or an 8bpp page: texels with the CLUT
                 * already in them — exact, and only as large as this primitive samples. */
                int tu, tv;
                const int b = one_patch(c, &tu, &tv) ? bake_slot(s, tu, tv, AM_VIS) : -1;
                if(b >= 0) {
                    mem = g_bake[b].mem;
                    fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
                    dim = BAKE_DIM; ou = tu * BAKE_DIM; ov = tv * BAKE_DIM;
                } else if(run_mir) {
                    /* Sampling wider than one patch, or the patch pool is all in flight: the
                     * nearest banked palette, which is the only lossy path left in the scene. */
                    g_bake_miss++;
                    const int nb = pal_bank_cached(s->clut_x, s->clut_y, 1, AM_VIS);
                    mem = run_mir;
                    fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(nb < 0 ? 0 : nb)
                        | PVR_TXRFMT_TWIDDLED;
                } else {
                    /* Sampling wider than one patch, or every patch in flight: the page. */
                    if(run_slot < 0) run_slot = tex_slot(s, AM_VIS);
                    else {}
                    if(run_slot < 0) continue;
                    else {}
                    g_tex[run_slot].bound_frame = g_tex_frame;
                    mem = g_tex[run_slot].mem;
                    fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
                }
            } else if(run_slot >= 0) {
                g_tex[run_slot].bound_frame = g_tex_frame;
                mem = g_tex[run_slot].mem;
                fmt = s->depth == 0
                    ? (PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(run_bank < 0 ? 0 : run_bank)
                       | PVR_TXRFMT_TWIDDLED)
                    : (PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED);
            } else {
                continue;   /* nowhere to put this page; drawing it untextured would be worse */
            }
        }

        if((int)c->state != cur_state || mem != cur_mem || fmt != cur_fmt
           || dim != cur_dim || ou != cur_ou || ov != cur_ov) {
            cur_state = (int)c->state;
            cur_mem = mem; cur_fmt = fmt; cur_dim = dim; cur_ou = ou; cur_ov = ov;
            cur_rdim = 1.0f / (float)dim;
            alpha = emit_header(mem, fmt, dim, s, 0, HK_NORMAL, &g_run_hdr);
            restate = 0;
            over_ready = 0;
            /* What put_tri adds after scaling: the buffer's corner on screen, and in the texture
             * the texel centre less the patch origin. rdim is a power of two, so the texture
             * terms are exact either way round. */
            cur_xo = -(float)g.ox * scale_x;
            cur_yo = -(float)g.oy * scale_y;
            cur_uo = (0.5f - (float)ou) * cur_rdim;
            cur_vo = (0.5f - (float)ov) * cur_rdim;
            cur_a = (uint32_t)(alpha * 255.0f) << 24;
            g.state = -1;           /* the semi-transparent path's header is not the last one now */
        } else if(restate) {
            pvr_prim(&g_run_hdr, sizeof(g_run_hdr));
            restate = 0;
        } else {}

        /* Vertices go by KOS direct rendering (put_tri), where pvr_prim built each one on the
         * stack and copied it through a call. */
        const uint32_t a = cur_a;
        if(c->is_rect) {
            const float x0 = (float)c->x[0] * scale_x + cur_xo;
            const float y0 = (float)c->y[0] * scale_y + cur_yo;
            const float x1 = (float)(c->x[0] + c->x[1]) * scale_x + cur_xo;
            const float y1 = (float)(c->y[0] + c->y[1]) * scale_y + cur_yo;
            const uint32_t argb = (bgr_to_argb(c->argb[0]) & 0x00FFFFFFu) | a;
            for(int k = 0; k < 4; k++) {
                pvr_vertex_t* v = (pvr_vertex_t*)pvr_dr_target();
                v->flags = (k == 3) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX;
                v->x = (k & 1) ? x1 : x0;
                v->y = (k & 2) ? y1 : y0;
                v->z = 1.0f;
                v->u = 0.0f; v->v = 0.0f;
                v->argb = argb;
                v->oargb = 0;
                pvr_dr_commit(v);
            }
        } else {
            /* A textured primitive's colour multiplies the texel, 0x80 meaning 1.0, and can go to
             * nearly 2.0 — which the PVR's modulate cannot, so a menu's text drawn in a bright
             * gradient over a grey font came out at half its brightness, dull and olive. The part
             * above 1.0 is drawn as a second, additive pass of the same triangle (emit_header's
             * `over`); only primitives that brighten pay for it. */
            uint32_t col[3];
            int bright = 0;
            for(int k = 0; k < 3; k++) {
                col[k] = ((mem ? bgr_to_argb_mod(c->argb[k]) : bgr_to_argb(c->argb[k]))
                          & 0x00FFFFFFu) | a;
                if(mem && bgr_brightens(c->argb[k])) bright = 1;
            }
            /* Cut to the drawing area where it reaches past an edge inside the picture. */
            const int inside = tri_inside(c, &g);
            if(!inside) {
                g.xo = cur_xo; g.yo = cur_yo; g.rdim = cur_rdim; g.uo = cur_uo; g.vo = cur_vo;
            } else {}
            if(inside) put_tri(c, col, scale_x, scale_y, cur_xo, cur_yo, cur_rdim, cur_uo, cur_vo);
            else put_clipped(c, col, &g);
            if(bright && !(s->flags & BP_GPU_RAW)) {
                if(over_ready) pvr_prim(&g_run_over, sizeof(g_run_over));
                else {
                    emit_header(mem, fmt, dim, s, 1, HK_NORMAL, &g_run_over);
                    over_ready = 1;
                }
                for(int k = 0; k < 3; k++)
                    col[k] = (bgr_to_argb_over(c->argb[k]) & 0x00FFFFFFu) | a;
                if(inside) put_tri(c, col, scale_x, scale_y, cur_xo, cur_yo, cur_rdim, cur_uo, cur_vo);
                else put_clipped(c, col, &g);
                restate = 1;      /* the next primitive of the run restates its header */
#if RECOMPSX_DC_PROFILE
                g_bright_prims++;
#endif
            } else {}
        }
    }
#if RECOMPSX_DC_PROFILE_OVERLAY
    /* Last: the list is drawn in submission order, so anything submitted before the game's
     * primitives is painted over by them — as the overlay was, when it followed the background. */
    draw_profile_overlay();
#endif
    pvr_list_finish();

#if RECOMPSX_DC_PROFILE
    {
        /* Collected here, PRINTED LATER — outside the region `submit` measures.
         *
         * It used to print from right here, and the cost landed in `submit`: windows carrying
         * this line reported 310-389 ms of scene building against 90-103 in windows without it,
         * and the whole 30-frame window ran ~317 ms longer. The instrument was the largest single
         * thing it was measuring. Serial output is slow and a formatted line of twenty fields is
         * not cheap either; neither belongs inside a timed region, and the interval is now a
         * thousand scenes rather than a hundred. */
        static int every;
        if(g_cmd_count > 0 && (every++ % 1000) == 0) {
            const gcmd_t* c = &g_cmds[0];
            const gstate_t* s0 = &g_states[c->state];
            g_diag.prim = g_cmd_count;      g_diag.state = g_state_count;
            g_diag.mir = g_mir_decodes;     g_diag.tex_dec = g_tex_decodes;
            g_diag.tex_hit = g_tex_hits;    g_diag.tex_conf = g_tex_conflicts;
            g_diag.bake_live = g_bake_live; g_diag.bake_dec = g_bake_decodes;
            g_diag.bake_miss = g_bake_miss; g_diag.pal_live = g_pal_live;
            g_diag.pal_approx = g_pal_stale; g_diag.pal_conf = g_pal_conflicts;
            g_diag.sx = sx; g_diag.sy = sy; g_diag.sw = sw; g_diag.sh = sh;
            g_diag.draw_x = s0->draw_x;     g_diag.draw_y = s0->draw_y;
            g_diag.v0x = c->x[0];           g_diag.v0y = c->y[0];
            g_diag.scr_x = (int)(((float)c->x[0] - (float)s0->draw_x) * scale_x);
            g_diag.scr_y = (int)(((float)c->y[0] - (float)s0->draw_y) * scale_y);
            g_diag.pending = 1;
        } else {}
    }
#endif

    if(g_cmd_overflowed) {
        g_cmd_overflowed = 0;
        bp_log(BP_LOG_WARN, "gpu: more primitives in a frame than the buffer holds — some dropped");
    }
}

static void present_frame(const uint16_t* vram, int sx, int sy, int sw, int sh, int flags) {
    if(!g_ready) return;

#if RECOMPSX_DC_PROFILE
#if RECOMPSX_DC_PROFILE
    if(g_cmd_count == 0 && g_frame_shown) g_empty_presents++;
    else {}
#endif
    const uint64_t t0 = bp_time_us();
    if(g_prof_end) {
        g_prof_emu += t0 - g_prof_end;
        perf_window_close(t0 - g_prof_end);
    } else {}
#endif

    /* The stream is polled here because this is the one call that happens once per emulated
     * frame no matter what the host is doing with pacing. */
    pump_audio();

    if(sw > VRAM_W) sw = VRAM_W;
    if(sh > VRAM_H) sh = VRAM_H;

    const int blank = (sw <= 0 || sh <= 0);

    static int shown_x = -1, shown_y = -1, shown_w = -1, shown_h = -1, shown_flags = -1;
    if(!g_scene_dirty && g_frame_shown && sx == shown_x && sy == shown_y && sw == shown_w
       && sh == shown_h && flags == shown_flags) {
#if RECOMPSX_DC_PROFILE
        g_prof_skipped++;
        g_prof_end = bp_time_us();
        g_prof_submit += g_prof_end - t0;
        profile_report();
        if(g_pc_armed || g_pc_frames == 0) perf_window_open();
        else {}
#endif
        return;
    }
    shown_x = sx; shown_y = sy; shown_w = sw; shown_h = sh; shown_flags = flags;
    g_scene_dirty = 0;

    /* Wait first, upload second. There is one texture and the PVR may still be reading it for the
     * previous frame; overwriting it mid-render would tear a picture that is otherwise correct,
     * which is the kind of fault that gets blamed on the emulator for a week. */
    pvr_wait_ready();
#if RECOMPSX_DC_PROFILE
    const uint64_t t1 = bp_time_us();
    g_prof_wait += t1 - t0;
#endif

    if(!blank && (sx != g_disp[0][0] || sy != g_disp[0][1] || sw != g_disp[0][2] || sh != g_disp[0][3])) {
        memcpy(g_disp[1], g_disp[0], sizeof(g_disp[0]));
        g_disp[0][0] = sx; g_disp[0][1] = sy; g_disp[0][2] = sw; g_disp[0][3] = sh;
    } else {}

    /* Covered: no upload, and no slot touched — the next picture that does show the background
     * finds its slot as it left it — unless a VRAM mark after the cover needs the texture. */
    const int cover = (!blank && g_cmd_count > 0) ? last_cover(sw, sh) : -1;
    const int need_bg = cover < 0 || marks_from(cover, sx, sy, sw, sh);
    if(!blank && need_bg) {
        declare_texture(pot(sw, TXR_MAX_W), pot(sh, TXR_MAX_H));
        const int d24 = (flags & BP_PRESENT_24BPP) != 0;
        const int k = bg_slot(sx, sy, sw, sh, d24);
        /* Without VRAM armed nothing reports writes (software drawing): every picture is new. */
        if(!g_bgs[k].valid || g_vram == NULL) {
            if(d24) upload_24bpp(vram, sx, sy, sw, sh, bg_mem(k));
            else    upload_15bpp(vram, sx, sy, sw, sh, bg_mem(k));
            g_bgs[k].x = sx; g_bgs[k].y = sy; g_bgs[k].w = sw; g_bgs[k].h = sh;
            g_bgs[k].d24 = d24;
            g_bgs[k].valid = 1;
        } else {}
        g_bgs[k].used = g_tex_frame;
        g_hdr = g_bg_hdr[k];
    }
#if RECOMPSX_DC_PROFILE
    const uint64_t t2 = bp_time_us();
    g_prof_upload += t2 - t1;
#endif

    pvr_scene_begin();
    if(g_cmd_count > 0) {
        /* Hardware drawing: the picture is geometry, over whatever VRAM already held. */
        build_scene(sx, sy, sw, sh, !blank && cover < 0, cover < 0 ? 0 : cover);
#if RECOMPSX_DC_PROFILE
        g_prof_build += bp_time_us() - t2;
#endif
    } else {
        pvr_list_begin(PVR_LIST_TR_POLY);
        /* A blank present submits nothing and the background colour becomes the whole screen —
         * which is the point: the display being off is a picture in its own right, and leaving
         * the last frame up instead would be a lie. */
        if(!blank) {
            pvr_prim(&g_hdr, sizeof(g_hdr));
            draw_quad(sw, sh);
        }
#if RECOMPSX_DC_PROFILE_OVERLAY
        draw_profile_overlay();
#endif
        pvr_list_finish();
    }
    pvr_scene_finish();

    /* Not cleared here — see g_frame_shown. The geometry stays until the game draws again. */
    g_frame_shown = 1;
#if RECOMPSX_DC_PROFILE
    /* Conflicts are the one number that must not pass silently, whatever the sampling phase. */
    if(g_tex_conflicts > 0 || g_pal_conflicts > 0) {
        static int warned;
        if(warned++ < 20) {
            char cmsg[128];
            snprintf(cmsg, sizeof(cmsg),
                     "gpu: %d page + %d palette conflict(s) this frame (%d/64 banks live)",
                     g_tex_conflicts, g_pal_conflicts, g_pal_live);
            bp_log(BP_LOG_WARN, cmsg);
        }
    }
    g_tex_decodes = 0;
    g_tex_hits = 0;
    g_tex_conflicts = 0;
    g_pal_conflicts = 0;
    g_pal_stale = 0;
    g_pal_live = 0;
    g_mir_decodes = 0;
    g_bake_live = 0;
    g_bake_decodes = 0;
    g_bake_miss = 0;
#endif
    /* Outside the profile guard on purpose: the in-flight eviction rule is arithmetic on this
     * counter, and a build without profiling must not lose its cache-coherency clock. */
    g_tex_frame++;

#if RECOMPSX_DC_PROFILE
    g_prof_end = bp_time_us();
    g_prof_submit += g_prof_end - t2;
    if(g_diag.pending) {
        g_diag.pending = 0;
        char m2[416];
        snprintf(m2, sizeof(m2),
                 "gpu: %d prim, %d state | mir %d dec | tex %d dec / %d hit / %d CONFLICT"
                 " | bake %d live / %d dec / %d miss"
                 " | pal %d live of 64 / %d approx / %d CONFLICT | disp %d,%d %dx%d | draw %d,%d"
                 " | first v0 vram %d,%d -> screen %d,%d",
                 g_diag.prim, g_diag.state, g_diag.mir, g_diag.tex_dec, g_diag.tex_hit,
                 g_diag.tex_conf, g_diag.bake_live, g_diag.bake_dec, g_diag.bake_miss,
                 g_diag.pal_live, g_diag.pal_approx, g_diag.pal_conf,
                 g_diag.sx, g_diag.sy, g_diag.sw, g_diag.sh, g_diag.draw_x, g_diag.draw_y,
                 g_diag.v0x, g_diag.v0y, g_diag.scr_x, g_diag.scr_y);
        bp_log(BP_LOG_INFO, m2);
    } else {}
    profile_report();
    {
        g_samp_frames++;
        static int every;
        /* The PC histogram goes to the serial port too; with the overlay naming the hot
         * functions on screen it is only the same cost again (see profile_report). */
#if RECOMPSX_DC_PROFILE_OVERLAY
        if((every++ % 200) == 0 && !g_txt) samp_report();
        else {}
#else
        if((every++ % 200) == 0) samp_report();
        else {}
#endif
    }
    if(g_pc_armed || g_pc_frames == 0) perf_window_open();
    else {}
#endif
}

/* A game runs at its own video rate, not at whatever the host manages. Where the Dreamcast is
 * slower than the PlayStation this waits for nothing (bp_pace_frame gives up on a deadline more
 * than four frames behind), but a small scene can outrun it: a cutscene read 75 fps, a quarter
 * faster than the game was written for, and a present whose scene was not rebuilt never waits
 * for the PVR, so nothing else holds it back. With sound on the AICA playing in real time the
 * picture would drift from it too. One present is one emulated vblank, so each is held to
 * 59.94 Hz, or 50 Hz for a PAL display mode. The time spent holding is not the emulator's: it is
 * shown as `pace` and kept out of `emu`. */
static void pace_present(int flags) {
#if RECOMPSX_DC_PROFILE
    const uint64_t a = bp_time_us();
#endif
    bp_pace_frame((flags & BP_PRESENT_PAL) ? 20000 : 16683);
#if RECOMPSX_DC_PROFILE
    const uint64_t b = bp_time_us();
    g_prof_pace += b - a;
    if(g_prof_end) g_prof_end = b;
    else {}
#endif
}

void bp_present(const uint16_t* vram, int sx, int sy, int sw, int sh, int flags) {
    if(!g_ready) return;
    present_frame(vram, sx, sy, sw, sh, flags);
    pace_present(flags);
}

/* ---- audio ------------------------------------------------------------------------------------ */

void bp_audio_push(const int16_t* frames, int frame_count) {
    if(g_stream == SND_STREAM_INVALID || frame_count <= 0) return;

    for(int i = 0; i < frame_count; i++) {
        const int next = (g_ring_head + 1) % RING_FRAMES;
        if(next == g_ring_tail) break;      /* full: the runtime's own cap should prevent this */
        g_ring[g_ring_head * 2 + 0] = frames[i * 2 + 0];
        g_ring[g_ring_head * 2 + 1] = frames[i * 2 + 1];
        g_ring_head = next;
    }
}

/* What the host still holds, which is the ring plus whatever of the AICA's own buffer has not
 * been played. The second part cannot be read back, so it is counted as the average — half the
 * buffer. Getting it approximately right matters: the runtime caps total latency against this
 * number, and reporting only the ring would let the true delay settle a whole AICA buffer
 * higher than asked for. */
int bp_audio_buffered(void) {
    if(g_stream == SND_STREAM_INVALID) return 0;
    pump_audio();
    /* 16-bit samples, so a channel's buffer holds STREAM_BYTES_PER_CHANNEL/2 samples, which is
     * the same number of stereo frames. Half of it is the average still unplayed. */
    const int aica_frames = STREAM_BYTES_PER_CHANNEL / 2 / 2;
    return ring_count() + aica_frames;
}

/* ---- input --------------------------------------------------------------------------------------
 * A Dreamcast pad is four face buttons, a d-pad, Start and two analogue triggers. A PlayStation
 * pad is four face buttons, a d-pad, Start, Select and four shoulders. Two things therefore have
 * to be found homes:
 *
 *   - L1/L2 and R1/R2 share a trigger each, split along its travel: a light pull is the first
 *     shoulder, a hard pull the second.
 *   - Select has no home at all. It is taken from the C button when a pad has one (arcade sticks
 *     and several third-party pads do), and otherwise from Start held with a full left trigger —
 *     which suppresses both of those for that frame, so a game never sees Start and Select at
 *     once from one gesture. */

static uint32_t map_buttons(const cont_state_t* st) {
    uint32_t b = 0;
    const uint32_t k = st->buttons;

    if(k & CONT_DPAD_UP)    b |= PAD_UP;
    if(k & CONT_DPAD_DOWN)  b |= PAD_DOWN;
    if(k & CONT_DPAD_LEFT)  b |= PAD_LEFT;
    if(k & CONT_DPAD_RIGHT) b |= PAD_RIGHT;
    if(k & CONT_A)          b |= PAD_CROSS;
    if(k & CONT_B)          b |= PAD_CIRCLE;
    if(k & CONT_X)          b |= PAD_SQUARE;
    if(k & CONT_Y)          b |= PAD_TRIANGLE;
    if(k & CONT_D)          b |= PAD_L3;

    if(st->ltrig >= TRIG_L2)      b |= PAD_L2;
    else if(st->ltrig >= TRIG_L1) b |= PAD_L1;
    if(st->rtrig >= TRIG_L2)      b |= PAD_R2;
    else if(st->rtrig >= TRIG_L1) b |= PAD_R1;

    const int select_combo = (k & CONT_START) && st->ltrig >= TRIG_L2;
    if((k & CONT_C) || select_combo) b |= PAD_SELECT;
    if((k & CONT_START) && !select_combo) b |= PAD_START;
    if(select_combo) b &= ~(uint32_t)PAD_L2;

    return b;
}

static uint8_t axis_to_byte(int v) {
    const int b = v + 128;
    return (uint8_t)(b < 0 ? 0 : (b > 255 ? 255 : b));
}

void bp_input_poll(void) {
    for(int i = 0; i < MAX_PADS; i++) {
        maple_device_t* dev = maple_enum_dev(i, 0);
        const cont_state_t* st = NULL;
        if(dev && dev->valid && (dev->info.functions & MAPLE_FUNC_CONTROLLER))
            st = (const cont_state_t*)maple_dev_status(dev);

        if(!st) {
            g_pad_present[i] = 0;
            g_pad_buttons[i] = 0;
            g_pad_axes[i][0] = g_pad_axes[i][1] = g_pad_axes[i][2] = g_pad_axes[i][3] = 0x80;
            continue;
        }

        g_pad_present[i] = 1;
        g_pad_buttons[i] = map_buttons(st);
        g_pad_axes[i][0] = axis_to_byte(st->joyx);
        g_pad_axes[i][1] = axis_to_byte(st->joyy);
        /* The pad has one stick. A second one reads centred, which is what a game asking a
         * DualShock about an axis nobody is touching would see. */
        g_pad_axes[i][2] = 0x80;
        g_pad_axes[i][3] = 0x80;

        /* Same gesture as the interrupt-time callback, seen from the polling side. Both exist
         * because they fail differently: this one cannot fire while the emulator is busy not
         * polling, and that one cannot see a pad the maple driver has not enumerated. */
        if((st->buttons & CONT_RESET_BUTTONS) == CONT_RESET_BUTTONS) g_quit = 1;
    }
}

int      bp_pad_connected(int pad) { return (pad >= 0 && pad < MAX_PADS) ? g_pad_present[pad] : 0; }
uint32_t bp_pad_buttons(int pad)   { return (pad >= 0 && pad < MAX_PADS) ? g_pad_buttons[pad] : 0u; }
int      bp_quit_requested(void)   { return g_quit; }

/* Reported digital even though the stick is read: a PlayStation pad in analogue mode has two
 * sticks and this machine has one, and a game that switches modes on the strength of that report
 * would find the right stick permanently centred. The axes are still served, for whatever asks. */
int bp_pad_type(int pad) {
    if(pad < 0 || pad >= MAX_PADS || !g_pad_present[pad]) return BP_PAD_NONE;
    return BP_PAD_DIGITAL;
}

int bp_pad_axis(int pad, int axis) {
    if(pad < 0 || pad >= MAX_PADS || axis < 0 || axis > 3) return 0x80;
    return g_pad_axes[pad][axis];
}

/* ---- storage -------------------------------------------------------------------------------- */

static int storage_path(const char* name, char* out, size_t out_len) {
    if(!g_storage_root || !name || !*name) return 0;
    for(const char* p = name; *p; p++) {
        const char c = *p;
        const int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                    || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if(!ok) return 0;   /* reject anything that could escape the directory */
    }
    snprintf(out, out_len, "%s/%s", g_storage_root, name);
    return 1;
}

int bp_storage_read(const char* name, uint8_t* buf, int len) {
    char path[256];
    if(!storage_path(name, path, sizeof(path))) return -1;
    FILE* f = fopen(path, "rb");
    if(!f) return -1;
    const size_t n = fread(buf, 1, (size_t)len, f);
    fclose(f);
    return (int)n;
}

/* A VMU holds about 100 KB across two hundred blocks of flash, so a 128 KB memory card image does
 * not fit on one and neither does a VRAM dump. Saying so is better than half-writing it. */
#define VMU_CAPACITY 100000

int bp_storage_write(const char* name, const uint8_t* buf, int len) {
    char path[256], tmp[264];
    if(!storage_path(name, path, sizeof(path))) return -1;
    if(g_storage_is_vmu && len > VMU_CAPACITY) {
        bp_log(BP_LOG_WARN, "too large for a VMU — not written");
        return -1;
    }

    /* Elsewhere the write goes to a temporary name and is renamed into place, so a power cut
     * mid-write cannot leave half a memory card behind. On a VMU it does not: the spare copy
     * would need a second 100 KB the card has not got, and flash writes are not atomic at any
     * granularity that would make the dance mean anything. */
    const char* target = path;
    if(!g_storage_is_vmu) {
        snprintf(tmp, sizeof(tmp), "%s.tmp", path);
        target = tmp;
    }

    FILE* f = fopen(target, "wb");
    if(!f) return -1;
    const size_t n = fwrite(buf, 1, (size_t)len, f);
    const int flushed = (fflush(f) == 0);
    fclose(f);
    if(n != (size_t)len || !flushed) { fs_unlink(target); return -1; }

    if(target != path && fs_rename(tmp, path) != 0) {
        /* Not every filesystem KOS mounts will rename over an existing file, and the second save
         * of a session is always over an existing file. Clear the way and try once more — that
         * loses the atomicity for this attempt, which is still better than a save that silently
         * stops working after the first one. */
        fs_unlink(path);
        if(fs_rename(tmp, path) != 0) { fs_unlink(tmp); return -1; }
    }
    return 0;
}

/* ---- disc / file streaming --------------------------------------------------------------------
 * These read the *PlayStation's* disc image, which on this machine is an ordinary file — on the
 * GD-ROM at /cd, on the development host at /pc, or on a mass-storage card. The Dreamcast's own
 * drive is never asked to pretend to be a PlayStation's: all sector layout and ISO9660 logic
 * lives in portable Haxe, and this stays a byte server. */

int bp_file_open(int slot, const char* path) {
    if(slot < 0 || slot >= MAX_FILES || !path) return -1;
    bp_file_close(slot);
    FILE* f = fopen(path, "rb");
    if(!f) return -1;
    /* Unbuffered, which is what makes the drive fast. Buffered, newlib's fread refills its own
     * small, unaligned buffer over and over, so KOS's ISO9660 driver saw sub-sector reads into
     * memory it could not DMA to and fetched every 2048-byte sector with a GD-ROM command of its
     * own: a 128 KB window was 64 commands, and a loading screen waited 2.6 s of every 3 on the
     * disc. Unbuffered, the window buffer (32-byte aligned, 2048-byte aligned offsets) reaches
     * the driver as it is, and the driver streams it — and keeps streaming across contiguous
     * windows, because a seek to where the stream already is does not stop it. */
    setvbuf(f, NULL, _IONBF, 0);
    if(fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    const long size = ftell(f);
    if(size < 0) { fclose(f); return -1; }
    g_files[slot] = f;
    g_file_size[slot] = (int)size;
    return 0;
}

int bp_file_size(int slot) {
    if(slot < 0 || slot >= MAX_FILES || !g_files[slot]) return -1;
    return g_file_size[slot];
}

/* Everything below runs with g_io_lock held unless it says otherwise. */

/** The I/O thread: fills whichever window it is asked for, one at a time, forever. */
static void* disc_io_main(void* unused) {
    (void)unused;
    mutex_lock(&g_io_lock);
    for(;;) {
        while(g_io_request < 0) cond_wait(&g_io_cv, &g_io_lock);
        const int w = g_io_request;
        g_io_request = -1;
        FILE* f = g_files[g_win[w].slot];
        const int at = g_win[w].at;
        const int size = g_win[w].size;
        mutex_unlock(&g_io_lock);
        int got = -1;
        if(f && fseek(f, at, SEEK_SET) == 0) got = (int)fread(g_winbuf[w], 1, (size_t)size, f);
        mutex_lock(&g_io_lock);
#if RECOMPSX_DC_PROFILE
        if(got > 0) g_prof_disc_bytes += (uint32_t)got;
#endif
        g_win[w].got = got;
        g_win[w].state = WIN_READY;
        cond_broadcast(&g_io_cv);
    }
    return NULL;
}

static void disc_io_start(void) {
    if(g_io_thread) return;
    g_io_thread = thd_create(true, disc_io_main, NULL);
    /* Ahead of the emulation, so a finished DMA is followed by the next request at once. */
    if(g_io_thread) thd_set_prio(g_io_thread, PRIO_DEFAULT - 1);
}

static int disc_io_busy(void) {
    return g_win[0].state == WIN_LOADING || g_win[1].state == WIN_LOADING;
}

/** Waits for the I/O thread to go idle; what the emulation stalls on is counted as disc time. */
static void disc_io_wait_idle(void) {
    if(!disc_io_busy()) return;
#if RECOMPSX_DC_PROFILE
    const uint64_t at = bp_time_us();
    g_prof_misses++;
#endif
    while(disc_io_busy()) cond_wait(&g_io_cv, &g_io_lock);
#if RECOMPSX_DC_PROFILE
    g_prof_disc_us += bp_time_us() - at;
#endif
}

static void disc_io_request(int w, int slot, int at, int size) {
    if(size > DISC_WINDOW) size = DISC_WINDOW;
    g_win[w].slot = slot;
    g_win[w].at = at;
    g_win[w].size = size;
    g_win[w].got = 0;
    if(!g_io_thread) {
        /* No thread to hand it to: read it here, synchronously, as the backend always used to. */
        int got = -1;
        if(fseek(g_files[slot], at, SEEK_SET) == 0) got = (int)fread(g_winbuf[w], 1, (size_t)size, g_files[slot]);
#if RECOMPSX_DC_PROFILE
        if(got > 0) g_prof_disc_bytes += (uint32_t)got;
#endif
        g_win[w].got = got;
        g_win[w].state = WIN_READY;
        return;
    }
    g_win[w].state = WIN_LOADING;
    g_io_request = w;
    cond_broadcast(&g_io_cv);
}

static void disc_drop_slot(int slot) {
    disc_io_wait_idle();
    for(int i = 0; i < 2; i++) if(g_win[i].slot == slot) g_win[i].state = WIN_EMPTY;
}

/** Straight to the file, bypassing the windows. Only with the I/O thread idle. */
static int read_direct(int slot, int offset, uint8_t* buf, int len) {
#if RECOMPSX_DC_PROFILE
    const uint64_t at = bp_time_us();
    g_prof_misses++;
#endif
    int got = -1;
    if(fseek(g_files[slot], offset, SEEK_SET) == 0)
        got = (int)fread(buf, 1, (size_t)len, g_files[slot]);
#if RECOMPSX_DC_PROFILE
    g_prof_disc_us += bp_time_us() - at;
    if(got > 0) g_prof_disc_bytes += (uint32_t)got;
#endif
    return got;
}

/* Whether window `w` holds file bytes from `offset` on (at least one). */
static int win_starts(const disc_win_t* w, int slot, int offset) {
    return w->state == WIN_READY && w->slot == slot && w->got > 0
        && offset >= w->at && offset < w->at + w->got;
}

/* Keeps one window read ahead: the bytes right after `c`, contiguous with it, so the drive only
 * ever reads forwards (the old windows overlapped by 4 KB, a step back at every seam). */
static void disc_read_ahead(int cur) {
    const disc_win_t* c = &g_win[cur];
    disc_win_t* n = &g_win[1 - cur];
    if(c->state != WIN_READY || c->got != c->size) return;       /* end of file, or a failure */
    const int want = c->at + c->got;
    if(n->state != WIN_EMPTY && n->slot == c->slot && n->at == want) return;
    if(disc_io_busy()) return;
    disc_io_request(1 - cur, c->slot, want, g_ra_size);
    g_ra_size = g_ra_size * 2 > DISC_WINDOW ? DISC_WINDOW : g_ra_size * 2;
}

int bp_file_read(int slot, int offset, uint8_t* buf, int len) {
    if(slot < 0 || slot >= MAX_FILES || !g_files[slot] || offset < 0 || len <= 0) return -1;
#if RECOMPSX_DC_PROFILE
    g_prof_reads++;
#endif
    disc_io_start();
    mutex_lock(&g_io_lock);

    if(len > DISC_WINDOW - 2048) {
        disc_io_wait_idle();
        const int got = read_direct(slot, offset, buf, len);
        mutex_unlock(&g_io_lock);
        return got;
    }

    int cur = g_win_cur;
    /* The read starts in the window read ahead: wait for it if it is on its way, move on to it,
     * and read on behind it. */
    if(!win_starts(&g_win[cur], slot, offset)) {
        const disc_win_t* n = &g_win[1 - cur];
        if(n->state != WIN_EMPTY && n->slot == slot && offset >= n->at && offset < n->at + n->size) {
            disc_io_wait_idle();
            if(win_starts(n, slot, offset)) {
                cur = 1 - cur;
                g_win_cur = cur;
                disc_read_ahead(cur);
            }
        }
    }
    /* Anywhere else is a seek: a small read to answer it now, and the read-ahead grows from there. */
    if(!win_starts(&g_win[cur], slot, offset)) {
        disc_io_wait_idle();
        const int at = offset & ~2047;
        int size = ((offset + len + 2047) & ~2047) - at;
        if(size < DISC_FIRST) size = DISC_FIRST;
        g_win[1 - cur].state = WIN_EMPTY;
        disc_io_request(cur, slot, at, size);
#if RECOMPSX_DC_PROFILE
        g_prof_misses++;
        const uint64_t t = bp_time_us();
#endif
        while(disc_io_busy()) cond_wait(&g_io_cv, &g_io_lock);
#if RECOMPSX_DC_PROFILE
        g_prof_disc_us += bp_time_us() - t;
#endif
        g_ra_size = size * 2 > DISC_WINDOW ? DISC_WINDOW : size * 2;
        g_win_cur = cur;
        if(win_starts(&g_win[cur], slot, offset)) disc_read_ahead(cur);
    }

    const disc_win_t* c = &g_win[cur];
    int result;
    if(win_starts(c, slot, offset)) {
        const int here = c->at + c->got - offset;
        if(len <= here) {
            memcpy(buf, g_winbuf[cur] + (offset - c->at), (size_t)len);
            result = len;
        } else {
            /* Across the seam: the head from this window, the tail from the next one, which is
             * contiguous with it (asked for now if it is not already on its way). */
            disc_read_ahead(cur);
            const disc_win_t* n = &g_win[1 - cur];
            if(n->state != WIN_EMPTY && n->slot == slot && n->at == c->at + c->got) {
                disc_io_wait_idle();
            }
            if(n->state == WIN_READY && n->slot == slot && n->at == c->at + c->got
               && n->got >= len - here) {
                memcpy(buf, g_winbuf[cur] + (offset - c->at), (size_t)here);
                memcpy(buf + here, g_winbuf[1 - cur], (size_t)(len - here));
                result = len;
            } else {
                /* The file ends here, or the read failed: answered directly and honestly. */
                disc_io_wait_idle();
                result = read_direct(slot, offset, buf, len);
            }
        }
        disc_read_ahead(cur);
    } else {
        disc_io_wait_idle();
        result = read_direct(slot, offset, buf, len);
    }
    mutex_unlock(&g_io_lock);
    return result;
}

void bp_file_close(int slot) {
    if(slot < 0 || slot >= MAX_FILES) return;
    mutex_lock(&g_io_lock);
    disc_drop_slot(slot);
    if(g_files[slot]) { fclose(g_files[slot]); g_files[slot] = NULL; g_file_size[slot] = 0; }
    mutex_unlock(&g_io_lock);
}

/* ---- time and diagnostics ---------------------------------------------------------------------
 * gettimeofday rather than KOS's own timer calls: it is standard C, it exists in every version of
 * KallistiOS, and underneath it is the same 80 ns hardware timer the KOS-specific spellings read.
 * The KOS-specific ones are not stable — timer_us_gettime64 is in the current release and gone
 * from the development branch — and a backend that only builds against one of them is a backend
 * that stops building. */

uint64_t bp_time_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ull + (uint64_t)tv.tv_usec;
}

void bp_sleep_us(uint64_t us) {
    if(us >= 1000ull) thd_sleep((unsigned)(us / 1000ull));
}

void bp_pace_frame(int target_us) {
    static uint64_t next_deadline;
    const uint64_t now = bp_time_us();

    if(target_us <= 0 || next_deadline == 0) {   /* first call, or an explicit reset */
        next_deadline = now + (uint64_t)(target_us > 0 ? target_us : 0);
        return;
    }

    for(;;) {
        /* Sleeping hands the CPU to whatever else KOS is running, but it also stops feeding the
         * AICA, so the stream is topped up on every pass. thd_sleep's granularity is a
         * millisecond; the last one is spun out, because a whole millisecond of slop is visible
         * at 60 Hz.
         *
         * The clock is read once per pass and the remaining time computed from that one reading.
         * Reading it twice would let the deadline pass between them, and on unsigned arithmetic
         * that is not a small error — it is a sleep of about six hundred thousand years. */
        pump_audio();
        const uint64_t at = bp_time_us();
        if(at >= next_deadline) break;
        const uint64_t left = next_deadline - at;
        if(left <= 2000ull) break;
        thd_sleep((unsigned)((left - 1000ull) / 1000ull));
    }
    while(bp_time_us() < next_deadline) { /* spin */ }

    next_deadline += (uint64_t)target_us;

    /* Falling behind is the ordinary case on a 200 MHz SH-4. The debt is capped at four frames,
     * so a stall is never sprinted through, but it is kept rather than wiped: wiping it set the
     * next deadline a whole frame ahead, and a quick frame (a present whose scene was not rebuilt)
     * then waited for it even though the game as a whole ran behind: 53 ms of every 30 frames in
     * Crash Bash's menu at 38 fps. Kept, a game that is behind never waits, and one that is ahead
     * is still held to the rate. */
    const uint64_t after = bp_time_us();
    if(next_deadline + (uint64_t)target_us * 4ull < after) next_deadline = after - (uint64_t)target_us * 4ull;
}

void bp_log(int level, const char* msg) {
#if RECOMPSX_DC_PROFILE_OVERLAY
    /* With the overlay on, nobody is reading the serial port, and every line is still spun out of
     * it a byte at a time: the runtime's heartbeat alone kept scif_write in the overlay's top six.
     * Warnings and errors still go out. */
    if(g_txt && level < BP_LOG_WARN) return;
    else {}
#endif
    static const char* names[] = { "debug", "info", "warn", "error" };
    const char* n = (level >= 0 && level <= 3) ? names[level] : "?";
#if RECOMPSX_DC_PROFILE
    const uint64_t at = bp_time_us();
#endif
    printf("[%s] %s\n", n, msg ? msg : "");
    fflush(stdout);
#if RECOMPSX_DC_PROFILE
    g_prof_log_us += bp_time_us() - at;
    g_prof_logs++;
#endif
}

void bp_fatal(const char* msg) {
    bp_log(BP_LOG_ERROR, msg);
    bp_shutdown();
    arch_exit();
}
