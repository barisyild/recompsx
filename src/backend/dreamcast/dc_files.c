/* dc_files.c — saves and the disc: bp_storage_*, bp_file_*, and the read-ahead thread. */

#include "dc_internal.h"

/* ---- storage state ---------------------------------------------------------------------------- */

const char* g_storage_root;   /* NULL until a writable one is found */
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
uint64_t g_prof_disc_us;
uint32_t g_prof_disc_bytes;   /* fetched from the drive this window, read-ahead included */
int      g_prof_reads, g_prof_misses;
#endif

/* ---- where saves go -------------------------------------------------------------------------- */

static int dir_exists(const char* path) {
    const file_t h = fs_open(path, O_RDONLY | O_DIR);
    if(h == FILEHND_INVALID) return 0;
    fs_close(h);
    return 1;
}

/* Where a save may go, in the order we would rather use them. /pc is the development machine
 * over dcload; /sd is a mass-storage card if the running build mounted one; /vmu/a1 is what a
 * console actually has in front of it. */
void find_storage(void) {
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

/* ---- memory cards (ADR-0037) -------------------------------------------------------------------
 * The runtime hands over a game's card in the card format — a header and the blocks the game's
 * saves occupy, 8336 bytes for a one-block game — and it is kept as it comes: <game>.card where
 * saves go as files (/pc, /sd), and on a VMU a package of the Dreamcast's own format, named by the
 * game's product code, which the console's file manager lists under the game's own save icon.
 * A VMU has 200 blocks of 512 bytes, so it holds a card of up to twelve PlayStation blocks; past
 * that the write fails, and saying so is better than half-writing it. The package's CRC is what
 * catches a VMU write a power cut interrupted: such a card fails to load, and the game finds a
 * blank one. A card with nothing on it is no file at all. */

#define CARD_RECORD BP_CARD_RECORD    /* a block's directory frame and its 8 KB */

static int card_file(const char* game, char* out, size_t len) {
    if(!game || !*game) return 0;
    for(const char* p = game; *p; p++) {
        if(!((*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9'))) return 0;
    }
    if(g_storage_is_vmu) snprintf(out, len, "%.12s", game);   /* a VMU name is 12 characters */
    else snprintf(out, len, "%s.card", game);
    return 1;
}

/* The VMU icon: the game's own, from the first of its saves on the card — the 16x16 frames of
 * that file's title block doubled to the VMU's 32x32, a pixel's left half in the high nibble
 * rather than the low, and its palette from the PlayStation's 15-bit colours to ARGB4444, with
 * colour 0000h transparent as it is on the PlayStation. A card with no save on it yet gets a
 * plain card. Returns the number of frames: the PlayStation animates up to three, as a VMU does. */
static int card_icon(const uint8_t* card, int len, uint16_t* pal, uint8_t* icons) {
    for(int at = BP_CARD_HEADER; at + CARD_RECORD <= len; at += CARD_RECORD) {
        const uint8_t* t = card + at + 0x80;   /* the block's first frame: its title, for a head */
        if(card[at] != 0x51 || t[0] != 'S' || t[1] != 'C') continue;
        const int frames = (t[2] >= 0x11 && t[2] <= 0x13) ? t[2] - 0x10 : 1;
        for(int i = 0; i < 16; i++) {
            const int c = t[0x60 + 2 * i] | (t[0x61 + 2 * i] << 8);
            pal[i] = c == 0 ? 0 : (uint16_t)(0xF000 | (((c >> 1) & 0xF) << 8) | (((c >> 6) & 0xF) << 4)
                                             | ((c >> 11) & 0xF));
        }
        for(int f = 0; f < frames; f++) {
            const uint8_t* src = t + 0x80 * (1 + f);
            for(int y = 0; y < 32; y++) {
                for(int x = 0; x < 16; x++) {
                    const int two = src[(y >> 1) * 8 + (x >> 1)];
                    const int px = (x & 1) ? two >> 4 : two & 0xF;
                    icons[f * 512 + y * 16 + x] = (uint8_t)((px << 4) | px);
                }
            }
        }
        return frames;
    }
    for(int i = 0; i < 16; i++) pal[i] = 0;
    pal[1] = 0xFFFF;
    pal[2] = 0xF358;
    for(int y = 0; y < 32; y++) {
        for(int x = 0; x < 16; x++) {
            const int in = y >= 4 && y < 28 && x >= 3 && x < 13;
            const int edge = y == 4 || y == 27 || x == 3 || x == 12;
            const int px = !in ? 0 : (edge ? 1 : 2);
            icons[y * 16 + x] = (uint8_t)((px << 4) | px);
        }
    }
    return 1;
}

int bp_card_load(const char* game, uint8_t* buf, int cap) {
    char name[32], path[256];
    if(!card_file(game, name, sizeof(name))) return -1;
    if(!g_storage_is_vmu) return bp_storage_read(name, buf, cap);
    if(!storage_path(name, path, sizeof(path))) return -1;

    /* O_META: the file as it is on the VMU, header and all; the package is ours to parse. */
    const file_t f = fs_open(path, O_RDONLY | O_META);
    if(f == FILEHND_INVALID) return -1;
    const size_t size = fs_total(f);
    uint8_t* raw = (size > 0 && size <= 200 * 512) ? malloc(size) : NULL;
    int ok = raw && fs_read(f, raw, size) == (ssize_t)size;
    fs_close(f);
    vmu_pkg_t pkg;
    ok = ok && vmu_pkg_parse(raw, size, &pkg) == 0 && pkg.data_len >= BP_CARD_HEADER && pkg.data_len <= cap;
    if(ok) shz_memcpy(buf, pkg.data, (size_t)pkg.data_len);
    else bp_log(BP_LOG_WARN, "memory card: the VMU's copy is damaged — the game gets a blank card");
    const int got = ok ? pkg.data_len : -1;
    free(raw);
    return got;
}

int bp_card_save(const char* game, const char* title, const uint8_t* buf, int len) {
    char name[32], path[256], msg[96];
    if(!card_file(game, name, sizeof(name))) return -1;
    if(len <= BP_CARD_HEADER) {
        if(storage_path(name, path, sizeof(path))) fs_unlink(path);
        return 0;
    }
    if(!g_storage_is_vmu) return bp_storage_write(name, buf, len);
    if(!storage_path(name, path, sizeof(path))) return -1;

    static uint8_t icons[3 * 512];
    vmu_pkg_t pkg;
    memset(&pkg, 0, sizeof(pkg));
    /* The header's fields are 16, 32 and 16 characters, and vmu_pkg_build copies what it is
     * given without a limit of its own. */
    const char* shown = title && *title ? title : game;
    snprintf(pkg.desc_short, sizeof(pkg.desc_short), "%.16s", shown);
    snprintf(pkg.desc_long, sizeof(pkg.desc_long), "%.32s", shown);
    snprintf(pkg.app_id, sizeof(pkg.app_id), "recompsx");
    pkg.icon_cnt = card_icon(buf, len, pkg.icon_pal, icons);
    pkg.icon_anim_speed = 10;
    pkg.icon_data = icons;
    pkg.eyecatch_type = VMUPKG_EC_NONE;
    pkg.data_len = len;
    pkg.data = buf;

    uint8_t* out = NULL;
    int out_size = 0;
    int ok = vmu_pkg_build(&pkg, &out, &out_size) == 0;
    if(ok) {
        const file_t f = fs_open(path, O_WRONLY | O_TRUNC | O_META);
        ok = f != FILEHND_INVALID;
        if(ok) {
            ok = fs_write(f, out, (size_t)out_size) == (ssize_t)out_size;
            ok = (fs_close(f) == 0) && ok;   /* the VMU is written at close */
        }
    }
    free(out);
    if(!ok) {
        snprintf(msg, sizeof(msg), "memory card: not written to the VMU (%d free blocks needed)",
                 (out_size + 511) / 512);
        bp_log(BP_LOG_WARN, msg);
    }
    return ok ? 0 : -1;
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
            shz_memcpy(buf, g_winbuf[cur] + (offset - c->at), (size_t)len);
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
                shz_memcpy(buf, g_winbuf[cur] + (offset - c->at), (size_t)here);
                shz_memcpy(buf + here, g_winbuf[1 - cur], (size_t)(len - here));
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
