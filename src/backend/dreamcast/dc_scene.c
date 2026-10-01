/* dc_scene.c — the GPU's primitives in hardware mode: recorded as the runtime draws them
 * (bp_gpu_*), and built into one PVR scene when the frame is presented (build_scene). */

#include "dc_internal.h"

/* ---- the command buffer: what the frame drew, in order (types in dc_internal.h) ---------------- */

const uint16_t* g_vram;          /* emulated VRAM, borrowed; NULL until armed */
gcmd_t   g_cmds[GPU_MAX_CMDS];
int      g_cmd_count;
gstate_t g_states[GPU_MAX_STATES];
int      g_state_count;
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

/** Drops the presented frame's geometry, the moment anything belonging to the next one arrives.
 *  Both entry points call it, and both must: state is latched before the primitive that uses it,
 *  so resetting in one place only would dedup a new frame's state against a dead table and then
 *  index into the emptied one. */
static int g_clip_x0, g_clip_y0, g_clip_x1 = 1023, g_clip_y1 = 511;

/* The new frame's first primitive, out of line and cold: inlined into the triangle path it was a
 * call site every primitive's values had to survive, and they went to the stack for it. */
__attribute__((noinline, cold)) static void begin_frame(void);
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

static void begin_frame(void) {
    g_frame_shown = 0;
    g_cmd_count = 0;
    g_rect_n = 0; g_rect_over = 0; g_marks = 0;
    /* The latched state carries over as the new frame's first entry: the ABI latches it until
     * the next bp_gpu_state, and the runtime now sends one only when it changes, so the first
     * primitive of a frame may well arrive under the last frame's state. */
    if(g_state_count > 0) {
        if(g_state_count > 1) shz_memcpy32_1(&g_states[0], &g_states[g_state_count - 1]);
        else {}
        g_state_count = 1;
        g_states[0].tris = 0;       /* the new frame's count starts here */
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
    shz_dcache_alloc_line(s);       /* every field is written below */
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
    s->pad = 0;
    s->tris = 0;
}

/* A new record's line, allocated in the cache without a read (see gcmd_t). The caller writes
 * every field a reader of its kind looks at; the rest of the line is undefined, as it was stale. */
static inline gcmd_t* cmd_alloc(void) {
    gcmd_t* c = &g_cmds[g_cmd_count++];
    shz_dcache_alloc_line(c);
    return c;
}

static inline gcmd_t* cmd_new(void) {
    begin_frame_if_needed();
    g_scene_dirty = 1;
    if(g_cmd_count >= GPU_MAX_CMDS) { g_cmd_overflowed = 1; return NULL; }
    gcmd_t* c = cmd_alloc();
    c->state = (uint16_t)(g_state_count > 0 ? g_state_count - 1 : 0);
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
    if(g_state_count > 0) g_states[g_state_count - 1].tris++;
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
    int i = g_cmd_count;
    while(i > 0 && g_cmds[i - 1].is_rect == GCMD_VRAM) i--;
    for(int k = i; k < g_cmd_count; k++) {
        const gcmd_t* m = &g_cmds[k];
        if(inside(x, y, w, h, m->x[0], m->y[0], m->x[1], m->y[1])) return;
    }
    int out = i;
    for(int k = i; k < g_cmd_count; k++) {
        const gcmd_t* m = &g_cmds[k];
        if(!inside(m->x[0], m->y[0], m->x[1], m->y[1], x, y, w, h)) {
            if(out != k) shz_memcpy32_1(&g_cmds[out], m);
            else {}
            out++;
        } else {}
    }
    g_cmd_count = out;
    if(g_cmd_count >= GPU_MAX_CMDS) { g_cmd_overflowed = 1; return; }
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
    if(g_state_count <= 0 || g_state_count >= GPU_MAX_STATES) return;
    const gstate_t* p = &g_states[g_state_count - 1];
    if(p->clip_x0 == x0 && p->clip_y0 == y0 && p->clip_x1 == x1 && p->clip_y1 == y1) return;
    gstate_t* n = &g_states[g_state_count++];
    *n = *p;
    n->clip_x0 = (int16_t)x0; n->clip_y0 = (int16_t)y0;
    n->clip_x1 = (int16_t)x1; n->clip_y1 = (int16_t)y1;
    n->tris = 0;
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
        for(int i = g_cmd_count - 1; i >= 0; i--) {
            const gcmd_t* c = &g_cmds[i];
            if(c->is_rect == GCMD_RECT && covers(c, sw, sh)) return i;
            else {}
        }
        return -1;
    } else {}
    for(int k = g_rect_n - 1; k >= 0; k--) {
        const int i = g_rect_at[k];
        if(i < g_cmd_count && g_cmds[i].is_rect == GCMD_RECT && covers(&g_cmds[i], sw, sh)) return i;
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
typedef struct { float sx, sy, rh; int ox, oy, ou2, ov2; } gvert_t;

static inline void vert_set(gvert_t* t, float sx, float sy, int ox, int oy, float rdim, int ou, int ov) {
    t->sx = sx; t->sy = sy; t->rh = 0.5f * rdim;
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
        const float v = (float)(2 * c->v[k] - t->ov2) * t->rh;
        a ^= 32;
        sq_vertex(a + 32, (k == 2) ? PVR_CMD_VERTEX_EOL : PVR_CMD_VERTEX, x, y, u, v, col[k]);
    }
    return a;
}

/** An untextured triangle: the same, with no texture coordinates to compute. An untextured
 *  header's vertex (the TA's packed-colour type 0) ignores the two words where U and V go. */
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
    gvert_t   t;              /* put_tri's form of the same binding (vert_set) */
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
            b->dim = BAKE_DIM; b->ou = tu * BAKE_STEP; b->ov = tv * BAKE_STEP;
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
            b->dim = BAKE_DIM; b->ou = tu * BAKE_STEP; b->ov = tv * BAKE_STEP;
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

/** Variant `am` of the one 64x64 patch primitive c samples, baked with its CLUT applied: exact,
 *  and no palette bank spent. 0 when c samples more than one patch or the pool is all in flight. */
static int bind_baked(const gcmd_t* c, const gstate_t* s, int am, gbind_t* b) {
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
    if(tri_inside(c, g)) {
        if(g->mem) put_tri(c, col, &g->t);
        else pvr_dr_addr = put_tri_col_at(pvr_dr_addr, c, col, &g->t);   /* an untextured pass */
    } else
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
    vert_set(&g->t, g->scale_x, g->scale_y, g->ox, g->oy, g->rdim, b->ou, b->ov);
    g->a = (uint32_t)(alpha * 255.0f) << 24;
}

/* The bindings a run of semi-transparent primitives goes back and forth between — a subtraction's
 * inverting and adding passes, a split CLUT's solid and STP ones — each set up once for the scene
 * and then restated from here. scene_header hashed and searched the header cache, divided for
 * rdim and set the vertex terms up again at every change, three to four times for each triangle
 * Crash 3 subtracts (a hundred a frame on its title screen). Keyed by everything scene_pass
 * compares; the state index is only a state's own for one scene, so build_scene clears them. */
#define SEMI_BINDS 4
typedef struct __attribute__((aligned(32))) {
    pvr_poly_hdr_t hdr;
    gvert_t   t;
    int       state, fmt, dim, ou, ov, kind;
    pvr_ptr_t mem;
    float     rdim, xo, yo, uo, vo;
    uint32_t  a;
} gsemibind_t;
static gsemibind_t g_semi_binds[SEMI_BINDS];
static int g_semi_next;

static void semi_binds_clear(void) {
    for(int k = 0; k < SEMI_BINDS; k++) g_semi_binds[k].state = -1;
    g_semi_next = 0;
}

/** scene_header, answered from g_semi_binds when this scene has seen the binding: the header sent
 *  again as it was compiled, and the terms put back. */
static void scene_bind(gscene_t* g, int state, const gstate_t* s, const gbind_t* b, int kind) {
    for(int k = 0; k < SEMI_BINDS; k++) {
        const gsemibind_t* e = &g_semi_binds[k];
        if(e->state == state && e->mem == b->mem && e->fmt == b->fmt && e->dim == b->dim
           && e->ou == b->ou && e->ov == b->ov && e->kind == kind) {
            shz_memcpy32_1(&g_run_hdr, &e->hdr);
            put_hdr(&g_run_hdr);
            g->state = state; g->mem = b->mem; g->fmt = b->fmt; g->dim = b->dim;
            g->ou = b->ou; g->ov = b->ov; g->kind = kind;
            g->rdim = e->rdim; g->xo = e->xo; g->yo = e->yo; g->uo = e->uo; g->vo = e->vo;
            g->t = e->t; g->a = e->a;
            g->restate = 0;
            g->over_ready = 0;
            return;
        } else {}
    }
    scene_header(g, state, s, b, kind);
    gsemibind_t* e = &g_semi_binds[g_semi_next];
    g_semi_next = (g_semi_next + 1) & (SEMI_BINDS - 1);
    shz_memcpy32_1(&e->hdr, &g_run_hdr);
    e->state = state; e->mem = b->mem; e->fmt = b->fmt; e->dim = b->dim;
    e->ou = b->ou; e->ov = b->ov; e->kind = kind;
    e->rdim = g->rdim; e->xo = g->xo; e->yo = g->yo; e->uo = g->uo; e->vo = g->vo;
    e->t = g->t; e->a = g->a;
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
    if(g->over_ready) put_hdr(&g_run_over);
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
        scene_bind(g, state, s, b, kind);
    } else if(g->restate) {
        put_hdr(&g_run_hdr);
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
 *  the STP ones in the state's blend — and B - F in three passes.
 *
 *  At 4bpp the two variants come from baked patches rather than palette banks: as banks they
 *  would be two more per CLUT, and Crash Bandicoot: Warped already binds sixty-odd CLUTs a frame
 *  against the hardware's sixty-four (split that way, the banks ran out and the frame went 10 %
 *  slower). A primitive sampling more than one patch, or one on a windowed page, is still drawn
 *  whole, every visible texel blended. Uka Uka's jaw in Crash 3's intro is such a CLUT — black
 *  opaque texels and two STP ones in a 50 % blend — and drawn whole it was see-through red. */
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
    if(r->cls == CLS_MIXED && s->depth == 0 && r->mir) {
        gbind_t solid;
        if(bind_baked(c, s, AM_SOLID, &solid) && bind_baked(c, s, AM_STP, &b)) {
            scene_pass(g, c, state, s, &solid, HK_OPAQUE);
            if(sub) subtract_passes(g, c, state, s, &b);
            else scene_pass(g, c, state, s, &b, HK_NORMAL);
            return;
        }
    }
    const int split = r->cls == CLS_MIXED && s->depth != 0;
    if(split && bind_texture(c, s, AM_SOLID, r, &b)) scene_pass(g, c, state, s, &b, HK_OPAQUE);
    if(!bind_texture(c, s, split ? AM_STP : AM_VIS, r, &b)) return;
    if(sub) subtract_passes(g, c, state, s, &b);
    else scene_pass(g, c, state, s, &b, HK_NORMAL);
}

