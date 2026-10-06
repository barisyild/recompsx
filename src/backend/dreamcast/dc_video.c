/* dc_video.c — the picture: the framebuffer texture, the background slots, and presenting a
 * finished frame to the television. */

#include "dc_internal.h"

/* ---- video state ---------------------------------------------------------------------------
 * One texture, allocated once at the largest size the PS1 can ask for and never freed. VRAM on
 * this machine is 8 MB and a full 1024x512 sheet at 16 bpp is 1 MB of it, which is cheap next to
 * the alternative: reallocating whenever a game changes resolution would fragment the PVR heap
 * over a play session, and a fragmented heap fails at the least convenient moment. Only the
 * dimensions the hardware is *told* about change with the mode. */
pvr_ptr_t      g_txr;
pvr_poly_hdr_t g_hdr;
int            g_txw, g_txh;      /* power-of-two dimensions currently declared */
int            g_ready;           /* video is up */
int            g_inited;          /* bp_init has run; a second call is a no-op */

/* One converted scanline on its way to the PVR. 32-byte aligned because the store queues that
 * carry it there require it. */
static uint16_t g_line[TXR_MAX_W + 16] __attribute__((aligned(32)));

/* The background's slots, carved out of g_txr (gbg_t says why there are several). */
gbg_t          g_bgs[BG_SLOTS];
static pvr_poly_hdr_t g_bg_hdr[BG_SLOTS];
int            g_bg_slots = 1;     /* how many fit at the declared size */

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
        /* The next row's first line while this one converts (Flycast counts none of this). */
        SHZ_PREFETCH(vram + (size_t)((sy + y + 1) & (VRAM_H - 1)) * VRAM_W + (sx & (VRAM_W - 1)));
        if(fast) {
            const uint32_t* s32 = (const uint32_t*)(const void*)(src + sx);
            uint32_t* d = sq_lock((void*)(tex + (size_t)y * g_txw * 2));
            for(int w = 0; w < row_words; w += 8) {
                SHZ_PREFETCH(s32 + w + 16);     /* two lines ahead; past the row is harmless */
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
            txr_put(g_line, (pvr_ptr_t)(dst + (size_t)y * g_txw * 2), row_bytes);
        }
    }
    sq_wait();
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
            /* Every eight pixels, 24 bytes: a line about three lines ahead of the reads. */
            if((x & 7) == 0) SHZ_PREFETCH(src + 96);
            else {}
            g_line[x] = (uint16_t)(((src[0] >> 3) << 10) | ((src[1] >> 3) << 5) | (src[2] >> 3));
            src += 3;
        }
        txr_put(g_line, (pvr_ptr_t)(dst + (size_t)y * g_txw * 2), row_bytes);
    }
    sq_wait();
}

/* ---- the pictures (ADR-0053) -------------------------------------------------------------------
 * A PlayStation keeps what it drew in VRAM; this backend draws on the PVR, so emulated VRAM never
 * receives it, and it used to keep nothing either: each present was built from the records since
 * the frame began, over emulated VRAM's display rectangle. A game that stops clearing — Crash 3's
 * pause draws its panels into buffers it no longer clears — showed them over black, and a buffer
 * the game cleared with primitives showed whatever was last uploaded there (Crash Bash's legal
 * screen, at every loading pause). So each display buffer has a picture: the PVR renders the
 * records into it, starting from the picture as it was, and the screen shows the displayed
 * buffer's. A record is rendered once. Pictures are RGB565, the PVR's own 16 bits, copied 1:1 with
 * point sampling and dithering off, so a picture redrawn every frame does not drift.
 *
 * A picture is the screen's size, 640x480 (ADR-0055): the buffer's records drawn as the screen
 * would draw them, at the Dreamcast's own resolution, and shown 1:1 — the sharpness of drawing
 * straight to the screen, which a picture at the buffer's resolution scaled up lost. A render draws
 * into the picture it starts from: the PVR draws a tile at a time, and the copy it starts from is
 * 1:1 and point sampled, so each tile reads only its own pixels, before it writes them. That keeps
 * two memories where a copy elsewhere and a swap needed three (1.8 MB at this size).
 *
 * At a lower resolution (bp_gpu_scale, ADR-0056) a picture is its buffer's size times the scale —
 * 512x240 at 1X, 256x120 at 0.5X — in the same memory, its rows still PIC_W apart, and the screen
 * shows it stretched and filtered. */

int g_pic_ok, g_pic_active, g_pic_done;
static pvr_ptr_t g_pic_mem[PIC_N];
static pvr_poly_hdr_t g_pic_point[PIC_N];       /* point sampled: the base, the screen, a copy */
static pvr_poly_hdr_t g_pic_linear[PIC_N];      /* RECOMPSX_DC_FILTER: a smaller one onto the screen */
static gpic_t g_pic[PIC_N];
float g_pic_ru[PIC_N], g_pic_rv[PIC_N];         /* screen pixels per buffer pixel, over the size */
int g_pic_tw[PIC_N], g_pic_th[PIC_N];           /* the size each is declared at (dc_internal.h) */
int g_scene_w = PIC_W, g_scene_h = PIC_H;
/* The scale asked for (bp_gpu_scale) and the one the pictures are at: a new one is taken at the
 * next present through the pictures (pictures_rescale). */
