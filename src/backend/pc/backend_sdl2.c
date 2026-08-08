/* backend_sdl2.c — the desktop implementation of backend_c_api.h.
 *
 * This is the ONLY file in the project that includes SDL. Everything platform-specific about
 * running on macOS, Linux or Windows is here; a console port replaces this file and nothing
 * else. Keep it boring: no emulation logic belongs here, and nothing here may influence
 * emulated state.
 */

#include "backend_c_api.h"

#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* PS1 VRAM geometry. Fixed by the hardware, not a preference. */
#define VRAM_W 1024
#define VRAM_H 512

#define MAX_PADS   4
#define MAX_FILES  8

static SDL_Window*     g_window;
static SDL_Renderer*   g_renderer;
static SDL_Texture*    g_texture;         /* streaming, VRAM_W x VRAM_H, RGBA8888 */
static SDL_AudioDeviceID g_audio;

static SDL_GameController* g_pads[MAX_PADS];
static uint32_t g_pad_buttons[MAX_PADS];
static uint8_t  g_pad_axes[MAX_PADS][4];
static int      g_pad_type[MAX_PADS];
static uint32_t g_keyboard_buttons;        /* merged into pad 0 */
static int      g_quit;

static FILE* g_files[MAX_FILES];
static int   g_file_size[MAX_FILES];

static int          g_argc;
static const char** g_argv;
static char         g_pref_path[1024];

/* Scratch buffer for the converted frame. Allocated once; never resized. */
static uint32_t* g_pixels;

/* PS1 controller bit layout, active high on this side of the API.
 * (The runtime inverts when it builds the SIO0 response — that is emulation, not platform.) */
enum {
    PAD_SELECT = 1 << 0,  PAD_L3     = 1 << 1,  PAD_R3    = 1 << 2,  PAD_START = 1 << 3,
    PAD_UP     = 1 << 4,  PAD_RIGHT  = 1 << 5,  PAD_DOWN  = 1 << 6,  PAD_LEFT  = 1 << 7,
    PAD_L2     = 1 << 8,  PAD_R2     = 1 << 9,  PAD_L1    = 1 << 10, PAD_R1    = 1 << 11,
    PAD_TRIANGLE = 1 << 12, PAD_CIRCLE = 1 << 13, PAD_CROSS = 1 << 14, PAD_SQUARE = 1 << 15
};

void bp_set_args(int argc, const char** argv);   /* called by main_pc.cpp before bp_init */

void bp_set_args(int argc, const char** argv) {
    g_argc = argc;
    g_argv = argv;
}

int bp_arg_count(void) { return g_argc; }

const char* bp_arg(int index) {
    if (index < 0 || index >= g_argc) return NULL;
    return g_argv[index];
}

/* ---- lifecycle ---------------------------------------------------------------------------- */

int bp_init(const char* title) {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMECONTROLLER) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    g_window = SDL_CreateWindow(title ? title : "recompsx",
                                SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                960, 720, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!g_window) { fprintf(stderr, "CreateWindow failed: %s\n", SDL_GetError()); return 2; }

    /* Deliberately no SDL_RENDERER_PRESENTVSYNC: the emulator core owns pacing. Letting the
     * host's refresh rate throttle us would couple emulated time to the display. */
    g_renderer = SDL_CreateRenderer(g_window, -1, SDL_RENDERER_ACCELERATED);
    if (!g_renderer) { fprintf(stderr, "CreateRenderer failed: %s\n", SDL_GetError()); return 3; }

    g_texture = SDL_CreateTexture(g_renderer, SDL_PIXELFORMAT_ARGB8888,
                                  SDL_TEXTUREACCESS_STREAMING, VRAM_W, VRAM_H);
    if (!g_texture) { fprintf(stderr, "CreateTexture failed: %s\n", SDL_GetError()); return 4; }

    g_pixels = (uint32_t*)calloc((size_t)VRAM_W * VRAM_H, sizeof(uint32_t));
    if (!g_pixels) return 5;

    SDL_AudioSpec want, have;
    SDL_zero(want);
    want.freq = 44100;
    want.format = AUDIO_S16SYS;
    want.channels = 2;
    want.samples = 1024;
    g_audio = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (g_audio) SDL_PauseAudioDevice(g_audio, 0);
    else fprintf(stderr, "audio unavailable: %s\n", SDL_GetError());

    char* pref = SDL_GetPrefPath("recompsx", title ? title : "default");
    if (pref) {
        snprintf(g_pref_path, sizeof(g_pref_path), "%s", pref);
        SDL_free(pref);
    }

    for (int i = 0; i < SDL_NumJoysticks() && i < MAX_PADS; i++) {
        if (SDL_IsGameController(i)) {
            g_pads[i] = SDL_GameControllerOpen(i);
            if (g_pads[i]) g_pad_type[i] = BP_PAD_ANALOG;
        }
    }
    /* Pad 0 always exists: the keyboard stands in for it. */
    if (!g_pads[0]) g_pad_type[0] = BP_PAD_DIGITAL;

    return 0;
}

