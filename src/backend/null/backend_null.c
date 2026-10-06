/* backend_null.c — the smallest honest implementation of backend_c_api.h.
 *
 * No window, no audio, no input; files are read with stdio, so a game runs headless. Logging
 * works; everything else reports its absence rather than pretending. Two uses:
 *
 *   - Conformance tests and CI, where the digest is the output and a window would be noise.
 *   - The first hour of a new platform port: build against this, confirm the emulator runs
 *     headless, then fill in the functions one at a time. If a platform cannot do audio yet,
 *     leaving bp_audio_push as a no-op is a supported state, not a broken build.
 *
 * That second use is the real argument for keeping it: it proves the ABI is genuinely
 * substitutable rather than SDL-shaped.
 */

#include "backend_c_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int          g_argc;
static const char** g_argv;

/* `--gpu-hash N`: this backend says it draws (BP_CAP_GPU_DRAW), so a run with `--video-hw` takes
 * the runtime's hardware path, and every bp_gpu_* call folds its arguments into one FNV-1a hash,
 * printed when the run ends at its Nth present. Two builds that print the same hash handed a
 * backend the same primitives and state in the same order: how a change to that path is shown to
 * change nothing. (`--headless-hash` cannot stop it: a run that hashes emulated VRAM never takes
 * the hardware path, since the backend then draws what the software rasteriser would have.) */
static int      g_gpu_hashing, g_gpu_frames;
static long     g_gpu_presents, g_gpu_stop;
/* FNV-1a's offset basis with its last digit missing (14695981039346656037): kept, since every hash
 * recorded so far was made from it, and the JavaScript shim's `--gpu-hash` starts from it too. */
static uint64_t g_gpu_hash = 1469598103934665603ull;
static uint64_t g_gpu_calls;
static uint64_t g_gpu_trace;      /* `--gpu-hash-trace N`: the first N calls printed, value by value */

static void gpu_mix(int v) {
    if (g_gpu_calls <= g_gpu_trace) printf(" %d", v);
    for (int k = 0; k < 4; k++) {
        g_gpu_hash ^= (uint64_t)((unsigned)v >> (8 * k) & 0xFFu);
        g_gpu_hash *= 1099511628211ull;
    }
}
static void gpu_call(int tag) {
    g_gpu_calls++;
    if (g_gpu_calls <= g_gpu_trace) printf("\ngpu-call %llu:", (unsigned long long)g_gpu_calls);
    gpu_mix(tag);
}
static void gpu_hash_report(void) {
    printf("[info] gpu-stream hash %016llx over %llu calls\n",
           (unsigned long long)g_gpu_hash, (unsigned long long)g_gpu_calls);
    fflush(stdout);
}

void bp_set_args(int argc, const char** argv) {
    g_argc = argc; g_argv = argv;
    /* `--gpu-hash-frames` as well: the running hash at every present, one line each, to find the
     * first frame at which two builds — two targets — hand the backend different things. */
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--gpu-hash-frames") == 0) g_gpu_frames = 1;
        if (strcmp(argv[i], "--gpu-hash-trace") == 0 && i + 1 < argc)
            g_gpu_trace = strtoull(argv[i + 1], NULL, 10);
    }
    for (int i = 0; i < argc; i++)
        if (argv[i][0] == '-' && argv[i][1] == '-' && argv[i][2] == 'g' && argv[i][3] == 'p'
            && argv[i][4] == 'u' && argv[i][5] == '-' && argv[i][6] == 'h' && argv[i][7] == 'a'
            && argv[i][8] == 's' && argv[i][9] == 'h' && argv[i][10] == 0 && !g_gpu_hashing) {
            g_gpu_hashing = 1;
            g_gpu_stop = i + 1 < argc ? strtol(argv[i + 1], NULL, 10) : 0;
            atexit(gpu_hash_report);
        }
}
int  bp_arg_count(void) { return g_argc; }
const char* bp_arg(int index) { return (index >= 0 && index < g_argc) ? g_argv[index] : NULL; }

int  bp_init(const char* title) { (void)title; return 0; }
void bp_shutdown(void) {}

void bp_exit_to_menu(void) {
    exit(0);
}

int bp_caps(int cap_id) {
    switch (cap_id) {
        case BP_CAP_MAX_PADS: return 4;   /* pads are simulated from replay data, not hardware */
        case BP_CAP_GPU_DRAW: return g_gpu_hashing;
        default:              return 0;
    }
}