static int g_scale = PIC_SCALE_SCREEN, g_pic_scale = PIC_SCALE_SCREEN;

const pvr_poly_hdr_t* g_base_hdr;
float g_base_x1, g_base_y1, g_base_u1, g_base_v1;

static void pic_compile(pvr_poly_hdr_t* hdr, pvr_ptr_t mem, int filter, int tw, int th) {
    pvr_poly_cxt_t cxt;
    pvr_poly_cxt_txr(&cxt, PVR_LIST_TR_POLY, PIC_FMT, tw, th, mem, filter);
    cxt.blend.src = PVR_BLEND_ONE;
    cxt.blend.dst = PVR_BLEND_ZERO;
    cxt.depth.comparison = PVR_DEPTHCMP_ALWAYS;
    cxt.depth.write = false;
    cxt.gen.culling = PVR_CULLING_NONE;
    cxt.txr.uv_clamp = PVR_UVCLAMP_UV;
    cxt.txr.env = PVR_TXRENV_REPLACE;
    pvr_poly_compile(hdr, &cxt);
}

/* At bp_init, once g_txr exists (TXR_BYTES): the pictures' memories follow slot 0 at
 * PIC_SRC_W x PIC_SRC_H, each 32-byte aligned (a whole number of 4 KB from g_txr). */
int pictures_init(void) {
    if(!g_txr) return 0;
    else {}
    for(int i = 0; i < PIC_N; i++) {
        g_pic_mem[i] = (pvr_ptr_t)((uint8_t*)g_txr + (size_t)PIC_SRC_W * PIC_SRC_H * 2
                                   + (size_t)i * PIC_BYTES);
        g_pic_tw[i] = PIC_TEXW;
        g_pic_th[i] = PIC_TEXH;
        pic_compile(&g_pic_point[i], g_pic_mem[i], PVR_FILTER_NONE, PIC_TEXW, PIC_TEXH);
        pic_compile(&g_pic_linear[i], g_pic_mem[i], RECOMPSX_DC_FILTER, PIC_TEXW, PIC_TEXH);
        g_pic[i].valid = 0;
        g_pic[i].w = 0;
        g_pic[i].pw = PIC_W;
        g_pic[i].ph = PIC_H;
        g_pic[i].used = 0;
        g_pic_ru[i] = 1.0f / (float)PIC_TEXW;
        g_pic_rv[i] = 1.0f / (float)PIC_TEXH;
    }
    /* One stride for every stride texture of a scene; the pictures are the only ones. */
    pvr_txr_set_stride(PIC_W);
    g_pic_ok = 1;
    return 1;
}

/* A present the pictures cannot show (24-bit video, a blank display, a mode larger than PIC_SRC_W x
 * PIC_SRC_H): the pictures may miss what it showed, so they start again from emulated VRAM, and
 * g_txr's slots are all the background's again (declared anew at the next upload). */
static void pictures_drop(void) {
    for(int i = 0; i < PIC_N; i++) g_pic[i].valid = 0;
    g_pic_active = 0;
    g_pic_done = 0;
    g_txw = 0;
    g_txh = 0;
    g_scene_dirty = 1;      /* the pictures ignore it (present_pictures); the old path must not */
}

/* The first present through the pictures: g_txr at PIC_SRC_W x PIC_SRC_H, slot 0 the background's
 * alone, the pictures' memories after it, none of which holds a picture yet. */
static void pictures_enter(void) {
    declare_texture(PIC_SRC_W, PIC_SRC_H);
    g_bg_slots = 1;
    for(int k = 1; k < BG_SLOTS; k++) g_bgs[k].valid = 0;
    for(int i = 0; i < PIC_N; i++) g_pic[i].valid = 0;
    g_pic_done = 0;
    g_pic_active = 1;
    g_pic_scale = g_scale;     /* none holds anything to keep */
}

/* A picture's size for a buffer of w x h at `percent` (ADR-0056): the screen's from
 * PIC_SCALE_SCREEN up, whatever the buffer's own (ADR-0055); below it the buffer's times the scale,
 * rounded. */
static void pic_size(int w, int h, int percent, int* pw, int* ph) {
    if(percent >= PIC_SCALE_SCREEN) {
        *pw = PIC_W;
        *ph = PIC_H;
    } else {
        const int x = (w * percent + 50) / 100, y = (h * percent + 50) / 100;
        *pw = x < 1 ? 1 : (x > PIC_W ? PIC_W : x);
        *ph = y < 1 ? 1 : (y > PIC_H ? PIC_H : y);
    }
}