void bp_shutdown(void) {
    for (int i = 0; i < MAX_FILES; i++) bp_file_close(i);
    for (int i = 0; i < MAX_PADS; i++) if (g_pads[i]) SDL_GameControllerClose(g_pads[i]);
    if (g_audio)    SDL_CloseAudioDevice(g_audio);
    if (g_pixels)   { free(g_pixels); g_pixels = NULL; }
    if (g_texture)  SDL_DestroyTexture(g_texture);
    if (g_renderer) SDL_DestroyRenderer(g_renderer);
    if (g_window)   SDL_DestroyWindow(g_window);
    SDL_Quit();
}

int bp_caps(int cap_id) {
    switch (cap_id) {
        case BP_CAP_MAX_PADS:        return MAX_PADS;
        case BP_CAP_HAS_AUDIO:       return g_audio != 0;
        case BP_CAP_HAS_STORAGE:     return 1;
        case BP_CAP_PREFERRED_SCALE: return 2;
        default:                     return 0;
    }
}

/* ---- video -------------------------------------------------------------------------------- */

static void convert_15bpp(const uint16_t* vram, int sx, int sy, int sw, int sh) {
    for (int y = 0; y < sh; y++) {
        const uint16_t* src = vram + (size_t)((sy + y) & (VRAM_H - 1)) * VRAM_W;
        uint32_t* dst = g_pixels + (size_t)y * VRAM_W;
        for (int x = 0; x < sw; x++) {
            const uint16_t p = src[(sx + x) & (VRAM_W - 1)];
            /* BGR555 -> ARGB8888, replicating the top bits so white stays white. */
            const uint32_t r = (uint32_t)((p      ) & 0x1F);
            const uint32_t g = (uint32_t)((p >>  5) & 0x1F);
            const uint32_t b = (uint32_t)((p >> 10) & 0x1F);
            dst[x] = 0xFF000000u
                   | (((r << 3) | (r >> 2)) << 16)
                   | (((g << 3) | (g >> 2)) <<  8)
                   |  ((b << 3) | (b >> 2));
        }
    }
}

static void convert_24bpp(const uint16_t* vram, int sx, int sy, int sw, int sh) {
    for (int y = 0; y < sh; y++) {
        const uint8_t* src = (const uint8_t*)(vram + (size_t)((sy + y) & (VRAM_H - 1)) * VRAM_W)
                           + (size_t)sx * 2;
        uint32_t* dst = g_pixels + (size_t)y * VRAM_W;
        for (int x = 0; x < sw; x++) {
            dst[x] = 0xFF000000u | ((uint32_t)src[0] << 16) | ((uint32_t)src[1] << 8) | src[2];
            src += 3;
        }
    }
}

