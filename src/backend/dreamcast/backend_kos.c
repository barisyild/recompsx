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
#endif

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
 * "Invalid texture V size", from pvr_poly_compile, at init, before anything is drawn. Four lines
 * of the 24-pixel BIOS font need 96, so the texture is 128 and the bottom 32 rows go unused; the
 * quad's V runs to TXT_USED/TXT_H rather than to 1. */
#define TXT_W 512
#define TXT_H 128
#define TXT_USED 96
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

/* One primitive. A rectangle borrows the triangle's slots: corner in [0], size in [1]. */
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
    uint8_t   flags, semi_mode, used;
    float     alpha;
    pvr_poly_hdr_t hdr;
} ghdr_t;
static ghdr_t g_hdrc[HDRC_N];
static int    g_hdr_hits, g_hdr_compiles;

static int hdr_slot(pvr_ptr_t mem, int fmt, int dim, const gstate_t* s) {
    uint32_t h = (uint32_t)(uintptr_t)mem;
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

typedef struct { pvr_ptr_t mem; uint32_t bound_frame; uint8_t valid, defer; } gpage4_t;
static gpage4_t  g_page4[PAGE4_N];
static pvr_ptr_t g_mir_base;
static int       g_mir_decodes;

typedef struct {
    pvr_ptr_t mem;
    uint16_t  tex_x, tex_y, clut_x, clut_y;
    uint8_t   tu, tv, used;
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

/* Whether emulated VRAM has changed since the background was last uploaded. In hardware mode the
 * only things that write VRAM are uploads and blits, and both announce themselves through
 * bp_gpu_dirty — so when nothing has, the 1 MB texture behind the geometry is still the picture
 * it was, and converting and pushing it again costs 11 ms to arrive at the same bytes. */
static int    g_bg_stale = 1;

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
 * and mixing. Part of `emu` — the overlay prints it beside it — and the runtime never sees the
 * clock, only says where the stretch begins and ends. */
static uint64_t g_prof_section_us[BP_PROFILE_SECTIONS];
static uint64_t g_prof_section_at[BP_PROFILE_SECTIONS];

void bp_profile_mark(int section, int begin) {
    if(section < 0 || section >= BP_PROFILE_SECTIONS) return;
    const uint64_t now = bp_time_us();
    if(begin) {
        g_prof_section_at[section] = now;
    } else if(g_prof_section_at[section]) {
        g_prof_section_us[section] += now - g_prof_section_at[section];
        g_prof_section_at[section] = 0;
    }
}

#define DISC_WINDOW (128 * 1024)
enum { WIN_EMPTY, WIN_LOADING, WIN_READY };
typedef struct {
    int slot;   /* which file */
    int at;     /* file offset of the first byte */
    int got;    /* bytes read; -1 after a failed read */
    int state;
} disc_win_t;
static uint8_t    g_winbuf[2][DISC_WINDOW] __attribute__((aligned(32)));
static disc_win_t g_win[2] = { { -1, 0, 0, WIN_EMPTY }, { -1, 0, 0, WIN_EMPTY } };
static int        g_win_cur;            /* the window reads are served from; the other is next */
static int        g_io_request = -1;    /* a window for the I/O thread to fill, or -1 */
static mutex_t    g_io_lock = MUTEX_INITIALIZER;
static condvar_t  g_io_cv = COND_INITIALIZER;
static kthread_t* g_io_thread;

#if RECOMPSX_DC_PROFILE
static uint64_t g_prof_disc_us;
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
static int g_hw_voices;   /* the AICA plays the SPU's voices; the mixed stream is gone */

static void pump_audio(void) {
    static uint64_t last_us;
    if(g_stream == SND_STREAM_INVALID || g_hw_voices) return;

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
 * The mixing that cost 8 ms a vblank of SH-4 time is the AICA's now. */

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
#endif

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

/* The sample a voice starting at `start` plays: kept, or decoded and uploaded now. */
static int spu_samp_for(int start) {
    for(int i = 0; i < SPU_SAMPLES; i++)
        if(g_spu_samp[i].start == start && !g_spu_samp[i].stale) {
            g_spu_samp[i].used_at = ++g_spu_samp_clock;
            return i;
        }
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
    /* The mixed stream has nothing to carry any more. Destroying it gives its two channels and its
     * sound RAM back, and stops anything polling it. */
    if(g_stream != SND_STREAM_INVALID) {
        snd_stream_stop(g_stream);
        snd_stream_destroy(g_stream);
        g_stream = SND_STREAM_INVALID;
    }
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

void bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r) {
    if(!g_spu_ram || v < 0 || v >= SPU_VOICES || g_vchn[v] < 0) return;
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
            snd_sfx_stop(chn);
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
    samp_start();
#endif

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

static void declare_texture(int w, int h) {
    if(w == g_txw && h == g_txh) return;
    g_txw = w;
    g_txh = h;

    pvr_poly_cxt_t cxt;
    /* The scene has exactly one hardware list — translucent, submission-ordered — so this header
     * must be compiled for it. It was compiled for the opaque list once, which no longer exists:
     * a header naming a disabled list wedges the tile accelerator mid-scene, the scene never
     * finishes, and the next wait-for-ready blocks forever. That was a black screen at boot,
     * because the boot screens are exactly the zero-primitive path that leads with this header. */
    pvr_poly_cxt_txr(&cxt, PVR_LIST_TR_POLY,
                     PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_NONTWIDDLED,
                     w, h, g_txr, RECOMPSX_DC_FILTER);
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
    pvr_poly_compile(&g_hdr, &cxt);
}

/* BGR555 to ARGB1555 is red and blue exchanged, green in place and bit 15 dropped (the quad
 * replaces, so alpha is never read). Done two texels to a 32-bit word and written straight into
 * the store queues, eight words a flush: one pass over the row. It used to be a 16-bit loop
 * into a staging line and then a second pass to copy that line out, about 11 ms for a 512x240
 * picture — and the picture is uploaded at every buffer flip of every menu. */
static inline uint32_t bgr555x2_to_argb1555x2(uint32_t p) {
    return (p & 0x03E003E0u) | ((p & 0x001F001Fu) << 10) | ((p >> 10) & 0x001F001Fu);
}

static void upload_15bpp(const uint16_t* vram, int sx, int sy, int sw, int sh) {
    const int row_bytes = (sw * 2 + 31) & ~31;
    const int row_words = row_bytes >> 2;
    uint8_t* dst = (uint8_t*)g_txr;
    const uintptr_t tex = ((uintptr_t)g_txr & 0xffffff) | PVR_TA_TEX_MEM;
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
static void upload_24bpp(const uint16_t* vram, int sx, int sy, int sw, int sh) {
    const int row_bytes = (sw * 2 + 31) & ~31;
    uint8_t* dst = (uint8_t*)g_txr;

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

static void samp_tick(irq_t code, irq_context_t* ctx, void* data) {
    (void)code; (void)data;
    /* Acknowledge FIRST and unconditionally. An SH-4 timer holds its underflow flag until
     * software clears it, so a handler that returns without clearing is re-entered immediately,
     * forever: the machine stops making progress and the symptom is simply "it does not boot".
     * KOS's own millisecond handler clears the same bit for the same reason. */
    timer_clear(TMU1);
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

static void profile_report(void) {
    if(++g_prof_frames < PROFILE_EVERY) return;

    const uint64_t total = g_prof_emu + g_prof_wait + g_prof_upload + g_prof_submit;
    /* Disc time is taken out of `emu` rather than printed beside it: the reads happen inside the
     * emulated frame, so leaving it in would credit the CPU with the drive's bill — which is
     * exactly the mistake this line exists to prevent. */
    const uint64_t emu = g_prof_emu > g_prof_disc_us ? g_prof_emu - g_prof_disc_us : 0;

    char msg[240];
    snprintf(msg, sizeof(msg),
             "dc: %d frames in %lu ms | emu %lu (spu %lu, aica %lu/%d) | disc %lu (%d rd, %d miss)"
             " | pvr-wait %lu | audio %lu (%d) | upload %lu | build %lu (%d hdr, %d cc) | submit %lu | empty %d | log %d in %lu",
             g_prof_frames,
             (unsigned long)(total / 1000),
             (unsigned long)(emu / 1000), (unsigned long)(g_prof_section_us[BP_PROFILE_SPU] / 1000),
             (unsigned long)(g_prof_aica / 1000), g_prof_aica_decodes,
             (unsigned long)(g_prof_disc_us / 1000), g_prof_reads, g_prof_misses,
             (unsigned long)(g_prof_wait / 1000),
             (unsigned long)(g_prof_audio / 1000), g_prof_polls,
             (unsigned long)(g_prof_upload / 1000),
             (unsigned long)(g_prof_build / 1000), g_hdr_hits, g_hdr_compiles,
             (unsigned long)((g_prof_submit - g_prof_build) / 1000), g_empty_presents,
             g_prof_logs,
             (unsigned long)(g_prof_log_us / 1000));

#if RECOMPSX_DC_PROFILE_OVERLAY
    /* The on-screen copy is built before the serial one is written, so the log counters describe
     * the period they belong to rather than including the cost of reporting themselves. */
    char l0[48], l1[48], l2[48], l3[48];
    const unsigned long tenths = total ? (unsigned long)((uint64_t)g_prof_frames * 10000000u / total) : 0;
    snprintf(l0, sizeof(l0), "%d fr %lu ms %lu.%lu fps", g_prof_frames, (unsigned long)(total / 1000),
             tenths / 10, tenths % 10);
    if(g_hw_voices)
        snprintf(l1, sizeof(l1), "emu %lu spu %lu aica %lu/%d wait %lu",
                 (unsigned long)(emu / 1000), (unsigned long)(g_prof_section_us[BP_PROFILE_SPU] / 1000),
                 (unsigned long)(g_prof_aica / 1000), g_prof_aica_decodes,
                 (unsigned long)(g_prof_wait / 1000));
    else
        snprintf(l1, sizeof(l1), "emu %lu spu %lu wait %lu",
                 (unsigned long)(emu / 1000), (unsigned long)(g_prof_section_us[BP_PROFILE_SPU] / 1000),
                 (unsigned long)(g_prof_wait / 1000));
    snprintf(l2, sizeof(l2), "up %lu build %lu fin %lu",
             (unsigned long)(g_prof_upload / 1000), (unsigned long)(g_prof_build / 1000),
             (unsigned long)((g_prof_submit - g_prof_build) / 1000));
    snprintf(l3, sizeof(l3), "skip %d hdr %d+%d disc %lu",
             g_prof_skipped, g_hdr_hits, g_hdr_compiles, (unsigned long)(g_prof_disc_us / 1000));

    if(g_txt) {
        memset(g_txt_buf, 0, sizeof(g_txt_buf));
        bfont_draw_str_ex(g_txt_buf,                        TXT_W, 0xFFFF, 0, 16, true, l0);
        bfont_draw_str_ex(g_txt_buf + TXT_W * TXT_LINE,     TXT_W, 0xFFFF, 0, 16, true, l1);
        bfont_draw_str_ex(g_txt_buf + TXT_W * TXT_LINE * 2, TXT_W, 0xFFFF, 0, 16, true, l2);
        bfont_draw_str_ex(g_txt_buf + TXT_W * TXT_LINE * 3, TXT_W, 0xFFFF, 0, 16, true, l3);
        pvr_txr_load(g_txt_buf, g_txt, sizeof(g_txt_buf));
        g_txt_ready = 1;
    }
#endif

    g_prof_logs = 0;
    g_prof_log_us = 0;
    bp_log(BP_LOG_INFO, msg);

    g_prof_frames = 0;
    g_prof_emu = g_prof_wait = g_prof_upload = g_prof_submit = g_prof_audio = 0;
    g_prof_polls = 0;
    g_empty_presents = 0;
    g_prof_build = 0;
    g_prof_skipped = 0;
    for(int i = 0; i < BP_PROFILE_SECTIONS; i++) g_prof_section_us[i] = 0;
    g_prof_aica = 0;
    g_prof_aica_decodes = 0;
    g_hdr_hits = g_hdr_compiles = 0;
    g_prof_disc_us = 0;
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
    v.x = 0.0f;   v.y = 384.0f; v.u = 0.0f; v.v = 0.0f; pvr_prim(&v, sizeof(v));
    v.x = 512.0f; v.y = 384.0f; v.u = 1.0f; v.v = 0.0f; pvr_prim(&v, sizeof(v));
    v.x = 0.0f;   v.y = 480.0f; v.u = 0.0f; v.v = vmax; pvr_prim(&v, sizeof(v));
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = 512.0f; v.y = 480.0f; v.u = 1.0f; v.v = vmax; pvr_prim(&v, sizeof(v));
}
#endif
#endif

/* ---- hardware drawing ---------------------------------------------------------------------- */

/** A GP0 command word's 24-bit BGR, as a PVR ARGB8888. */
static uint32_t bgr_to_argb(uint32_t c) {
    return 0xFF000000u | ((c & 0xFFu) << 16) | (c & 0xFF00u) | ((c >> 16) & 0xFFu);
}

/** The same, doubled: PlayStation modulation is texel*colour/128, so 0x80 means "unchanged",
 *  where the PVR's multiply wants 0xFF for that. Brightening past 1.0 is not representable and
 *  clamps — which is the one place this path is dimmer than the software rasteriser. */
static uint32_t bgr_to_argb_mod(uint32_t c) {
    uint32_t r = (c & 0xFFu) << 1, g = ((c >> 8) & 0xFFu) << 1, b = ((c >> 16) & 0xFFu) << 1;
    if(r > 255) r = 255;
    if(g > 255) g = 255;
    if(b > 255) b = 255;
    return 0xFF000000u | (r << 16) | (g << 8) | b;
}

/** BGR555 as VRAM holds it, to the ARGB1555 the PVR samples. Texel zero is the PlayStation's
 *  "nothing here", and becomes alpha 0 so punch-through drops it. */
static uint16_t texel_to_argb1555(uint16_t p) {
    if(p == 0) return 0;
    return (uint16_t)(0x8000u | (p & 0x03E0u) | ((p & 0x001Fu) << 10) | ((p >> 10) & 0x001Fu));
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
static void tex_decode(pvr_ptr_t dst, const gstate_t* s) {
    /* Pages upload as INDICES for the paletted depths, so no CLUT is applied here at all — and
     * with no texture window the 4bpp and 8bpp paths are a straight row copy out of VRAM, since
     * the PlayStation's nibble order is already the PVR's. The window path gathers per texel;
     * it is the rare case. 15bpp still converts colours as before. */
    static uint8_t page[TEX_DIM * TEX_DIM] __attribute__((aligned(32)));
    static uint16_t page16[TEX_DIM * TEX_DIM] __attribute__((aligned(32)));
    static uint16_t clut8[256];

    if(s->depth == 1)
        for(int i = 0; i < 256; i++)
            clut8[i] = texel_to_argb1555(g_vram[(s->clut_y & 511) * VRAM_W + ((s->clut_x + i) & 1023)]);

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
                dst[tx] = texel_to_argb1555(src[(s->tex_x + su) & 1023]);
            }
        }
    }
    if(s->depth == 0)
        pvr_txr_load_ex(page, dst, TEX_DIM, TEX_DIM, PVR_TXRLOAD_4BPP);
    else
        pvr_txr_load_ex(page16, dst, TEX_DIM, TEX_DIM, PVR_TXRLOAD_16BPP);
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
static int pal_bank_at(int clut_x, int clut_y, int allow_approx) {
    uint16_t want[16];
    uint32_t h = 2166136261u;
    for(int i = 0; i < 16; i++) {
        want[i] = texel_to_argb1555(g_vram[(clut_y & 511) * VRAM_W + ((clut_x + i) & 1023)]);
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

/** The slot holding this page, decoding it first if nobody has. Round-robin eviction: a scene
 *  using more than sixteen pages will thrash, and the profiler is what would say so. */
static int tex_slot(const gstate_t* s) {
    for(int i = 0; i < g_tex_big_n + g_tex_small_n; i++) {
        if(g_tex[i].used && g_tex[i].tex_x == s->tex_x && g_tex[i].tex_y == s->tex_y
           && g_tex[i].depth == s->depth && g_tex[i].window == s->window
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
    g_tex_decodes++;
    tex_decode(g_tex[slot].mem, s);
    return slot;
}

/** The permanent 4bpp mirror slot for a texture page, decoded on first use and after any write
 *  to the VRAM it covers. Never evicted: the slot IS the page, so nothing else can want it. */
static pvr_ptr_t page4_mirror(const gstate_t* s) {
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
            tex_decode(pg->mem, s);
            pg->valid = 1;
            pg->defer = 0;
            g_mir_decodes++;
        }
    }
    pg->bound_frame = g_tex_frame;
    return pg->mem;
}

/** One 64x64 patch of a page with a CLUT already applied, for palettes that got no bank. */
static void bake_decode(pvr_ptr_t dst, const gstate_t* s, int tu, int tv) {
    static uint16_t buf[BAKE_DIM * BAKE_DIM] __attribute__((aligned(32)));
    uint16_t clut[16];
    for(int i = 0; i < 16; i++)
        clut[i] = texel_to_argb1555(g_vram[(s->clut_y & 511) * VRAM_W + ((s->clut_x + i) & 1023)]);
    for(int ty = 0; ty < BAKE_DIM; ty++) {
        const uint16_t* src = g_vram + (size_t)((s->tex_y + tv * BAKE_DIM + ty) & 511) * VRAM_W;
        uint16_t* d = buf + (size_t)ty * BAKE_DIM;
        /* Four texels a halfword, and the patch origin is a multiple of four, so the nibble
         * order never has to be recomputed inside the row. */
        for(int tx = 0; tx < BAKE_DIM; tx += 4) {
            const uint16_t hw = src[(s->tex_x + ((tu * BAKE_DIM + tx) >> 2)) & 1023];
            d[tx    ] = clut[hw & 0xF];
            d[tx + 1] = clut[(hw >> 4) & 0xF];
            d[tx + 2] = clut[(hw >> 8) & 0xF];
            d[tx + 3] = clut[(hw >> 12) & 0xF];
        }
    }
    pvr_txr_load_ex(buf, dst, BAKE_DIM, BAKE_DIM, PVR_TXRLOAD_16BPP);
}

static int bake_slot(const gstate_t* s, int tu, int tv) {
    for(int i = 0; i < g_bake_n; i++) {
        if(g_bake[i].used && g_bake[i].tex_x == s->tex_x && g_bake[i].tex_y == s->tex_y
           && g_bake[i].clut_x == s->clut_x && g_bake[i].clut_y == s->clut_y
           && g_bake[i].tu == tu && g_bake[i].tv == tv) {
            if(g_bake[i].bound_frame != g_tex_frame) g_bake_live++;
            g_bake[i].bound_frame = g_tex_frame;
            return i;
        }
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
    g_bake[slot].bound_frame = g_tex_frame;
    g_bake_live++;
    g_bake_decodes++;
    bake_decode(g_bake[slot].mem, s, tu, tv);
    return slot;
}

/** Hands the sixty-four banks to the palettes that draw the most primitives, before anything is
 *  submitted. Arrival order would give them to the backdrop — submitted first because the
 *  ordering table runs far-to-near — and leave the characters to be baked. Both are exact; this
 *  is about which path is cheaper for the majority of the picture. Counting is a direct-mapped
 *  table with four probes: a collision costs a palette its count, never its correctness. */
#define PRIO_SLOTS 256
static struct { uint16_t cx, cy; uint32_t n; uint8_t used; } g_prio[PRIO_SLOTS];

static void palette_priority(void) {
    memset(g_prio, 0, sizeof(g_prio));
    for(int i = 0; i < g_cmd_count; i++) {
        const gcmd_t* c = &g_cmds[i];
        const gstate_t* s = &g_states[c->state];
        if(c->is_rect || !(s->flags & BP_GPU_TEXTURED) || s->depth != 0) continue;
        const uint32_t base = (uint32_t)s->clut_x * 31u + (uint32_t)s->clut_y * 17u;
        for(int probe = 0; probe < 4; probe++) {
            const int hh = (int)((base + (uint32_t)probe) & (PRIO_SLOTS - 1));
            if(!g_prio[hh].used) {
                g_prio[hh].used = 1;
                g_prio[hh].cx = s->clut_x;
                g_prio[hh].cy = s->clut_y;
                g_prio[hh].n = 1;
                break;
            }
            if(g_prio[hh].cx == s->clut_x && g_prio[hh].cy == s->clut_y) { g_prio[hh].n++; break; }
        }
    }
    for(int k = 0; k < PAL_BANKS_4BPP; k++) {
        int best = -1;
        for(int i = 0; i < PRIO_SLOTS; i++)
            if(g_prio[i].used && g_prio[i].n > 0
               && (best < 0 || g_prio[i].n > g_prio[best].n)) best = i;
        if(best < 0) break;
        /* A refusal means no bank is free for THIS palette; a later one may still be resident
         * and want its lease refreshed, so the pass continues rather than abandoning the list. */
        pal_bank_at(g_prio[best].cx, g_prio[best].cy, 0);
        g_prio[best].n = 0;
    }
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
static void begin_frame_if_needed(void) {
    if(!g_frame_shown) return;
    g_frame_shown = 0;
    g_cmd_count = 0;
    g_state_count = 0;
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
           && p->draw_x == draw_x && p->draw_y == draw_y)
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
}

static gcmd_t* cmd_new(void) {
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
    c->is_rect = 0;
    c->x[0] = (int16_t)x0; c->y[0] = (int16_t)y0; c->u[0] = (uint8_t)u0; c->v[0] = (uint8_t)v0;
    c->x[1] = (int16_t)x1; c->y[1] = (int16_t)y1; c->u[1] = (uint8_t)u1; c->v[1] = (uint8_t)v1;
    c->x[2] = (int16_t)x2; c->y[2] = (int16_t)y2; c->u[2] = (uint8_t)u2; c->v[2] = (uint8_t)v2;
    const int textured = g_state_count > 0 && (g_states[c->state].flags & BP_GPU_TEXTURED);
    c->argb[0] = textured ? bgr_to_argb_mod((uint32_t)c0) : bgr_to_argb((uint32_t)c0);
    c->argb[1] = textured ? bgr_to_argb_mod((uint32_t)c1) : bgr_to_argb((uint32_t)c1);
    c->argb[2] = textured ? bgr_to_argb_mod((uint32_t)c2) : bgr_to_argb((uint32_t)c2);
}

void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode) {
    /* Blend state arrived through bp_gpu_state, which the runtime calls first and which knows the
     * drawing area; these two say the same thing and are kept in the signature because the ABI
     * describes a rectangle completely rather than half-completely. */
    (void)semi; (void)semi_mode;
    gcmd_t* c = cmd_new();
    if(!c) return;
    c->is_rect = 1;
    c->x[0] = (int16_t)x; c->y[0] = (int16_t)y;
    c->x[1] = (int16_t)w; c->y[1] = (int16_t)h;
    c->argb[0] = bgr_to_argb((uint32_t)bgr);
}

/* The rectangle of VRAM the background was last built from, so a write that lands somewhere else
 * does not cost a rebuild. Games blit into their back buffer every frame while displaying the
 * front one, and treating any write anywhere as "the picture changed" made that 5.5 ms a frame
 * for a picture that had not. */
static int g_bg_x, g_bg_y, g_bg_w, g_bg_h;

/* Recorded, not yet applied: the PVR's user clip rectangle is the obvious home for it, and the
 * spill it would remove is the one the double-buffered menus show at the top of the screen. */
static int g_clip_x0, g_clip_y0, g_clip_x1 = 1023, g_clip_y1 = 511;
void bp_gpu_clip(int x0, int y0, int x1, int y1) {
    g_clip_x0 = x0; g_clip_y0 = y0; g_clip_x1 = x1; g_clip_y1 = y1;
}

/* Recorded, not yet applied. The PVR has no stencil; the browser backend models these with one. */
static int g_mask_set, g_mask_check;
void bp_gpu_mask(int set_bit, int check_bit) {
    g_mask_set = set_bit; g_mask_check = check_bit;
}

void bp_gpu_dirty(int x, int y, int w, int h) {
    g_scene_dirty = 1;
    if(!(g_bg_x + g_bg_w <= x || x + w <= g_bg_x
      || g_bg_y + g_bg_h <= y || y + h <= g_bg_y)) g_bg_stale = 1;
    else {}
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
     * permanent, so "evict" here means only "decode it again next time it is asked for". */
    for(int i = 0; i < PAGE4_N; i++) {
        if(!g_page4[i].valid) continue;
        const int px = (i % PAGE4_COLS) * 64, py = (i / PAGE4_COLS) * 256;
        if(!(px + 64 <= x || x + w <= px || py + 256 <= y || y + h <= py)) g_page4[i].valid = 0;
    }
    /* A baked patch has the CLUT inside it, so it goes stale from either direction. */
    for(int i = 0; i < g_bake_n; i++) {
        if(!g_bake[i].used) continue;
        const int bx = g_bake[i].tex_x + g_bake[i].tu * (BAKE_DIM / 4);
        const int by = g_bake[i].tex_y + g_bake[i].tv * BAKE_DIM;
        const int page_hit = !(bx + BAKE_DIM / 4 <= x || x + w <= bx
                            || by + BAKE_DIM <= y || y + h <= by);
        const int clut_hit = g_bake[i].clut_y >= y && g_bake[i].clut_y < y + h
                          && g_bake[i].clut_x < x + w && g_bake[i].clut_x + 16 > x;
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
        case 2:   /* B - F. The PVR has no inverse-source-colour factor, so this cannot be had;
                   * half-and-half is the nearest thing that still darkens rather than glows. */
            if(!g_warned_sub) {
                g_warned_sub = 1;
                bp_log(BP_LOG_WARN, "gpu: subtractive blending approximated as half-and-half");
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
        if(!c->is_rect) continue;
        const gstate_t* s = &g_states[c->state];
        if(s->flags & BP_GPU_SEMI) continue;
        const int x0 = c->x[0] - s->draw_x, y0 = c->y[0] - s->draw_y;
        if(x0 <= 0 && y0 <= 0 && x0 + c->x[1] >= sw && y0 + c->y[1] >= sh) return i;
    }
    return -1;
}

static void build_scene(int sx, int sy, int sw, int sh, int with_background, int first) {
    if(sw <= 0 || sh <= 0) return;
    const float scale_x = 640.0f / (float)sw;
    const float scale_y = 480.0f / (float)sh;

    pvr_list_begin(PVR_LIST_TR_POLY);

    if(with_background) {
        pvr_prim(&g_hdr, sizeof(g_hdr));
        draw_quad(sw, sh);
    }

    palette_priority();

    int cur_state = -1, cur_fmt = -1, cur_dim = 0, cur_ou = 0, cur_ov = 0;
    /* The reciprocal of the bound texture's size, so the vertex loop multiplies where it used to
     * divide. The divisor is constant for a whole run of primitives and SH-4's FDIV is expensive
     * and poorly pipelined; at three vertices and two coordinates each, a busy scene was asking
     * for nine thousand divisions a frame to compute a number that changes a few dozen times. */
    float cur_rdim = 1.0f / (float)TEX_DIM;
    pvr_ptr_t cur_mem = NULL;
    /* Resolved once per run of primitives sharing a state — which is how they arrive. */
    int run_state = -1, run_bank = -1, run_slot = -1;
    pvr_ptr_t run_mir = NULL;
    float alpha = 1.0f;
    for(int i = first; i < g_cmd_count; i++) {
        const gcmd_t* c = &g_cmds[i];
        const gstate_t* s = &g_states[c->state];

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
                if(run_mir) {
                    run_bank = pal_bank_at(s->clut_x, s->clut_y, 0);
                } else {
                    run_slot = tex_slot(s);
                    if(run_slot >= 0 && s->depth == 0)
                        run_bank = pal_bank_at(s->clut_x, s->clut_y, 1);
                }
            }
            if(run_mir && run_bank >= 0) {
                mem = run_mir;
                fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(run_bank) | PVR_TXRFMT_TWIDDLED;
            } else if(run_mir) {
                /* No bank was left for this palette, so draw it from texels that already have
                 * the CLUT in them — exact, and only as large as this primitive samples. */
                int umin = c->u[0], umax = c->u[0], vmin = c->v[0], vmax = c->v[0];
                for(int k = 1; k < 3; k++) {
                    if(c->u[k] < umin) umin = c->u[k];
                    if(c->u[k] > umax) umax = c->u[k];
                    if(c->v[k] < vmin) vmin = c->v[k];
                    if(c->v[k] > vmax) vmax = c->v[k];
                }
                const int tu = umin / BAKE_DIM, tv = vmin / BAKE_DIM;
                const int b = (umax / BAKE_DIM == tu && vmax / BAKE_DIM == tv)
                            ? bake_slot(s, tu, tv) : -1;
                if(b >= 0) {
                    mem = g_bake[b].mem;
                    fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
                    dim = BAKE_DIM; ou = tu * BAKE_DIM; ov = tv * BAKE_DIM;
                } else {
                    /* Sampling wider than one patch, or the patch pool is all in flight: the
                     * nearest banked palette, which is the only lossy path left in the scene. */
                    g_bake_miss++;
                    const int nb = pal_bank_at(s->clut_x, s->clut_y, 1);
                    mem = run_mir;
                    fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(nb < 0 ? 0 : nb)
                        | PVR_TXRFMT_TWIDDLED;
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
            const int hs = hdr_slot(mem, fmt, dim, s);
            if(g_hdrc[hs].used && g_hdrc[hs].mem == mem && g_hdrc[hs].fmt == fmt
               && g_hdrc[hs].dim == dim && g_hdrc[hs].flags == s->flags
               && g_hdrc[hs].semi_mode == s->semi_mode) {
                alpha = g_hdrc[hs].alpha;
                g_hdr_hits++;
                pvr_prim(&g_hdrc[hs].hdr, sizeof(pvr_poly_hdr_t));
            } else {
            pvr_poly_cxt_t cxt;
            if(mem) {
                pvr_poly_cxt_txr(&cxt, PVR_LIST_TR_POLY, fmt,
                                 dim, dim, mem, PVR_FILTER_NONE);
                /* MODULATE keeps the texel's own alpha: a transparent texel reaches the blender
                 * with alpha 0 and the blend below keeps the destination, which is what the
                 * PlayStation's "texel zero draws nothing" means. */
                cxt.txr.env = (s->flags & BP_GPU_RAW) ? PVR_TXRENV_REPLACE
                            : ((s->flags & BP_GPU_SEMI) ? PVR_TXRENV_MODULATEALPHA
                                                        : PVR_TXRENV_MODULATE);
                cxt.txr.uv_clamp = PVR_UVCLAMP_NONE;
            } else {
                pvr_poly_cxt_col(&cxt, PVR_LIST_TR_POLY);
            }
            cxt.gen.culling = PVR_CULLING_NONE;
            /* No depth. The list renders in submission order; nothing may re-decide it. */
            cxt.depth.comparison = PVR_DEPTHCMP_ALWAYS;
            cxt.depth.write = false;
            if(s->flags & BP_GPU_SEMI) {
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
            pvr_poly_compile(&g_hdrc[hs].hdr, &cxt);
            g_hdrc[hs].used = 1;
            g_hdrc[hs].mem = mem;
            g_hdrc[hs].fmt = fmt;
            g_hdrc[hs].dim = dim;
            g_hdrc[hs].flags = s->flags;
            g_hdrc[hs].semi_mode = s->semi_mode;
            g_hdrc[hs].alpha = alpha;
            g_hdr_compiles++;
            pvr_prim(&g_hdrc[hs].hdr, sizeof(pvr_poly_hdr_t));
            }
        }

        const uint32_t a = (uint32_t)(alpha * 255.0f) << 24;
        pvr_vertex_t vert;
        vert.oargb = 0;
        vert.z = 1.0f;
        if(c->is_rect) {
            const float x0 = ((float)c->x[0] - (float)s->draw_x) * scale_x;
            const float y0 = ((float)c->y[0] - (float)s->draw_y) * scale_y;
            const float x1 = ((float)(c->x[0] + c->x[1]) - (float)s->draw_x) * scale_x;
            const float y1 = ((float)(c->y[0] + c->y[1]) - (float)s->draw_y) * scale_y;
            vert.argb = (c->argb[0] & 0x00FFFFFFu) | a;
            vert.u = 0.0f; vert.v = 0.0f;
            vert.flags = PVR_CMD_VERTEX;
            vert.x = x0; vert.y = y0; pvr_prim(&vert, sizeof(vert));
            vert.x = x1; vert.y = y0; pvr_prim(&vert, sizeof(vert));
            vert.x = x0; vert.y = y1; pvr_prim(&vert, sizeof(vert));
            vert.flags = PVR_CMD_VERTEX_EOL;
            vert.x = x1; vert.y = y1; pvr_prim(&vert, sizeof(vert));
        } else {
            for(int k = 0; k < 3; k++) {
                vert.flags = (k == 2) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX;
                vert.x = ((float)c->x[k] - (float)s->draw_x) * scale_x;
                vert.y = ((float)c->y[k] - (float)s->draw_y) * scale_y;
                vert.u = ((float)c->u[k] - (float)cur_ou + 0.5f) * cur_rdim;
                vert.v = ((float)c->v[k] - (float)cur_ov + 0.5f) * cur_rdim;
                vert.argb = (c->argb[k] & 0x00FFFFFFu) | a;
                pvr_prim(&vert, sizeof(vert));
            }
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

void bp_present(const uint16_t* vram, int sx, int sy, int sw, int sh, int flags) {
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

    /* The window itself moving counts as a change: the same VRAM seen through a different
     * rectangle is a different picture. */
    static int last_x = -1, last_y = -1, last_w = -1, last_h = -1;
    if(sx != last_x || sy != last_y || sw != last_w || sh != last_h) g_bg_stale = 1;
    last_x = sx; last_y = sy; last_w = sw; last_h = sh;

    /* Covered: no upload, and the background stays marked stale for the next picture that
     * does show it. */
    const int cover = (!blank && g_cmd_count > 0) ? last_cover(sw, sh) : -1;
    if(!blank && cover < 0 && (g_bg_stale || g_vram == NULL)) {
        declare_texture(pot(sw, TXR_MAX_W), pot(sh, TXR_MAX_H));
        if(flags & BP_PRESENT_24BPP) upload_24bpp(vram, sx, sy, sw, sh);
        else                         upload_15bpp(vram, sx, sy, sw, sh);
        g_bg_stale = 0;
        g_bg_x = sx; g_bg_y = sy; g_bg_w = sw; g_bg_h = sh;
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
        if((every++ % 200) == 0) samp_report();
        else {}
    }
    if(g_pc_armed || g_pc_frames == 0) perf_window_open();
    else {}
#endif
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
        mutex_unlock(&g_io_lock);
        int got = -1;
        if(f && fseek(f, at, SEEK_SET) == 0) got = (int)fread(g_winbuf[w], 1, DISC_WINDOW, f);
        mutex_lock(&g_io_lock);
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

static void disc_io_request(int w, int slot, int at) {
    g_win[w].slot = slot;
    g_win[w].at = at;
    g_win[w].got = 0;
    if(!g_io_thread) {
        /* No thread to hand it to: read it here, synchronously, as the backend always used to. */
        int got = -1;
        if(fseek(g_files[slot], at, SEEK_SET) == 0) got = (int)fread(g_winbuf[w], 1, DISC_WINDOW, g_files[slot]);
        g_win[w].got = got;
        g_win[w].state = WIN_READY;
        return;
    }
    g_win[w].state = WIN_LOADING;
    g_io_request = w;
    cond_broadcast(&g_io_cv);
}

static int win_has(const disc_win_t* w, int slot, int offset, int len) {
    return w->state == WIN_READY && w->slot == slot && w->got > 0
        && offset >= w->at && offset + len <= w->at + w->got;
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
#endif
    return got;
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
    if(!win_has(&g_win[cur], slot, offset, len)) {
        const int next = 1 - cur;
        const disc_win_t* n = &g_win[next];
        /* The one being read ahead: wait for it if it is still on its way, and move on to it. */
        if(n->state != WIN_EMPTY && n->slot == slot && offset >= n->at
           && offset + len <= n->at + DISC_WINDOW) {
            disc_io_wait_idle();
            if(win_has(n, slot, offset, len)) cur = next;
        }
        if(!win_has(&g_win[cur], slot, offset, len)) {
            /* Somewhere else: a seek. Read the window that starts at the sector holding it. */
            disc_io_wait_idle();
            cur = g_win_cur;
            disc_io_request(cur, slot, offset & ~2047);
            disc_io_wait_idle();
        }
        g_win_cur = cur;
    }

    const disc_win_t* c = &g_win[cur];
    int result;
    if(win_has(c, slot, offset, len)) {
        memcpy(buf, g_winbuf[cur] + (offset - c->at), (size_t)len);
        result = len;
        /* And the next window, if the drive is free and it is not already there or on its way.
         * It starts a little before this one ends: a PlayStation sector is 2352 bytes and a
         * window 128 KB, so sectors straddle the seam all the time, and one that is wholly in
         * neither window would be a seek and a stall at every crossing. */
        const int next = 1 - cur;
        const int want = (c->at + c->got - 4096) & ~2047;
        const disc_win_t* n = &g_win[next];
        if(c->got == DISC_WINDOW && !disc_io_busy()
           && !(n->state == WIN_READY && n->slot == slot && n->at == want))
            disc_io_request(next, slot, want);
    } else {
        /* Short of what was asked for: near the end of the file, or a failure. Answered
         * directly and honestly, as before. */
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

    /* If we fell far behind — which on a 200 MHz SH-4 is the ordinary case, not the exception —
     * give up on catching up rather than sprinting through frames nobody will see. */
    const uint64_t after = bp_time_us();
    if(next_deadline + (uint64_t)target_us * 4ull < after) next_deadline = after + (uint64_t)target_us;
}

void bp_log(int level, const char* msg) {
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
