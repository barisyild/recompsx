/* backend_sdl2.c — the desktop implementation of backend_c_api.h.
 *
 * This is the ONLY file in the project that includes SDL. Everything platform-specific about
 * running on macOS, Linux or Windows is here; a console port replaces this file and nothing
 * else. Keep it boring: no emulation logic belongs here, and nothing here may influence
 * emulated state.
 */

#include "backend_c_api.h"
#include "pointer_art.h"

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
/* The DualShock motors each pad runs (bp_pad_rumble), and when its effect was last sent. */
static int      g_rumble_small[MAX_PADS], g_rumble_large[MAX_PADS];
static Uint32   g_rumble_sent[MAX_PADS];
static uint32_t g_keyboard_buttons;        /* merged into pad 0 */
static int      g_quit;

#define TYPED_CAP 64                       /* a power of two */
static int g_typing;                       /* bp_key_text: the keyboard types */
static int g_typed[TYPED_CAP];
static int g_typed_head, g_typed_count;

static SDL_Rect g_picture;                 /* where bp_present last put the picture */
static int      g_mouse_over, g_mouse_x, g_mouse_y, g_mouse_buttons;
static int      g_mouse_pressed;           /* buttons that went down since the last poll */
static SDL_Cursor* g_pointer;              /* the machine's pointer as a cursor (bp_mouse_pointer) */

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
    /* A DualShock 4 or DualSense over Bluetooth rumbles only in its extended report mode, which
     * SDL leaves off unless asked (it changes what other programs see of the pad). */
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1");
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
    for (int i = 0; i < MAX_PADS; i++) {
        if (g_pads[i]) {
            SDL_GameControllerRumble(g_pads[i], 0, 0, 0);
            SDL_GameControllerClose(g_pads[i]);
        }
    }
    if (g_audio)    SDL_CloseAudioDevice(g_audio);
    if (g_pixels)   { free(g_pixels); g_pixels = NULL; }
    if (g_texture)  SDL_DestroyTexture(g_texture);
    if (g_renderer) SDL_DestroyRenderer(g_renderer);
    if (g_window)   SDL_DestroyWindow(g_window);
    if (g_pointer)  { SDL_FreeCursor(g_pointer); g_pointer = NULL; }
    SDL_Quit();
}

/* The desktop is the host's menu: the program exits. */
void bp_exit_to_menu(void) {
    bp_shutdown();
    exit(0);
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
    g_picture = dst;
    SDL_SetRenderDrawColor(g_renderer, 0, 0, 0, 255);
    SDL_RenderClear(g_renderer);
    SDL_RenderCopy(g_renderer, g_texture, &src, &dst);
    SDL_RenderPresent(g_renderer);
}

/* ---- hardware drawing -------------------------------------------------------------------------
 * SDL2 gets the finished picture, not the primitives: this backend answers 0 to BP_CAP_GPU_DRAW,
 * so the runtime never takes the fork and these are never called. They exist because the ABI is
 * the contract and a backend answers all of it — and because the day a desktop GPU path is
 * wanted, the seam is already here. */

void bp_gpu_vram(const uint16_t* vram) { (void)vram; }

void bp_gpu_state(int tex_base_x, int tex_base_y, int tex_depth,
                  int clut_x, int clut_y, int semi_mode, int flags, int tex_window,
                  int draw_x, int draw_y) {
    (void)tex_base_x; (void)tex_base_y; (void)tex_depth;
    (void)clut_x; (void)clut_y; (void)semi_mode; (void)flags; (void)tex_window;
    (void)draw_x; (void)draw_y;
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
    (void)x0; (void)y0; (void)c0; (void)u0; (void)v0;
    (void)x1; (void)y1; (void)c1; (void)u1; (void)v1;
    (void)x2; (void)y2; (void)c2; (void)u2; (void)v2;
}

void bp_gpu_tri_w(const int* w) {
    bp_gpu_tri(w[0], w[1], w[2] & 0xFFFFFF, w[3] & 0xFF, (w[3] >> 8) & 0xFF,
               w[4], w[5], w[6] & 0xFFFFFF, w[7] & 0xFF, (w[7] >> 8) & 0xFF,
               w[8], w[9], w[10] & 0xFFFFFF, w[11] & 0xFF, (w[11] >> 8) & 0xFF);
}