/* The smallest power of two at least v, and at least 8: the side of a PVR texture. */
static int pic_pow2(int v) {
    int n = 8;
    while(n < v) n <<= 1;
    return n;
}

/* Picture i at pw x ph: declared at the next powers of two of its size, the texture Flycast keeps
 * a render to texture as (pvr_begin_queued_render's clip, rounded up) and matches a read of it by —
 * on a console only the coordinates' scale; its headers made again when that changes, and the
 * bindings kept for its memory forgotten. Its texel coordinates, in its buffer's pixels, reach its
 * own through its scale (`g_pic_ru`, `g_pic_rv`). */
static void pic_resize(int i, int pw, int ph) {
    gpic_t* p = &g_pic[i];
    p->pw = pw;
    p->ph = ph;
    const int tw = pic_pow2(pw), th = pic_pow2(ph);
    if(tw != g_pic_tw[i] || th != g_pic_th[i]) {
        g_pic_tw[i] = tw;
        g_pic_th[i] = th;
        pic_compile(&g_pic_point[i], g_pic_mem[i], PVR_FILTER_NONE, tw, th);
        pic_compile(&g_pic_linear[i], g_pic_mem[i], RECOMPSX_DC_FILTER, tw, th);
        hdr_forget(g_pic_mem[i]);
    } else {}
    g_pic_ru[i] = (float)pw / ((float)p->w * (float)tw);
    g_pic_rv[i] = (float)ph / ((float)p->h * (float)th);
}

static gpic_t* pic_find(int x, int y, int w, int h) {
    for(int i = 0; i < PIC_N; i++) {
        gpic_t* p = &g_pic[i];
        if(p->valid && p->x == x && p->y == y && p->w == w && p->h == h) return p;
        else {}
    }
    return NULL;
}

/* The picture a buffer is drawn into: its own, or the least recently used one, taken for it and
 * not valid yet (it starts from emulated VRAM). */
static gpic_t* pic_take(int x, int y, int w, int h) {
    gpic_t* p = pic_find(x, y, w, h);
    if(p) return p;
    else {}
    p = &g_pic[0];
    for(int i = 1; i < PIC_N; i++) {
        if(!g_pic[i].valid || (p->valid && g_pic[i].used < p->used)) p = &g_pic[i];
        else {}
    }
    p->x = x; p->y = y; p->w = w; p->h = h;
    p->valid = 0;
    int pw, ph;
    pic_size(w, h, g_pic_scale, &pw, &ph);
    pic_resize((int)(p - g_pic), pw, ph);
    return p;
}

/* A 15-bit texture page whose corner lies in a buffer with a picture (ADR-0054): the picture, as a
 * texture of PIC_TEXW x PIC_TEXH bound as `dim` PIC_TEXDIM + its index — a page's coordinates
 * (0..255 from a corner inside the buffer) reach its pixels through the picture's scale — and the
 * page's offset into it. During a render of that same buffer the picture is the one it started from
 * in an emulator, which keeps a render apart from the texture it read; on a console, where the
 * render draws into it a tile at a time, a tile the render has finished already holds the new. */
int pic_page(int tx, int ty, pvr_ptr_t* mem, int* dim, int* ou, int* ov) {
    if(!g_pic_active) return 0;
    else {}
    for(int i = 0; i < PIC_N; i++) {
        const gpic_t* p = &g_pic[i];
        if(p->valid && tx >= p->x && tx < p->x + p->w && ty >= p->y && ty < p->y + p->h) {
            *mem = g_pic_mem[i];
            *dim = PIC_TEXDIM + i;
            *ou = p->x - tx;
            *ov = p->y - ty;
            return 1;
        } else {}
    }
    return 0;
}

/* The picture holding all of a copy's source rectangle, point sampled as it replaces, its corner
 * and its scale (ADR-0054): a texel coordinate in the buffer's pixels times ru, rv. */
const pvr_poly_hdr_t* pic_source(int x, int y, int w, int h, int* px, int* py, float* ru, float* rv) {
    for(int i = 0; i < PIC_N; i++) {
        const gpic_t* p = &g_pic[i];
        if(p->valid && inside(x, y, w, h, p->x, p->y, p->w, p->h)) {
            *px = p->x;
            *py = p->y;
            *ru = g_pic_ru[i];
            *rv = g_pic_rv[i];
            return &g_pic_point[i];
        } else {}
    }
    return NULL;
}

/* A rectangle from (0,0) to (x1,y1), the texture from (u0,v0) to (u1,v1), after its header. */
static void tex_rect_uv(float x1, float y1, float u0, float v0, float u1, float v1) {
    pvr_vertex_t vert;
    vert.flags = PVR_CMD_VERTEX;
    vert.argb  = 0xFFFFFFFFu;
    vert.oargb = 0;
    vert.z     = 1.0f;
    vert.x = 0.0f; vert.y = 0.0f; vert.u = u0; vert.v = v0; put_vtx(&vert);
    vert.x = x1;   vert.y = 0.0f; vert.u = u1; vert.v = v0; put_vtx(&vert);
    vert.x = 0.0f; vert.y = y1;   vert.u = u0; vert.v = v1; put_vtx(&vert);
    vert.flags = PVR_CMD_VERTEX_EOL;
    vert.x = x1;   vert.y = y1;   vert.u = u1; vert.v = v1; put_vtx(&vert);
}

