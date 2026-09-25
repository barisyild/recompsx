/* backend_null.c — the smallest honest implementation of backend_c_api.h.
 *
 * No window, no audio, no input, no disc. Logging works; everything else reports its absence
 * rather than pretending. Two uses:
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

static int          g_argc;
static const char** g_argv;

void bp_set_args(int argc, const char** argv) { g_argc = argc; g_argv = argv; }
int  bp_arg_count(void) { return g_argc; }
const char* bp_arg(int index) { return (index >= 0 && index < g_argc) ? g_argv[index] : NULL; }

int  bp_init(const char* title) { (void)title; return 0; }
void bp_shutdown(void) {}

int bp_caps(int cap_id) {
    switch (cap_id) {
        case BP_CAP_MAX_PADS: return 4;   /* pads are simulated from replay data, not hardware */
        default:              return 0;
    }
}

void bp_present(const uint16_t* vram, int sx, int sy, int sw, int sh, int flags) {
    (void)vram; (void)sx; (void)sy; (void)sw; (void)sh; (void)flags;
}

/* No rasteriser here, and bp_caps says so, so the runtime never calls these. They exist because
 * the ABI is the contract and a backend answers all of it. */
void bp_gpu_vram(const uint16_t* vram) { (void)vram; }
void bp_gpu_state(int tex_base_x, int tex_base_y, int tex_depth,
                  int clut_x, int clut_y, int semi_mode, int flags, int tex_window,
                  int draw_x, int draw_y) {
    (void)tex_base_x; (void)tex_base_y; (void)tex_depth;
    (void)clut_x; (void)clut_y; (void)semi_mode; (void)flags; (void)tex_window;
    (void)draw_x; (void)draw_y;
}
void bp_gpu_tri(int x0, int y0, int c0, int u0, int v0,
                int x1, int y1, int c1, int u1, int v1,
                int x2, int y2, int c2, int u2, int v2) {
    (void)x0; (void)y0; (void)c0; (void)u0; (void)v0;
    (void)x1; (void)y1; (void)c1; (void)u1; (void)v1;
    (void)x2; (void)y2; (void)c2; (void)u2; (void)v2;
}
void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode) {
    (void)x; (void)y; (void)w; (void)h; (void)bgr; (void)semi; (void)semi_mode;
}
void bp_gpu_dirty(int x, int y, int w, int h) { (void)x; (void)y; (void)w; (void)h; }
void bp_gpu_clip(int x0, int y0, int x1, int y1) { (void)x0; (void)y0; (void)x1; (void)y1; }
void bp_gpu_mask(int set_bit, int check_bit) { (void)set_bit; (void)check_bit; }

void bp_audio_push(const int16_t* frames, int frame_count) { (void)frames; (void)frame_count; }
int  bp_audio_buffered(void) { return 0; }

void     bp_input_poll(void) {}
int      bp_pad_connected(int pad) { (void)pad; return 0; }
int      bp_pad_type(int pad) { (void)pad; return BP_PAD_NONE; }
uint32_t bp_pad_buttons(int pad) { (void)pad; return 0u; }
int      bp_pad_axis(int pad, int axis) { (void)pad; (void)axis; return 0x80; }
int      bp_quit_requested(void) { return 0; }

int bp_storage_read(const char* name, uint8_t* buf, int len) {
    (void)name; (void)buf; (void)len; return -1;
}
int bp_storage_write(const char* name, const uint8_t* buf, int len) {
    (void)name; (void)buf; (void)len; return -1;
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
