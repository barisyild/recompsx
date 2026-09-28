/* dc_gdrom.c — a GD-ROM's high-density area as /cd.
 *
 * KallistiOS's ISO9660 driver mounts the last data track of the disc's *low-density* TOC. On a
 * CD-R (MIL-CD, our CDIs) that is the data session, and /cd is our files. On a GD-ROM — a GDI or
 * CHD image, which is all Demul loads, or a GD-ROM drive emulator — the low-density area is the
 * small single-density one at the start of the disc, and a disc mkdcdisc makes has only its
 * ABSTRACT.TXT, BIBLIOGR.TXT and COPYRIGH.TXT there. The program, the PlayStation's disc image and
 * RECOMPSX.CFG are in the high-density area from LBA 45000, where the BIOS booted us from, and
 * /cd never shows them: the launch line is never read, nothing runs, and the screen stays black.
 *
 * So on a GD-ROM this takes /cd over: the ISO9660 filesystem of the high-density area's data
 * track, read only, enough for what the backend opens — files by path, read and seek. KallistiOS
 * has no way to point its own driver at the other area, so its /cd is shut down first. A CD is
 * left to KallistiOS exactly as before.
 *
 * API used: the intersection of KallistiOS v2.2.2 and the development branch (see backend_kos.c):
 * the TOC is a buffer of the documented layout rather than a named type, whose name differs
 * between the two, and the disc type and DMA mode are the BIOS's numbers. */

#include "dc_internal.h"
#include <dc/cdrom.h>
#include <dc/fs_iso9660.h>
#include <errno.h>

#define SECTOR 2048
#define GD_FILES 8
/* The BIOS's disc type for a GD-ROM (GDROM_GetDriveStatus: 80h). */
#define DISC_GDROM 0x80
/* cdrom_read_sectors_ex's last argument: 1 reads by DMA in both KallistiOS versions. */
#define READ_DMA 1
/* KallistiOS's sector numbers are the TOC's, 150 above the LBA an ISO9660 extent names. */
#define TOC_OFFSET 150

/* The table of contents as the drive returns it: 99 track entries, the first and last track,
 * the lead-out. */
typedef struct { uint32_t entry[99]; uint32_t first, last, leadout; } gd_toc_t;

typedef struct {
    int      used;
    uint32_t extent;   /* first sector, as an ISO9660 LBA */
    uint32_t size;     /* bytes */
    uint32_t pos;
} gd_file_t;

static gd_file_t g_gd_files[GD_FILES];
static uint32_t  g_gd_root, g_gd_root_size;   /* the root directory's extent and length */
static uint8_t   g_gd_sector[SECTOR] __attribute__((aligned(32)));
static uint32_t  g_gd_cached = 0xFFFFFFFFu;   /* which sector g_gd_sector holds */
static mutex_t   g_gd_lock = MUTEX_INITIALIZER;

static uint32_t le32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* One sector into g_gd_sector, unless it is there already. Lock held. */
static int gd_sector(uint32_t lba) {
    if(g_gd_cached == lba) return 0;
    g_gd_cached = 0xFFFFFFFFu;
    if(cdrom_read_sectors_ex(g_gd_sector, lba + TOC_OFFSET, 1, READ_DMA) != 0) return -1;
    g_gd_cached = lba;
    return 0;
}

/* Whether a directory record's name is `name` (length `len`): ISO9660 level 1 as mkdcdisc
 * writes it — upper case, with a ";1" version, and "NAME." for a file with no extension. */
static int gd_name_is(const uint8_t* rec, const char* name, size_t len) {
    size_t n = rec[32];
    const char* id = (const char*)rec + 33;
    for(size_t i = 0; i < n; i++) if(id[i] == ';') { n = i; break; }
    if(n > 0 && id[n - 1] == '.') n--;
    if(n != len) return 0;
    for(size_t i = 0; i < n; i++) {
        char a = id[i], b = name[i];
        if(a >= 'a' && a <= 'z') a = (char)(a - 32);
        if(b >= 'a' && b <= 'z') b = (char)(b - 32);
        if(a != b) return 0;
    }
    return 1;
}

/* Finds `path` ("/DISC.BIN", "/DIR/FILE") from the root: its extent, length and whether it is a
 * directory. Records never cross a sector; a zero length ends a sector's. Lock held. */
static int gd_lookup(const char* path, uint32_t* extent, uint32_t* size, int* is_dir) {
    uint32_t dir = g_gd_root, dir_size = g_gd_root_size;
    int dir_flag = 1;
    while(*path == '/') path++;
    while(*path) {
        const char* end = path;
        while(*end && *end != '/') end++;
        const size_t len = (size_t)(end - path);
        int found = 0;
        for(uint32_t s = 0; !found && s * SECTOR < dir_size; s++) {
            if(gd_sector(dir + s) != 0) return -1;
            uint32_t at = 0;
            while(at < SECTOR && g_gd_sector[at] != 0) {
                const uint8_t* rec = g_gd_sector + at;
                if(rec[0] < 34 || at + rec[0] > SECTOR) break;
                if(rec[32] > 1 && gd_name_is(rec, path, len)) {   /* not "." or ".." */
                    dir = le32(rec + 2);
                    dir_size = le32(rec + 10);
                    dir_flag = (rec[25] & 2) != 0;
                    found = 1;
                    break;
                }
                at += rec[0];
            }
        }
        if(!found) return -1;
        path = end;
        while(*path == '/') path++;
        if(*path && !dir_flag) return -1;
    }
    *extent = dir;
    *size = dir_size;
    *is_dir = dir_flag;
    return 0;
}