/* The screen's band a picture is shown in: x from x0 to x1, the whole height, the texture from
 * (u0,v0) to (u1,v1), after its header. */
static void screen_rect(float x0, float x1, float u0, float v0, float u1, float v1) {
    pvr_vertex_t vert;
    vert.flags = PVR_CMD_VERTEX;
    vert.argb  = 0xFFFFFFFFu;
    vert.oargb = 0;
    vert.z     = 1.0f;
    vert.x = x0; vert.y = 0.0f;   vert.u = u0; vert.v = v0; put_vtx(&vert);
    vert.x = x1; vert.y = 0.0f;   vert.u = u1; vert.v = v0; put_vtx(&vert);
    vert.x = x0; vert.y = 480.0f; vert.u = u0; vert.v = v1; put_vtx(&vert);
    vert.flags = PVR_CMD_VERTEX_EOL;
    vert.x = x1; vert.y = 480.0f; vert.u = u1; vert.v = v1; put_vtx(&vert);
}

/* A rectangle from (0,0) to (x1,y1), the texture from (0,0) to (u1,v1), after its header. */
static void tex_rect(float x1, float y1, float u1, float v1) {
    pvr_vertex_t vert;
    vert.flags = PVR_CMD_VERTEX;
    vert.argb  = 0xFFFFFFFFu;
    vert.oargb = 0;
    vert.z     = 1.0f;
    vert.x = 0.0f; vert.y = 0.0f; vert.u = 0.0f; vert.v = 0.0f; put_vtx(&vert);
    vert.x = x1;   vert.y = 0.0f; vert.u = u1;   vert.v = 0.0f; put_vtx(&vert);
    vert.x = 0.0f; vert.y = y1;   vert.u = 0.0f; vert.v = v1;   put_vtx(&vert);
    vert.flags = PVR_CMD_VERTEX_EOL;
    vert.x = x1;   vert.y = y1;   vert.u = u1;   vert.v = v1;   put_vtx(&vert);
}

/* A 4:3 picture on a 16:9 screen, as the last screen showed it (dc_internal.h). */
int g_pillarbox = 0;

/* The background texture over the screen's band from x1 to x2. */
static void draw_quad_band(int sw, int sh, float x1, float x2) {
    const float u1 = 0.0f, v1 = 0.0f;
    const float u2 = (float)sw / (float)g_txw;
    const float v2 = (float)sh / (float)g_txh;
    const float y1 = 0.0f, y2 = 480.0f;

    pvr_vertex_t vert;
    vert.flags = PVR_CMD_VERTEX;
    vert.argb  = 0xFFFFFFFFu;
    vert.oargb = 0;
    vert.z     = 1.0f;

    vert.x = x1; vert.y = y1; vert.u = u1; vert.v = v1; put_vtx(&vert);
    vert.x = x2; vert.y = y1; vert.u = u2; vert.v = v1; put_vtx(&vert);
    vert.x = x1; vert.y = y2; vert.u = u1; vert.v = v2; put_vtx(&vert);
    vert.flags = PVR_CMD_VERTEX_EOL;
    vert.x = x2; vert.y = y2; vert.u = u2; vert.v = v2; put_vtx(&vert);
}

void draw_quad(int sw, int sh) {
    draw_quad_band(sw, sh, 0.0f, 640.0f);
}

/* ---- presenting a frame: the scene (dc_scene.c) or the software picture, paced -------------- */

/* Presents in a row that kept the last picture up because the GPU was still drawing
 * (BP_PRESENT_DRAWING), and how many of them a frame is given. A walk is a few milliseconds and
 * crosses one vblank at most; the bound is for a game whose GPU never rests at a vblank, which
 * gets a torn picture every fourth vblank rather than none. */
static int g_held;
#define HOLD_MAX 3

#if RECOMPSX_DC_PROFILE
/* A built present's counters, on either path: conflicts said, the frame's counts zeroed. */
static void present_counted(void) {
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
    if(g_bake_live > g_bake_live_max) g_bake_live_max = g_bake_live;
    else {}
    g_bake_miss_all += g_bake_miss;
    g_bake_live = 0;
    g_bake_decodes = 0;
    g_bake_miss = 0;
}

/* A present's reports, on either path: the diagnostic line when one is due, the profile, and the PC
 * histogram every 200 presents. */
static void present_reported(void) {
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
}
#endif

/* The records from `from` on that draw into the buffer at tx, ty (tw x th), rendered into its
 * picture: over the picture as it was, or over emulated VRAM's rectangle when it has none, unless a
 * fill covers the buffer; VRAM marks drawn from that rectangle in their place in the order. */
