/* dc_scene.c — the GPU's primitives in hardware mode: recorded as the runtime draws them
 * (bp_gpu_*), and built into one PVR scene when the frame is presented (build_scene). */

#include "dc_internal.h"

/* No loop unswitching in the scene build (ledger E-185): at -O3 GCC copied the record loops once for
 * each value of their invariant tests — build_scene 13.8 KB, run_tris 4.0 KB — and the build's hot
 * code no longer fitted the SH-4's 8 KB instruction cache; without it they are 7.3 and 2.8 KB, the
 * same code. Every function below this line. */
#pragma GCC optimize("no-unswitch-loops")

/* ---- the command buffer: what the frame drew, in order (types in dc_internal.h) ---------------- */

const uint16_t* g_vram;          /* emulated VRAM, borrowed; NULL until armed */
gcmd_t   g_cmds[GPU_MAX_CMDS];
/* The polygon core's way in (ADR-0051, backend_c_api.h): the next record, the buffer's end, and the
 * current state's tag and count, which state_enter keeps (sink_state). Its next is the frame's count
 * (cmd_count): cmd_line appends there too. Open from the start, as a frame is; closed while one is
 * shown (present_frame), reopened by begin_frame. Before the frame's first state its records count
 * into g_sink_no_tris, which nothing reads — as bp_gpu_tri_w counted none then. */
static uint16_t g_sink_no_tris;
bp_gpu_sink_t bp_gpu_sink = { (uint32_t*)g_cmds, (uint32_t*)(g_cmds + GPU_MAX_CMDS), 0, &g_sink_no_tris };
_Static_assert(GCMD_TRI == 0, "a sink tag is a state index, a triangle's kind being 0");
gstate_t g_states[GPU_MAX_STATES];
int      g_state_count;
/* The state records name now (cmd_new): the one last entered, which state_enter finds among those
 * the frame recorded before it records one more. */
static int g_state_cur;
static int      g_cmd_overflowed;
/* Set when a frame has been presented, cleared by the next primitive to arrive. It is what makes
 * the geometry persist: a PlayStation's framebuffer keeps what was drawn into it until something
 * overwrites it, and a game drawing at thirty frames a second submits nothing at all on every
 * other vblank. Clearing the buffer at present time instead would show that game its background
 * on one frame and its world on the next, alternating — which is exactly what it did. */
int      g_frame_shown;
/* Whether anything the picture is made of has changed since the last scene went to the PVR: a
 * primitive, a VRAM write, the display window. When nothing has, the scene is not built at all —
 * the PVR keeps showing the last one it rendered. A game at thirty frames a second presents
 * every frame twice, and building the same list the second time cost as much as the first. */
int      g_scene_dirty = 1;
#if RECOMPSX_TA_HASH
#include <stdio.h>
uint32_t g_ta_hash;
int      g_ta_hashing;
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
    int       fmt;
    uint32_t  key;      /* the rest of the binding in one word (hdr_key); 0 for a free slot */
    float     alpha;
    pvr_poly_hdr_t hdr;
} ghdr_t;
static ghdr_t g_hdrc[HDRC_N];
int    g_hdr_hits, g_hdr_compiles;

/* What one pass of a primitive does to the picture — see build_scene's semi-transparency.
 * HK_NORMAL blends as the state says; HK_OPAQUE draws a semi-transparent state's solid texels
 * as an opaque primitive would; HK_ADD adds the source (B + F, reading no alpha); HK_INVERT is
 * untextured white turning each pixel under it into its complement (1 - B). */
enum { HK_NORMAL = 0, HK_OPAQUE = 1, HK_ADD = 2, HK_INVERT = 3 };

/* A header's binding less its texture and format: the size (at most 1024), the state's flags and
 * blend, the pass and the kind, and a bit that no free slot has. One compare where there were six,
 * and two multiplies of the hash where there were four, each waiting on the one before: the cache
 * answers every run of every frame, ~400 times a frame in Crash Bash, and it nearly always hits. */
static inline uint32_t hdr_key(int dim, const gstate_t* s, int over, int kind) {
    return (uint32_t)dim | ((uint32_t)s->flags << 11) | ((uint32_t)s->semi_mode << 19)
         | ((uint32_t)over << 23) | ((uint32_t)kind << 24) | (1u << 27);
}

/* A picture's memory declared at another size (ADR-0056): every header kept for it is the old
 * size's, and Flycast matches a render to texture by its size. */
void hdr_forget(pvr_ptr_t mem) {
    for(int k = 0; k < HDRC_N; k++) {
        if(g_hdrc[k].mem == mem) g_hdrc[k].key = 0;
        else {}
    }
}

static inline int hdr_slot(pvr_ptr_t mem, int fmt, uint32_t key) {
    const uint32_t h = (((uint32_t)(uintptr_t)mem ^ (uint32_t)fmt) * 2654435761u ^ key) * 0x85EBCA6Bu;
    return (int)(h >> (32 - HDRC_BITS));
}

gdiag_t g_diag;
static int      g_warned_sub;           /* the one blend mode the PVR cannot express */

/* ---- colour conversion ------------------------------------------------------------------------
 * A primitive's colour is the PlayStation's 24-bit BGR; the PVR wants ARGB. These run for every
 * vertex of every scene, so all three channels are done at once in one word, without branches:
 * clamping a doubled channel is a matter of whether its top bit was set, and that bit can be
 * spread over its byte with a shift and a subtraction. The host test checks each against the
 * per-channel form it replaced, for every one of the 2^24 colours. */

/** Bytes 0 and 2 of `c` change places, byte 3 cleared: bytes 0 and 2 alone, their halves swapped
 *  (`swap.w`), byte 1 put back. The same in C GCC turns into its byte-reversal idiom, three swaps
 *  and two shifts. */
static inline uint32_t swap_rb(uint32_t c) {
    uint32_t x = c & 0x00FF00FFu;
    __asm__("swap.w %1, %0" : "=r" (x) : "r" (x));
    return x | (c & 0x0000FF00u);
}

/** BGR to RGB888, byte 3 clear for the vertex's alpha (the header's blend's): bytes 0 and 2 change
 *  places. */
static inline uint32_t bgr_to_rgb(uint32_t c) {
    return swap_rb(c);
}

/* 0xFF in every byte of `c` whose top bit is set, 0 elsewhere (c's other bits must be clear). */
static inline uint32_t byte_mask(uint32_t top_bits) {
    return (top_bits << 1) - (top_bits >> 7);
}

/** The same, doubled: PlayStation modulation is texel*colour/128, so 0x80 means "unchanged",
 *  where the PVR's multiply wants 0xFF for that — min(2c, 255) per channel. What the clamp
 *  loses is bgr_to_rgb_over's. */
static inline uint32_t bgr_to_rgb_mod(uint32_t c) {
    const uint32_t d = ((c << 1) & 0x00FEFEFEu) | byte_mask(c & 0x00808080u);
    return swap_rb(d);
}

/** What the doubled colour loses to the clamp: 2c - 255 per channel, floored at zero. Drawn as a
 *  second, additive pass it restores PlayStation modulation above 1.0 — texel*(2c) is
 *  texel*min(2c, 1) + texel*max(2c - 1, 0), and blending is linear in the source. For a channel
 *  of 0x80 or more, 2c - 255 is 2(c - 0x80) + 1. */
static inline uint32_t bgr_to_rgb_over(uint32_t c) {
    const uint32_t v = ((c & 0x007F7F7Fu) << 1) | 0x00010101u;
    return swap_rb(v & byte_mask(c & 0x00808080u));
}

/** Whether any channel brightens: above 0x80, the PlayStation's 1.0 — top bit set and some other
 *  bit too. Adding 0x7F to a byte's low seven bits sets its top bit exactly when they are not all
 *  zero, and cannot carry into the next byte. */
static inline int bgr_brightens(uint32_t c) {
    return (c & ((c & 0x007F7F7Fu) + 0x007F7F7Fu) & 0x00808080u) != 0;
}

/* The three above for a vertex's colour at once, from two constants where they take five (run_tris,
 * where those five and the spread's shift were held in registers the vertex terms wanted, and
 * spilled: ledger E-159). `t` is the channels' top bits, `l` their low seven, `u` 0x7F in each
 * channel whose top bit is set (t - (t >> 7)), so that byte_mask(t) is t + u: the doubled colour is
 * 2l | (t + u), a channel brightens where l & u, and what the clamp loses is (2l | t >> 7) & (t + u).
 * Every one of the 2^24 colours gives the bits the functions above give (checked on the host). */
typedef struct { uint32_t t, l, u; } gbgr_t;

static inline gbgr_t bgr_parts(uint32_t c) {
    gbgr_t p;
    p.t = c & 0x00808080u;
    p.l = c ^ p.t;
    p.u = p.t - ((p.t + p.t) >> 8);
    return p;
}

/** swap_rb for a colour of 24 bits, from its one constant: green is what the mask leaves. */
static inline uint32_t swap_rb24(uint32_t c) {
    uint32_t x = c & 0x00FF00FFu;
    const uint32_t g = c ^ x;
    __asm__("swap.w %1, %0" : "=r" (x) : "r" (x));
    return x | g;
}

static inline uint32_t bgr_parts_mod(gbgr_t p) { return swap_rb24((p.l + p.l) | (p.t + p.u)); }
static inline uint32_t bgr_parts_bright(gbgr_t p) { return p.l & p.u; }
static inline uint32_t bgr_parts_over(gbgr_t p) {
    return swap_rb24(((p.l + p.l) | (p.t >> 7)) & (p.t + p.u));
}

/** Drops the presented frame's geometry, the moment anything belonging to the next one arrives.
 *  Both entry points call it, and both must: state is latched before the primitive that uses it,
 *  so resetting in one place only would dedup a new frame's state against a dead table and then
 *  index into the emptied one. */
static int g_clip_x0, g_clip_y0, g_clip_x1 = 1023, g_clip_y1 = 511;

/* The new frame's first primitive, out of line and cold: inlined into the triangle path it was a
 * call site every primitive's values had to survive, and they went to the stack for it. */
__attribute__((noinline, cold)) static void begin_frame(void);
static void state_table_reset(void);
static inline void begin_frame_if_needed(void) {
    if(__builtin_expect(g_frame_shown, 0)) begin_frame();
    else {}
}

/* The frame's fill rectangles by record index, and how many VRAM marks it has: present_frame asks
 * for the last fill covering the picture and for marks after it, and walking every record for
 * those — a cache line each, long evicted — was 0.2 ms a frame of Crash 3's title screen under the
 * cache model, which has ~1,100 records and no covering fill (E-045). Rectangles are never moved
 * once recorded (mark_vram compacts only the trailing marks); a frame with more than the list holds
 * walks the records as before. The mark count is an upper bound (compaction can remove marks). */
#define RECT_KEEP 1024
static uint16_t g_rect_at[RECT_KEEP];
static int      g_rect_n, g_rect_over, g_marks;

/* The sink's state: what a record the core writes under the current state carries and counts into. */
static inline void sink_state(void) {
    bp_gpu_sink.tag = ((uint32_t)g_state_cur & 0x3FFFu) << 16;
    bp_gpu_sink.tris = &g_states[g_state_cur].tris;
}

static void begin_frame(void) {
    /* Through the pictures (ADR-0053) a frame's records are rendered once, at the present after
     * them; a VRAM mark recorded since — an upload between frames — is not in a picture yet, and
     * the picture, not emulated VRAM, is the next frame's background. So it moves to the front of
     * the new frame instead of going with the old one. */
    int keep = 0;
    if(g_pic_active) {
        const int n = cmd_count();
        for(int i = g_pic_done; i < n; i++) {
            if(g_cmds[i].is_rect >= GCMD_VRAM) {
                if(keep != i) shz_memcpy32_1(&g_cmds[keep], &g_cmds[i]);
                else {}
                keep++;
            } else {}
        }
    } else {}
    g_pic_done = 0;
    g_frame_shown = 0;
    bp_gpu_sink.next = (uint32_t*)(void*)(g_cmds + keep);
    bp_gpu_sink.end = (uint32_t*)(g_cmds + GPU_MAX_CMDS);
    bp_gpu_sink.tag = 0;
    bp_gpu_sink.tris = &g_sink_no_tris;
    g_rect_n = 0; g_rect_over = 0; g_marks = keep;
    /* The latched state carries over as the new frame's first entry: the ABI latches it until
     * the next bp_gpu_state, and the runtime now sends one only when it changes, so the first
     * primitive of a frame may well arrive under the last frame's state. */
    if(g_state_count > 0) {
        if(g_state_cur > 0) shz_memcpy32_1(&g_states[0], &g_states[g_state_cur]);
        else {}
        g_state_count = 1;
        g_state_cur = 0;
        g_states[0].tris = 0;       /* the new frame's count starts here */
        sink_state();
    } else {}
    state_table_reset();
}

/* The frame's states by content: open addressing over a hash of a state's words, each slot the
 * index of a state recorded this frame plus one (0 empty). A state the frame recorded before is
 * named again rather than recorded again — Crash Bash changes state ~1,130 times a frame among
 * ~105 states, Crash 3 ~370 among 37 on its title screen and ~670 among ~120 in play, the same few
 * over and over as the ordering table interleaves objects — so build_scene can remember what it
 * worked out for each (g_sres) and palette_priority walks a state once. Past SDEDUP_FILL states a
 * frame (none seen) new ones are recorded without an entry, as before. */
#define SDEDUP_BITS 10
#define SDEDUP_FILL 640
static uint16_t g_sdedup[1 << SDEDUP_BITS] __attribute__((aligned(8)));

static inline uint32_t state_hash(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3, uint32_t w6) {
    const uint32_t h = (w0 ^ (w1 * 33u) ^ (w2 << 7) ^ (w3 * 5u) ^ (w6 << 13)) * 0x9E3779B1u;
    return h >> (32 - SDEDUP_BITS);
}

static inline int state_same(const gstate_t* p, uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3,
                             uint32_t w4, uint32_t w5, uint32_t w6) {
    return ((p->w[0] ^ w0) | (p->w[1] ^ w1) | (p->w[2] ^ w2) | (p->w[3] ^ w3) | (p->w[4] ^ w4)
            | (p->w[5] ^ w5) | (p->w[6] ^ w6)) == 0;
}

/* The drawing areas the frame's states draw within — the buffer's corner and the area's corners,
 * words 3-5 of a state's line — each named by its index in the frame: state_enter gives a new state
 * its area's index (gstate_t's `area`), so build_scene tells "the area of the last state placed" by
 * one compare where it compared six fields at every change of state (Crash Bash changes state
 * ~1,130 times a frame, within one or two areas). Past AREA_MAX areas in a frame a state is given
 * an index of its own, AREA_MAX + its own index, which costs build_scene only the placement again. */
#define AREA_MAX 16
static uint32_t g_area_w[AREA_MAX][3];
static int      g_area_count;

static inline uint32_t area_index(uint32_t w3, uint32_t w4, uint32_t w5, int state) {
    for(int k = 0; k < g_area_count; k++) {
        if(((g_area_w[k][0] ^ w3) | (g_area_w[k][1] ^ w4) | (g_area_w[k][2] ^ w5)) == 0) return (uint32_t)k;
        else {}
    }
    if(g_area_count < AREA_MAX) {
        g_area_w[g_area_count][0] = w3; g_area_w[g_area_count][1] = w4; g_area_w[g_area_count][2] = w5;
        return (uint32_t)g_area_count++;
    } else {}
    return (uint32_t)(AREA_MAX + state);
}

/** The frame's first state (begin_frame's carried-over entry 0) in emptied tables. */
static void state_table_reset(void) {
    shz_memset8(g_sdedup, 0, sizeof g_sdedup);
    g_area_count = 0;
    if(g_state_count > 0) {
        gstate_t* p = &g_states[0];
        g_sdedup[state_hash(p->w[0], p->w[1], p->w[2], p->w[3], p->w[6])] = 1;
        p->area = (uint16_t)area_index(p->w[3], p->w[4], p->w[5], 0);
    } else {}
}

/** Names the state with these words (gstate_t's `w`: the page, palette, window, the buffer's corner,
 *  the drawing area's corners, then depth, blend and flags): the current one when it is that — the
 *  runtime sends a state only when its own fields change — else one the frame recorded, else a new
 *  record. Compared as seven words in one test, written as words where fourteen fields went one by
 *  one through r0. */