void bp_present(const uint16_t* vram, int sx, int sy, int sw, int sh, int flags) {
    (void)vram; (void)sx; (void)sy; (void)sw; (void)sh; (void)flags;
    if (g_gpu_hashing && g_gpu_stop > 0) {
        ++g_gpu_presents;
        if (g_gpu_frames)
            printf("gpu-frame %ld %016llx %llu\n", g_gpu_presents, (unsigned long long)g_gpu_hash,
                   (unsigned long long)g_gpu_calls);
        if (g_gpu_presents >= g_gpu_stop) exit(0);
    }
}

/* No rasteriser here, and bp_caps says so, so the runtime never calls these — unless `--gpu-hash`
 * asked for their stream to be hashed (above). They exist because the ABI is the contract and a
 * backend answers all of it. */
void bp_gpu_vram(const uint16_t* vram) { (void)vram; }
void bp_gpu_state(int tex_base_x, int tex_base_y, int tex_depth,
                  int clut_x, int clut_y, int semi_mode, int flags, int tex_window,
                  int draw_x, int draw_y) {
    if (!g_gpu_hashing) return;
    gpu_call(2); gpu_mix(tex_base_x); gpu_mix(tex_base_y); gpu_mix(tex_depth); gpu_mix(clut_x);
    gpu_mix(clut_y); gpu_mix(semi_mode); gpu_mix(flags); gpu_mix(tex_window); gpu_mix(draw_x);
    gpu_mix(draw_y);
}

void bp_gpu_state_w(const int* w) {
    bp_gpu_state(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9]);
}

/* Only an SH-4 polygon core that writes the backend's records itself calls this (ADR-0051); here no
 * core runs, every triangle comes through bp_gpu_tri_w, and this is the state alone. */
void bp_gpu_state_after_tri(const int* w) {
    bp_gpu_state_w(w);
}
void bp_gpu_tri(int x0, int y0, int c0, int u0, int v0,
                int x1, int y1, int c1, int u1, int v1,
                int x2, int y2, int c2, int u2, int v2) {
    if (!g_gpu_hashing) return;
    gpu_call(1); gpu_mix(x0); gpu_mix(y0); gpu_mix(c0); gpu_mix(u0); gpu_mix(v0);
    gpu_mix(x1); gpu_mix(y1); gpu_mix(c1); gpu_mix(u1); gpu_mix(v1);
    gpu_mix(x2); gpu_mix(y2); gpu_mix(c2); gpu_mix(u2); gpu_mix(v2);
}

void bp_gpu_tri_w(const int* w) {
    bp_gpu_tri(w[0], w[1], w[2] & 0xFFFFFF, w[3] & 0xFF, (w[3] >> 8) & 0xFF,
               w[4], w[5], w[6] & 0xFFFFFF, w[7] & 0xFF, (w[7] >> 8) & 0xFF,
               w[8], w[9], w[10] & 0xFFFFFF, w[11] & 0xFF, (w[11] >> 8) & 0xFF);
}
void bp_gpu_sprite(int x, int y, int w, int h, int u, int v, int bgr, int flip) {
    (void)x; (void)y; (void)w; (void)h; (void)u; (void)v; (void)bgr; (void)flip;
}

void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode) {
    if (!g_gpu_hashing) return;
    gpu_call(3); gpu_mix(x); gpu_mix(y); gpu_mix(w); gpu_mix(h); gpu_mix(bgr); gpu_mix(semi);
    gpu_mix(semi_mode);
}
void bp_gpu_dirty(int x, int y, int w, int h) {
    if (!g_gpu_hashing) return;
    gpu_call(4); gpu_mix(x); gpu_mix(y); gpu_mix(w); gpu_mix(h);
}
/* Never offered (bp_caps answers 0 for BP_CAP_GPU_COPIES), so a hashed run's copies arrive as
 * bp_gpu_dirty, as they did before ADR-0054; hashed as the browser's shim hashes them otherwise. */
void bp_gpu_copy(int sx, int sy, int dx, int dy, int w, int h, int changed) {
    if (!g_gpu_hashing) return;
    gpu_call(7); gpu_mix(sx); gpu_mix(sy); gpu_mix(dx); gpu_mix(dy); gpu_mix(w); gpu_mix(h);
    gpu_mix(changed);
}
void bp_gpu_clip(int x0, int y0, int x1, int y1) {
    if (!g_gpu_hashing) return;
    gpu_call(5); gpu_mix(x0); gpu_mix(y0); gpu_mix(x1); gpu_mix(y1);
}
void bp_gpu_mask(int set_bit, int check_bit) {
    if (!g_gpu_hashing) return;
    gpu_call(6); gpu_mix(set_bit); gpu_mix(check_bit);
}
/* Never offered (BP_CAP_GPU_SCALE is 0), and the picture's resolution is not the stream's to hash. */
void bp_gpu_scale(int percent) { (void)percent; }