void bp_present(const uint16_t* vram, int sx, int sy, int sw, int sh, int flags) {
    if (!g_renderer || sw <= 0 || sh <= 0) return;
    if (sw > VRAM_W) sw = VRAM_W;
    if (sh > VRAM_H) sh = VRAM_H;

    if (flags & BP_PRESENT_24BPP) convert_24bpp(vram, sx, sy, sw, sh);
    else                          convert_15bpp(vram, sx, sy, sw, sh);

    const SDL_Rect src = { 0, 0, sw, sh };
    SDL_UpdateTexture(g_texture, &src, g_pixels, VRAM_W * (int)sizeof(uint32_t));

    int win_w, win_h;
    SDL_GetRendererOutputSize(g_renderer, &win_w, &win_h);

    /* Every PS1 horizontal resolution covers the same physical width, so the picture is 4:3
     * regardless of sw. Letterbox to 4:3 and centre; integer-scale when it fits exactly. */
    int dst_w = win_w, dst_h = (win_w * 3) / 4;
    if (dst_h > win_h) { dst_h = win_h; dst_w = (win_h * 4) / 3; }

    const SDL_Rect dst = { (win_w - dst_w) / 2, (win_h - dst_h) / 2, dst_w, dst_h };
    SDL_SetRenderDrawColor(g_renderer, 0, 0, 0, 255);
    SDL_RenderClear(g_renderer);
    SDL_RenderCopy(g_renderer, g_texture, &src, &dst);
    SDL_RenderPresent(g_renderer);
}

/* ---- audio -------------------------------------------------------------------------------- */

void bp_audio_push(const int16_t* frames, int frame_count) {
    if (!g_audio || frame_count <= 0) return;
    SDL_QueueAudio(g_audio, frames, (Uint32)frame_count * 4u);
}

int bp_audio_buffered(void) {
    if (!g_audio) return 0;
    return (int)(SDL_GetQueuedAudioSize(g_audio) / 4u);
}

/* ---- input -------------------------------------------------------------------------------- */

static uint32_t key_to_button(SDL_Keycode k) {
    switch (k) {
        case SDLK_UP:     return PAD_UP;
        case SDLK_DOWN:   return PAD_DOWN;
        case SDLK_LEFT:   return PAD_LEFT;
        case SDLK_RIGHT:  return PAD_RIGHT;
        case SDLK_x:      return PAD_CROSS;
        case SDLK_s:      return PAD_SQUARE;
        case SDLK_z:      return PAD_TRIANGLE;
        case SDLK_a:      return PAD_CIRCLE;
        case SDLK_q:      return PAD_L1;
        case SDLK_w:      return PAD_R1;
        case SDLK_1:      return PAD_L2;
        case SDLK_2:      return PAD_R2;
        case SDLK_RETURN: return PAD_START;
        case SDLK_RSHIFT: return PAD_SELECT;
        default:          return 0;
    }
}

static uint32_t controller_buttons(SDL_GameController* c) {
    uint32_t b = 0;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_DPAD_UP))    b |= PAD_UP;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_DPAD_DOWN))  b |= PAD_DOWN;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_DPAD_LEFT))  b |= PAD_LEFT;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_DPAD_RIGHT)) b |= PAD_RIGHT;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_A))          b |= PAD_CROSS;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_B))          b |= PAD_CIRCLE;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_X))          b |= PAD_SQUARE;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_Y))          b |= PAD_TRIANGLE;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_LEFTSHOULDER))  b |= PAD_L1;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)) b |= PAD_R1;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_START))      b |= PAD_START;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_BACK))       b |= PAD_SELECT;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_LEFTSTICK))  b |= PAD_L3;
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_RIGHTSTICK)) b |= PAD_R3;
    if (SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_TRIGGERLEFT)  > 16384) b |= PAD_L2;
    if (SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 16384) b |= PAD_R2;
    return b;
}

static uint8_t axis_to_byte(Sint16 v) { return (uint8_t)(((int)v + 32768) >> 8); }