static void render_picture(const uint16_t* vram, int tx, int ty, int tw, int th, int from) {
    gpic_t* p = pic_take(tx, ty, tw, th);
    const int cover = last_cover_at(tx, ty, tw, th, from);
#if RECOMPSX_DC_PROFILE
    g_pic_renders++;
    if(cover < 0 && p->valid) g_pic_copies++;
    else {}
#endif
    const int base_vram = cover < 0 && !p->valid;
    /* Wait first, upload second, as present_frame does: the PVR may still be reading the slot. */
    pvr_wait_ready();
    if(base_vram || marks_from(cover < 0 ? from : cover, tx, ty, tw, th)) {
        const int k = bg_slot(tx, ty, tw, th, 0);
        const gbg_t* b = &g_bgs[k];
        if(!b->valid || b->x != tx || b->y != ty || b->w != tw || b->h != th) {
            /* One slot only: a scene of this present or the last may still read it. */
            if(b->used + 1 >= g_tex_frame) pvr_wait_render_done();
            else {}
            g_bgs[k].valid = 0;
        } else {}
        if(!g_bgs[k].valid) {
            upload_15bpp(vram, tx, ty, tw, th, bg_mem(k));
            g_bgs[k].x = tx; g_bgs[k].y = ty; g_bgs[k].w = tw; g_bgs[k].h = th;
            g_bgs[k].d24 = 0;
            g_bgs[k].valid = 1;
        } else {}
        g_bgs[k].used = g_tex_frame;
        g_hdr = g_bg_hdr[k];
    } else {}
    const int i = (int)(p - g_pic);
    if(cover < 0) {
        g_base_x1 = (float)p->pw;
        g_base_y1 = (float)p->ph;
        if(p->valid) {
            /* The picture itself, 1:1: drawn into it, each tile reads only what it then writes. */
            g_base_hdr = &g_pic_point[i];
            g_base_u1 = (float)p->pw / (float)g_pic_tw[i];
            g_base_v1 = (float)p->ph / (float)g_pic_th[i];
        } else {
            g_base_hdr = &g_hdr;
            g_base_u1 = (float)tw / (float)g_txw;
            g_base_v1 = (float)th / (float)g_txh;
        }
    } else {}
    g_scene_w = p->pw;
    g_scene_h = p->ph;
    /* Over a picture that is its own base, its records drawn uncut and the outside of their drawing
     * area drawn again from it after them, where that is exact (RECOMPSX_UNCUT, area_uncut). */
#if RECOMPSX_UNCUT
    const int uncut = cover < 0 && p->valid && area_uncut(tx, ty, tw, th, from);
#else
    const int uncut = 0;
#endif
    pvr_scene_begin_rtt(g_pic_mem[i], p->pw, p->ph, PIC_W);
    build_scene(tx, ty, tw, th, cover < 0, cover < 0 ? from : cover, 1);
    if(uncut) area_uncut_end();
    else {}
    pvr_scene_finish();
    p->valid = 1;
    p->used = g_tex_frame;
}

/* The buffers this present's new records draw into: each state's (screen_origin), and each display
 * rectangle a new VRAM mark meets. Up to four. */
static int picture_targets(int t[4][4]) {
    int n = state_targets(t, 4, g_pic_done);
    for(int k = 0; k < 2 && n < 4; k++) {
        const int* d = g_disp[k];
        if(d[2] <= 0 || d[3] <= 0 || !marks_from(g_pic_done, d[0], d[1], d[2], d[3])) continue;
        else {}
        int seen = 0;
        for(int j = 0; j < n; j++) seen |= t[j][0] == d[0] && t[j][1] == d[1] && t[j][2] == d[2] && t[j][3] == d[3];
        if(!seen) { t[n][0] = d[0]; t[n][1] = d[1]; t[n][2] = d[2]; t[n][3] = d[3]; n++; }
        else {}
    }
    return n;
}

/* One render: memory `mem` drawn at w x h from a picture through `hdr`, (0,0) to (u1,v1) of it —
 * its own scene, as a picture's render is. */
static void pic_render_from(const pvr_poly_hdr_t* hdr, pvr_ptr_t mem, int w, int h, float u0, float v0,
                            float u1, float v1) {
    pvr_wait_ready();
    pvr_scene_begin_rtt(mem, w, h, PIC_W);
    pvr_list_begin(PVR_LIST_TR_POLY);
    put_hdr(hdr);
    tex_rect_uv((float)w, (float)h, u0, v0, u1, v1);
    pvr_list_finish();
    pvr_scene_finish();
}