void bp_audio_push(const int16_t* frames, int frame_count) { (void)frames; (void)frame_count; }
int  bp_audio_buffered(void) { return 0; }

void     bp_input_poll(void) {}
int      bp_pad_connected(int pad) { (void)pad; return 0; }
int      bp_pad_type(int pad) { (void)pad; return BP_PAD_NONE; }
uint32_t bp_pad_buttons(int pad) { (void)pad; return 0u; }
int      bp_pad_axis(int pad, int axis) { (void)pad; (void)axis; return 0x80; }
void     bp_pad_rumble(int pad, int small, int large) { (void)pad; (void)small; (void)large; }
int      bp_quit_requested(void) { return 0; }

/* No keyboard: text entry is accepted and nothing is ever typed. */
void bp_key_text(int on) { (void)on; }
int  bp_key_next(void) { return -1; }

/* No mouse: never over the picture, nothing held. */
int bp_mouse(int field) { (void)field; return 0; }
void bp_mouse_pointer(int state) { (void)state; }
/* No network: the i-mode adaptor's phone finds none (ADR-0040). */
int  bp_http_open(const char* host, int port, const uint8_t* request, int len) { (void)host; (void)port; (void)request; (void)len; return -1; }
int  bp_http_read(int handle, uint8_t* buf, int cap) { (void)handle; (void)buf; (void)cap; return -2; }
void bp_http_close(int handle) { (void)handle; }

int bp_storage_read(const char* name, uint8_t* buf, int len) {
    (void)name; (void)buf; (void)len; return -1;
}
int bp_storage_write(const char* name, const uint8_t* buf, int len) {
    (void)name; (void)buf; (void)len; return -1;
}

/* No card is kept either: every run starts with a blank one, as a headless run does. */
int bp_card_load(const char* game, uint8_t* buf, int cap) {
    (void)game; (void)buf; (void)cap; return -1;
}
int bp_card_save(const char* game, const char* title, const uint8_t* buf, int len) {
    (void)game; (void)title; (void)buf; (void)len; return -1;
}

/* Files do work here: a headless run still needs to read a disc image. */
static FILE* g_files[8];
static int   g_file_size[8];

int bp_file_open(int slot, const char* path) {
    if (slot < 0 || slot >= 8 || !path) return -1;
    bp_file_close(slot);
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    const long size = ftell(f);
    if (size < 0) { fclose(f); return -1; }
    g_files[slot] = f;
    g_file_size[slot] = (int)size;
    return 0;
}

int bp_file_size(int slot) {
    if (slot < 0 || slot >= 8 || !g_files[slot]) return -1;
    return g_file_size[slot];
}

int bp_file_read(int slot, int offset, uint8_t* buf, int len) {
    if (slot < 0 || slot >= 8 || !g_files[slot] || offset < 0 || len <= 0) return -1;
    if (fseek(g_files[slot], offset, SEEK_SET) != 0) return -1;
    return (int)fread(buf, 1, (size_t)len, g_files[slot]);
}

void bp_file_close(int slot) {
    if (slot < 0 || slot >= 8) return;
    if (g_files[slot]) { fclose(g_files[slot]); g_files[slot] = NULL; g_file_size[slot] = 0; }
}

/* Time exists but nothing paces: a headless run should finish as fast as it can. */
uint64_t bp_time_us(void) { return 0; }
void     bp_sleep_us(uint64_t us) { (void)us; }
void     bp_pace_frame(int target_us) { (void)target_us; }
void bp_profile_mark(int section, int begin) { (void)section; (void)begin; }
void bp_spu_ram(const uint8_t* ram) { (void)ram; }
void bp_spu_dirty(int addr, int len) { (void)addr; (void)len; }
int bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r) {
    (void)v; (void)key; (void)on; (void)start; (void)pitch; (void)vol_l; (void)vol_r;
    return 0;   /* no sampler: every voice stays in the software mix */
}

void bp_log(int level, const char* msg) {
    static const char* names[] = { "debug", "info", "warn", "error" };
    const char* n = (level >= 0 && level <= 3) ? names[level] : "?";
    printf("[%s] %s\n", n, msg ? msg : "");
    fflush(stdout);
}

void bp_fatal(const char* msg) {
    bp_log(BP_LOG_ERROR, msg);
    exit(1);
}