void bp_input_poll(void) {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        switch (e.type) {
            case SDL_QUIT:
                g_quit = 1;
                break;
            case SDL_KEYDOWN:
                if (e.key.keysym.sym == SDLK_ESCAPE) g_quit = 1;
                g_keyboard_buttons |= key_to_button(e.key.keysym.sym);
                break;
            case SDL_KEYUP:
                g_keyboard_buttons &= ~key_to_button(e.key.keysym.sym);
                break;
            case SDL_CONTROLLERDEVICEADDED: {
                const int i = e.cdevice.which;
                if (i >= 0 && i < MAX_PADS && !g_pads[i] && SDL_IsGameController(i)) {
                    g_pads[i] = SDL_GameControllerOpen(i);
                    if (g_pads[i]) g_pad_type[i] = BP_PAD_ANALOG;
                }
                break;
            }
            case SDL_CONTROLLERDEVICEREMOVED:
                for (int i = 0; i < MAX_PADS; i++) {
                    if (g_pads[i] && SDL_GameControllerFromInstanceID(e.cdevice.which) == g_pads[i]) {
                        SDL_GameControllerClose(g_pads[i]);
                        g_pads[i] = NULL;
                        g_pad_type[i] = (i == 0) ? BP_PAD_DIGITAL : BP_PAD_NONE;
                    }
                }
                break;
            default:
                break;
        }
    }

    /* Latch a stable snapshot: accessors must not see input shift mid-frame. */
    for (int i = 0; i < MAX_PADS; i++) {
        uint32_t b = 0;
        if (g_pads[i]) {
            b = controller_buttons(g_pads[i]);
            g_pad_axes[i][0] = axis_to_byte(SDL_GameControllerGetAxis(g_pads[i], SDL_CONTROLLER_AXIS_LEFTX));
            g_pad_axes[i][1] = axis_to_byte(SDL_GameControllerGetAxis(g_pads[i], SDL_CONTROLLER_AXIS_LEFTY));
            g_pad_axes[i][2] = axis_to_byte(SDL_GameControllerGetAxis(g_pads[i], SDL_CONTROLLER_AXIS_RIGHTX));
            g_pad_axes[i][3] = axis_to_byte(SDL_GameControllerGetAxis(g_pads[i], SDL_CONTROLLER_AXIS_RIGHTY));
        } else {
            g_pad_axes[i][0] = g_pad_axes[i][1] = g_pad_axes[i][2] = g_pad_axes[i][3] = 0x80;
        }
        if (i == 0) b |= g_keyboard_buttons;
        g_pad_buttons[i] = b;
    }
}

int      bp_pad_connected(int pad) {
    if (pad < 0 || pad >= MAX_PADS) return 0;
    return (pad == 0 || g_pads[pad] != NULL) ? 1 : 0;
}
int      bp_pad_type(int pad)      { return (pad >= 0 && pad < MAX_PADS) ? g_pad_type[pad] : BP_PAD_NONE; }
uint32_t bp_pad_buttons(int pad)   { return (pad >= 0 && pad < MAX_PADS) ? g_pad_buttons[pad] : 0u; }
int      bp_quit_requested(void)   { return g_quit; }

int bp_pad_axis(int pad, int axis) {
    if (pad < 0 || pad >= MAX_PADS || axis < 0 || axis > 3) return 0x80;
    return g_pad_axes[pad][axis];
}

/* ---- storage ------------------------------------------------------------------------------ */

static int storage_path(const char* name, char* out, size_t out_len) {
    if (!name || !*name) return 0;
    for (const char* p = name; *p; p++) {
        const char c = *p;
        const int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                    || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) return 0;   /* reject anything that could escape the directory */
    }
    snprintf(out, out_len, "%s%s", g_pref_path[0] ? g_pref_path : "./", name);
    return 1;
}

int bp_storage_read(const char* name, uint8_t* buf, int len) {
    char path[1200];
    if (!storage_path(name, path, sizeof(path))) return -1;
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    const size_t n = fread(buf, 1, (size_t)len, f);
    fclose(f);
    return (int)n;
}