void bp_gpu_rect(int x, int y, int w, int h, int bgr, int semi, int semi_mode) {
    (void)x; (void)y; (void)w; (void)h; (void)bgr; (void)semi; (void)semi_mode;
}

void bp_gpu_dirty(int x, int y, int w, int h) { (void)x; (void)y; (void)w; (void)h; }
void bp_gpu_copy(int sx, int sy, int dx, int dy, int w, int h, int changed) {
    (void)sx; (void)sy; (void)dx; (void)dy; (void)w; (void)h; (void)changed;
}
void bp_gpu_clip(int x0, int y0, int x1, int y1) { (void)x0; (void)y0; (void)x1; (void)y1; }
void bp_gpu_mask(int set_bit, int check_bit) { (void)set_bit; (void)check_bit; }

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
    /* The centre button (PS, Xbox, Home) is the DualShock's ANALOG button (ADR-0052). */
    if (SDL_GameControllerGetButton(c, SDL_CONTROLLER_BUTTON_GUIDE))      b |= BP_PAD_ANALOG_BUTTON;
    if (SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_TRIGGERLEFT)  > 16384) b |= PAD_L2;
    if (SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 16384) b |= PAD_R2;
    return b;
}

static uint8_t axis_to_byte(Sint16 v) { return (uint8_t)(((int)v + 32768) >> 8); }

/* ---- motors (bp_pad_rumble) -------------------------------------------------------------------
 * The DualShock's large left motor is the controller's low-frequency one, its small right motor
 * the high-frequency one, on at full strength. SDL runs an effect for a set time, so a running
 * one is sent again from bp_input_poll before it ends: if the program stops polling, the pad
 * stops shaking within RUMBLE_MS. */
#define RUMBLE_MS    500
#define RUMBLE_RENEW 250

static void rumble_send(int i) {
    if (!g_pads[i]) return;
    const int on = g_rumble_small[i] || g_rumble_large[i];
    SDL_GameControllerRumble(g_pads[i], (Uint16)(g_rumble_large[i] * 257),
                             g_rumble_small[i] ? 0xFFFF : 0, on ? RUMBLE_MS : 0);
    g_rumble_sent[i] = SDL_GetTicks();
}

void bp_pad_rumble(int pad, int small, int large) {
    if (pad < 0 || pad >= MAX_PADS) return;
    g_rumble_small[pad] = small ? 1 : 0;
    g_rumble_large[pad] = large < 0 ? 0 : (large > 255 ? 255 : large);
    rumble_send(pad);
}

static void rumble_renew(void) {
    const Uint32 now = SDL_GetTicks();
    for (int i = 0; i < MAX_PADS; i++)
        if ((g_rumble_small[i] || g_rumble_large[i]) && now - g_rumble_sent[i] >= RUMBLE_RENEW) rumble_send(i);
}

/* ---- keyboard as text (bp_key_text, bp_key_next) --------------------------------------------
 * While text entry is on, characters come from SDL_TEXTINPUT — the host's layout and input
 * method have already made them, so a Turkish keyboard types ş and a compose sequence arrives
 * whole — and the three editing keys from SDL_KEYDOWN. The keyboard's pad keys are then only
 * the arrows, and Escape cancels rather than quits. */

static int is_arrow(SDL_Keycode k) {
    return k == SDLK_UP || k == SDLK_DOWN || k == SDLK_LEFT || k == SDLK_RIGHT;
}

static void typed_push(int c) {
    if (g_typed_count < TYPED_CAP) {
        g_typed[(g_typed_head + g_typed_count) & (TYPED_CAP - 1)] = c;
        g_typed_count++;
    }
}

/* SDL_TEXTINPUT's UTF-8 as code points; a malformed sequence is skipped, not guessed at. */
static void typed_utf8(const char* text) {
    const unsigned char* p = (const unsigned char*)text;
    while (*p) {
        int cp = 0, n = 0;
        if (p[0] < 0x80)                { cp = p[0];        n = 1; }
        else if ((p[0] & 0xE0) == 0xC0) { cp = p[0] & 0x1F; n = 2; }
        else if ((p[0] & 0xF0) == 0xE0) { cp = p[0] & 0x0F; n = 3; }
        else if ((p[0] & 0xF8) == 0xF0) { cp = p[0] & 0x07; n = 4; }
        else { p++; continue; }
        int i = 1;
        while (i < n && (p[i] & 0xC0) == 0x80) { cp = (cp << 6) | (p[i] & 0x3F); i++; }
        if (i == n) typed_push(cp);
        p += i;
    }
}