/** The rest of an opaque run: the triangles after `c` recorded under the same state (one compare
 *  of the record's tag), drawn with the binding `c` was. Everything else build_scene's loop asks of
 *  a record — its state's area and blending, its texture, the header — is the same for all of them,
 *  and each was ~40 instructions of that loop a triangle. Stops at the first record that needs more
 *  than its colours and three vertices, a brightened one (a second pass) or one reaching past the
 *  drawing area (the clipper), which build_scene then takes as before; returns it. Its own function,
 *  so that the binding's terms and the queue address stay in registers for the run. */
__attribute__((noinline))
static const gcmd_t* run_tris(const gcmd_t* c, const gcmd_t* end, uint32_t a, int textured, int raw,
                              const gscene_t* g, const gvert_t* bt) {
    const uint16_t tag = c->tag;
    const gvert_t t = *bt;
    uint32_t q = pvr_dr_addr;
    uint32_t col[3];
    c++;
    if(textured) {
        for(; c < end && c->tag == tag; c++) {
            SHZ_PREFETCH(c + 4);
            int bright = 0;
            for(int k = 0; k < 3; k++) {
                col[k] = (bgr_to_argb_mod(c->argb[k]) & 0x00FFFFFFu) | a;
                bright |= bgr_brightens(c->argb[k]);
            }
            if((bright && !raw) || !tri_inside(c, g)) break;
            else {}
            q = put_tri_at(q, c, col, &t);
        }
    } else {
        for(; c < end && c->tag == tag; c++) {
            SHZ_PREFETCH(c + 4);
            for(int k = 0; k < 3; k++) col[k] = (bgr_to_argb(c->argb[k]) & 0x00FFFFFFu) | a;
            if(!tri_inside(c, g)) break;
            else {}
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

PROF_NOINLINE void build_scene(int sx, int sy, int sw, int sh, int with_background, int first) {
    if(sw <= 0 || sh <= 0) return;
    const float scale_x = 640.0f / (float)sw;
    const float scale_y = 480.0f / (float)sh;

    pvr_list_begin(PVR_LIST_TR_POLY);

    if(with_background) {
        put_hdr(&g_hdr);
        draw_quad(sw, sh);
    }

    g_pal_memo_gen++;         /* VRAM may have changed since the last build */
    palette_priority();
    semi_binds_clear();
    if(++g_tbind_gen == 0) {   /* a wrapped generation would find last builds' answers valid */
        for(int k = 0; k < (1 << TBIND_BITS); k++) g_tbind[k].gen = 0;
        g_tbind_gen = 1;
    } else {}

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
    gvert_t cur_t;
    vert_set(&cur_t, scale_x, scale_y, 0, 0, cur_rdim, 0, 0);
    uint32_t cur_a = 0xFF000000u;
    /* What the vertex terms and cur_a were last worked out from (cur_dim is the size): none yet. */
    int vs_ou = -1, vs_ov = -1, vs_ox = 0x7FFFFFFF, vs_oy = 0x7FFFFFFF;
    float vs_alpha = -1.0f;
    for(int i = first; i < g_cmd_count; i++) {
        const gcmd_t* c = &g_cmds[i];
        /* Four records — four lines — ahead: the buffer is far larger than the cache and is read
         * once, front to back, so every line is a miss unless it was asked for in time. Past the
         * end it touches the memory after the array, which is harmless. */
        SHZ_PREFETCH(c + 4);
        if(c->is_rect == GCMD_VRAM) {
            if(draw_mark(c, sx, sy, sw, sh, scale_x, scale_y)) { restate = 1; g.state = -1; }
            else {}
            continue;
        } else {}
        const gstate_t* s = &g_states[c->state];
        /* States are recorded in the order primitives use them, so the next one is where the
         * walk is going; past the last one this touches the array's own tail, harmlessly. */
        SHZ_PREFETCH(s + 1);
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
                int ow = 0, oh = 0;   /* unset when not placed, and then never read */
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
        /* Whether the binding is the state's, not the record's: then the records after this one
         * under the same state bind the same way (run_tris). A baked patch is per record. */
        int per_state = 1;

        if(textured) {
            if((int)c->state != run_state) {
                run_state = (int)c->state;
                const uint32_t pk = (uint32_t)s->tex_x | ((uint32_t)s->tex_y << 16);
                const uint32_t ck = (uint32_t)s->clut_x | ((uint32_t)s->clut_y << 16);
                gtbind_t* tb = tbind_at(pk, ck, s->window, s->depth);
                if(tb->gen == g_tbind_gen && tb->page == pk && tb->clut == ck
                   && tb->window == s->window && tb->depth == s->depth
                   && (tb->slot < 0 || slot_holds(tb->slot, s))) {
                    run_mir = tb->mir; run_bank = tb->bank; run_slot = tb->slot;
                    run_patch8 = tb->patch8;
                } else {
                    run_bank = -1; run_slot = -1; run_mir = NULL;
                    /* The page grid is the mirror's index, so a page origin that is not on
                     * the grid would silently read a neighbour. The texpage encoding cannot
                     * produce one; the guard costs a compare and removes the assumption. */
                    if(s->depth == 0 && (s->window & 0x3FF) == 0
                       && (s->tex_x & 63) == 0 && (s->tex_y & 255) == 0)
                        run_mir = page4_mirror(s);
                    else {}
                    /* An unwindowed 8bpp page is drawn from 64x64 patches through its CLUT
                     * (bake_slot); the whole page is decoded only for a primitive sampling
                     * across patches, below. */
                    run_patch8 = s->depth == 1 && (s->window & 0x3FF) == 0
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
                }
            }
            if(run_mir && run_bank >= 0) {
                mem = run_mir;
                fmt = PVR_TXRFMT_PAL4BPP | PVR_TXRFMT_4BPP_PAL(run_bank) | PVR_TXRFMT_TWIDDLED;
            } else if(run_mir || run_patch8) {
                /* No bank was left for this palette, or an 8bpp page: texels with the CLUT
                 * already in them — exact, and only as large as this primitive samples. */
                per_state = 0;
                int tu, tv;
                const int b = one_patch(c, &tu, &tv) ? bake_slot(s, tu, tv, AM_VIS) : -1;
                if(b >= 0) {
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

        if((int)c->state != cur_state || mem != cur_mem || fmt != cur_fmt
           || dim != cur_dim || ou != cur_ou || ov != cur_ov) {
            cur_state = (int)c->state;
            cur_mem = mem; cur_fmt = fmt; cur_ou = ou; cur_ov = ov;
            alpha = emit_header(mem, fmt, dim, s, 0, HK_NORMAL, &g_run_hdr);
            restate = 0;
            over_ready = 0;
            /* What put_tri adds after scaling: the buffer's corner on screen, and in the texture
             * the texel centre less the patch origin. rdim is a power of two, so the texture
             * terms are exact either way round. They depend on the size, the patch and the
             * corner, which nearly every state shares with the one before it: worked out again
             * only when one of those changed (a divide and a dozen conversions, E-044). */
            if(dim != cur_dim || ou != vs_ou || ov != vs_ov || g.ox != vs_ox || g.oy != vs_oy) {
                cur_dim = dim; vs_ou = ou; vs_ov = ov; vs_ox = g.ox; vs_oy = g.oy;
                cur_rdim = 1.0f / (float)dim;
                cur_xo = -(float)g.ox * scale_x;
                cur_yo = -(float)g.oy * scale_y;
                cur_uo = (0.5f - (float)ou) * cur_rdim;
                cur_vo = (0.5f - (float)ov) * cur_rdim;
                vert_set(&cur_t, scale_x, scale_y, g.ox, g.oy, cur_rdim, ou, ov);
            } else {}
            if(alpha != vs_alpha) {
                vs_alpha = alpha;
                cur_a = (uint32_t)(alpha * 255.0f) << 24;
            } else {}
            g.state = -1;           /* the semi-transparent path's header is not the last one now */
        } else if(restate) {
            put_hdr(&g_run_hdr);
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
            if(inside) {
                if(mem) put_tri(c, col, &cur_t);
                else pvr_dr_addr = put_tri_col_at(pvr_dr_addr, c, col, &cur_t);
            } else put_clipped(c, col, &g);
            if(bright && !(s->flags & BP_GPU_RAW)) {
                if(over_ready) put_hdr(&g_run_over);
                else {
                    emit_header(mem, fmt, dim, s, 1, HK_NORMAL, &g_run_over);
                    over_ready = 1;
                }
                for(int k = 0; k < 3; k++)
                    col[k] = (bgr_to_argb_over(c->argb[k]) & 0x00FFFFFFu) | a;
                if(inside) put_tri(c, col, &cur_t);
                else put_clipped(c, col, &g);
                restate = 1;      /* the next primitive of the run restates its header */
#if RECOMPSX_DC_PROFILE
                g_bright_prims++;
#endif
            } else {}
            if(per_state && !restate) {
                const gcmd_t* next = run_tris(c, &g_cmds[g_cmd_count], a, mem != NULL,
                                              (s->flags & BP_GPU_RAW) != 0, &g, &cur_t);
                i = (int)(next - g_cmds) - 1;
            } else {}
        }
    }
#if RECOMPSX_DC_PROFILE_OVERLAY
    /* Last: the list is drawn in submission order, so anything submitted before the game's
     * primitives is painted over by them — as the overlay was, when it followed the background. */
    draw_profile_overlay();
#endif
    draw_mouse_pointer();
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