static inline void state_enter(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3, uint32_t w4,
                               uint32_t w5, uint32_t w6) {
    if(g_state_count > 0 && state_same(&g_states[g_state_cur], w0, w1, w2, w3, w4, w5, w6)) return;
    else {}
    uint32_t h = state_hash(w0, w1, w2, w3, w6);
    for(;;) {
        const int k = g_sdedup[h];
        if(k == 0) break;
        else {}
        if(state_same(&g_states[k - 1], w0, w1, w2, w3, w4, w5, w6)) {
            g_state_cur = k - 1;
            sink_state();
            return;
        } else {}
        h = (h + 1) & ((1u << SDEDUP_BITS) - 1);
    }
    if(g_state_count >= GPU_MAX_STATES) {
        /* Unreachable: a state is recorded only when it differs, and each primitive latches at
         * most one; if it ever fires, that reasoning broke. */
        static int warned;
        if(!warned) { warned = 1; bp_log(BP_LOG_WARN, "gpu: state table overflow — impossible"); }
        return;
    } else {}
    gstate_t* s = &g_states[g_state_count];
    shz_dcache_alloc_line(s);       /* every word is written below */
    s->w[0] = w0; s->w[1] = w1; s->w[2] = w2; s->w[3] = w3;
    s->w[4] = w4; s->w[5] = w5; s->w[6] = w6;
    s->w[7] = area_index(w3, w4, w5, g_state_count) << 16;   /* tris 0, and its area */
    if(g_state_count < SDEDUP_FILL) g_sdedup[h] = (uint16_t)(g_state_count + 1);
    else {}
    g_state_cur = g_state_count++;
    sink_state();
}

/* A state from the runtime: its words with the drawing area latched by bp_gpu_clip. */
static inline void state_record(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3, uint32_t w6) {
    begin_frame_if_needed();
    const uint32_t w4 = ((uint32_t)g_clip_x0 & 0xFFFFu) | ((uint32_t)g_clip_y0 << 16);
    const uint32_t w5 = ((uint32_t)g_clip_x1 & 0xFFFFu) | ((uint32_t)g_clip_y1 << 16);
    state_enter(w0, w1, w2, w3, w4, w5, w6);
}

/* The words of a state's line from its values: halfword pairs, and depth, blend and flags in bytes
 * (pad 0). Every value is within its field (pages, palettes and corners within VRAM, depth and blend
 * 0-3, flags 0-7), so the words compare as the fields did. */
#define STATE_W0(lo, hi)    (((uint32_t)(lo) & 0xFFFFu) | ((uint32_t)(hi) << 16))
#define STATE_W6(d, sm, f)  (((uint32_t)(d) & 0xFFu) | (((uint32_t)(sm) & 0xFFu) << 8) | (((uint32_t)(f) & 0xFFu) << 16))

void bp_gpu_state(int tex_base_x, int tex_base_y, int tex_depth,
                  int clut_x, int clut_y, int semi_mode, int flags, int tex_window,
                  int draw_x, int draw_y) {
    state_record(STATE_W0(tex_base_x, tex_base_y), STATE_W0(clut_x, clut_y), (uint32_t)tex_window,
                 STATE_W0(draw_x, draw_y), STATE_W6(tex_depth, semi_mode, flags));
}

/* bp_gpu_state from the runtime's words (ADR-0047): read after nothing that could change them,
 * nothing held across the frame's begin. Forced inline: LTO takes it into the runtime's polygon
 * path. */
__attribute__((always_inline))
void bp_gpu_state_w(const int* w) {
    state_record(STATE_W0(w[0], w[1]), STATE_W0(w[3], w[4]), (uint32_t)w[7], STATE_W0(w[8], w[9]),
                 STATE_W6(w[2], w[5], w[6]));
}

/* A new record's line, allocated in the cache without a read (see gcmd_t). The caller writes
 * every field a reader of its kind looks at; the rest of the line is undefined, as it was stale. */
static inline gcmd_t* cmd_alloc(void) {
    gcmd_t* c = (gcmd_t*)(void*)bp_gpu_sink.next;
    bp_gpu_sink.next += 8;
    shz_dcache_alloc_line(c);
    return c;
}

/* A new record's line: the frame begun, the scene marked, the buffer's end kept. */
static inline gcmd_t* cmd_line(void) {
    begin_frame_if_needed();
    g_scene_dirty = 1;
    if(cmd_count() >= GPU_MAX_CMDS) { g_cmd_overflowed = 1; return NULL; }
    return cmd_alloc();
}

static inline gcmd_t* cmd_new(void) {
    gcmd_t* c = cmd_line();
    if(!c) return NULL;
    c->state = (uint16_t)(g_state_count > 0 ? g_state_cur : 0);
    return c;
}

/* Forced inline (LTO takes it into the runtime's triangle path, polygonHw): the count below made
 * GCC stop inlining it on its own, and as a call its fifteen arguments went through the stack —
 * +0.49 ms a frame of Crash 3 against the 0.22 the count saves. */
__attribute__((always_inline))
void bp_gpu_tri(int x0, int y0, int c0, int u0, int v0,
                int x1, int y1, int c1, int u1, int v1,
                int x2, int y2, int c2, int u2, int v2) {
    gcmd_t* c = cmd_new();
    if(!c) return;
    /* Counted where it is recorded, on the state line just written, so that palette_priority
     * reads the few states instead of walking every record — a cache miss each — again. */
    if(g_state_count > 0) g_states[g_state_cur].tris++;
    else {}
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

/* bp_gpu_tri from the runtime's words (ADR-0047): the same record, written as the line's eight
 * words (gcmd_t's `w`) — positions in halfword pairs, colours masked, u0-u2 v0 and v1 v2 with the
 * tag, the state index and the kind in one store — each word made from words read after the line
 * is allocated, so nothing of the triangle is held across cmd_line. The texture words' bits 16-31
 * are zero (the ABI says so). Forced inline for the same reason as bp_gpu_tri (LTO takes it into the
 * runtime's polygon path). */
__attribute__((always_inline))
void bp_gpu_tri_w(const int* w) {
    gcmd_t* c = cmd_line();
    if(!c) return;
    /* The current state's tag and count, as the polygon core takes them from the sink: state 0 and
     * no count before the frame's first state. */
    (*bp_gpu_sink.tris)++;
    const uint32_t t0 = (uint32_t)w[3], t1 = (uint32_t)w[7], t2 = (uint32_t)w[11];
    c->w[0] = ((uint32_t)w[0] & 0xFFFFu) | ((uint32_t)w[4] << 16);
    c->w[1] = ((uint32_t)w[8] & 0xFFFFu) | ((uint32_t)w[1] << 16);
    c->w[2] = ((uint32_t)w[5] & 0xFFFFu) | ((uint32_t)w[9] << 16);
    c->w[3] = (uint32_t)w[2] & 0x00FFFFFFu;
    c->w[4] = (uint32_t)w[6] & 0x00FFFFFFu;
    c->w[5] = (uint32_t)w[10] & 0x00FFFFFFu;
    c->w[6] = (t0 & 0xFFu) | ((t1 & 0xFFu) << 8) | ((t2 & 0xFFu) << 16) | ((t0 & 0xFF00u) << 16);
    c->w[7] = (t1 >> 8) | (t2 & 0xFF00u) | bp_gpu_sink.tag;
}

/* After the polygon core recorded a triangle under the state it had and answered 2 (ADR-0051): the
 * new state, and the record the core wrote last moved into it when it is another — the tag in its
 * last halfword and the count — as if the state had come first, as it does through bp_gpu_tri_w. */
void bp_gpu_state_after_tri(const int* w) {
    uint16_t* const was = bp_gpu_sink.tris;
    bp_gpu_state_w(w);
    if(bp_gpu_sink.tris != was) {
        (*was)--;
        (*bp_gpu_sink.tris)++;
        uint32_t* const r = bp_gpu_sink.next - 8;
        r[7] = (r[7] & 0xFFFFu) | bp_gpu_sink.tag;
    } else {}
}

void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode) {
    /* Blend state arrived through bp_gpu_state, which the runtime calls first and which knows the
     * drawing area; these two say the same thing and are kept in the signature because the ABI
     * describes a rectangle completely rather than half-completely. */
    (void)semi; (void)semi_mode;
    gcmd_t* c = cmd_new();
    if(!c) return;
    if(g_rect_n < RECT_KEEP) g_rect_at[g_rect_n++] = (uint16_t)(c - g_cmds);
    else g_rect_over = 1;
    c->is_rect = GCMD_RECT;
    c->x[0] = (int16_t)x; c->y[0] = (int16_t)y;
    c->x[1] = (int16_t)w; c->y[1] = (int16_t)h;
    c->argb[0] = (uint32_t)bgr & 0x00FFFFFFu;   /* BGR, converted at build time */
}

/* One axis of a sprite (bp_gpu_sprite) as runs a triangle's texture bytes can carry: from texel `t`
 * for `n` pixels, counting up (`dir` 1) or down (-1), wrapping at 256. A run's vertices carry the
 * texel at its first pixel and the one past its last, as a polygon's do, so its far coordinate must
 * stay in a byte: the column at texel 255 counting up (0 counting down), whose far coordinate would
 * be 256 (-1), is a run of its own with that texel at both ends. Up to the edge, the edge, after the
 * wrap — three runs for a sprite of up to 256, a few more for one that repeats its texture. */
typedef struct { int at, n, t0, t1; } gspan_t;
#define SPRITE_SPANS 12

static int sprite_spans(int t, int n, int dir, gspan_t* s) {
    int k = 0, at = 0;
    while(n > 0 && k < SPRITE_SPANS) {
        t &= 255;
        const int edge = dir > 0 ? 255 : 0;
        const int room = dir > 0 ? 255 - t : t;    /* texels before the edge one */
        if(room == 0) {
            s[k].at = at; s[k].n = 1; s[k].t0 = edge; s[k].t1 = edge;
            at += 1; n -= 1; t += dir;
        } else {
            const int m = n < room ? n : room;
            s[k].at = at; s[k].n = m; s[k].t0 = t; s[k].t1 = t + dir * m;
            at += m; n -= m; t += dir * m;
        }
        k++;
    }
    return k;
}

/* A sprite as the triangles of the quads its runs make, each a polygon the scene draws as it draws
 * the game's own: the binding, the texel centres, the passes. Almost every sprite is one quad. */
void bp_gpu_sprite(int x, int y, int w, int h, int u, int v, int bgr, int flip) {
    gspan_t su[SPRITE_SPANS], sv[SPRITE_SPANS];
    const int nu = sprite_spans(u, w, (flip & 1) ? -1 : 1, su);
    const int nv = sprite_spans(v, h, (flip & 2) ? -1 : 1, sv);
    for(int j = 0; j < nv; j++) {
        const int y0 = y + sv[j].at, y1 = y0 + sv[j].n, v0 = sv[j].t0, v1 = sv[j].t1;
        for(int i = 0; i < nu; i++) {
            const int x0 = x + su[i].at, x1 = x0 + su[i].n, u0 = su[i].t0, u1 = su[i].t1;
            bp_gpu_tri(x0, y0, bgr, u0, v0, x1, y0, bgr, u1, v0, x0, y1, bgr, u0, v1);
            bp_gpu_tri(x1, y0, bgr, u1, v0, x0, y1, bgr, u0, v1, x1, y1, bgr, u1, v1);
        }
    }
}

/* The last two display rectangles presented: a double-buffered game shows one and writes the
 * other, and a write into either is a write into a picture this backend draws. */
int g_disp[2][4];

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
 * that a later primitive samples (Crash 3 draws its shadow into 64x64 at 0,320). The runtime
 * rasterises that kind itself, into emulated VRAM, by this same rule from the same rectangles
 * (gpu.Gpu.offscreen), and reports it through bp_gpu_dirty like an upload, so it does not arrive
 * here; should any arrive anyway, the PlayStation never shows it, so neither is it drawn: 0. */
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

/* State s's buffer added to the n targets in t, unless it is there already or t is full. */
static int add_target(int t[][4], int n, int max, const gstate_t* s) {
    int ox, oy, ow, oh;
    if(n >= max || !screen_origin(s, &ox, &oy, &ow, &oh)) return n;
    else {}
    for(int k = 0; k < n; k++) {
        if(t[k][0] == ox && t[k][1] == oy && t[k][2] == ow && t[k][3] == oh) return n;
        else {}
    }
    t[n][0] = ox; t[n][1] = oy; t[n][2] = ow; t[n][3] = oh;
    return n + 1;
}

/* The buffers the records from `from` on draw into, each the rectangle screen_origin finds, at most
 * `max` of them, distinct (ADR-0053: the pictures a present renders). By state: each one a triangle
 * was recorded under, and each fill's. Not every state of the frame: the first is the last frame's
 * last, carried over (begin_frame), which in a double-buffered game draws into the other buffer.
 * Counted, it had every present of Crash 3 render the picture on screen again, over itself: a
 * second scene, a second walk of the frame's records with none of them placed. */
int state_targets(int t[][4], int max, int from) {
    int n = 0;
    for(int i = 0; i < g_state_count && n < max; i++) {
        if(g_states[i].tris != 0) n = add_target(t, n, max, &g_states[i]);
        else {}
    }
    const int ncmd = cmd_count();
    if(g_rect_over) {
        for(int i = from; i < ncmd && n < max; i++) {
            if(g_cmds[i].is_rect == GCMD_RECT) n = add_target(t, n, max, &g_states[g_cmds[i].state]);
            else {}
        }
    } else {
        for(int k = 0; k < g_rect_n && n < max; k++) {
            const int i = g_rect_at[k];
            if(i >= from && i < ncmd && g_cmds[i].is_rect == GCMD_RECT)
                n = add_target(t, n, max, &g_states[g_cmds[i].state]);
            else {}
        }
    }
    return n;
}

/* A picture whose records are drawn uncut (area_uncut): its drawing area, relative to the buffer's
 * corner (VRAM units, the right and bottom edges one past), for the build that follows. */
static int g_uncut, g_uncut_x0, g_uncut_y0, g_uncut_x1, g_uncut_y1;

/* Crash Bandicoot: Warped draws into y 12..227 of its 240-line buffers, so every triangle reaching
 * across either edge was cut in software (put_clipped, clip_step: 63 a present of its gameplay,
 * ~1,000 cycles each). Drawn whole instead, and the picture outside the area drawn again from the
 * picture itself after them (area_restore) — what the base did there, read before this render
 * writes a tile — the outside ends as it began and the inside as cutting left it. Only where that
 * holds: every triangle the frame recorded for this buffer under one drawing area (a state with
 * none, such as the frame's first, carried over from the last, is no matter), inside the buffer
 * and not all of it, every rectangle of the buffer within the area (fills ignore it), and no VRAM
 * mark (drawn from emulated VRAM, outside the area too). The caller asks only over a picture that
 * is its own base. */
int area_uncut(int tx, int ty, int tw, int th, int first) {
    g_uncut = 0;
    if(g_marks != 0 || g_rect_over || g_state_count <= 0) return 0;
    else {}
    int area = -1;
    /* Which buffer a state draws into depends only on its buffer corner and drawing area (words
     * 3-5), which the frame's states share by the hundred: worked out once for each. */
    uint32_t last_w3 = 0, last_w4 = 0, last_w5 = 0;
    int last_here = -1;
    for(int i = 0; i < g_state_count; i++) {
        const gstate_t* s = &g_states[i];
        if(s->tris == 0) continue;
        else {}
        if(last_here < 0 || ((s->w[3] ^ last_w3) | (s->w[4] ^ last_w4) | (s->w[5] ^ last_w5)) != 0) {
            int ox, oy, ow, oh;
            last_w3 = s->w[3]; last_w4 = s->w[4]; last_w5 = s->w[5];
            last_here = screen_origin(s, &ox, &oy, &ow, &oh) && ox == tx && oy == ty;
        } else {}
        if(!last_here) continue;
        else {}
        if(area < 0) area = i;
        else if(s->w[4] != g_states[area].w[4] || s->w[5] != g_states[area].w[5]) return 0;
        else {}
    }
    if(area < 0) return 0;
    else {}
    const gstate_t* a = &g_states[area];
    const int x0 = a->clip_x0, y0 = a->clip_y0, x1 = a->clip_x1 + 1, y1 = a->clip_y1 + 1;
    if(x0 < tx || y0 < ty || x1 > tx + tw || y1 > ty + th || x1 <= x0 || y1 <= y0) return 0;
    else {}
    if(x0 == tx && y0 == ty && x1 == tx + tw && y1 == ty + th) return 0;   /* nothing to cut */
    else {}
    const int n = cmd_count();
    for(int k = 0; k < g_rect_n; k++) {
        const int i = g_rect_at[k];
        if(i < first || i >= n || g_cmds[i].is_rect != GCMD_RECT) continue;
        else {}
        const gcmd_t* c = &g_cmds[i];
        int ox, oy, ow, oh;
        if(!screen_origin(&g_states[c->state], &ox, &oy, &ow, &oh) || ox != tx || oy != ty) continue;
        else {}
        if(c->x[0] < x0 || c->y[0] < y0 || c->x[0] + c->x[1] > x1 || c->y[0] + c->y[1] > y1) return 0;
        else {}
    }
    g_uncut = 1;
    g_uncut_x0 = x0 - tx; g_uncut_y0 = y0 - ty; g_uncut_x1 = x1 - tx; g_uncut_y1 = y1 - ty;
    return 1;
}