void bp_key_text(int on) {
    g_typing = on != 0;
    g_typed_head = g_typed_count = 0;
    if (g_typing) SDL_StartTextInput();
    else SDL_StopTextInput();
}

int bp_key_next(void) {
    if (g_typed_count == 0) return -1;
    const int c = g_typed[g_typed_head];
    g_typed_head = (g_typed_head + 1) & (TYPED_CAP - 1);
    g_typed_count--;
    return c;
}

/* ---- mouse (bp_mouse) -------------------------------------------------------------------------
 * The pointer over the picture, as a fraction of the rectangle bp_present last drew it in. That
 * rectangle is in the renderer's pixels and the pointer in the window's points — two pixels to a
 * point on a high-DPI display — so the pointer is scaled first. A press seen as an event counts
 * as held until the next poll, so a click shorter than a frame still reaches the machine. */

static int mouse_bit(Uint8 button) {
    if (button == SDL_BUTTON_LEFT) return 1;
    if (button == SDL_BUTTON_RIGHT) return 2;
    if (button == SDL_BUTTON_MIDDLE) return 4;
    if (button == SDL_BUTTON_X1) return 8;
    if (button == SDL_BUTTON_X2) return 16;
    return 0;
}

static void latch_mouse(void) {
    int wx = 0, wy = 0, ww = 0, wh = 0, ow = 0, oh = 0;
    const Uint32 held = SDL_GetMouseState(&wx, &wy);
    SDL_GetWindowSize(g_window, &ww, &wh);
    SDL_GetRendererOutputSize(g_renderer, &ow, &oh);
    const int px = ww > 0 ? (int)((int64_t)wx * ow / ww) : wx;
    const int py = wh > 0 ? (int)((int64_t)wy * oh / wh) : wy;
    const SDL_Rect r = g_picture;
    g_mouse_over = SDL_GetMouseFocus() == g_window && r.w > 0 && r.h > 0
        && px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
    if (g_mouse_over) {
        g_mouse_x = (int)((int64_t)(px - r.x) * 65536 / r.w);
        g_mouse_y = (int)((int64_t)(py - r.y) * 65536 / r.h);
        int b = g_mouse_pressed;
        if (held & SDL_BUTTON_LMASK) b |= 1;
        if (held & SDL_BUTTON_RMASK) b |= 2;
        if (held & SDL_BUTTON_MMASK) b |= 4;
        if (held & SDL_BUTTON_X1MASK) b |= 8;
        if (held & SDL_BUTTON_X2MASK) b |= 16;
        g_mouse_buttons = b;
    } else {
        g_mouse_x = g_mouse_y = g_mouse_buttons = 0;
    }
    g_mouse_pressed = 0;
}

/* The machine's pointer is the host's cursor: the system's own while it has none, the art of
 * pointer_art.h while it is shown (made once, a pixel a pixel, tip at the hotspot), no cursor at all
 * while a pad is in use. */
static SDL_Cursor* pointer_cursor(void) {
    if (!g_pointer) {
        SDL_Surface* art = SDL_CreateRGBSurfaceWithFormat(0, POINTER_W, POINTER_H, 32, SDL_PIXELFORMAT_ARGB8888);
        if (art) {
            for (int y = 0; y < POINTER_H; y++) {
                uint32_t* row = (uint32_t*)((uint8_t*)art->pixels + y * art->pitch);
                for (int x = 0; x < POINTER_W; x++) row[x] = pointer_argb(k_pointer[y][x]);
            }
            g_pointer = SDL_CreateColorCursor(art, 0, 0);
            SDL_FreeSurface(art);
        }
    }
    return g_pointer;
}

void bp_mouse_pointer(int state) {
    if (state == BP_POINTER_HIDDEN) {
        SDL_ShowCursor(SDL_DISABLE);
    } else {
        SDL_Cursor* art = state == BP_POINTER_SHOWN ? pointer_cursor() : NULL;
        SDL_SetCursor(art ? art : SDL_GetDefaultCursor());
        SDL_ShowCursor(SDL_ENABLE);
    }
}

int bp_mouse(int field) {
    switch (field) {
        case BP_MOUSE_OVER:    return g_mouse_over;
        case BP_MOUSE_X:       return g_mouse_x;
        case BP_MOUSE_Y:       return g_mouse_y;
        case BP_MOUSE_BUTTONS: return g_mouse_buttons;
        default:               return 0;
    }
}

