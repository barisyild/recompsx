/* dc_textures.c — PlayStation texture pages as PVR textures: colour conversion, the twiddled
 * upload, the page, slot, bake and palette caches, and bp_gpu_vram. */

#include "dc_internal.h"

/* ---- texture cache state (the layouts and their reasons are in dc_internal.h) --------------- */

#define PAGE4_BYTES (TEX_DIM * TEX_DIM / 2)
#define BAKE_BYTES (BAKE_DIM * BAKE_DIM * 2)

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
gpage4_t  g_page4[PAGE4_N];
static pvr_ptr_t g_mir_base;
int       g_mir_decodes;
gbake_t g_bake[BAKE_MAX];
int     g_bake_n, g_bake_live, g_bake_decodes, g_bake_miss;
static int g_bake_next;

gtex_t g_tex[TEX_SLOTS_MAX]; /* [0, big_n) ARGB pool, [big_n, big_n+small_n) 4bpp pool */
int    g_tex_big_n, g_tex_small_n;        /* allocated at arming time, floor-checked   */
static int    g_tex_big_next, g_tex_small_next;  /* round-robin eviction cursor, one per pool */
/* Decodes and hits per frame. A 256x256 page is 65,536 texels through a palette, so a scene that
 * misses more than a handful of times is not using a cache, it is rebuilding one. */
int    g_tex_decodes, g_tex_hits;
/* A conflict is the cache's cardinal sin: evicting a slot that a primitive EARLIER IN THIS SAME
 * SCENE already bound. The PVR reads textures at render time, not at submit time, so that
 * earlier primitive will be drawn with the newcomer's texels — unrelated content, changing with
 * the round-robin phase, exactly what per-frame-shifting corruption looks like. */
int      g_tex_conflicts;
/* Bank pressure gets its own numbers: how many 4bpp palettes this frame actually bound, and how
 * many times one was repainted while an earlier primitive of the same scene still named it. The
 * hardware ceiling is sixty-four; a scene living above it recolours its losers with whichever
 * palette was written last — the whole-screen single-tint wash. */
int      g_pal_live, g_pal_stale, g_pal_conflicts;
/* Counts scenes, and starts at ONE. Zero is the value every cache entry has before it is ever
 * bound, and the in-flight rule reads it as "virgin, take it freely" — so with a zeroth frame,
 * everything bound during it stayed forever indistinguishable from unused, and could be
 * overwritten while the PVR was still rendering from it. That is precisely a first-frames
 * corruption that heals itself as entries acquire honest numbers. */
uint32_t g_tex_frame = 1;

/* ---- texel colour conversion (a vertex's is dc_scene.c's) ------------------------------------ */

/** BGR555 as VRAM holds it, to the ARGB1555 the PVR samples. Texel zero is the PlayStation's
 *  "nothing here", and becomes alpha 0 so punch-through drops it. */
static uint16_t texel_to_argb1555(uint16_t p) {
    if(p == 0) return 0;
    return (uint16_t)(0x8000u | (p & 0x03E0u) | ((p & 0x001Fu) << 10) | ((p >> 10) & 0x001Fu));
}

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

void twid_init(void) {
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
                for(int r = 0; r < 8; r++) SHZ_PREFETCH(s + 8 + r * (VRAM_W / 2));
            uint32_t* o = d + ((ybits | ((uint32_t)g_spread[4 * tx] << 1)) >> 1);
            tile4(o, s);
            sq_flush(o);
        }
    }
}

/* Prefetching emulated VRAM for the decoders below. Flycast counts none of this; a console
 * misses the operand cache on nearly every new line of a page, which is the point. The rows of
 * a tile row are VRAM_W halfwords apart, so each is its own line. */
static inline void prefetch_rows(int y, int px) {
    for(int r = 0; r < 8; r++)
        SHZ_PREFETCH(g_vram + (size_t)((y + r) & 511) * VRAM_W + (px & 1023));
}
/* The next tile row of a bake patch: eight rows of `hw` halfwords from column px, every line. */
static inline void prefetch_patch(int y, int px, int hw) {
    for(int r = 0; r < 8; r++) {
        const uint16_t* row = g_vram + (size_t)((y + r) & 511) * VRAM_W;
        for(int x = 0; x < hw; x += 16) SHZ_PREFETCH(row + ((px + x) & 1023));
        SHZ_PREFETCH(row + ((px + hw - 1) & 1023));
    }
}

/** A 256x256 8bpp page at VRAM (px, py) through a CLUT given as two tables — lo[i] the colour,
 *  hi[i] the colour shifted up 16 — so a pair of texels is one OR. The page is 128 halfwords
 *  wide and wraps at the right edge of VRAM like the PlayStation's U; a tile never straddles
 *  the wrap. */
static void twid8_page(uint32_t* d, int px, int py, const uint32_t* lo, const uint32_t* hi) {
    for(int ty = 0; ty < 64; ty += 2) {
        const uint16_t* r0 = g_vram + (size_t)((py + 4 * ty) & 511) * VRAM_W;
        prefetch_rows(py + 4 * (ty + 2), px);
        for(int tx = 0; tx < 64; tx++) {
            const uint32_t* s = (const uint32_t*)(r0 + ((px + 2 * tx) & 1023));
            /* A line is eight columns of a row here: the next eight, all eight rows. */
            if((tx & 7) == 0 && tx + 8 < 64 && ((px + 2 * tx) & 1023) + 32 <= VRAM_W)
                for(int r = 0; r < 8; r++) SHZ_PREFETCH(s + 8 + r * (VRAM_W / 2));
            else {}
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
        prefetch_rows(py + 4 * (ty + 2), px);
        for(int tx = 0; tx < 64; tx++) {
            const uint32_t* s = (const uint32_t*)(r0 + ((px + 4 * tx) & 1023));
            /* A line is four columns of a row here: the next four, all eight rows. */
            if((tx & 3) == 0 && tx + 4 < 64 && ((px + 4 * tx) & 1023) + 32 <= VRAM_W)
                for(int r = 0; r < 8; r++) SHZ_PREFETCH(s + 8 + r * (VRAM_W / 2));
            else {}
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
        if(ty + 2 < 16) prefetch_patch(py + 4 * (ty + 2), px, 16);
        else {}
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
        if(ty + 2 < 16) prefetch_patch(py + 4 * (ty + 2), px, 32);
        else {}
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
                shz_memcpy(dst, src + s->tex_x, TEX_DIM / 2);
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
uint32_t g_pal_memo_gen = 1;
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
    shz_memcpy2_16(g_pal4[bank].entry, want);
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

PROF_NOINLINE int pal_bank_cached(int clut_x, int clut_y, int allow_approx, int amode) {
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
PROF_NOINLINE int tex_slot(const gstate_t* s, int amode) {
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
PROF_NOINLINE pvr_ptr_t page4_mirror(const gstate_t* s) {
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
        twid_bake8(d, s->tex_x + tu * (BAKE_STEP / 2), s->tex_y + tv * BAKE_STEP, lo, hi);
    else
        twid_bake(d, s->tex_x + tu * (BAKE_STEP / 4), s->tex_y + tv * BAKE_STEP, lo, hi);
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

PROF_NOINLINE int bake_slot(const gstate_t* s, int tu, int tv, int amode) {
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
static struct { uint16_t cx, cy; uint32_t n; uint8_t used; } g_prio[PRIO_SLOTS] __attribute__((aligned(8)));
_Static_assert(sizeof(g_prio) % 8 == 0, "g_prio is cleared with shz_memset8");

PROF_NOINLINE void palette_priority(void) {
    shz_memset8(g_prio, 0, sizeof(g_prio));
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