void area_uncut_end(void) {
    g_uncut = 0;
}

/** The picture outside the drawing area drawn again from the picture itself, last (area_uncut): up
 *  to four bands — above, below, left and right of the area — through the base's header, each
 *  texel where it is. A band's edge at a fraction of a pixel (a scale that is not whole) covers
 *  the pixels whose centres lie outside the area, the ones cutting left alone. */
__attribute__((noinline))
static void area_restore(float scale_x, float scale_y) {
    const float pw = g_base_x1, ph = g_base_y1;
    const float x0 = (float)g_uncut_x0 * scale_x, x1 = (float)g_uncut_x1 * scale_x;
    const float y0 = (float)g_uncut_y0 * scale_y, y1 = (float)g_uncut_y1 * scale_y;
    const float band[4][4] = {
        { 0.0f, 0.0f, pw, y0 }, { 0.0f, y1, pw, ph }, { 0.0f, y0, x0, y1 }, { x1, y0, pw, y1 },
    };
    const float su = g_base_u1 / pw, sv = g_base_v1 / ph;
    put_hdr(g_base_hdr);
    for(int k = 0; k < 4; k++) {
        const float bx0 = band[k][0], by0 = band[k][1], bx1 = band[k][2], by1 = band[k][3];
        if(bx1 <= bx0 || by1 <= by0) continue;
        else {}
        pvr_vertex_t v;
        v.argb = 0xFFFFFFFFu;
        v.oargb = 0;
        v.z = 1.0f;
        v.flags = PVR_CMD_VERTEX;
        v.x = bx0; v.y = by0; v.u = bx0 * su; v.v = by0 * sv; put_vtx(&v);
        v.x = bx1; v.y = by0; v.u = bx1 * su; v.v = by0 * sv; put_vtx(&v);
        v.x = bx0; v.y = by1; v.u = bx0 * su; v.v = by1 * sv; put_vtx(&v);
        v.flags = PVR_CMD_VERTEX_EOL;
        v.x = bx1; v.y = by1; v.u = bx1 * su; v.v = by1 * sv; put_vtx(&v);
    }
}

/* True when rectangle a lies inside rectangle b (corner, size). */
int inside(int ax, int ay, int aw, int ah, int bx, int by, int bw, int bh) {
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
    const int n = cmd_count();
    /* Through the pictures (ADR-0053) the marks before g_pic_done are in a picture already: a new
     * upload inside one is new content, and is neither dropped for it nor compacted with it. */
    const int floor = g_pic_active ? g_pic_done : 0;
    int i = n;
    while(i > floor && g_cmds[i - 1].is_rect == GCMD_VRAM) i--;
    for(int k = i; k < n; k++) {
        const gcmd_t* m = &g_cmds[k];
        if(inside(x, y, w, h, m->x[0], m->y[0], m->x[1], m->y[1])) return;
    }
    int out = i;
    for(int k = i; k < n; k++) {
        const gcmd_t* m = &g_cmds[k];
        if(!inside(m->x[0], m->y[0], m->x[1], m->y[1], x, y, w, h)) {
            if(out != k) shz_memcpy32_1(&g_cmds[out], m);
            else {}
            out++;
        } else {}
    }
    bp_gpu_sink.next = (uint32_t*)(void*)&g_cmds[out];
    if(out >= GPU_MAX_CMDS) { g_cmd_overflowed = 1; return; }
    gcmd_t* c = cmd_alloc();
    g_marks++;
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
    if(g_state_count <= 0) return;
    const gstate_t* p = &g_states[g_state_cur];
    state_enter(p->w[0], p->w[1], p->w[2], p->w[3],
                ((uint32_t)x0 & 0xFFFFu) | ((uint32_t)y0 << 16),
                ((uint32_t)x1 & 0xFFFFu) | ((uint32_t)y1 << 16), p->w[6]);
}

/* Recorded, not yet applied. The PVR has no stencil; the browser backend models these with one. */
static int g_mask_set, g_mask_check;
void bp_gpu_mask(int set_bit, int check_bit) {
    g_mask_set = set_bit; g_mask_check = check_bit;
}

static void textures_stale(int x, int y, int w, int h);

void bp_gpu_dirty(int x, int y, int w, int h) {
    g_scene_dirty = 1;
    textures_stale(x, y, w, h);
    mark_vram(x, y, w, h);
}

/* GP0(80h) (ADR-0054). Out of a buffer this backend draws — through the pictures, a buffer on
 * screen or the one before it — a record, drawn where it falls among the primitives from the source
 * buffer's picture (draw_copy): emulated VRAM's copy of a buffer lacks what was drawn in it. Out of
 * anything else emulated VRAM holds the copy, and it is a write like an upload's, when it changed
 * something there (`changed`, bp_gpu_dirty's rule). Into VRAM no
 * picture is made of from a buffer, there is nowhere to put what was drawn: emulated VRAM's copy
 * stands there, stale, and it is said once. */
void bp_gpu_copy(int sx, int sy, int dx, int dy, int w, int h, int changed) {
    /* Onto itself it moves nothing a picture holds: the runtime reports one only when it sets the
     * mask bit, which a picture does not keep (Crash Bash's 2x1 at every flip of its warning
     * screen). */
    if(sx == dx && sy == dy) return;
    else {}
    const int drawn = g_pic_active
        && (inside(sx, sy, w, h, g_disp[0][0], g_disp[0][1], g_disp[0][2], g_disp[0][3])
            || inside(sx, sy, w, h, g_disp[1][0], g_disp[1][1], g_disp[1][2], g_disp[1][3]));
    if(!drawn) {
        if(changed) bp_gpu_dirty(dx, dy, w, h);
        else {}
        return;
    } else {}
    g_scene_dirty = 1;
    textures_stale(dx, dy, w, h);
    if(!meets(g_disp[0], dx, dy, w, h) && !meets(g_disp[1], dx, dy, w, h)) {
        static int warned;
        if(!warned) { warned = 1; bp_log(BP_LOG_WARN, "gpu: a copy out of a buffer into VRAM no picture is made of (stale there)"); }
        else {}
        return;
    } else {}
    gcmd_t* c = cmd_line();
    if(!c) return;
    else {}
    g_marks++;
    c->is_rect = GCMD_COPY;
    c->state = 0;
    c->x[0] = (int16_t)dx; c->y[0] = (int16_t)dy;
    c->x[1] = (int16_t)w;  c->y[1] = (int16_t)h;
    c->x[2] = (int16_t)sx; c->y[2] = (int16_t)sy;
}

/* What emulated VRAM's write under this rectangle makes stale: the background slots and every
 * texture, palette and patch decoded out of it. */