void bp_input_poll(void) {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        switch (e.type) {
            case SDL_QUIT:
                g_quit = 1;
                break;
            case SDL_MOUSEBUTTONDOWN:
                g_mouse_pressed |= mouse_bit(e.button.button);
                break;
            case SDL_KEYDOWN: {
                const SDL_Keycode k = e.key.keysym.sym;
                /* A held key's button went down with its first press; repeats press nothing, so a
                 * key held when text entry ends becomes a button only when pressed again. */
                if (g_typing) {
                    if (k == SDLK_BACKSPACE) typed_push(BP_KEY_BACKSPACE);
                    else if (k == SDLK_RETURN || k == SDLK_KP_ENTER) typed_push(BP_KEY_ENTER);
                    else if (k == SDLK_ESCAPE) typed_push(BP_KEY_ESCAPE);
                    if (is_arrow(k) && !e.key.repeat) g_keyboard_buttons |= key_to_button(k);
                } else if (!e.key.repeat) {
                    if (k == SDLK_ESCAPE) g_quit = 1;
                    g_keyboard_buttons |= key_to_button(k);
                }
                break;
            }
            case SDL_KEYUP:
                g_keyboard_buttons &= ~key_to_button(e.key.keysym.sym);
                break;
            case SDL_TEXTINPUT:
                if (g_typing) typed_utf8(e.text.text);
                break;
            case SDL_CONTROLLERDEVICEADDED: {
                const int i = e.cdevice.which;
                if (i >= 0 && i < MAX_PADS && !g_pads[i] && SDL_IsGameController(i)) {
                    g_pads[i] = SDL_GameControllerOpen(i);
                    if (g_pads[i]) {
                        g_pad_type[i] = BP_PAD_ANALOG;
                        /* A new controller is a new DualShock: the runtime stops whatever ran. */
                        g_rumble_small[i] = g_rumble_large[i] = 0;
                    }
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
    if (g_window && g_renderer) latch_mouse();
    rumble_renew();
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

/* ---- memory cards --------------------------------------------------------------------------
 * <game>.card beside the other saves, in the card format as the runtime hands it over (ADR-0037),
 * through bp_storage_write's temporary file and rename. A card with nothing on it is no file. */
static int card_name(const char* game, char* out, size_t len) {
    if (!game || !*game) return 0;
    snprintf(out, len, "%s.card", game);
    return 1;
}

int bp_card_load(const char* game, uint8_t* buf, int cap) {
    char name[64];
    if (!card_name(game, name, sizeof(name))) return -1;
    return bp_storage_read(name, buf, cap);
}

int bp_card_save(const char* game, const char* title, const uint8_t* buf, int len) {
    char name[64], path[1200];
    (void)title;
    if (!card_name(game, name, sizeof(name))) return -1;
    if (len > BP_CARD_HEADER) return bp_storage_write(name, buf, len);
    if (!storage_path(name, path, sizeof(path))) return -1;
    remove(path);
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

/* Nothing shows these on the desktop; the profilers there see the functions themselves. */
void bp_profile_mark(int section, int begin) { (void)section; (void)begin; }

/* No sampler of its own: bp_caps(BP_CAP_SPU_VOICES) is 0, so the runtime never calls these. */
void bp_spu_ram(const uint8_t* ram) { (void)ram; }
void bp_spu_dirty(int addr, int len) { (void)addr; (void)len; }
int bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r) {
    (void)v; (void)key; (void)on; (void)start; (void)pitch; (void)vol_l; (void)vol_r;
    return 0;   /* no sampler: every voice stays in the software mix */
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

    /* After a stall (or a debugger breakpoint) the debt is capped at four frames, so nothing is
     * sprinted through, but it is kept rather than wiped: wiping it made a quick frame wait even
     * while the game as a whole ran behind. Same rule as the Dreamcast backend. */
    const uint64_t after = bp_time_us();
    if (next_deadline + (uint64_t)target_us * 4ull < after) next_deadline = after - (uint64_t)target_us * 4ull;
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

/* ---- network (bp_http_*, ADR-0040) ---------------------------------------------------------
 * The i-mode adaptor's phone reaches the host's network through these: one HTTP/1.0 exchange a
 * handle over a plain TCP socket, never blocking the game. The name is resolved as the request
 * opens (getaddrinfo — on a slow resolver the one wait there is), the socket connects in the
 * background, the request goes out as the socket takes it, and the response comes back as it
 * arrives until the server closes. */
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET http_sock;
#define HTTP_BAD INVALID_SOCKET
#define http_closesock closesocket
static int http_would_block(void) {
    const int e = WSAGetLastError();
    return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS || e == WSAEALREADY;
}
static int http_nonblock(http_sock s) { u_long on = 1; return ioctlsocket(s, FIONBIO, &on); }
static void http_startup(void) {
    static int up;
    if (!up) { WSADATA w; WSAStartup(MAKEWORD(2, 2), &w); up = 1; }
}
#else
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int http_sock;
#define HTTP_BAD (-1)
#define http_closesock close
static int http_would_block(void) {
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS || errno == EALREADY;
}
static int http_nonblock(http_sock s) { return fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK); }
static void http_startup(void) {}
#endif
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define MAX_HTTP 4

typedef struct {
    int used;
    http_sock sock;
    int connected;
    uint8_t* request;
    int len, sent;
} http_t;

static http_t g_http[MAX_HTTP];

int bp_http_open(const char* host, int port, const uint8_t* request, int len) {
    int h = -1;
    for (int i = 0; i < MAX_HTTP && h < 0; i++) if (!g_http[i].used) h = i;
    if (h < 0 || !host || !*host || port <= 0 || len <= 0) return -1;
    http_startup();
    char service[8];
    snprintf(service, sizeof service, "%d", port);
    struct addrinfo hints, *found = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, service, &hints, &found) != 0 || !found) return -1;
    http_sock s = socket(found->ai_family, found->ai_socktype, found->ai_protocol);
    int ok = s != HTTP_BAD && http_nonblock(s) == 0;
#ifdef SO_NOSIGPIPE
    if (ok) { int one = 1; setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one); }
#endif
    if (ok && connect(s, found->ai_addr, (int)found->ai_addrlen) != 0 && !http_would_block()) ok = 0;
    freeaddrinfo(found);
    uint8_t* copy = ok ? (uint8_t*)malloc((size_t)len) : NULL;
    if (!copy) {
        if (s != HTTP_BAD) http_closesock(s);
        return -1;
    }
    memcpy(copy, request, (size_t)len);
    http_t* t = &g_http[h];
    t->used = 1;
    t->sock = s;
    t->connected = 0;
    t->request = copy;
    t->len = len;
    t->sent = 0;
    return h;
}

/* Whether the socket has connected: 1, 0 not yet, -1 it failed. */
static int http_connected(http_t* t) {
    if (t->connected) return 1;
#ifdef _WIN32
    fd_set w, e;
    FD_ZERO(&w); FD_ZERO(&e);
    FD_SET(t->sock, &w); FD_SET(t->sock, &e);
    struct timeval zero = {0, 0};
    if (select(0, NULL, &w, &e, &zero) <= 0) return 0;
    if (FD_ISSET(t->sock, &e)) return -1;
#else
    struct pollfd p = { t->sock, POLLOUT, 0 };
    if (poll(&p, 1, 0) <= 0) return 0;
    int err = 0;
    socklen_t n = sizeof err;
    if (getsockopt(t->sock, SOL_SOCKET, SO_ERROR, &err, &n) != 0 || err != 0) return -1;
#endif
    t->connected = 1;
    return 1;
}

int bp_http_read(int handle, uint8_t* buf, int cap) {
    if (handle < 0 || handle >= MAX_HTTP || !g_http[handle].used) return -2;
    http_t* t = &g_http[handle];
    const int c = http_connected(t);
    if (c <= 0) return c < 0 ? -2 : 0;
    while (t->sent < t->len) {
        const int n = (int)send(t->sock, (const char*)t->request + t->sent, t->len - t->sent, MSG_NOSIGNAL);
        if (n > 0) t->sent += n;
        else if (n < 0 && http_would_block()) return 0;
        else return -2;
    }
    const int n = (int)recv(t->sock, (char*)buf, cap, 0);
    if (n > 0) return n;
    if (n == 0) return -1;
    return http_would_block() ? 0 : -2;
}

void bp_http_close(int handle) {
    if (handle < 0 || handle >= MAX_HTTP || !g_http[handle].used) return;
    http_closesock(g_http[handle].sock);
    free(g_http[handle].request);
    memset(&g_http[handle], 0, sizeof g_http[handle]);
}