/* A new scale (bp_gpu_scale, ADR-0056), at the first present through the pictures after it. The
 * pictures keep what they hold — what a frame does not redraw, the pause's frozen game, is nowhere
 * else — at their new size: the picture shown (or else the last used) is drawn at it into the other
 * picture's memory, filtered, and that back into its own, 1:1. A render in place would read tiles
 * it has already written wherever the picture grows. The other picture then holds the same: it stays
 * valid when its buffer is the same size — a double-buffered game's other buffer, which the game
 * draws over again — and starts again from emulated VRAM otherwise. Returns whether a picture
 * changed. */
static int pictures_rescale(int sx, int sy, int sw, int sh) {
    g_pic_scale = g_scale;
    gpic_t* a = pic_find(sx, sy, sw, sh);
    if(!a) {
        for(int i = 0; i < PIC_N; i++) {
            if(g_pic[i].valid && (!a || g_pic[i].used > a->used)) a = &g_pic[i];
            else {}
        }
    } else {}
    if(!a) return 0;
    else {}
    int pw, ph;
    pic_size(a->w, a->h, g_pic_scale, &pw, &ph);
    if(pw == a->pw && ph == a->ph) return 0;
    else {}
    const int ia = (int)(a - g_pic), ib = (ia + 1) % PIC_N;
    gpic_t* b = &g_pic[ib];
    const int keep = b->valid && b->w == a->w && b->h == a->h;
    const float tw = (float)g_pic_tw[ia], th = (float)g_pic_th[ia];
    pic_render_from(&g_pic_linear[ia], g_pic_mem[ib], pw, ph, 0.5f / tw, 0.5f / th,
                    ((float)a->pw - 0.5f) / tw, ((float)a->ph - 0.5f) / th);
    /* b's memory holds a's picture now, at the new size: declared so, and copied back into a's. */
    if(!keep) {
        b->valid = 0;
        b->w = a->w;
        b->h = a->h;
    } else {}
    pic_resize(ib, pw, ph);
    pic_render_from(&g_pic_point[ib], g_pic_mem[ia], pw, ph, 0.0f, 0.0f,
                    (float)pw / (float)g_pic_tw[ib], (float)ph / (float)g_pic_th[ib]);
    pic_resize(ia, pw, ph);
    return 1;
}

/* The picture's resolution (ADR-0056), 25..400 percent of the PlayStation's: taken at the next
 * present through the pictures. The direct path, for a picture the pictures cannot show, draws at the
 * screen's resolution whatever it is. */
void bp_gpu_scale(int percent) {
    g_scale = percent < 25 ? 25 : (percent > 400 ? 400 : percent);
}

/* A present through the pictures: the new records into their buffers' pictures, then the displayed
 * buffer's picture onto the screen. A present with nothing new for the same rectangle is skipped,
 * and the screen keeps the last one. One during a list still being walked (`hold`, ADR-0039)
 * renders nothing yet, though the buffer being drawn is not the one shown: rendered now, the frame
 * would be two scenes, each with a scene's fixed cost, and its second half drawn over a copy of
 * the first. It shows a buffer the game has just flipped to. One a program asked to keep the
 * picture for (`keep`, BP_PRESENT_HOLD: HoldPicture, ADR-0060) renders its records into the
 * pictures as any present does — a new scale with them — and leaves the screen as it is; the first
 * present after it shows anew. Returns 0 when skipped. */