static void* gd_open(vfs_handler_t* vfs, const char* fn, int mode) {
    (void)vfs;
    if((mode & O_MODE_MASK) != O_RDONLY) { errno = EROFS; return NULL; }
    mutex_lock(&g_gd_lock);
    uint32_t extent, size;
    int is_dir;
    gd_file_t* f = NULL;
    if(gd_lookup(fn, &extent, &size, &is_dir) != 0) errno = ENOENT;
    else if(is_dir || (mode & O_DIR)) errno = is_dir ? EISDIR : ENOTDIR;
    else {
        for(int i = 0; i < GD_FILES; i++) if(!g_gd_files[i].used) { f = &g_gd_files[i]; break; }
        if(f) { f->used = 1; f->extent = extent; f->size = size; f->pos = 0; }
        else errno = EMFILE;
    }
    mutex_unlock(&g_gd_lock);
    return f;
}

static int gd_close(void* h) {
    mutex_lock(&g_gd_lock);
    ((gd_file_t*)h)->used = 0;
    mutex_unlock(&g_gd_lock);
    return 0;
}

/* Whole sectors into a 32-byte-aligned buffer go straight to the drive, by DMA, as many as there
 * are in one command — the read-ahead windows of dc_files.c are exactly that. The rest goes
 * through one cached sector. */
static ssize_t gd_read(void* h, void* buf, size_t cnt) {
    gd_file_t* f = (gd_file_t*)h;
    uint8_t* out = (uint8_t*)buf;
    ssize_t done = 0;
    mutex_lock(&g_gd_lock);
    if(cnt > f->size - f->pos) cnt = f->size - f->pos;
    while(cnt > 0) {
        const uint32_t lba = f->extent + f->pos / SECTOR;
        const uint32_t in = f->pos % SECTOR;
        if(in == 0 && cnt >= SECTOR && ((uintptr_t)out & 31) == 0) {
            const size_t n = cnt / SECTOR;
            if(cdrom_read_sectors_ex(out, lba + TOC_OFFSET, n, READ_DMA) != 0) goto failed;
            out += n * SECTOR;
            f->pos += (uint32_t)(n * SECTOR);
            done += (ssize_t)(n * SECTOR);
            cnt -= n * SECTOR;
        } else {
            size_t n = SECTOR - in;
            if(n > cnt) n = cnt;
            if(gd_sector(lba) != 0) goto failed;
            memcpy(out, g_gd_sector + in, n);
            out += n;
            f->pos += (uint32_t)n;
            done += (ssize_t)n;
            cnt -= n;
        }
    }
    mutex_unlock(&g_gd_lock);
    return done;
failed:
    mutex_unlock(&g_gd_lock);
    errno = EIO;
    return done > 0 ? done : -1;
}

static off_t gd_seek(void* h, off_t offset, int whence) {
    gd_file_t* f = (gd_file_t*)h;
    mutex_lock(&g_gd_lock);
    off_t to = offset;
    if(whence == SEEK_CUR) to += (off_t)f->pos;
    else if(whence == SEEK_END) to += (off_t)f->size;
    else {}
    if(to < 0) to = 0;
    else if(to > (off_t)f->size) to = (off_t)f->size;
    else {}
    f->pos = (uint32_t)to;
    mutex_unlock(&g_gd_lock);
    return to;
}

static off_t gd_tell(void* h) { return (off_t)((gd_file_t*)h)->pos; }

static size_t gd_total(void* h) { return ((gd_file_t*)h)->size; }

static vfs_handler_t g_gd_vfs = {
    .nmmgr = { "/cd", 0, 0x00010000, 0, NMMGR_TYPE_VFS, NMMGR_LIST_INIT },
    .open = gd_open,
    .close = gd_close,
    .read = gd_read,
    .seek = gd_seek,
    .tell = gd_tell,
    .total = gd_total
};

void gdrom_mount(void) {
    int status = 0, type = 0;
    if(cdrom_get_status(&status, &type) != 0 || type != DISC_GDROM) return;

    gd_toc_t toc;
    if(cdrom_read_toc((void*)&toc, 1) != 0) {
        bp_log(BP_LOG_WARN, "GD-ROM: no high-density table of contents; /cd stays KallistiOS's");
        return;
    }
    const uint32_t track = cdrom_locate_data_track((void*)&toc);   /* the TOC's sector number */
    if(track < TOC_OFFSET) {
        bp_log(BP_LOG_WARN, "GD-ROM: no data track in the high-density area; /cd stays KallistiOS's");
        return;
    }

    /* The primary volume descriptor, sector 16 of the track: type 1, "CD001", the root
     * directory's record at byte 156. */
    mutex_lock(&g_gd_lock);
    const int ok = gd_sector(track - TOC_OFFSET + 16) == 0 && g_gd_sector[0] == 1
        && memcmp(g_gd_sector + 1, "CD001", 5) == 0;
    if(ok) {
        g_gd_root = le32(g_gd_sector + 156 + 2);
        g_gd_root_size = le32(g_gd_sector + 156 + 10);
    } else {}
    mutex_unlock(&g_gd_lock);
    if(!ok) {
        bp_log(BP_LOG_WARN, "GD-ROM: no ISO9660 volume in the high-density area; /cd stays KallistiOS's");
        return;
    }

    fs_iso9660_shutdown();
    if(nmmgr_handler_add(&g_gd_vfs.nmmgr) != 0) {
        bp_log(BP_LOG_ERROR, "GD-ROM: could not mount the high-density area at /cd");
        return;
    }
    char msg[96];
    snprintf(msg, sizeof(msg), "GD-ROM: /cd is the high-density area (track at LBA %u)",
        (unsigned)(track - TOC_OFFSET));
    bp_log(BP_LOG_INFO, msg);
}