int bp_storage_write(const char* name, const uint8_t* buf, int len) {
    char path[1200], tmp[1264];
    if (!storage_path(name, path, sizeof(path))) return -1;
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);

    /* Write to a temporary file and rename: a crash mid-write must never corrupt a save. */
    FILE* f = fopen(tmp, "wb");
    if (!f) return -1;
    const size_t n = fwrite(buf, 1, (size_t)len, f);
    const int flushed = (fflush(f) == 0);
    fclose(f);
    if (n != (size_t)len || !flushed) { remove(tmp); return -1; }
    if (rename(tmp, path) != 0) { remove(tmp); return -1; }
    return 0;
}

/* ---- disc / file streaming ---------------------------------------------------------------- */

int bp_file_open(int slot, const char* path) {
    if (slot < 0 || slot >= MAX_FILES || !path) return -1;
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
    if (slot < 0 || slot >= MAX_FILES || !g_files[slot]) return -1;
    return g_file_size[slot];
}

int bp_file_read(int slot, int offset, uint8_t* buf, int len) {
    if (slot < 0 || slot >= MAX_FILES || !g_files[slot] || offset < 0 || len <= 0) return -1;
    if (fseek(g_files[slot], offset, SEEK_SET) != 0) return -1;
    return (int)fread(buf, 1, (size_t)len, g_files[slot]);
}

void bp_file_close(int slot) {
    if (slot < 0 || slot >= MAX_FILES) return;
    if (g_files[slot]) { fclose(g_files[slot]); g_files[slot] = NULL; g_file_size[slot] = 0; }
}

/* ---- time and diagnostics ----------------------------------------------------------------- */

uint64_t bp_time_us(void) {
    const Uint64 freq = SDL_GetPerformanceFrequency();
    if (!freq) return 0;
    const Uint64 now = SDL_GetPerformanceCounter();
    /* Split to keep the multiply from overflowing on long sessions. */
    return (now / freq) * 1000000ull + ((now % freq) * 1000000ull) / freq;
}

void bp_sleep_us(uint64_t us) {
    if (us >= 1000ull) SDL_Delay((Uint32)(us / 1000ull));
}

void bp_pace_frame(int target_us) {
    static uint64_t next_deadline;
    const uint64_t now = bp_time_us();

    if (target_us <= 0 || next_deadline == 0) {   /* first call, or an explicit reset */
        next_deadline = now + (uint64_t)(target_us > 0 ? target_us : 0);
        return;
    }

    if (now < next_deadline) {
        const uint64_t wait = next_deadline - now;
        /* Sleep the bulk, then spin the remainder: SDL_Delay granularity is milliseconds, and
         * a whole millisecond of slop is visible at 60 Hz. */
        if (wait > 1500ull) SDL_Delay((Uint32)((wait - 1000ull) / 1000ull));
        while (bp_time_us() < next_deadline) { /* spin */ }
    }

    next_deadline += (uint64_t)target_us;

    /* If we fell far behind (a stall, or a debugger breakpoint), give up on catching up rather
     * than sprinting through frames the user will never see. */
    const uint64_t after = bp_time_us();
    if (next_deadline + (uint64_t)target_us * 4ull < after) next_deadline = after + (uint64_t)target_us;
}

void bp_log(int level, const char* msg) {
    static const char* names[] = { "debug", "info", "warn", "error" };
    const char* n = (level >= 0 && level <= 3) ? names[level] : "?";
    fprintf(level >= BP_LOG_WARN ? stderr : stdout, "[%s] %s\n", n, msg ? msg : "");
    if (level >= BP_LOG_WARN) fflush(stderr);
}

void bp_fatal(const char* msg) {
    bp_log(BP_LOG_ERROR, msg);
    if (g_window) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "recompsx", msg ? msg : "fatal error", g_window);
    }
    bp_shutdown();
    exit(1);
}