static int present_pictures(const uint16_t* vram, int sx, int sy, int sw, int sh, int hold, int keep,
                            int pillar) {
    static int shown_x = -1, shown_y = -1, shown_w = -1, shown_h = -1, shown_pillar = 0;
    if(!g_pic_active) {
        shown_x = -1;
        pictures_enter();
    } else {}
    /* A new scale: the pictures at it, and the screen shown again. */
    if(g_scale != g_pic_scale && pictures_rescale(sx, sy, sw, sh)) shown_x = -1;
    else {}
    if(sx != g_disp[0][0] || sy != g_disp[0][1] || sw != g_disp[0][2] || sh != g_disp[0][3]) {
        shz_memcpy4(g_disp[1], g_disp[0], sizeof(g_disp[0]));
        g_disp[0][0] = sx; g_disp[0][1] = sy; g_disp[0][2] = sw; g_disp[0][3] = sh;
    } else {}
    /* A texture upload alone (g_scene_dirty) changes no picture: a picture is drawn already, and
     * an upload into a buffer is a VRAM mark, a record. */
    const int render = cmd_count() > g_pic_done && !hold;
    /* Kept, or shown in another band of the screen (ADR-0064): the screen built again after it. */
    if(keep || pillar != shown_pillar) shown_x = -1;
    else {}
    if(!render && (keep || (sx == shown_x && sy == shown_y && sw == shown_w && sh == shown_h))) return 0;
    else {}
    if(!keep) {
        shown_x = sx; shown_y = sy; shown_w = sw; shown_h = sh; shown_pillar = pillar;
    } else {}
    g_scene_dirty = 0;
    if(render) {
        int t[4][4];
        const int n = picture_targets(t);
        for(int k = 0; k < n; k++) render_picture(vram, t[k][0], t[k][1], t[k][2], t[k][3], g_pic_done);
        g_pic_done = cmd_count();
        /* The records are in the pictures: the next primitive begins the next frame's. */
        g_frame_shown = 1;
        bp_gpu_sink.end = bp_gpu_sink.next;
    } else {}
    if(keep) return render;
    else {}
    gpic_t* p = pic_find(sx, sy, sw, sh);
    if(!p) {
        /* Never drawn into: emulated VRAM's picture of it, as the old path showed — the base
         * alone, since records held back (or none) are not rendered here. */
        render_picture(vram, sx, sy, sw, sh, cmd_count());
        p = pic_find(sx, sy, sw, sh);
    } else {}
    pvr_wait_ready();
    pvr_scene_begin();
    pvr_list_begin(PVR_LIST_TR_POLY);
#if RECOMPSX_DC_PROFILE
    g_pic_screens++;
#endif
    g_pillarbox = pillar;
    if(p && p->pw == PIC_W && p->ph == PIC_H && !pillar) {
        /* The screen's own size: a pixel a texel. */
        put_hdr(&g_pic_point[(int)(p - g_pic)]);
        tex_rect((float)PIC_W, (float)PIC_H, (float)PIC_W / (float)PIC_TEXW, (float)PIC_H / (float)PIC_TEXH);
        p->used = g_tex_frame;
    } else if(p) {
        /* Smaller (ADR-0056), or a 4:3 picture kept to the middle of a 16:9 screen (ADR-0064):
         * stretched over its band, filtered, its edge texels' centres at the band's edges — the
         * memory past its rows is not its. */
        const int i = (int)(p - g_pic);
        const float tw = (float)g_pic_tw[i], th = (float)g_pic_th[i];
        const float x0 = pillar ? (float)PILLAR_X0 : 0.0f;
        put_hdr(&g_pic_linear[i]);
        screen_rect(x0, x0 + (pillar ? (float)PILLAR_W : (float)PIC_W), 0.5f / tw, 0.5f / th,
                    ((float)p->pw - 0.5f) / tw, ((float)p->ph - 0.5f) / th);
        p->used = g_tex_frame;
    } else {}
#if RECOMPSX_DC_PROFILE_OVERLAY
    draw_profile_overlay();
#endif
    draw_mouse_pointer();
    pvr_list_finish();
    pvr_scene_finish();
    return 1;
}