static void textures_stale(int x, int y, int w, int h) {
    vram_rows_written(y, h);   /* the palette and CLUT memos' rows (g_vram_row_gen) */
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
    /* A VQ slot's indices are the page's (ADR-0061): the rows written go again at the next bind;
     * its codebooks go stale by their CLUT's row generation, asked at the bind. */
    vq_stale(x, y, w, h);
    /* A baked patch has the CLUT inside it, so it goes stale from either direction. */
    for(int i = 0; i < g_bake_n; i++) {
        if(!g_bake[i].used) continue;
        /* A patch is 64 texels: 16 halfwords at 4bpp, 32 at 8bpp; its CLUT 16 or 256. It starts
         * on a BAKE_STEP boundary: 8 halfwords at 4bpp, 16 at 8bpp. */
        const int bw = g_bake[i].depth == 1 ? BAKE_DIM / 2 : BAKE_DIM / 4;
        const int bs = g_bake[i].depth == 1 ? BAKE_STEP / 2 : BAKE_STEP / 4;
        const int cw = g_bake[i].depth == 1 ? 256 : 16;
        const int bx = g_bake[i].tex_x + g_bake[i].tu * bs;
        const int by = g_bake[i].tex_y + g_bake[i].tv * BAKE_STEP;
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
static int covers(const gcmd_t* c, int sw, int sh) {
    const gstate_t* s = &g_states[c->state];
    if(s->flags & BP_GPU_SEMI) return 0;
    int ox, oy, ow, oh;
    if(!screen_origin(s, &ox, &oy, &ow, &oh)) return 0;
    const int x0 = c->x[0] - ox, y0 = c->y[0] - oy;
    return x0 <= 0 && y0 <= 0 && x0 + c->x[1] >= sw && y0 + c->y[1] >= sh;
}

int last_cover(int sw, int sh) {
    if(g_rect_over) {
        for(int i = cmd_count() - 1; i >= 0; i--) {
            const gcmd_t* c = &g_cmds[i];
            if(c->is_rect == GCMD_RECT && covers(c, sw, sh)) return i;
            else {}
        }
        return -1;
    } else {}
    const int n = cmd_count();
    for(int k = g_rect_n - 1; k >= 0; k--) {
        const int i = g_rect_at[k];
        if(i < n && g_cmds[i].is_rect == GCMD_RECT && covers(&g_cmds[i], sw, sh)) return i;
        else {}
    }
    return -1;
}

/* The last opaque fill from record `from` on that covers the whole of the buffer at tx, ty (sw x sh),
 * or -1: last_cover, for one picture of several (ADR-0053). */
static int covers_at(const gcmd_t* c, int tx, int ty, int sw, int sh) {
    const gstate_t* s = &g_states[c->state];
    if(s->flags & BP_GPU_SEMI) return 0;
    int ox, oy, ow, oh;
    if(!screen_origin(s, &ox, &oy, &ow, &oh) || ox != tx || oy != ty) return 0;
    const int x0 = c->x[0] - ox, y0 = c->y[0] - oy;
    return x0 <= 0 && y0 <= 0 && x0 + c->x[1] >= sw && y0 + c->y[1] >= sh;
}

int last_cover_at(int tx, int ty, int sw, int sh, int from) {
    const int n = cmd_count();
    if(g_rect_over) {
        for(int i = n - 1; i >= from; i--) {
            const gcmd_t* c = &g_cmds[i];
            if(c->is_rect == GCMD_RECT && covers_at(c, tx, ty, sw, sh)) return i;
            else {}
        }
        return -1;
    } else {}
    for(int k = g_rect_n - 1; k >= 0; k--) {
        const int i = g_rect_at[k];
        if(i < from) break;
        else if(i < n && g_cmds[i].is_rect == GCMD_RECT && covers_at(&g_cmds[i], tx, ty, sw, sh)) return i;
        else {}
    }
    return -1;
}

/* Whether a VRAM mark from `first` on falls inside the picture (sx, sy, sw, sh): if so the
 * background texture is needed even under a covering fill. */
int marks_from(int first, int sx, int sy, int sw, int sh) {
    if(g_marks == 0) return 0;      /* none this frame: no walk */
    else {}
    const int disp[4] = { sx, sy, sw, sh };
    const int n = cmd_count();
    for(int i = first < 0 ? 0 : first; i < n; i++) {
        const gcmd_t* c = &g_cmds[i];
        if(c->is_rect >= GCMD_VRAM && meets(disp, c->x[0], c->y[0], c->x[1], c->y[1])) return 1;
    }
    return 0;
}

/** The part of the background texture a VRAM mark covers, drawn where the mark sits in the order.
 *  Returns 1 when something was drawn, so the caller restates its own header after it. */
__attribute__((noinline))
static int draw_mark(const gcmd_t* c, int sx, int sy, int sw, int sh, float scale_x, float scale_y) {
    int x0 = c->x[0], y0 = c->y[0], x1 = c->x[0] + c->x[1], y1 = c->y[0] + c->y[1];
    if(x0 < sx) x0 = sx;
    if(y0 < sy) y0 = sy;
    if(x1 > sx + sw) x1 = sx + sw;
    if(y1 > sy + sh) y1 = sy + sh;
    if(x0 >= x1 || y0 >= y1) return 0;
    put_hdr(&g_hdr);
    pvr_vertex_t v;
    v.argb = 0xFFFFFFFFu;
    v.oargb = 0;
    v.z = 1.0f;
    const float u0 = (float)(x0 - sx) / (float)g_txw, u1 = (float)(x1 - sx) / (float)g_txw;
    const float w0 = (float)(y0 - sy) / (float)g_txh, w1 = (float)(y1 - sy) / (float)g_txh;
    const float px0 = (float)(x0 - sx) * scale_x, px1 = (float)(x1 - sx) * scale_x;
    const float py0 = (float)(y0 - sy) * scale_y, py1 = (float)(y1 - sy) * scale_y;
    v.flags = PVR_CMD_VERTEX;
    v.x = px0; v.y = py0; v.u = u0; v.v = w0; put_vtx(&v);
    v.x = px1; v.y = py0; v.u = u1; v.v = w0; put_vtx(&v);
    v.x = px0; v.y = py1; v.u = u0; v.v = w1; put_vtx(&v);
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = px1; v.y = py1; v.u = u1; v.v = w1; put_vtx(&v);
    return 1;
}

/** A copy into the buffer at sx, sy being rendered (ADR-0054): the picture of the buffer it reads,
 *  point sampled and replacing, where its destination falls in this one — the PlayStation copies
 *  what that buffer holds, which emulated VRAM lacks. Pixel for pixel when the two buffers are the
 *  same size, as both pictures are the screen's. A source with no picture yet: emulated VRAM's
 *  result, as a mark is drawn. Inside one buffer the picture read is the one this render started
 *  from (pic_page says where that holds). Returns 1 when something was drawn. */
__attribute__((noinline))
static int draw_copy(const gcmd_t* c, int sx, int sy, int sw, int sh, float scale_x, float scale_y) {
    int x0 = c->x[0], y0 = c->y[0], x1 = c->x[0] + c->x[1], y1 = c->y[0] + c->y[1];
    if(x0 < sx) x0 = sx;
    if(y0 < sy) y0 = sy;
    if(x1 > sx + sw) x1 = sx + sw;
    if(y1 > sy + sh) y1 = sy + sh;
    if(x0 >= x1 || y0 >= y1) return 0;
    else {}
    const int cx = c->x[2] + (x0 - c->x[0]), cy = c->y[2] + (y0 - c->y[0]);
    int px, py;
    float ru, rv;
    const pvr_poly_hdr_t* src = pic_source(cx, cy, x1 - x0, y1 - y0, &px, &py, &ru, &rv);
    if(!src) return draw_mark(c, sx, sy, sw, sh, scale_x, scale_y);
    else {}
    put_hdr(src);
    pvr_vertex_t v;
    v.argb = 0xFFFFFFFFu;
    v.oargb = 0;
    v.z = 1.0f;
    const float u0 = (float)(cx - px) * ru, u1 = (float)(cx - px + x1 - x0) * ru;
    const float w0 = (float)(cy - py) * rv, w1 = (float)(cy - py + y1 - y0) * rv;
    const float px0 = (float)(x0 - sx) * scale_x, px1 = (float)(x1 - sx) * scale_x;
    const float py0 = (float)(y0 - sy) * scale_y, py1 = (float)(y1 - sy) * scale_y;
    v.flags = PVR_CMD_VERTEX;
    v.x = px0; v.y = py0; v.u = u0; v.v = w0; put_vtx(&v);
    v.x = px1; v.y = py0; v.u = u1; v.v = w0; put_vtx(&v);
    v.x = px0; v.y = py1; v.u = u0; v.v = w1; put_vtx(&v);
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = px1; v.y = py1; v.u = u1; v.v = w1; put_vtx(&v);
    return 1;
}

/** Submits the header for this binding, compiled once and kept (see g_hdrc), and returns the
 *  vertex alpha its blend needs. `over` is the second pass of a brightened primitive: the same
 *  texture and source factor, but added to what is there (dst ONE) instead of replacing it. */
/* `keep`, when given, receives a copy of the header emitted, for build_scene to restate without
 * asking the cache again (the slot itself may be taken by the next header that hashes there). */
static float emit_header_compile(pvr_ptr_t mem, int fmt, int dim, const gstate_t* s, int over, int kind,
                                 pvr_poly_hdr_t* keep, int hs, uint32_t key) __attribute__((noinline));

static float emit_header(pvr_ptr_t mem, int fmt, int dim, const gstate_t* s, int over, int kind,
                         pvr_poly_hdr_t* keep) {
    const uint32_t key = hdr_key(dim, s, over, kind);
    const int hs = hdr_slot(mem, fmt, key);
    ghdr_t* e = &g_hdrc[hs];
    if(e->key == key && e->mem == mem && e->fmt == fmt) {
        g_hdr_hits++;
        put_hdr(&e->hdr);
        if(keep) shz_memcpy32_1(keep, &e->hdr);
        else {}
        return e->alpha;
    } else return emit_header_compile(mem, fmt, dim, s, over, kind, keep, hs, key);
}

/* A binding the cache does not hold: compiled, kept and emitted. Out of line, so that the hit
 * above does not open this one's frame (the context below is most of it) for every run. */
static float emit_header_compile(pvr_ptr_t mem, int fmt, int dim, const gstate_t* s, int over, int kind,
                                 pvr_poly_hdr_t* keep, int hs, uint32_t key) {
    float alpha;
    pvr_poly_cxt_t cxt;
    const int blends = (s->flags & BP_GPU_SEMI) && kind == HK_NORMAL;
    if(mem && kind != HK_INVERT) {
        pvr_poly_cxt_txr(&cxt, PVR_LIST_TR_POLY, fmt, dim_u(dim), dim_v(dim), mem, PVR_FILTER_NONE);
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
    g_hdrc[hs].key = key;
    g_hdrc[hs].mem = mem;
    g_hdrc[hs].fmt = fmt;
    g_hdrc[hs].alpha = alpha;
    g_hdr_compiles++;
    put_hdr(&g_hdrc[hs].hdr);
    if(keep) shz_memcpy32_1(keep, &g_hdrc[hs].hdr);
    else {}
    return alpha;
}

/* What put_tri needs of the current binding: the scale, and the offsets as integers — the buffer's
 * corner in VRAM, and in the texture twice the patch origin less the texel centre (ou2 = 2 * ou - 1)
 * — so that each coordinate is an integer subtraction, one conversion and one multiply. It was a
 * multiply-add, and on the SH-4 fmac takes its multiplier in fr0 and overwrites its addend, so each
 * one also cost a move into fr0 and a copy of the offset. Texture terms stay exact: rh = rdim / 2
 * is a power of two. */
typedef struct { float sx, sy, rh, rv; int ox, oy, ou2, ov2; } gvert_t;

static inline void vert_set(gvert_t* t, float sx, float sy, int ox, int oy, float rdim, float rdimv,
                            int ou, int ov) {
    t->sx = sx; t->sy = sy; t->rh = 0.5f * rdim; t->rv = 0.5f * rdimv;
    t->ox = ox; t->oy = oy; t->ou2 = 2 * ou - 1; t->ov2 = 2 * ov - 1;
}

/** One vertex into the store queue that ends at `end`, and the queue sent to the TA: written
 *  backwards, every store a pre-decrement (`mov.l`/`fmov.s @-Rn`), then `pref` on the queue — what
 *  pvr_dr_commit does. The SH-4's `fmov.s` has no displacement form, so the same fields written in
 *  place (pvr_vertex_t) cost an address computation per float, and GCC turns `*--p` back into
 *  displacements, hence the asm. Every field is written: the queue holds whatever went before.
 *  No "memory" clobber: the queue is no C object, so nothing C reads can change under it, and with
 *  the clobber every vertex made the compiler load the record and the binding again. The asm is
 *  volatile, so the queue's stores keep their order and the `pref` its place. */
static inline void sq_vertex(uint32_t end, uint32_t flags, float x, float y, float u, float v,
                             uint32_t argb) {
#if RECOMPSX_TA_HASH
    {
        pvr_vertex_t h;
        h.flags = flags; h.x = x; h.y = y; h.z = 1.0f; h.u = u; h.v = v; h.argb = argb; h.oargb = 0;
        TA_HASH(&h);
    }
#endif
    __asm__ __volatile__(
        "mov.l   %[zero], @-%[p]\n\t"   /* oargb */
        "mov.l   %[argb], @-%[p]\n\t"
        "fmov.s  %[v], @-%[p]\n\t"
        "fmov.s  %[u], @-%[p]\n\t"
        "fmov.s  %[z], @-%[p]\n\t"      /* no depth: the order of submission decides */
        "fmov.s  %[y], @-%[p]\n\t"
        "fmov.s  %[x], @-%[p]\n\t"
        "mov.l   %[flags], @-%[p]\n\t"
        "pref    @%[p]"
        : [p] "+r" (end)
        : [zero] "r" (0), [argb] "r" (argb), [flags] "r" (flags),
          [x] "f" (x), [y] "f" (y), [u] "f" (u), [v] "f" (v), [z] "f" (1.0f));
}

/** One triangle's vertices, straight into the store queues and on to the TA (KOS direct
 *  rendering), the queue address kept in a register for the triangle and stored back once where
 *  pvr_dr_target read and wrote `pvr_dr_addr` at every vertex. All four coordinates of a vertex
 *  are computed before any is stored, so the multiplies overlap. */
static inline uint32_t put_tri_at(uint32_t a, const gcmd_t* c, const uint32_t* col, const gvert_t* t) {
    for(int k = 0; k < 3; k++) {
        const float x = (float)(c->x[k] - t->ox) * t->sx;
        const float y = (float)(c->y[k] - t->oy) * t->sy;
        const float u = (float)(2 * c->u[k] - t->ou2) * t->rh;
        const float v = (float)(2 * c->v[k] - t->ov2) * t->rv;
        a ^= 32;
        sq_vertex(a + 32, (k == 2) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX, x, y, u, v, col[k]);
    }
    return a;
}

/** An untextured triangle: the same, with no texture coordinates to compute. An untextured
 *  header's vertex (the TA's packed-colour type 0) ignores the two words where U and V go. */
/* A texel coordinate of the common binding — a whole 256-texel page, no patch origin (`ou` and `ov` 0)
 * — as put_tri_at works it out, (2 * u + 1) * (1 / 512): the texel's centre. Exact either way (an odd
 * integer below 2^9 times a power of two), so a table read gives the bits the arithmetic did, where
 * that was a byte load through r0's address forms, an add, a subtract, a conversion and a multiply
 * for each of six coordinates a triangle. Filled by build_scene's first call. */
static float g_uv256[256];

/** put_tri_at for the common binding (g_uv256): the record's texture words read whole, each
 *  coordinate a byte of them and an indexed load. */
static inline uint32_t put_tri_uv256_at(uint32_t a, const gcmd_t* c, const uint32_t* col, const gvert_t* t) {
    const uint32_t w6 = c->w[6], w7 = c->w[7];
    const uint32_t uv[6] = { w6 & 0xFFu, (w6 >> 8) & 0xFFu, (w6 >> 16) & 0xFFu, w6 >> 24, w7 & 0xFFu,
                             (w7 >> 8) & 0xFFu };
    for(int k = 0; k < 3; k++) {
        const float x = (float)(c->x[k] - t->ox) * t->sx;
        const float y = (float)(c->y[k] - t->oy) * t->sy;
        const float u = g_uv256[uv[k]];
        const float v = g_uv256[uv[3 + k]];
        a ^= 32;
        sq_vertex(a + 32, (k == 2) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX, x, y, u, v, col[k]);
    }
    return a;
}

static inline uint32_t put_tri_col_at(uint32_t a, const gcmd_t* c, const uint32_t* col, const gvert_t* t) {
    for(int k = 0; k < 3; k++) {
        const float x = (float)(c->x[k] - t->ox) * t->sx;
        const float y = (float)(c->y[k] - t->oy) * t->sy;
        a ^= 32;
        sq_vertex(a + 32, (k == 2) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX, x, y, 0.0f, 0.0f, col[k]);
    }
    return a;
}

static inline void put_tri(const gcmd_t* c, const uint32_t* col, const gvert_t* t) {
    pvr_dr_addr = put_tri_at(pvr_dr_addr, c, col, t);
}

/** A header into the store queue that ends at `end`, and the queue sent to the TA: its eight words
 *  through two integer registers, written backwards as sq_vertex writes a vertex. For run_tris,
 *  which keeps the queue's address in a register and the vertex terms in the FPU's: put_hdr goes
 *  through pvr_dr_addr and copies with the FPU's pair moves, which clobber eight of its registers. */
static inline void sq_header(uint32_t end, const pvr_poly_hdr_t* h) {
    TA_HASH(h);
    uint32_t t0, t1;
    __asm__ __volatile__(
        "mov.l   @(28,%[h]), %[t0]\n\t"
        "mov.l   @(24,%[h]), %[t1]\n\t"
        "mov.l   %[t0], @-%[p]\n\t"
        "mov.l   @(20,%[h]), %[t0]\n\t"
        "mov.l   %[t1], @-%[p]\n\t"
        "mov.l   @(16,%[h]), %[t1]\n\t"
        "mov.l   %[t0], @-%[p]\n\t"
        "mov.l   @(12,%[h]), %[t0]\n\t"
        "mov.l   %[t1], @-%[p]\n\t"
        "mov.l   @(8,%[h]), %[t1]\n\t"
        "mov.l   %[t0], @-%[p]\n\t"
        "mov.l   @(4,%[h]), %[t0]\n\t"
        "mov.l   %[t1], @-%[p]\n\t"
        "mov.l   @%[h], %[t1]\n\t"
        "mov.l   %[t0], @-%[p]\n\t"
        "mov.l   %[t1], @-%[p]\n\t"
        "pref    @%[p]"
        : [p] "+r" (end), [t0] "=&r" (t0), [t1] "=&r" (t1)
        : [h] "r" (h), "m" (*(const uint8_t (*)[32])h));
}

/* The current run's header and its brightening header, as build_scene last emitted them; restated
 * from where g_run_hdr_p points: g_run_hdr, or a state's entry in g_sres. */
static pvr_poly_hdr_t g_run_hdr __attribute__((aligned(32)));
static pvr_poly_hdr_t g_run_over __attribute__((aligned(32)));
static const pvr_poly_hdr_t* g_run_hdr_p = &g_run_hdr;

/* What build_scene worked out for a state of this build, by its index (states are recorded once a
 * frame by content, state_enter): the textures it binds — as g_tbind keeps them by what they bind,
 * without the hash — and the header made for that binding, sent again from here at each return to
 * the state, where emit_header hashed, searched and copied it every time. Direct-mapped; an entry is
 * its state's while `tag` says so in this build (`gen`). */
#define SRES_BITS 7
typedef struct __attribute__((aligned(32))) {
    pvr_poly_hdr_t hdr;         /* the header made for (mem, fmt, dim), when hdr_ok */
    pvr_ptr_t mir, mem;
    int       fmt, dim;
    float     alpha;
    union {
        struct { uint16_t tag, gen; };
        uint32_t key;           /* tag | gen << 16: the entry's state in this build, one compare */
    };
    int16_t   bank, slot;
    uint8_t   patch8, bind_ok, hdr_ok;
    /* What a return to the state can take from here without asking anything again (build_scene's
     * fast path): 0 nothing; else the header is the one its triangles' binding wants, and that
     * binding is a page mirror's bank (SRES_MIR), a page slot's (SRES_SLOT, checked against what the
     * slot holds) or none, untextured (SRES_FLAT). */
    uint8_t   fast;
} gsres_t;
enum { SRES_MIR = 1, SRES_SLOT = 2, SRES_FLAT = 3, SRES_VQ = 4 };
static gsres_t g_sres[1 << SRES_BITS];
/* A VQ binding's rows (ADR-0061), for an entry whose `fast` is SRES_VQ: the codebook's V offset, kept
 * beside the entries rather than in them, which are two cache lines exactly. */
static int8_t g_sres_rows[1 << SRES_BITS];

/* A binding of the semi-transparent path, as semi_bind made it (see g_semi_binds). */
typedef struct gsemibind gsemibind_t;

/* The scene's placement and clipping, the semi-transparent path's current binding, and the terms
 * the clipper adds after scaling. */
typedef struct {
    float     scale_x, scale_y;
    /* The semi-transparent path's binding — its header, the terms put_tri adds, the vertex alpha —
     * when its header was the last one sent; NULL when another went out after it. */
    const gsemibind_t* e;
    /* What put_clipped adds after scaling, for the triangle it is given: the reciprocal of the bound
     * texture's size, so the clipper multiplies where it used to divide — SH-4's FDIV is expensive
     * and poorly pipelined — and the offsets. */
    float     rdim, rdimv, xo, yo, uo, vo;
    /* The current state's buffer corner in VRAM (screen_origin) and its drawing area, both in
     * VRAM units: the area as integers for the inside test, and as the edges the clipper cuts
     * at — the right and bottom one past the last pixel, since pixel x covers [x, x + 1). */
    int       ox, oy, clx0, cly0, clx1, cly1;
    int       cut_x, cut_y;   /* whether an edge of that axis lies inside the picture at all */
    /* The same edges as tri_inside takes them: a coordinate is inside when (unsigned)(v - lo) is at
     * most span (cut_span). */
    int       xlo, ylo;
    uint32_t  xspan, yspan;
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
/* Kept past its build while the CLUT's row is unchanged (rgen, g_vram_row_gen): the class is read
 * from that row alone. `ok` marks an entry ever written. */
static struct { uint32_t gen, rgen; uint16_t cx, cy; uint8_t depth, cls, ok; } g_cls_memo[CLS_MEMO];

/* Remembered for one scene build, as pal_bank_cached's answers are: VRAM is still while the scene
 * is built, and a semi-transparent state's CLUT was scanned again at every run that used it — an
 * 8bpp one is 256 reads. */
static int clut_class_scan(const gstate_t* s);
static int clut_class(const gstate_t* s) {
    if(s->depth == 2) return CLS_MIXED;
    const uint32_t k = (((uint32_t)s->clut_x >> 4) ^ ((uint32_t)s->clut_y * 0x9E5u)
                        ^ ((uint32_t)s->depth << 7)) & (CLS_MEMO - 1);
    if(g_cls_memo[k].ok && g_cls_memo[k].cx == s->clut_x && g_cls_memo[k].cy == s->clut_y
       && g_cls_memo[k].depth == s->depth
       && (g_cls_memo[k].gen == g_pal_memo_gen
           || g_cls_memo[k].rgen == g_vram_row_gen[s->clut_y & (VRAM_H - 1)]))
        return g_cls_memo[k].cls;
    const int cls = clut_class_scan(s);
    g_cls_memo[k].ok = 1;
    g_cls_memo[k].rgen = g_vram_row_gen[s->clut_y & (VRAM_H - 1)];
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
    pvr_ptr_t pic;                      /* a page in a buffer's picture (ADR-0054), its binding */
    pvr_ptr_t vqm[AM_N];                /* a VQ page's binding per variant (ADR-0061), when vqr >= 0 */
    int8_t    vqr[AM_N];                /* its rows; -2 not asked yet, -1 none */
    int       pdim, pou, pov;
} grun_t;

static void run_begin(grun_t* r, const gstate_t* s, int state) {
    r->state = state;
    for(int k = 0; k < AM_N; k++) { r->bank[k] = -2; r->slot[k] = -2; r->vqr[k] = -2; }
    /* The page grid is the mirror's index, so a page origin that is not on the grid would
     * silently read a neighbour. The texpage encoding cannot produce one; the guard costs a
     * compare and removes the assumption. */
    const int plain = (s->window & 0x3FF) == 0 && (s->tex_x & 63) == 0 && (s->tex_y & 255) == 0;
#if RECOMPSX_VQ >= 2
    r->mir = NULL;          /* every plain 4bpp page a VQ page too (ADR-0061): no mirror, no bank */
#else
    r->mir = (s->depth == 0 && plain) ? page4_mirror(s) : NULL;
#endif
    /* An unwindowed 8bpp page is drawn from 64x64 patches through its CLUT (bake_slot); the
     * whole page is decoded only for a primitive sampling across patches. */
    r->patch8 = (s->depth == 1 || (RECOMPSX_VQ >= 2 && s->depth == 0)) && plain;
    r->cls = (s->flags & BP_GPU_SEMI) ? clut_class(s) : CLS_SOLID;
    /* A 15-bit page in a buffer this backend draws: its picture (ADR-0054). A picture keeps no bit
     * 15, so every texel is taken as the PlayStation's "blend me" one — what most of a frame drawn
     * from Crash Bandicoot: Warped's textures carries (83 % of its pixels when its transition
     * reads it back). */
    r->pic = NULL;
    if(s->depth == 2 && (s->window & 0x3FF) == 0 && pic_page(s->tex_x, s->tex_y, &r->pic, &r->pdim, &r->pou, &r->pov)) {
        r->mir = NULL;
        r->patch8 = 0;
        if(s->flags & BP_GPU_SEMI) r->cls = CLS_STP;
        else {}
    } else {}
}

/** Whether a semi-transparent record is one pass in its state's own blend, which build_scene draws
 *  as it draws an opaque record — the same header (emit_header, HK_NORMAL: the state's blend), the
 *  same colours and brightening pass, in runs, its state's answers kept in g_sres — rather than
 *  through semi_prim, whose passes, bindings and their caches are for the primitives that need
 *  more than one: a triangle untextured or through a CLUT whose every visible texel blends
 *  (CLS_STP; at 4 or 8 bits, where the bank or the patch is the visible variant's either way), in
 *  any mode but B - F. Crash 3's demo sends ~45 such triangles a present, each ~1,500 cycles
 *  through semi_prim's passes against ~300 in a run. A CLUT with solid texels as well (two passes),
 *  one with none (nothing drawn), a 15-bit page and a rectangle keep semi_prim. */
#ifndef RECOMPSX_SEMI_SINGLE
#define RECOMPSX_SEMI_SINGLE 1      /* 0: every semi-transparent record through semi_prim, as before */
#endif
static inline uint32_t sres_key(int state);
/* The states of this build semi_single has said no to (their sres_key, by their g_sres index): a
 * state that needs semi_prim's passes asks again at every record — no fast path ever takes it — and
 * clut_class's memo was ~95 cycles each time (ledger E-182). */
static uint32_t g_semi_multi[1 << SRES_BITS];
static inline int semi_single(const gcmd_t* c, const gstate_t* s) {
    if(!RECOMPSX_SEMI_SINGLE || s->semi_mode == 2 || c->is_rect) return 0;
    else if(!(s->flags & BP_GPU_TEXTURED)) return 1;
    else {}
    const uint32_t key = sres_key(c->state);
    uint32_t* const m = &g_semi_multi[c->state & ((1 << SRES_BITS) - 1)];
    if(*m == key) return 0;
    else if(s->depth != 2 && clut_class(s) == CLS_STP) return 1;
    else {}
    *m = key;
    return 0;
}

/* The 64x64 patch a primitive samples within, if it samples within one. */
/* Along one axis, the origin (in BAKE_STEP units) of a patch holding texels lo..hi: the aligned
 * patch when they fit in it, else the one starting at lo's own step. 0 when neither holds them. */
static inline int patch_origin(int lo, int hi, int* t) {
    int o = (lo / BAKE_DIM) * (BAKE_DIM / BAKE_STEP);
    if(hi >= o * BAKE_STEP + BAKE_DIM) o = lo / BAKE_STEP;
    *t = o;
    return hi < o * BAKE_STEP + BAKE_DIM;
}

static int one_patch(const gcmd_t* c, int* tu, int* tv) {
    int umin = c->u[0], umax = c->u[0], vmin = c->v[0], vmax = c->v[0];
    for(int k = 1; k < 3; k++) {
        if(c->u[k] < umin) umin = c->u[k];
        if(c->u[k] > umax) umax = c->u[k];
        if(c->v[k] < vmin) vmin = c->v[k];
        if(c->v[k] > vmax) vmax = c->v[k];
    }
    return patch_origin(umin, umax, tu) && patch_origin(vmin, vmax, tv);
}

/** State s's page through its CLUT in variant `am` as a VQ codebook (ADR-0061), into b: the
 *  state's binding, the same for every record under it. */
static int bind_vq(const gstate_t* s, int am, gbind_t* b) {
    pvr_ptr_t vm;
    int rows;
    if(!vq_bind(s, am, &vm, &rows)) return 0;
    else {}
    b->mem = vm; b->fmt = VQ_FMT; b->dim = VQ_TEXDIM; b->ou = 0; b->ov = -rows;
    return 1;
}

/** Where primitive c's texels come from in variant `am`, into b; 0 when nowhere, and then the
 *  primitive is skipped — drawing it untextured would be worse. */
__attribute__((noinline))
static int bind_texture_slow(const gcmd_t* c, const gstate_t* s, int am, grun_t* r, gbind_t* b) {
    int tu, tv;
#if RECOMPSX_VQ
    (void)c; (void)tu; (void)tv;      /* the bake's patch (ADR-0061) */
#endif
    b->ou = 0; b->ov = 0; b->dim = TEX_DIM;
    if(r->mir) {
        if(r->bank[am] == -2) r->bank[am] = pal_bank_cached(s->clut_x, s->clut_y, 0, am);
        if(r->bank[am] >= 0) {
            b->mem = r->mir;
            b->fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(r->bank[am]) | PVR_TXRFMT_TWIDDLED;
            return 1;
        }
        /* No bank was left for this palette: the page's indices through its CLUT as a VQ codebook
         * (ADR-0061), or texels that already have the CLUT in them — exact either way. */
#if RECOMPSX_VQ
        if(bind_vq(s, am, b)) return 1;
        else {}
#else
        const int k = one_patch(c, &tu, &tv) ? bake_slot(s, tu, tv, am) : -1;
        if(k >= 0) {
            b->mem = g_bake[k].mem;
            b->fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
            b->dim = BAKE_DIM; b->ou = tu * BAKE_STEP; b->ov = tv * BAKE_STEP;
            return 1;
        }
#endif
        /* Sampling wider than one patch, or the patch pool is all in flight: the nearest banked
         * palette, which is the only lossy path left in the scene. */
        g_bake_miss++;
        const int nb = pal_bank_cached(s->clut_x, s->clut_y, 1, am);
        b->mem = r->mir;
        b->fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(nb < 0 ? 0 : nb) | PVR_TXRFMT_TWIDDLED;
        return 1;
    }
    if(r->patch8) {
#if RECOMPSX_VQ
        /* Asked once a run and variant: the state's answer for the build. */
        if(r->vqr[am] == -2) {
            int rows;
            r->vqr[am] = vq_bind(s, am, &r->vqm[am], &rows) ? (int8_t)rows : -1;
        } else {}
        if(r->vqr[am] >= 0) {
            b->mem = r->vqm[am]; b->fmt = VQ_FMT; b->dim = VQ_TEXDIM; b->ou = 0; b->ov = -r->vqr[am];
            return 1;
        } else {}
#else
#if RECOMPSX_VQ8
        /* An 8bpp page as a VQ page, asked once a run and variant (RECOMPSX_VQ8). */
        if(s->depth == 1) {
            if(r->vqr[am] == -2) {
                int rows;
                r->vqr[am] = vq_bind(s, am, &r->vqm[am], &rows) ? (int8_t)rows : -1;
            } else {}
            if(r->vqr[am] >= 0) {
                b->mem = r->vqm[am]; b->fmt = VQ_FMT; b->dim = VQ_TEXDIM; b->ou = 0; b->ov = -r->vqr[am];
                return 1;
            } else {}
        } else {}
#endif
        const int k = one_patch(c, &tu, &tv) ? bake_slot(s, tu, tv, am) : -1;
        if(k >= 0) {
            b->mem = g_bake[k].mem;
            b->fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
            b->dim = BAKE_DIM; b->ou = tu * BAKE_STEP; b->ov = tv * BAKE_STEP;
            return 1;
        }
#endif
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

/** Variant `am` of the one 64x64 patch primitive c samples, baked with its CLUT applied: exact,
 *  and no palette bank spent. 0 when c samples more than one patch or the pool is all in flight. */
static int bind_baked(const gcmd_t* c, const gstate_t* s, int am, gbind_t* b) {
#if RECOMPSX_VQ
    (void)c;
    return bind_vq(s, am, b);
#endif
    int tu, tv;
    if(!one_patch(c, &tu, &tv)) return 0;
    const int k = bake_slot(s, tu, tv, am);
    if(k < 0) return 0;
    b->mem = g_bake[k].mem;
    b->fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
    b->dim = BAKE_DIM; b->ou = tu * BAKE_STEP; b->ov = tv * BAKE_STEP;
    return 1;
}

/* A vertex of a clipped polygon, in VRAM units, with what is interpolated along an edge. Padded to
 * 32 bytes and aligned so a kept vertex is one shz_memcpy32_1: at seven floats every copy was a
 * call to GCC's __movstr_i4_odd, 0.4-0.6 % of a frame in both games. */
typedef struct __attribute__((aligned(32))) { float x, y, u, v, r, g, b, pad; } cvert_t;
_Static_assert(sizeof(cvert_t) == 32, "a clipped vertex is one cache line");

/* One Sutherland-Hodgman step: keeps the part of polygon v (n vertices) on the inner side of an
 * edge — coordinate `axis` (0 x, 1 y) at least `lim` when `lower`, at most it otherwise. */
static int clip_step(const cvert_t* v, int n, cvert_t* out, int axis, float lim, int lower) {
    int m = 0;
    for(int i = 0; i < n; i++) {
        const cvert_t* a = &v[i];
        const cvert_t* b = &v[i + 1 == n ? 0 : i + 1];
        const float ca = axis ? a->y : a->x, cb = axis ? b->y : b->x;
        const float da = lower ? ca - lim : lim - ca, db = lower ? cb - lim : lim - cb;
        if(da >= 0.0f) shz_memcpy32_1(&out[m++], a);
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
    /* Only the edges that lie inside the picture, each step writing the other buffer — and of
     * those only the ones the triangle reaches past: a step with every vertex on its inner side
     * copies them as they are, in order, and adds none, so it is left out. The triangle's own
     * integers decide it: a step on one axis adds vertices at its edge, an area's height or width
     * away from the other edge of that axis; one on x adds vertices whose y is interpolated and may
     * lie an ulp outside the triangle's, so after one the y edges are skipped only when the
     * triangle is a whole unit inside them. A triangle crossing the drawing area's bottom took four
     * steps where it needs one (ledger E-113). */
    const int xmin = c->x[0] < c->x[1] ? (c->x[0] < c->x[2] ? c->x[0] : c->x[2]) : (c->x[1] < c->x[2] ? c->x[1] : c->x[2]);
    const int xmax = c->x[0] > c->x[1] ? (c->x[0] > c->x[2] ? c->x[0] : c->x[2]) : (c->x[1] > c->x[2] ? c->x[1] : c->x[2]);
    const int ymin = c->y[0] < c->y[1] ? (c->y[0] < c->y[2] ? c->y[0] : c->y[2]) : (c->y[1] < c->y[2] ? c->y[1] : c->y[2]);
    const int ymax = c->y[0] > c->y[1] ? (c->y[0] > c->y[2] ? c->y[0] : c->y[2]) : (c->y[1] > c->y[2] ? c->y[1] : c->y[2]);
    int n = 3;
    int xcut = 0;
    cvert_t* t;
    if(g->cut_x) {
        if(xmin < g->clx0) { n = clip_step(v, n, w, 0, (float)g->clx0, 1); t = v; v = w; w = t; xcut = 1; }
        else {}
        if(n && xmax > g->clx1 + 1) { n = clip_step(v, n, w, 0, (float)(g->clx1 + 1), 0); t = v; v = w; w = t; xcut = 1; }
        else {}
    } else {}
    if(g->cut_y && n) {
        if(ymin < g->cly0 + xcut) { n = clip_step(v, n, w, 1, (float)g->cly0, 1); t = v; v = w; w = t; }
        else {}
        if(n && ymax > g->cly1 + 1 - xcut) { n = clip_step(v, n, w, 1, (float)(g->cly1 + 1), 0); t = v; v = w; w = t; }
        else {}
    } else {}
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
        d->v = q->v * g->rdimv + g->vo;
        d->argb = a | ((uint32_t)(q->r + 0.5f) << 16) | ((uint32_t)(q->g + 0.5f) << 8)
                | (uint32_t)(q->b + 0.5f);
        d->oargb = 0;
        TA_HASH(d);
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
/* lo <= v <= hi is (unsigned)(v - lo) <= hi - lo, one compare a coordinate where it was two
 * differences and their signs (E-159); an edge pair with no coordinate between them takes a lo no
 * record holds (positions are eleven bits and an offset of eleven), so that nothing is inside. */
static inline void cut_span(int lo, int hi, int* base, uint32_t* span) {
    if(hi >= lo) { *base = lo; *span = (uint32_t)(hi - lo); }
    else { *base = 32767; *span = 0; }
}

static inline int tri_inside(const gcmd_t* c, const gscene_t* g) {
    if(g->cut_y) {
        const int lo = g->ylo;
        const uint32_t sp = g->yspan;
        if(((uint32_t)(c->y[0] - lo) > sp) | ((uint32_t)(c->y[1] - lo) > sp) | ((uint32_t)(c->y[2] - lo) > sp))
            return 0;
        else {}
    } else {}
    if(g->cut_x) {
        const int lo = g->xlo;
        const uint32_t sp = g->xspan;
        if(((uint32_t)(c->x[0] - lo) > sp) | ((uint32_t)(c->x[1] - lo) > sp) | ((uint32_t)(c->x[2] - lo) > sp))
            return 0;
        else {}
    } else {}
    return 1;
}

/* The passes of a semi-transparent primitive (semi_prim), and their parts. Opaque primitives —
 * nearly all of them — keep build_scene's own loop, which is where this machinery first lived:
 * spread over calls, it cost Crash Bash a second of its 32 s window and Crash 3 a fifth of its
 * scene build. */

/* The bindings a run of semi-transparent primitives goes back and forth between — a subtraction's
 * inverting and adding passes, a split CLUT's solid and STP ones — each set up once for the scene:
 * its header compiled, its vertex terms worked out, and from then on pointed at (gscene_t's `e`),
 * the header sent again from the entry. Copying the terms back at every change was most of a
 * change, three to four times for each triangle Crash 3 subtracts (a hundred a frame on its title
 * screen). Keyed by everything a pass compares; the state index is only a state's own for one
 * scene, so build_scene clears them. */
#define SEMI_BINDS 4
struct __attribute__((aligned(32))) gsemibind {
    pvr_poly_hdr_t hdr;
    gvert_t   t;
    int       state, fmt, dim, ou, ov, kind;
    pvr_ptr_t mem;
    float     rdim, rdimv, xo, yo, uo, vo;
    uint32_t  a;              /* the vertex alpha the header's blend wants, in place */
    int       uv256;          /* the common binding: put_tri_uv256_at's coordinates */
};
static gsemibind_t g_semi_binds[SEMI_BINDS];
static int g_semi_next;

static void semi_binds_clear(void) {
    for(int k = 0; k < SEMI_BINDS; k++) g_semi_binds[k].state = -1;
    g_semi_next = 0;
}

/** A pass's binding: its entry of g_semi_binds when this scene has made it, else a new one — the
 *  header compiled or found (emit_header), the offsets put_tri adds under it worked out — and its
 *  header sent. */
static const gsemibind_t* semi_bind(gscene_t* g, int state, const gstate_t* s, const gbind_t* b,
                                    int kind) {
    g->restate = 0;
    g->over_ready = 0;
    for(int k = 0; k < SEMI_BINDS; k++) {
        const gsemibind_t* e = &g_semi_binds[k];
        if(e->state == state && e->mem == b->mem && e->fmt == b->fmt && e->dim == b->dim
           && e->ou == b->ou && e->ov == b->ov && e->kind == kind) {
            put_hdr(&e->hdr);
            g->e = e;
            return e;
        } else {}
    }
    gsemibind_t* e = &g_semi_binds[g_semi_next];
    g_semi_next = (g_semi_next + 1) & (SEMI_BINDS - 1);
    e->state = state; e->mem = b->mem; e->fmt = b->fmt; e->dim = b->dim;
    e->ou = b->ou; e->ov = b->ov; e->kind = kind;
    e->rdim = dim_ru(b->dim);
    e->rdimv = dim_rv(b->dim);
    const float alpha = emit_header(b->mem, b->fmt, b->dim, s, 0, kind, &e->hdr);
    /* What put_tri adds after scaling: the buffer's corner on screen, and in the texture the texel
     * centre less the patch origin. rdim is a power of two, so the texture terms are exact either
     * way round. */
    e->xo = -(float)g->ox * g->scale_x;
    e->yo = -(float)g->oy * g->scale_y;
    e->uo = (0.5f - (float)b->ou) * e->rdim;
    e->vo = (0.5f - (float)b->ov) * e->rdimv;
    vert_set(&e->t, g->scale_x, g->scale_y, g->ox, g->oy, e->rdim, e->rdimv, b->ou, b->ov);
    e->a = (uint32_t)(alpha * 255.0f) << 24;
    e->uv256 = e->t.ou2 == -1 && e->t.ov2 == -1 && e->t.rh == 1.0f / 512.0f && e->t.rv == e->t.rh;
    g->e = e;
    return e;
}

/* What every pass of a semi-transparent primitive shares, worked out once by semi_prim: whether it
 * lies within its drawing area (a rectangle always: the runtime clipped it), its colours — doubled
 * for a textured one, its alpha the pass's own — and whether one of them brightens. */
typedef struct {
    int      inside, bright;
    uint32_t rgb[3];
} gprim_t;

/** A triangle of one pass under binding e: within its drawing area straight to the store queue (the
 *  common binding's coordinates from g_uv256), else through the clipper with e's terms. */
static void semi_tri(gscene_t* g, const gsemibind_t* e, const gcmd_t* c, const uint32_t* col,
                     int inside) {
    if(inside) {
        if(!e->mem) pvr_dr_addr = put_tri_col_at(pvr_dr_addr, c, col, &e->t);   /* untextured */
        else if(e->uv256) pvr_dr_addr = put_tri_uv256_at(pvr_dr_addr, c, col, &e->t);
        else put_tri(c, col, &e->t);
    } else {
        g->rdim = e->rdim; g->rdimv = e->rdimv; g->xo = e->xo; g->yo = e->yo; g->uo = e->uo; g->vo = e->vo;
        put_clipped(c, col, g);
    }
}

/** A rectangle: four vertices, untextured (the runtime clipped it already). */
__attribute__((noinline))
static void scene_rect(const gscene_t* g, const gsemibind_t* e, const gcmd_t* c, int kind) {
    const float x0 = (float)c->x[0] * g->scale_x + e->xo;
    const float y0 = (float)c->y[0] * g->scale_y + e->yo;
    const float x1 = (float)(c->x[0] + c->x[1]) * g->scale_x + e->xo;
    const float y1 = (float)(c->y[0] + c->y[1]) * g->scale_y + e->yo;
    const uint32_t argb = kind == HK_INVERT ? 0xFFFFFFFFu
                        : (bgr_to_rgb(c->argb[0]) | e->a);
    for(int k = 0; k < 4; k++) {
        pvr_vertex_t* v = (pvr_vertex_t*)pvr_dr_target();
        v->flags = (k == 3) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX;
        v->x = (k & 1) ? x1 : x0;
        v->y = (k & 2) ? y1 : y0;
        v->z = 1.0f;
        v->u = 0.0f; v->v = 0.0f;
        v->argb = argb;
        v->oargb = 0;
        TA_HASH(v);
        pvr_dr_commit(v);
    }
}

/** A textured primitive's colour multiplies the texel, 0x80 meaning 1.0, and can go to nearly
 *  2.0 — which the PVR's modulate cannot, so a menu's text drawn in a bright gradient over a grey
 *  font came out at half its brightness, dull and olive. The part above 1.0 is drawn as a
 *  second, additive pass of the same triangle (emit_header's `over`); only primitives that
 *  brighten pay for it. */
__attribute__((noinline))
static void scene_bright(gscene_t* g, const gsemibind_t* e, const gcmd_t* c, const gstate_t* s,
                         const gbind_t* b, int kind, int inside) {
    if(g->over_ready) put_hdr(&g_run_over);
    else {
        emit_header(b->mem, b->fmt, b->dim, s, 1, kind, &g_run_over);
        g->over_ready = 1;
    }
    uint32_t col[3];
    for(int k = 0; k < 3; k++)
        col[k] = bgr_to_rgb_over(c->argb[k]) | e->a;
    semi_tri(g, e, c, col, inside);
    g->restate = 1;      /* the next primitive of the run restates its header */
#if RECOMPSX_DC_PROFILE
    g_bright_prims++;
#endif
}

/** Where primitive c's texels come from, the common cases inline in the scene loop: a page
 *  mirror whose palette already has its bank, and a page slot already bound this run. The
 *  rest — a first ask, a baked patch, a fallback — goes the full way. */
static inline int bind_texture(const gcmd_t* c, const gstate_t* s, int am, grun_t* r, gbind_t* b) {
    if(r->pic) {
        b->mem = r->pic;
        b->fmt = PIC_FMT;
        b->dim = r->pdim; b->ou = r->pou; b->ov = r->pov;
        return 1;
    } else if(r->mir) {
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
 *  a call. What the passes share comes worked out (`p`); a pass adds its binding's alpha. */
static void scene_pass(gscene_t* g, const gcmd_t* c, int state, const gstate_t* s,
                       const gbind_t* b, int kind, const gprim_t* p) {
    const gsemibind_t* e = g->e;
    if(!e || state != e->state || b->mem != e->mem || b->fmt != e->fmt || b->dim != e->dim
       || b->ou != e->ou || b->ov != e->ov || kind != e->kind) {
        e = semi_bind(g, state, s, b, kind);
    } else if(g->restate) {
        put_hdr(&e->hdr);
        g->restate = 0;
    }
    if(c->is_rect) {
        scene_rect(g, e, c, kind);
        return;
    }
    uint32_t col[3];
    if(kind == HK_INVERT) {
        col[0] = col[1] = col[2] = 0xFFFFFFFFu;     /* an inverting pass is white */
    } else {
        const uint32_t a = e->a;
        col[0] = p->rgb[0] | a; col[1] = p->rgb[1] | a; col[2] = p->rgb[2] | a;
    }
    semi_tri(g, e, c, col, p->inside);
    if(p->bright && b->mem && kind != HK_INVERT && kind != HK_ADD && !(s->flags & BP_GPU_RAW))
        scene_bright(g, e, c, s, b, kind, p->inside);
    else {}
}

/** B - F, which the PVR's blender cannot subtract, as 1 - ((1 - B) + F) in three passes of the
 *  same primitive: invert what is under it, add F — clamping at white is the PlayStation's
 *  clamp at zero, seen inverted — and invert back. The tile buffer blends at eight bits a
 *  channel, so each pass is exact. Where F is a texture the STP variant is black wherever a
 *  texel must not subtract, so the whole primitive can be inverted twice. Crash Bandicoot:
 *  Warped fades every transition with a full-screen quad in this mode, its colour stepping from
 *  FFFFFF (black) to 121212; drawn half-and-half, the screen went a flat grey instead. */
static void subtract_passes(gscene_t* g, const gcmd_t* c, int state, const gstate_t* s,
                            const gbind_t* b, const gprim_t* p) {
    const gbind_t none = { NULL, 0, TEX_DIM, 0, 0 };
    scene_pass(g, c, state, s, &none, HK_INVERT, p);
    scene_pass(g, c, state, s, b, HK_ADD, p);
    scene_pass(g, c, state, s, &none, HK_INVERT, p);
}

/** A semi-transparent primitive, as the PlayStation draws it: per texel for a textured one —
 *  where the CLUT holds both kinds, the solid texels first as an opaque primitive draws them, then
 *  the STP ones in the state's blend — and B - F in three passes.
 *
 *  At 4bpp the two variants come from baked patches rather than palette banks: as banks they
 *  would be two more per CLUT, and Crash Bandicoot: Warped already binds sixty-odd CLUTs a frame
 *  against the hardware's sixty-four (split that way, the banks ran out and the frame went 10 %
 *  slower). A primitive sampling more than one patch, or one on a windowed page, is still drawn
 *  whole, every visible texel blended. Uka Uka's jaw in Crash 3's intro is such a CLUT — black
 *  opaque texels and two STP ones in a 50 % blend — and drawn whole it was see-through red.
 *
 *  What its passes share — the inside test, the colours, whether one brightens — is worked out
 *  here, once (`gprim_t`), where each pass did all of it again. */
__attribute__((noinline))
static void semi_prim(gscene_t* g, grun_t* r, const gcmd_t* c, int state, const gstate_t* s) {
    static const gbind_t none = { NULL, 0, TEX_DIM, 0, 0 };
    const int sub = s->semi_mode == 2;
    gprim_t p;
    p.bright = 0;
    if(c->is_rect) p.inside = 1;
    else {
        p.inside = tri_inside(c, g);
        if(s->flags & BP_GPU_TEXTURED) {
            for(int k = 0; k < 3; k++) {
                p.rgb[k] = bgr_to_rgb_mod(c->argb[k]);
                p.bright |= bgr_brightens(c->argb[k]);
            }
        } else {
            for(int k = 0; k < 3; k++) p.rgb[k] = bgr_to_rgb(c->argb[k]);
        }
    }
    if(!(s->flags & BP_GPU_TEXTURED) || c->is_rect) {
        if(sub) subtract_passes(g, c, state, s, &none, &p);
        else scene_pass(g, c, state, s, &none, HK_NORMAL, &p);
        return;
    }
    if(state != r->state) run_begin(r, s, state);
    if(r->cls == CLS_NONE) return;                /* holes only */
    gbind_t b;
    if(r->cls == CLS_SOLID) {
        /* No texel blends: drawn as the opaque primitive it is. */
        if(bind_texture(c, s, AM_VIS, r, &b)) scene_pass(g, c, state, s, &b, HK_OPAQUE, &p);
        return;
    }
    if(r->cls == CLS_MIXED && s->depth == 0 && r->mir) {
        gbind_t solid;
        if(bind_baked(c, s, AM_SOLID, &solid) && bind_baked(c, s, AM_STP, &b)) {
            scene_pass(g, c, state, s, &solid, HK_OPAQUE, &p);
            if(sub) subtract_passes(g, c, state, s, &b, &p);
            else scene_pass(g, c, state, s, &b, HK_NORMAL, &p);
            return;
        }
    }
    const int split = r->cls == CLS_MIXED && (s->depth != 0 || RECOMPSX_VQ >= 2);
    if(split && bind_texture(c, s, AM_SOLID, r, &b)) scene_pass(g, c, state, s, &b, HK_OPAQUE, &p);
    if(!bind_texture(c, s, split ? AM_STP : AM_VIS, r, &b)) return;
    if(sub) subtract_passes(g, c, state, s, &b, &p);
    else scene_pass(g, c, state, s, &b, HK_NORMAL, &p);
}

/* What a run's triangles need of build_scene's header bookkeeping: whether the run's header must be
 * said again before the next triangle (`restate`: a brightening pass or a VRAM mark went out after
 * it), whether g_run_over holds the binding's brightening header, and what that header is made
 * from when it does not — the binding's texture, format, size and state, as the run's header was. */
typedef struct {
    int restate, over_ready;
    pvr_ptr_t mem;
    int fmt, dim;
    const gstate_t* s;
    /* For run_switch: whether the run's binding is its state's (a run of a baked patch is one record),
     * the drawing area placed and the alpha the run's vertices were made for; and the last state the
     * run went on into, for build_scene to take as its own (-1 none). */
    int may_switch, area;
    float alpha;
    int switched;
} gpass_t;

/** The brightening header (emit_header's `over`), the first time a run asks for it: compiled or
 *  found, kept in g_run_over and sent. Out of line: once per binding at most. */
__attribute__((noinline))
static void over_header(gpass_t* h) {
    emit_header(h->mem, h->fmt, h->dim, h->s, 1, HK_NORMAL, &g_run_over);
    h->over_ready = 1;
}

static inline uint32_t sres_key(int state);
static inline int slot_holds(int i, const gstate_t* s);

/** Whether the run may go on into record c's state as build_scene's fast path would take it, and if
 *  so its bookkeeping done: a triangle under a state whose binding and header g_sres holds (`fast`),
 *  of the run's kind (textured or not), on the same drawing area, with the same alpha and the same
 *  RAW flag — so the vertex terms and alpha the run's vertices are made with stay what they are, and
 *  only the header changes. The header itself the caller sends (g_run_hdr_p). What build_scene's
 *  fast path does besides — its own variables — it does from `switched` when the run returns. */
static inline int run_switch(const gcmd_t* c, int textured, int raw, gpass_t* h) {
    if(c->is_rect != GCMD_TRI || !h->may_switch) return 0;
    const gsres_t* fr = &g_sres[c->state & ((1 << SRES_BITS) - 1)];
    if(fr->key != sres_key(c->state)
       || (textured ? fr->fast != SRES_MIR && fr->fast != SRES_SLOT : fr->fast != SRES_FLAT))
        return 0;
    const gstate_t* s = &g_states[c->state];
    if((int)s->area != h->area || fr->alpha != h->alpha || ((s->flags & BP_GPU_RAW) != 0) != raw
       || (fr->fast == SRES_SLOT && !slot_holds(fr->slot, s)))
        return 0;
    if(fr->fast == SRES_SLOT) g_tex[fr->slot].bound_frame = g_tex_frame;
    else {}
    h->restate = 0; h->over_ready = 0;
    h->mem = fr->mem; h->fmt = fr->fmt; h->dim = TEX_DIM; h->s = s;
    g_run_hdr_p = &fr->hdr;
    h->switched = (int)c->state;
    return 1;
}

/** An opaque run: `c` and the triangles after it recorded under the same state (one compare of
 *  the record's tag), drawn with the binding `c` was, up to `end` — and on into the next state when
 *  run_switch says it may, its header sent between (ledger E-117). Everything else build_scene's
 *  loop asks of a record — its state's area and blending, its texture, the header — is the same for
 *  all of them, and each was ~40 instructions of that loop a triangle. A brightened triangle's second
 *  pass goes out here too, under the brightening header, and the run's header after it (`restate`):
 *  in Crash Bash two of every three textured triangles brighten, and each went back through
 *  build_scene's loop, whose frame is too large for the SH-4's registers. Stops at the first triangle
 *  reaching past the drawing area (the clipper), which build_scene then takes as before; returns
 *  it. Its own function, so that the binding's terms and the queue address stay in registers. */
__attribute__((noinline))
static const gcmd_t* run_tris(const gcmd_t* c, const gcmd_t* end, uint32_t a, int textured, int raw,
                              const gscene_t* g, const gvert_t* bt, gpass_t* h) {
    uint16_t tag = c->tag;
    const gvert_t t = *bt;
    uint32_t q = pvr_dr_addr;
    uint32_t col[3];
    /* The common binding's coordinates from g_uv256 (see there): ou2 and ov2 are 2 * 0 - 1, rh 1/512. */
    const int uv256 = t.ou2 == -1 && t.ov2 == -1 && t.rh == 1.0f / 512.0f && t.rv == t.rh;
    if(textured) {
        for(; c < end; c++) {
            if(c->tag != tag) {
                if(!run_switch(c, 1, raw, h)) break;
                else {}
                tag = c->tag;
                q ^= 32;
                sq_header(q + 32, g_run_hdr_p);
            } else {}
            SHZ_PREFETCH(c + 4);
            if(!tri_inside(c, g)) break;
            else {}
            /* Each colour doubled and clamped and whether any brightens (bgr_parts). A flat
             * triangle's three are the command word's, converted three times: a test for it cost
             * every triangle what the two conversions save the few flat ones (E-159). */
            uint32_t bright = 0;
            for(int k = 0; k < 3; k++) {
                const gbgr_t p = bgr_parts(c->argb[k]);
                col[k] = bgr_parts_mod(p) | a;
                bright |= bgr_parts_bright(p);
            }
            if(h->restate) {
                q ^= 32;
                sq_header(q + 32, g_run_hdr_p);
                h->restate = 0;
            } else {}
            q = uv256 ? put_tri_uv256_at(q, c, col, &t) : put_tri_at(q, c, col, &t);
            if(bright && !raw) {
                /* The part above 1.0, added (see build_scene): its header, the triangle again in
                 * what the clamp lost, and the run's header before the next one. */
                if(h->over_ready) {
                    q ^= 32;
                    sq_header(q + 32, &g_run_over);
                } else {
                    pvr_dr_addr = q;
                    over_header(h);
                    q = pvr_dr_addr;
                }
                for(int k = 0; k < 3; k++) col[k] = bgr_parts_over(bgr_parts(c->argb[k])) | a;
                q = uv256 ? put_tri_uv256_at(q, c, col, &t) : put_tri_at(q, c, col, &t);
                h->restate = 1;
#if RECOMPSX_DC_PROFILE
                g_bright_prims++;
#endif
            } else {}
        }
    } else {
        for(; c < end; c++) {
            if(c->tag != tag) {
                if(!run_switch(c, 0, raw, h)) break;
                else {}
                tag = c->tag;
                q ^= 32;
                sq_header(q + 32, g_run_hdr_p);
            } else {}
            SHZ_PREFETCH(c + 4);
            if(!tri_inside(c, g)) break;
            else {}
            for(int k = 0; k < 3; k++) col[k] = bgr_to_rgb(c->argb[k]) | a;
            if(h->restate) {
                q ^= 32;
                sq_header(q + 32, g_run_hdr_p);
                h->restate = 0;
            } else {}
            q = put_tri_col_at(q, c, col, &t);
        }
    }
    pvr_dr_addr = q;
    return c;
}

/* The textures a state binds, by what it binds — its page, CLUT, texture window and depth — for
 * the build under way. A frame's state records alternate between a few contents (Crash Bash's
 * Ballistix: 401 records a frame, the page or the CLUT changing at nearly every one), and each
 * change asked page4_mirror, the palette cache and the slot table again, ~150 cycles, for an answer
 * the build had already had (docs/perf/dreamcast-ledger.md, E-044). Nothing a build does changes
 * those answers: VRAM is written between builds, a page's first use in the build decodes it, and a
 * palette's bank is memoised for the build (pal_bank_cached). A slot can be reassigned when the pool
 * is all in flight, so a slot is checked against what it holds before it is trusted. */
#define TBIND_BITS 6
typedef struct {
    uint32_t page, clut, window;    /* tex_x | tex_y << 16, clut_x | clut_y << 16, the window */
    uint16_t depth, gen;
    pvr_ptr_t mir;
    int16_t   bank, slot;
    uint8_t   patch8;
} gtbind_t;
static gtbind_t g_tbind[1 << TBIND_BITS];
static uint16_t g_tbind_gen;

/* A g_sres entry's key for a state of this build: its tag and gen as one word. */
static inline uint32_t sres_key(int state) {
    return (uint32_t)(uint16_t)state | ((uint32_t)g_tbind_gen << 16);
}

static inline gtbind_t* tbind_at(uint32_t page, uint32_t clut, uint32_t window, int depth) {
    uint32_t h = page * 2654435761u + clut;
    h = h * 2654435761u + window + (uint32_t)depth;
    return &g_tbind[(h * 2654435761u) >> (32 - TBIND_BITS)];
}

/** Whether texture slot `i` still holds what `s` binds (tex_slot's own match). */
static inline int slot_holds(int i, const gstate_t* s) {
    const int amode = AM_VIS;
    return g_tex[i].used && g_tex[i].tex_x == s->tex_x && g_tex[i].tex_y == s->tex_y
        && g_tex[i].depth == s->depth && g_tex[i].window == s->window && g_tex[i].amode == amode
        && (s->depth != 1 || (g_tex[i].clut_x == s->clut_x && g_tex[i].clut_y == s->clut_y));
}

/** A state's binding into its g_sres entry, the entry taken for it if another state had it. */
static inline void sres_bind(gsres_t* sr, int state, pvr_ptr_t mir, int bank, int slot, int patch8) {
    const uint32_t key = sres_key(state);
    if(sr->key != key) {
        sr->key = key; sr->hdr_ok = 0;
    } else {}
    sr->mir = mir; sr->bank = (int16_t)bank; sr->slot = (int16_t)slot; sr->patch8 = (uint8_t)patch8;
    sr->bind_ok = 1;
    sr->fast = 0;
}

/* The base of a picture's render (g_base_*, set by present_pictures): a rectangle from (0,0). */
static void base_rect(void) {
    pvr_vertex_t v;
    v.argb = 0xFFFFFFFFu;
    v.oargb = 0;
    v.z = 1.0f;
    v.flags = PVR_CMD_VERTEX;
    v.x = 0.0f;       v.y = 0.0f;       v.u = 0.0f;       v.v = 0.0f;       put_vtx(&v);
    v.x = g_base_x1;  v.y = 0.0f;       v.u = g_base_u1;  v.v = 0.0f;       put_vtx(&v);
    v.x = 0.0f;       v.y = g_base_y1;  v.u = 0.0f;       v.v = g_base_v1;  put_vtx(&v);
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = g_base_x1;  v.y = g_base_y1;  v.u = g_base_u1;  v.v = g_base_v1;  put_vtx(&v);
}

/* build_scene's rare paths, out of line: the record loop runs ~700 times a present and its own
 * lines are what the instruction cache should keep; these run a few times a frame, or for the few
 * records that need them, and as part of its body they spread its hot lines over 20 KB (ledger
 * E-170). Each is the loop's code as it was, moved. */

/** Where state s's buffer is on screen, and which edges of its drawing area to cut at: when the
 *  drawing area changes, a few times a frame. Whether the buffer is placed in this scene. */
__attribute__((noinline))
static int place_area(const gstate_t* s, gscene_t* g, int to_picture, int sx, int sy) {
    int ow = 0, oh = 0;   /* unset when not placed, and then never read */
    const int placed = screen_origin(s, &g->ox, &g->oy, &ow, &oh)
                       && (!to_picture || (g->ox == sx && g->oy == sy));
    /* Only the edges of the drawing area that lie inside the picture are cut here; one at or past
     * the picture's own edge is where the screen ends anyway. Crash 3's area is its buffer's whole
     * width, and cutting every triangle that crossed the side of the screen cost 200 ms of the
     * window for nothing. */
    /* With the area's outside drawn again from the picture after the records (area_uncut), nothing
     * is cut at its edges: what reaches past them is painted over. */
    g->clx0 = s->clip_x0 > g->ox && !g_uncut ? s->clip_x0 : -32768;
    g->clx1 = s->clip_x1 + 1 < g->ox + ow && !g_uncut ? s->clip_x1 : 32766;
    g->cly0 = s->clip_y0 > g->oy && !g_uncut ? s->clip_y0 : -32768;
    g->cly1 = s->clip_y1 + 1 < g->oy + oh && !g_uncut ? s->clip_y1 : 32766;
    g->cut_x = g->clx0 != -32768 || g->clx1 != 32766;
    g->cut_y = g->cly0 != -32768 || g->cly1 != 32766;
    cut_span(g->clx0, g->clx1 + 1, &g->xlo, &g->xspan);
    cut_span(g->cly0, g->cly1 + 1, &g->ylo, &g->yspan);
    return placed;
}

/** A state's texture binding worked out in full, when neither g_sres nor g_tbind holds it: the 4bpp
 *  mirror and its palette bank, an 8bpp page's patches, or a slot; kept in both caches. */
__attribute__((noinline))
static void resolve_binding(const gstate_t* s, int state, gsres_t* sr, gtbind_t* tb, uint32_t pk,
                            uint32_t ck, pvr_ptr_t* mir, int* bank, int* slot, int* patch8) {
    int run_bank = -1, run_slot = -1;
    pvr_ptr_t run_mir = NULL;
    /* The page grid is the mirror's index, so a page origin that is not on the grid would silently
     * read a neighbour. The texpage encoding cannot produce one; the guard costs a compare and
     * removes the assumption. */
    if(RECOMPSX_VQ < 2 && s->depth == 0 && (s->window & 0x3FF) == 0 && (s->tex_x & 63) == 0
       && (s->tex_y & 255) == 0)
        run_mir = page4_mirror(s);
    else {}
    /* An unwindowed 8bpp page is drawn from 64x64 patches through its CLUT (bake_slot); the whole
     * page is decoded only for a primitive sampling across patches. With RECOMPSX_VQ (ADR-0061) an
     * unwindowed 8bpp page is a VQ page, its CLUT a codebook — and at 2 a 4bpp one too, with no
     * mirror and no banks: `run_patch8` says so. */
    const int run_patch8 = (s->depth == 1 || (RECOMPSX_VQ >= 2 && s->depth == 0)) && (s->window & 0x3FF) == 0
                        && (s->tex_x & 63) == 0 && (s->tex_y & 255) == 0;
    if(run_mir) {
        run_bank = pal_bank_cached(s->clut_x, s->clut_y, 0, AM_VIS);
    } else if(!run_patch8) {
        run_slot = tex_slot(s, AM_VIS);
        if(run_slot >= 0 && s->depth == 0)
            run_bank = pal_bank_cached(s->clut_x, s->clut_y, 1, AM_VIS);
        else {}
    } else {}
    tb->page = pk; tb->clut = ck; tb->window = s->window;
    tb->depth = s->depth; tb->gen = g_tbind_gen;
    tb->mir = run_mir; tb->bank = (int16_t)run_bank; tb->slot = (int16_t)run_slot;
    tb->patch8 = (uint8_t)run_patch8;
    sres_bind(sr, state, run_mir, run_bank, run_slot, run_patch8);
    *mir = run_mir; *bank = run_bank; *slot = run_slot; *patch8 = run_patch8;
}

/** A rectangle record: four vertices, untextured (the runtime clipped it already). */
__attribute__((noinline))
static void put_rect_record(const gcmd_t* c, float scale_x, float scale_y, float xo, float yo,
                            uint32_t a) {
    const float x0 = (float)c->x[0] * scale_x + xo;
    const float y0 = (float)c->y[0] * scale_y + yo;
    const float x1 = (float)(c->x[0] + c->x[1]) * scale_x + xo;
    const float y1 = (float)(c->y[0] + c->y[1]) * scale_y + yo;
    const uint32_t argb = bgr_to_rgb(c->argb[0]) | a;
    for(int k = 0; k < 4; k++) {
        pvr_vertex_t* v = (pvr_vertex_t*)pvr_dr_target();
        v->flags = (k == 3) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX;
        v->x = (k & 1) ? x1 : x0;
        v->y = (k & 2) ? y1 : y0;
        v->z = 1.0f;
        v->u = 0.0f; v->v = 0.0f;
        v->argb = argb;
        v->oargb = 0;
        TA_HASH(v);
        pvr_dr_commit(v);
    }
}

/** A primitive reaching past the drawing area, cut to it (g's terms already set): its colours, the
 *  part above 1.0 of a brightening one as a second, additive pass, and the run's header after. */
__attribute__((noinline))
static void put_cut(const gcmd_t* c, pvr_ptr_t mem, const gstate_t* s, uint32_t a, gscene_t* g,
                    gpass_t* h) {
    /* A textured primitive's colour multiplies the texel, 0x80 meaning 1.0, and can go to nearly
     * 2.0 — which the PVR's modulate cannot, so a menu's text drawn in a bright gradient over a grey
     * font came out at half its brightness, dull and olive. The part above 1.0 is drawn as a second,
     * additive pass of the same triangle (emit_header's `over`); only primitives that brighten pay
     * for it. */
    uint32_t col[3];
    int bright = 0;
    for(int k = 0; k < 3; k++) {
        col[k] = (mem ? bgr_to_rgb_mod(c->argb[k]) : bgr_to_rgb(c->argb[k])) | a;
        if(mem && bgr_brightens(c->argb[k])) bright = 1;
    }
    put_clipped(c, col, g);
    if(bright && !(s->flags & BP_GPU_RAW)) {
        if(h->over_ready) put_hdr(&g_run_over);
        else over_header(h);
        for(int k = 0; k < 3; k++)
            col[k] = bgr_to_rgb_over(c->argb[k]) | a;
        put_clipped(c, col, g);
        h->restate = 1;      /* the next primitive of the run restates its header */
#if RECOMPSX_DC_PROFILE
        g_bright_prims++;
#endif
    } else {}
}

PROF_NOINLINE void build_scene(int sx, int sy, int sw, int sh, int with_background, int first,
                               int to_picture) {
    if(sw <= 0 || sh <= 0) return;
    /* The screen is 640 x 480, and so is a picture (ADR-0055) unless it is drawn at a lower
     * resolution (ADR-0056): then its own size. */
    const float scale_x = (to_picture ? (float)g_scene_w : 640.0f) / (float)sw;
    const float scale_y = (to_picture ? (float)g_scene_h : 480.0f) / (float)sh;

    pvr_list_begin(PVR_LIST_TR_POLY);
#if RECOMPSX_TA_HASH
    g_ta_hash = 2166136261u;
    g_ta_hashing = 1;
#endif

    if(with_background && to_picture) {
        put_hdr(g_base_hdr);
        base_rect();
    } else if(with_background) {
        put_hdr(&g_hdr);
        draw_quad(sw, sh);
    } else {}

    if(g_uv256[255] == 0.0f) {
        for(int u = 0; u < 256; u++) g_uv256[u] = (float)(2 * u + 1) * (1.0f / 512.0f);
    } else {}

    g_pal_memo_gen++;         /* VRAM may have changed since the last build */
#if RECOMPSX_VQ < 2
    palette_priority();     /* the banks' frame (at RECOMPSX_VQ 2 only windowed 4bpp pages take banks) */
#endif
    semi_binds_clear();
    if(++g_tbind_gen == 0) {   /* a wrapped generation would find last builds' answers valid */
        for(int k = 0; k < (1 << TBIND_BITS); k++) g_tbind[k].gen = 0;
        for(int k = 0; k < (1 << SRES_BITS); k++) { g_sres[k].gen = 0; g_semi_multi[k] = 0; }
        g_tbind_gen = 1;
    } else {}
    g_run_hdr_p = &g_run_hdr;

    /* The semi-transparent path's own binding and texture answers (semi_prim), and what both
     * paths share: the scale, and the current state's buffer corner and drawing area. */
    gscene_t g;
    g.scale_x = scale_x; g.scale_y = scale_y;
    g.e = NULL;
    g.rdim = 1.0f / (float)TEX_DIM;
    g.rdimv = g.rdim;
    g.xo = 0.0f; g.yo = 0.0f; g.uo = 0.0f; g.vo = 0.0f;
    g.restate = 0; g.over_ready = 0;
    g.ox = 0; g.oy = 0; g.clx0 = 0; g.cly0 = 0; g.clx1 = 1023; g.cly1 = 511;
    g.cut_x = 0; g.cut_y = 0;
    cut_span(g.clx0, g.clx1 + 1, &g.xlo, &g.xspan);
    cut_span(g.cly0, g.cly1 + 1, &g.ylo, &g.yspan);
    grun_t semi_run;
    semi_run.state = -1;
    int placed_state = -1, placed = 0, placed_area = -1;

    int cur_state = -1, cur_fmt = -1, cur_dim = 0, cur_ou = 0, cur_ov = 0;
    /* The reciprocal of the bound texture's size, so the vertex loop multiplies where it used to
     * divide. The divisor is constant for a whole run of primitives and SH-4's FDIV is expensive
     * and poorly pipelined; at three vertices and two coordinates each, a busy scene was asking
     * for nine thousand divisions a frame to compute a number that changes a few dozen times. */
    float cur_rdim = 1.0f / (float)TEX_DIM, cur_rdimv = cur_rdim;
    pvr_ptr_t cur_mem = NULL;
    /* Resolved once per run of primitives sharing a state — which is how they arrive. */
    int run_state = -1, run_bank = -1, run_slot = -1, run_patch8 = 0;
    /* The patch the last record baked through bound to, by its state and corner: the records of a
     * mesh sample a page's patches over and over, and each asked bake_slot again — a hash, a check
     * of nine fields — for the slot the record before it had (243 asks a frame of Crash 3's
     * gameplay). Same key, same answer: nothing between two records evicts or rebinds a patch
     * bound this frame (the in-flight rule), and the slot's frame is already this one. */
    int memo_state = -1, memo_tu = -1, memo_tv = -1, memo_b = -1;
#if RECOMPSX_VQ
    (void)memo_state; (void)memo_tu; (void)memo_tv; (void)memo_b;   /* the bake's (ADR-0061) */
#endif
    pvr_ptr_t run_mir = NULL;
    float alpha = 1.0f;
    /* A brightening pass or a VRAM mark puts another header on the list in the middle of a run,
     * and the run's next primitive must say its own again. That used to be a full lookup — the
     * state compared, the cache hashed and searched — twice per brightened primitive, and a busy
     * arena brightens a quarter of them. Now the run's header is kept when first emitted and
     * copied back (`restate`), and the brightening header is looked up once per run. */
    gpass_t h;
    h.restate = 0; h.over_ready = 0; h.mem = NULL; h.fmt = 0; h.dim = TEX_DIM; h.s = NULL;
    h.may_switch = 0; h.area = -1; h.alpha = 1.0f; h.switched = -1;
    float cur_xo = 0.0f, cur_yo = 0.0f, cur_uo = 0.0f, cur_vo = 0.0f;
    gvert_t cur_t;
    vert_set(&cur_t, scale_x, scale_y, 0, 0, cur_rdim, cur_rdimv, 0, 0);
    uint32_t cur_a = 0xFF000000u;
    /* What the vertex terms and cur_a were last worked out from (cur_dim is the size): none yet. */
    int vs_ou = -1, vs_ov = -1, vs_ox = 0x7FFFFFFF, vs_oy = 0x7FFFFFFF;
    float vs_alpha = -1.0f;
    /* The frame's records (cmd_count): nothing the walk below calls appends one. */
    const int ncmd = cmd_count();
    for(int i = first; i < ncmd; i++) {
        const gcmd_t* c = &g_cmds[i];
        /* Four records — four lines — ahead: the buffer is far larger than the cache and is read
         * once, front to back, so every line is a miss unless it was asked for in time. Past the
         * end it touches the memory after the array, which is harmless. */
        SHZ_PREFETCH(c + 4);
        if(c->is_rect >= GCMD_VRAM) {
            /* A copy out of a buffer (ADR-0054) from that buffer's picture; on the old path,
             * where there are none, emulated VRAM's result, as a mark. */
            const int drew = c->is_rect == GCMD_COPY && to_picture
                           ? draw_copy(c, sx, sy, sw, sh, scale_x, scale_y)
                           : draw_mark(c, sx, sy, sw, sh, scale_x, scale_y);
            if(drew) { h.restate = 1; g.e = NULL; }
            else {}
            continue;
        } else {}
        const gstate_t* s = &g_states[c->state];
        /* States are recorded in the order primitives use them, so the next one is where the
         * walk is going; past the last one this touches the array's own tail, harmlessly. */
        SHZ_PREFETCH(s + 1);
        pvr_ptr_t mem = NULL;
        int fmt = 0, dim = TEX_DIM, ou = 0, ov = 0;
        /* Whether the binding is the state's, not the record's: then the records after this one
         * under the same state bind the same way (run_tris). A baked patch is per record. */
        int per_state = 1;
        int bound_vq = 0;           /* the binding is a VQ page's (ADR-0061): SRES_VQ below */
        /* A return to a state this build has drawn a triangle under, on the drawing area the
         * last one had: its binding and its header as g_sres kept them (`fast`), and the walk
         * below — the area, the blending, the texture answers asked again, six compares for the
         * header — skipped. What it would have done is done here, the same way: the same header
         * sent, the same terms. Two thirds of the records of Crash 3's gameplay change the state,
         * ~200 instructions each on that walk (ledger E-114). */
        if((int)c->state != cur_state) {
            const gsres_t* fr = &g_sres[c->state & ((1 << SRES_BITS) - 1)];
            if(fr->key == sres_key(c->state) && fr->fast && placed && (int)s->area == placed_area
               && !c->is_rect && (fr->fast != SRES_SLOT || slot_holds(fr->slot, s))) {
                placed_state = (int)c->state;
                if(fr->fast != SRES_FLAT) {
                    run_state = (int)c->state;
                    run_mir = fr->mir; run_bank = fr->bank; run_slot = fr->slot;
                    run_patch8 = fr->patch8;
                    if(fr->fast == SRES_SLOT) g_tex[run_slot].bound_frame = g_tex_frame;
                    else {}
                } else {}
                mem = fr->mem; fmt = fr->fmt;
                if(fr->fast == SRES_VQ) {
                    dim = VQ_TEXDIM;
                    ov = -g_sres_rows[c->state & ((1 << SRES_BITS) - 1)];
                } else {}
                cur_state = (int)c->state;
                cur_mem = mem; cur_fmt = fmt; cur_ou = 0; cur_ov = ov;
                put_hdr(&fr->hdr);
                alpha = fr->alpha;
                g_run_hdr_p = &fr->hdr;
                goto header_made;
            } else {}
        } else {}
        /* Where the state's buffer is on screen, and which edges of its drawing area to cut at:
         * a function of the drawing area alone, which changes a few times a frame, where the
         * state changes at nearly every primitive. A new origin reaches the header's offsets
         * because a new state always re-emits the header. */
        if((int)c->state != placed_state) {
            placed_state = (int)c->state;
            if((int)s->area != placed_area) {
                placed_area = (int)s->area;
                placed = place_area(s, &g, to_picture, sx, sy);
            }
        }
        if(!placed) continue;       /* drawn into VRAM off screen: not a picture */
        if((s->flags & BP_GPU_SEMI) && !semi_single(c, s)) {
            semi_prim(&g, &semi_run, c, (int)c->state, s);
            cur_state = -1;         /* its headers went out after this loop's */
            continue;
        }

        const int textured = (s->flags & BP_GPU_TEXTURED) && !c->is_rect;

        if(textured) {
            pvr_ptr_t pmem;
            int pdim, pou, pov;
            if(to_picture && s->depth == 2 && (s->window & 0x3FF) == 0
               && pic_page(s->tex_x, s->tex_y, &pmem, &pdim, &pou, &pov)) {
                /* A page in a buffer this backend draws (ADR-0054): its picture, which holds what
                 * was drawn there and emulated VRAM's copy of the buffer does not. Bound per record,
                 * since the state's own answers (g_sres) are the page's in emulated VRAM. */
                per_state = 0;
                run_state = -1;
                mem = pmem;
                fmt = PIC_FMT;
                dim = pdim; ou = pou; ov = pov;
            } else {
                if((int)c->state != run_state) {
                    run_state = (int)c->state;
                    const uint32_t pk = (uint32_t)s->tex_x | ((uint32_t)s->tex_y << 16);
                    const uint32_t ck = (uint32_t)s->clut_x | ((uint32_t)s->clut_y << 16);
                    gsres_t* sr = &g_sres[c->state & ((1 << SRES_BITS) - 1)];
                    gtbind_t* tb;
                    if(sr->key == sres_key(c->state) && sr->bind_ok
                       && (sr->slot < 0 || slot_holds(sr->slot, s))) {
                        run_mir = sr->mir; run_bank = sr->bank; run_slot = sr->slot;
                        run_patch8 = sr->patch8;
                    } else if(tb = tbind_at(pk, ck, s->window, s->depth),
                       tb->gen == g_tbind_gen && tb->page == pk && tb->clut == ck
                       && tb->window == s->window && tb->depth == s->depth
                       && (tb->slot < 0 || slot_holds(tb->slot, s))) {
                        run_mir = tb->mir; run_bank = tb->bank; run_slot = tb->slot;
                        run_patch8 = tb->patch8;
                        sres_bind(sr, c->state, run_mir, run_bank, run_slot, run_patch8);
                    } else {
                        resolve_binding(s, (int)c->state, sr, tb, pk, ck,
                                        &run_mir, &run_bank, &run_slot, &run_patch8);
                    }
                }
                if(run_mir && run_bank >= 0) {
                    mem = run_mir;
                    fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(run_bank) | PVR_TXRFMT_TWIDDLED;
                } else if(run_mir || run_patch8) {
                    /* No bank was left for this palette, or an 8bpp page: the page's indices through
                     * the CLUT as a VQ codebook (ADR-0061) — the state's binding, so the records
                     * after it run on — or texels with the CLUT already in them, as large as this
                     * primitive samples. Exact either way. */
                    int tu = 0, tv = 0;
                    int b = -1;
#if RECOMPSX_VQ
                    pvr_ptr_t vm = NULL;
                    int rows = 0;
                    const int vq = vq_bind(s, AM_VIS, &vm, &rows);
#else
                    pvr_ptr_t vm = NULL;
                    int rows = 0;
                    /* An 8bpp page as a VQ page (RECOMPSX_VQ8): the state's binding, its run goes on. */
                    const int vq = RECOMPSX_VQ8 && s->depth == 1 && vq_bind(s, AM_VIS, &vm, &rows);
                    if(!vq) {
                        per_state = 0;
                        if(one_patch(c, &tu, &tv)) {
                            if((int)c->state == memo_state && tu == memo_tu && tv == memo_tv) b = memo_b;
                            else {
                                b = bake_slot(s, tu, tv, AM_VIS);
                                if(b >= 0) { memo_state = (int)c->state; memo_tu = tu; memo_tv = tv; memo_b = b; }
                                else {}
                            }
                        } else {}
                    } else {}
#endif
                    if(vq) {
                        mem = vm;
                        fmt = VQ_FMT;
                        dim = VQ_TEXDIM; ou = 0; ov = -rows;
                        bound_vq = 1;
                    } else if(b >= 0) {
                        mem = g_bake[b].mem;
                        fmt = PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_TWIDDLED;
                        dim = BAKE_DIM; ou = tu * BAKE_STEP; ov = tv * BAKE_STEP;
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
        }

        if((int)c->state != cur_state || mem != cur_mem || fmt != cur_fmt
           || dim != cur_dim || ou != cur_ou || ov != cur_ov) {
            cur_state = (int)c->state;
            cur_mem = mem; cur_fmt = fmt; cur_ou = ou; cur_ov = ov;
            /* A state's own binding (not a baked patch's): its header from g_sres when this build
             * made it for this binding, else made, sent and kept there. */
            gsres_t* sr = &g_sres[c->state & ((1 << SRES_BITS) - 1)];
            if(!per_state) {
                alpha = emit_header(mem, fmt, dim, s, 0, HK_NORMAL, &g_run_hdr);
                g_run_hdr_p = &g_run_hdr;
            } else {
                if(sr->key == sres_key(c->state) && sr->hdr_ok && sr->mem == mem
                   && sr->fmt == fmt && sr->dim == dim) {
                    put_hdr(&sr->hdr);
                    alpha = sr->alpha;
                } else {
                    if(sr->key != sres_key(c->state)) {
                        sr->key = sres_key(c->state); sr->bind_ok = 0;
                    } else {}
                    alpha = emit_header(mem, fmt, dim, s, 0, HK_NORMAL, &sr->hdr);
                    sr->mem = mem; sr->fmt = fmt; sr->dim = dim; sr->alpha = alpha; sr->hdr_ok = 1;
                }
                g_run_hdr_p = &sr->hdr;
                /* The fast path's leave to come back here: a triangle's header for the binding the
                 * state's own answers give (bind_ok: they are this state's), or an untextured one. */
                sr->fast = c->is_rect ? 0
                         : !mem ? SRES_FLAT
                         : !sr->bind_ok ? 0
                         : bound_vq ? SRES_VQ
                         : (run_mir && run_bank >= 0) ? SRES_MIR
                         : (!run_mir && !run_patch8 && run_slot >= 0) ? SRES_SLOT : 0;
                if(bound_vq) g_sres_rows[c->state & ((1 << SRES_BITS) - 1)] = (int8_t)(-ov);
                else {}
            }
        header_made:
            h.restate = 0;
            h.over_ready = 0;
            h.mem = mem; h.fmt = fmt; h.dim = dim; h.s = s;
            /* What put_tri adds after scaling: the buffer's corner on screen, and in the texture
             * the texel centre less the patch origin. rdim is a power of two, so the texture
             * terms are exact either way round. They depend on the size, the patch and the
             * corner, which nearly every state shares with the one before it: worked out again
             * only when one of those changed (a divide and a dozen conversions, E-044). */
            if(dim != cur_dim || ou != vs_ou || ov != vs_ov || g.ox != vs_ox || g.oy != vs_oy) {
                cur_dim = dim; vs_ou = ou; vs_ov = ov; vs_ox = g.ox; vs_oy = g.oy;
                cur_rdim = dim_ru(dim);
                cur_rdimv = dim_rv(dim);
                cur_xo = -(float)g.ox * scale_x;
                cur_yo = -(float)g.oy * scale_y;
                cur_uo = (0.5f - (float)ou) * cur_rdim;
                cur_vo = (0.5f - (float)ov) * cur_rdimv;
                vert_set(&cur_t, scale_x, scale_y, g.ox, g.oy, cur_rdim, cur_rdimv, ou, ov);
            } else {}
            if(alpha != vs_alpha) {
                vs_alpha = alpha;
                cur_a = (uint32_t)(alpha * 255.0f) << 24;
            } else {}
            g.e = NULL;             /* the semi-transparent path's header is not the last one now */
        } else if(h.restate) {
            put_hdr(g_run_hdr_p);
            h.restate = 0;
        } else {}

        /* Vertices go by KOS direct rendering (put_tri), where pvr_prim built each one on the
         * stack and copied it through a call. */
        const uint32_t a = cur_a;
        if(c->is_rect) {
            put_rect_record(c, scale_x, scale_y, cur_xo, cur_yo, a);
        } else {
            /* This triangle and the records after it under the same binding: run_tris, unless this
             * one reaches past the drawing area. A baked patch binds one record (per_state 0). */
            h.may_switch = per_state; h.area = placed_area; h.alpha = alpha;
            const gcmd_t* next = run_tris(c, per_state ? &g_cmds[ncmd] : c + 1, a, mem != NULL,
                                          (s->flags & BP_GPU_RAW) != 0, &g, &cur_t, &h);
            if(h.switched >= 0) {
                /* The run went on into other states (run_switch): what the fast path above would
                 * have left in this loop's variables for the last of them. */
                const int sw = h.switched;
                const gsres_t* fr = &g_sres[sw & ((1 << SRES_BITS) - 1)];
                h.switched = -1;
                placed_state = sw;
                if(fr->fast != SRES_FLAT) {
                    run_state = sw;
                    run_mir = fr->mir; run_bank = fr->bank; run_slot = fr->slot; run_patch8 = fr->patch8;
                } else {}
                cur_state = sw;
                cur_mem = fr->mem; cur_fmt = fr->fmt; cur_ou = 0; cur_ov = 0;
                g.e = NULL;
            } else {}
            if(next != c) {
                i = (int)(next - g_cmds) - 1;
                continue;
            } else {}
            /* Cut to the drawing area where it reaches past an edge inside the picture (put_cut). */
            g.xo = cur_xo; g.yo = cur_yo; g.rdim = cur_rdim; g.rdimv = cur_rdimv; g.uo = cur_uo; g.vo = cur_vo;
            put_cut(c, mem, s, a, &g, &h);
        }
    }
    /* Drawn uncut (area_uncut): the picture outside the drawing area as it was, over what reached
     * past it. */
    if(g_uncut && to_picture) area_restore(scale_x, scale_y);
    else {}
#if RECOMPSX_TA_HASH
    g_ta_hashing = 0;
    {
        static unsigned scenes;
        char m[48];
        snprintf(m, sizeof m, "ta hash %u %08x", ++scenes, (unsigned)g_ta_hash);
        bp_log(BP_LOG_WARN, m);
    }
#endif
    /* Last, and on the screen only — never into a picture, which keeps what the game drew: the list
     * is drawn in submission order, so anything submitted before the game's primitives is painted
     * over by them — as the overlay was, when it followed the background. */
    if(!to_picture) {
#if RECOMPSX_DC_PROFILE_OVERLAY
        draw_profile_overlay();
#endif
        draw_mouse_pointer();
    } else {}
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
        if(cmd_count() > 0 && (every++ % 1000) == 0) {
            const gcmd_t* c = &g_cmds[0];
            const gstate_t* s0 = &g_states[c->state];
            g_diag.prim = cmd_count();      g_diag.state = g_state_count;
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