static void present_frame(const uint16_t* vram, int sx, int sy, int sw, int sh, int flags) {
    if(!g_ready) return;

#if RECOMPSX_DC_PROFILE
#if RECOMPSX_DC_PROFILE
    if(cmd_count() == 0 && g_frame_shown) g_empty_presents++;
    else {}
#endif
    const uint64_t t0 = bp_time_us();
    if(g_prof_end) {
        g_prof_emu += t0 - g_prof_end;
        g_frame_emu_us = (uint32_t)(t0 - g_prof_end);
        perf_window_close(t0 - g_prof_end);
    } else {}
#endif

    /* The stream is polled here because this is the one call that happens once per emulated
     * frame no matter what the host is doing with pacing. */
    pump_audio();

    if(sw > VRAM_W) sw = VRAM_W;
    if(sh > VRAM_H) sh = VRAM_H;

    const int blank = (sw <= 0 || sh <= 0);

    /* Hardware drawing of a 15-bit picture up to PIC_SRC_W x PIC_SRC_H: through the pictures
     * (ADR-0053). */
    if(g_pic_ok && g_vram != NULL && !blank && !(flags & BP_PRESENT_24BPP) && sw <= PIC_SRC_W
       && sh <= PIC_SRC_H) {
        /* The walk's first part waits for the rest, as below; bounded the same way. */
        const int hold = (flags & BP_PRESENT_DRAWING) && cmd_count() > g_pic_done
                         && g_held < HOLD_MAX;
        g_held = hold ? g_held + 1 : 0;
        /* A program drawing the picture anew keeps this one on screen (HoldPicture, ADR-0060). */
        const int keep = (flags & BP_PRESENT_HOLD) != 0;
        /* A 4:3 picture on a 16:9 screen, kept to its middle (ADR-0064). */
        const int pillar = (flags & BP_PRESENT_WIDE) && !(flags & BP_PRESENT_WIDE_FILL);
#if RECOMPSX_DC_PROFILE
        const int built = present_pictures(vram, sx, sy, sw, sh, hold, keep, pillar);
        const uint64_t tb = bp_time_us();
        /* All of it `submit`, as on the other path, the build inside it: the bench's total is
         * the sum of the columns. */
        g_prof_submit += tb - t0;
        if(built) g_prof_build += tb - t0;
        else g_prof_skipped++;
        g_prof_end = tb;
        g_frame_present_us = (uint32_t)(tb - t0);
#else
        const int built = present_pictures(vram, sx, sy, sw, sh, hold, keep, pillar);
#endif
#if RECOMPSX_DC_PROFILE
        if(built) present_counted();
        else {}
#endif
        if(built) g_tex_frame++;
        else {}
#if RECOMPSX_DC_PROFILE
        present_reported();
#endif
        return;
    } else if(g_pic_active) pictures_drop();
    else {}

    /* The GPU is still walking this frame's list (ADR-0039): what is recorded is its first part,
     * and the rest arrives after this vblank. Built now, the frame went out in two halves, a
     * vblank each — in Crash 3's village the sky and the far hills, then the near half on black,
     * or only the sky and then everything but it. So the last picture stays up, as a skipped
     * present keeps it, and what the walk still draws joins this frame. */
    const int hold = (flags & BP_PRESENT_DRAWING) && cmd_count() > 0 && !g_frame_shown
                     && g_held < HOLD_MAX;
    g_held = hold ? g_held + 1 : 0;
    flags &= ~BP_PRESENT_DRAWING;

    static int shown_x = -1, shown_y = -1, shown_w = -1, shown_h = -1, shown_flags = -1;
    if(hold || (!g_scene_dirty && g_frame_shown && sx == shown_x && sy == shown_y && sw == shown_w
                && sh == shown_h && flags == shown_flags)) {
#if RECOMPSX_DC_PROFILE
        g_prof_skipped++;
        g_prof_end = bp_time_us();
        g_prof_submit += g_prof_end - t0;
        g_frame_present_us = (uint32_t)(g_prof_end - t0);
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
        shz_memcpy4(g_disp[1], g_disp[0], sizeof(g_disp[0]));
        g_disp[0][0] = sx; g_disp[0][1] = sy; g_disp[0][2] = sw; g_disp[0][3] = sh;
    } else {}

    /* Covered: no upload, and no slot touched — the next picture that does show the background
     * finds its slot as it left it — unless a VRAM mark after the cover needs the texture. */
    const int cover = (!blank && cmd_count() > 0) ? last_cover(sw, sh) : -1;
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
    if(cmd_count() > 0) {
        /* Hardware drawing: the picture is geometry, over whatever VRAM already held — over the
         * whole screen, a 4:3 picture on a 16:9 one too (the band is the pictures' and the
         * background's, ADR-0064). */
        g_pillarbox = 0;
        build_scene(sx, sy, sw, sh, !blank && cover < 0, cover < 0 ? 0 : cover, 0);
#if RECOMPSX_DC_PROFILE
        g_prof_build += bp_time_us() - t2;
#endif
    } else {
        pvr_list_begin(PVR_LIST_TR_POLY);
        /* A blank present submits nothing and the background colour becomes the whole screen —
         * which is the point: the display being off is a picture in its own right, and leaving
         * the last frame up instead would be a lie. */
        /* A 4:3 picture on a 16:9 screen in the middle of it (ADR-0064): a film, say. */
        g_pillarbox = (flags & BP_PRESENT_WIDE) && !(flags & BP_PRESENT_WIDE_FILL);
        if(!blank) {
            put_hdr(&g_hdr);
            if(g_pillarbox) draw_quad_band(sw, sh, (float)PILLAR_X0, (float)(PILLAR_X0 + PILLAR_W));
            else draw_quad(sw, sh);
        }
#if RECOMPSX_DC_PROFILE_OVERLAY
        draw_profile_overlay();
#endif
        draw_mouse_pointer();
        pvr_list_finish();
    }
    pvr_scene_finish();

    /* Not cleared here — see g_frame_shown. The geometry stays until the game draws again; the
     * polygon core's sink closes (ADR-0051), so that the next record comes through cmd_line, which
     * begins the next frame. */
    g_frame_shown = 1;
    bp_gpu_sink.end = bp_gpu_sink.next;
#if RECOMPSX_DC_PROFILE
    present_counted();
#endif
    /* Outside the profile guard on purpose: the in-flight eviction rule is arithmetic on this
     * counter, and a build without profiling must not lose its cache-coherency clock. */
    g_tex_frame++;

#if RECOMPSX_DC_PROFILE
    g_prof_end = bp_time_us();
    g_prof_submit += g_prof_end - t2;
    g_frame_present_us = (uint32_t)(g_prof_end - t0);
    present_reported();
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
    /* A memory card transfer (ADR-0037): nothing to watch, so nothing to hold for. The deadline
     * is reset, so the frame after it is held from now rather than racing to catch up. */
    if(flags & BP_PRESENT_FAST) {
        pump_audio();
        bp_pace_frame(0);
        return;
    }
#if RECOMPSX_DC_PROFILE
    static uint64_t paced;      /* when the last present's pacing ended */
    const uint64_t a = bp_time_us();
    if(paced) bench_frame_busy(a - paced);
    else {}
#endif
    bp_pace_frame((flags & BP_PRESENT_PAL) ? 20000 : 16683);
#if RECOMPSX_DC_PROFILE
    const uint64_t b = bp_time_us();
    paced = b;
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
