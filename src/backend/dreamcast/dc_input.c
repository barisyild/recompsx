/* dc_input.c — maple controllers as PlayStation pads, the reset combo, a keyboard as text, and a
 * mouse as the HLE kernel's pointer. */

#include "dc_internal.h"
#include "pointer_art.h"
#include <dc/maple/keyboard.h>
#include <dc/maple/mouse.h>
#include <dc/vblank.h>
#include <kos/irq.h>

/* ---- input state ---------------------------------------------------------------------------- */

static uint32_t g_pad_buttons[MAX_PADS];
static uint8_t  g_pad_axes[MAX_PADS][4];
static int      g_pad_present[MAX_PADS];
/* Written from the maple driver's button callback, which runs on an interrupt. */
static volatile int g_quit;

/* PS1 controller bit layout, active high on this side of the API.
 * (The runtime inverts when it builds the SIO0 response — that is emulation, not platform.) */
enum {
    PAD_SELECT = 1 << 0,  PAD_L3     = 1 << 1,  PAD_R3    = 1 << 2,  PAD_START = 1 << 3,
    PAD_UP     = 1 << 4,  PAD_RIGHT  = 1 << 5,  PAD_DOWN  = 1 << 6,  PAD_LEFT  = 1 << 7,
    PAD_L2     = 1 << 8,  PAD_R2     = 1 << 9,  PAD_L1    = 1 << 10, PAD_R1    = 1 << 11,
    PAD_TRIANGLE = 1 << 12, PAD_CIRCLE = 1 << 13, PAD_CROSS = 1 << 14, PAD_SQUARE = 1 << 15
};

/* Where a light trigger press becomes a shoulder button, and where a hard one becomes the second
 * shoulder button instead. The Dreamcast pad has two analogue triggers where the PlayStation has
 * four digital shoulders, so each trigger carries two of them along its travel. */
#define TRIG_L1 40
#define TRIG_L2 200

/* The console's universal "put this down": A+B+X+Y+Start. The maple driver calls this from its
 * own interrupt, which is what makes it worth having on top of the same check in bp_input_poll —
 * the gesture keeps working during a long disc read, when nothing is polling pads at all. */
void reset_combo(uint8_t addr, uint32_t btns) {
    (void)addr; (void)btns;
    g_quit = 1;
}

/* ---- input --------------------------------------------------------------------------------------
 * A Dreamcast pad is four face buttons, a d-pad, Start and two analogue triggers. A PlayStation
 * pad is four face buttons, a d-pad, Start, Select and four shoulders. Two things therefore have
 * to be found homes:
 *
 *   - L1/L2 and R1/R2 share a trigger each, split along its travel: a light pull is the first
 *     shoulder, a hard pull the second.
 *   - Select has no home at all. It is taken from the C button when a pad has one (arcade sticks
 *     and several third-party pads do), and otherwise from Start held with a full left trigger —
 *     which suppresses both of those for that frame, so a game never sees Start and Select at
 *     once from one gesture. */

static uint32_t map_buttons(const cont_state_t* st) {
    uint32_t b = 0;
    const uint32_t k = st->buttons;

    if(k & CONT_DPAD_UP)    b |= PAD_UP;
    if(k & CONT_DPAD_DOWN)  b |= PAD_DOWN;
    if(k & CONT_DPAD_LEFT)  b |= PAD_LEFT;
    if(k & CONT_DPAD_RIGHT) b |= PAD_RIGHT;
    if(k & CONT_A)          b |= PAD_CROSS;
    if(k & CONT_B)          b |= PAD_CIRCLE;
    if(k & CONT_X)          b |= PAD_SQUARE;
    if(k & CONT_Y)          b |= PAD_TRIANGLE;
    if(k & CONT_D)          b |= PAD_L3;

    if(st->ltrig >= TRIG_L2)      b |= PAD_L2;
    else if(st->ltrig >= TRIG_L1) b |= PAD_L1;
    if(st->rtrig >= TRIG_L2)      b |= PAD_R2;
    else if(st->rtrig >= TRIG_L1) b |= PAD_R1;

    const int select_combo = (k & CONT_START) && st->ltrig >= TRIG_L2;
    if((k & CONT_C) || select_combo) b |= PAD_SELECT;
    if((k & CONT_START) && !select_combo) b |= PAD_START;
    if(select_combo) b &= ~(uint32_t)PAD_L2;

    return b;
}

static uint8_t axis_to_byte(int v) {
    const int b = v + 128;
    return (uint8_t)(b < 0 ? 0 : (b > 255 ? 255 : b));
}

static void poll_mouse(void);
static maple_device_t* keyboard(void);
static uint32_t keyboard_pad(const kbd_state_t* ks);
static int g_typing;

void bp_input_poll(void) {
    poll_mouse();
#if RECOMPSX_DC_PROFILE
    /* An automated profiling run (--dc-rxprof) has to measure the same frames every time. With a
     * controller in the port, whatever reaches the emulator's window — a key pressed while it had
     * focus — changes what the game does, and the benchmark with it: a run of Crash 3's demo
     * window measured the title screen instead. So its ports stay empty, as every measurement
     * before controllers existed had them. */
    if(g_rxprof) {
        for(int i = 0; i < MAX_PADS; i++) {
            g_pad_present[i] = 0;
            g_pad_buttons[i] = 0;
            g_pad_axes[i][0] = g_pad_axes[i][1] = g_pad_axes[i][2] = g_pad_axes[i][3] = 0x80;
        }
        return;
    }
#endif
    for(int i = 0; i < MAX_PADS; i++) {
        maple_device_t* dev = maple_enum_dev(i, 0);
        const cont_state_t* st = NULL;
        if(dev && dev->valid && (dev->info.functions & MAPLE_FUNC_CONTROLLER))
            st = (const cont_state_t*)maple_dev_status(dev);

        if(!st) {
            g_pad_present[i] = 0;
            g_pad_buttons[i] = 0;
            g_pad_axes[i][0] = g_pad_axes[i][1] = g_pad_axes[i][2] = g_pad_axes[i][3] = 0x80;
            continue;
        }

        g_pad_present[i] = 1;
        g_pad_buttons[i] = map_buttons(st);
        g_pad_axes[i][0] = axis_to_byte(st->joyx);
        g_pad_axes[i][1] = axis_to_byte(st->joyy);
        /* The pad has one stick. A second one reads centred, which is what a game asking a
         * DualShock about an axis nobody is touching would see. */
        g_pad_axes[i][2] = 0x80;
        g_pad_axes[i][3] = 0x80;

        /* Same gesture as the interrupt-time callback, seen from the polling side. Both exist
         * because they fail differently: this one cannot fire while the emulator is busy not
         * polling, and that one cannot see a pad the maple driver has not enumerated. */
        if((st->buttons & CONT_RESET_BUTTONS) == CONT_RESET_BUTTONS) g_quit = 1;
    }

    /* A keyboard is pad 0 as well — merged with the pad in port A, and pad 0 even without one. */
    maple_device_t* kbd = keyboard();
    const kbd_state_t* ks = kbd ? (const kbd_state_t*)maple_dev_status(kbd) : NULL;
    if(ks) {
        g_pad_present[0] = 1;
        g_pad_buttons[0] |= keyboard_pad(ks);
    }
}

/* The keyboard as the desktop and the browser map it: arrows for the d-pad, X S Z A for cross,
 * square, triangle and circle, Q W for L1 R1, 1 2 for L2 R2, Enter for Start, the right Shift for
 * Select. While text entry is on only the arrows count, so that a letter typed is never a button
 * pressed as well (backend_c_api.h). */
static uint32_t keyboard_pad(const kbd_state_t* ks) {
    uint32_t b = 0;
    if(ks->key_states[KBD_KEY_UP].is_down)    b |= PAD_UP;
    if(ks->key_states[KBD_KEY_DOWN].is_down)  b |= PAD_DOWN;
    if(ks->key_states[KBD_KEY_LEFT].is_down)  b |= PAD_LEFT;
    if(ks->key_states[KBD_KEY_RIGHT].is_down) b |= PAD_RIGHT;
    if(!g_typing) {
        if(ks->key_states[KBD_KEY_X].is_down) b |= PAD_CROSS;
        if(ks->key_states[KBD_KEY_S].is_down) b |= PAD_SQUARE;
        if(ks->key_states[KBD_KEY_Z].is_down) b |= PAD_TRIANGLE;
        if(ks->key_states[KBD_KEY_A].is_down) b |= PAD_CIRCLE;
        if(ks->key_states[KBD_KEY_Q].is_down) b |= PAD_L1;
        if(ks->key_states[KBD_KEY_W].is_down) b |= PAD_R1;
        if(ks->key_states[KBD_KEY_1].is_down) b |= PAD_L2;
        if(ks->key_states[KBD_KEY_2].is_down) b |= PAD_R2;
        if(ks->key_states[KBD_KEY_ENTER].is_down || ks->key_states[KBD_KEY_PAD_ENTER].is_down) b |= PAD_START;
        if(ks->cond.modifiers.raw & KBD_MOD_RSHIFT) b |= PAD_SELECT;
    }
    return b;
}

int      bp_pad_connected(int pad) { return (pad >= 0 && pad < MAX_PADS) ? g_pad_present[pad] : 0; }
uint32_t bp_pad_buttons(int pad)   { return (pad >= 0 && pad < MAX_PADS) ? g_pad_buttons[pad] : 0u; }
int      bp_quit_requested(void)   { return g_quit; }

/* Reported digital even though the stick is read: a PlayStation pad in analogue mode has two
 * sticks and this machine has one, and a game that switches modes on the strength of that report
 * would find the right stick permanently centred. The axes are still served, for whatever asks. */
int bp_pad_type(int pad) {
    if(pad < 0 || pad >= MAX_PADS || !g_pad_present[pad]) return BP_PAD_NONE;
    return BP_PAD_DIGITAL;
}

int bp_pad_axis(int pad, int axis) {
    if(pad < 0 || pad >= MAX_PADS || axis < 0 || axis > 3) return 0x80;
    return g_pad_axes[pad][axis];
}

/* ---- keyboard as text (bp_key_text, bp_key_next) -------------------------------------------------
 * A Dreamcast keyboard on any port types while text entry is on (backend_c_api.h). KallistiOS
 * queues its presses, repeats included, each with the modifiers and lock lights of its moment, and
 * bp_key_next turns them into code points by the keyboard's own region — the layout a Dreamcast
 * keyboard reports, translated by KallistiOS into ISO-8859-1, the first 256 code points of
 * Unicode. (An emulator reports its host's layout when it recognises it: Flycast passes the host's
 * keys on by position and says US otherwise, so on a Turkish Q keyboard the '.' key, where US has
 * '/', types '/', and the key where US has '.' types '.'.) The keypad types the same under every
 * region, digits and '.' while Num Lock is on — KallistiOS makes them arrows and navigation keys
 * while it is off, as a PC does — and / * - + either way. Enter, Backspace and Escape are the three
 * editing keys; a key with no character (an arrow, a function key) types nothing. The same keyboard
 * is pad 0 (keyboard_pad), and while it types only its arrows are; without one, nothing is typed. */

/* The keypad from / to . (54h..63h); Enter is an editing key. */
static const char k_keypad[] = "/*-+\n1234567890.";

static int key_char(int key, kbd_mods_t mods, kbd_leds_t leds, int region) {
    if(key == KBD_KEY_ENTER || key == KBD_KEY_PAD_ENTER) return BP_KEY_ENTER;
    if(key == KBD_KEY_BACKSPACE) return BP_KEY_BACKSPACE;
    if(key == KBD_KEY_ESCAPE) return BP_KEY_ESCAPE;
    if(key >= KBD_KEY_PAD_DIVIDE && key <= KBD_KEY_PAD_PERIOD) return k_keypad[key - KBD_KEY_PAD_DIVIDE];
    /* KallistiOS's char is signed: a character past 7Fh must not come back negative. */
    return (unsigned char)kbd_key_to_ascii((kbd_key_t)key, (kbd_region_t)region, mods, leds);
}

static maple_device_t* keyboard(void) {
#if RECOMPSX_DC_PROFILE
    /* A profiling run measures the same frames every time: nothing typed, as no pad pressed. */
    if(g_rxprof) return NULL;
#endif
    return maple_enum_type(0, MAPLE_FUNC_KEYBOARD);
}

void bp_key_text(int on) {
    g_typing = on != 0;
    /* What was pressed before the field opened is not typed into it. */
    maple_device_t* kbd = keyboard();
    if(kbd) while(kbd_queue_pop(kbd, false) != KBD_QUEUE_END) {}
}

int bp_key_next(void) {
    maple_device_t* kbd = g_typing ? keyboard() : NULL;
    const kbd_state_t* ks = kbd ? (const kbd_state_t*)maple_dev_status(kbd) : NULL;
    if(!ks) return -1;
    for(;;) {
        /* Untranslated: the key, its modifiers a byte up, its lock lights two. */
        const int k = kbd_queue_pop(kbd, false);
        if(k == KBD_QUEUE_END) return -1;
        kbd_mods_t mods; kbd_leds_t leds;
        mods.raw = (uint8_t)(k >> 8);
        leds.raw = (uint8_t)(k >> 16);
        const int c = key_char(k & 0xFF, mods, leds, (int)ks->region);
        if(c > 0) return c;   /* the kernel drops what is not a character (Tab, say) */
    }
}

/* ---- mouse (bp_mouse) -----------------------------------------------------------------------------
 * A maple mouse on any port is the pointer (backend_c_api.h). KallistiOS asks it for its motion
 * every bus frame, 60 a second, and keeps only the last frame's (dx, dy) — while the emulator,
 * below 60 frames a second, polls less often. So a vblank handler adds each frame's motion up and
 * zeroes what it took, which also keeps a frame the bus did not answer from being counted twice;
 * bp_input_poll takes the sums. The pointer itself is kept here, on the 640 x 480 screen the
 * picture fills, and reported as a fraction of it. The console draws no pointer of its own, so the
 * backend draws the machine's — draw_mouse_pointer, the last thing in each scene — while the kernel
 * says it is shown (bp_mouse_pointer: a mod has turned the mouse on and no pad is in use). Left,
 * right and the third button (KOS's "side") are the mouse's. */

static volatile int g_acc_on, g_acc_dx, g_acc_dy, g_acc_held, g_acc_pressed;
static int g_vblank_hooked;

static void mouse_vblank(uint32_t code, void* data) {
    (void)code; (void)data;
    maple_device_t* dev = maple_enum_type(0, MAPLE_FUNC_MOUSE);
    mouse_state_t* st = dev ? (mouse_state_t*)maple_dev_status(dev) : NULL;
    if(!st) {
        g_acc_on = 0;
        g_acc_held = 0;
        return;
    }
    g_acc_on = 1;
    g_acc_dx += st->dx;
    g_acc_dy += st->dy;
    st->dx = 0;
    st->dy = 0;
    g_acc_held = (int)st->buttons;
    g_acc_pressed |= (int)st->buttons;
}

static int g_mouse_on;                     /* a mouse is attached */
static int g_mouse_px = 320, g_mouse_py = 240;
static int g_mouse_buttons;
static int g_pointer_shown;                /* BP_POINTER_SHOWN: none until a mod turns the mouse on */

static void poll_mouse(void) {
#if RECOMPSX_DC_PROFILE
    if(g_rxprof) {
        g_mouse_on = 0;
        g_mouse_buttons = 0;
        return;
    }
#endif
    if(!g_vblank_hooked) {
        vblank_handler_add(mouse_vblank, NULL);
        g_vblank_hooked = 1;
    }
    const irq_mask_t mask = irq_disable();
    const int on = g_acc_on, dx = g_acc_dx, dy = g_acc_dy, held = g_acc_held, pressed = g_acc_pressed;
    g_acc_dx = 0;
    g_acc_dy = 0;
    g_acc_pressed = 0;
    irq_restore(mask);
    g_mouse_on = on;
    if(!on) {
        g_mouse_buttons = 0;
        return;
    }
    g_mouse_px += dx;
    g_mouse_py += dy;
    if(g_mouse_px < 0) g_mouse_px = 0;
    if(g_mouse_px > 639) g_mouse_px = 639;
    if(g_mouse_py < 0) g_mouse_py = 0;
    if(g_mouse_py > 479) g_mouse_py = 479;
    const int b = held | pressed;
    int out = 0;
    if(b & MOUSE_LEFTBUTTON)  out |= 1;
    if(b & MOUSE_RIGHTBUTTON) out |= 2;
    if(b & MOUSE_SIDEBUTTON)  out |= 8;
    g_mouse_buttons = out;
}

void bp_mouse_pointer(int state) {
    g_pointer_shown = state == BP_POINTER_SHOWN;
}

int bp_mouse(int field) {
    switch(field) {
        case BP_MOUSE_OVER:    return g_mouse_on;
        case BP_MOUSE_X:       return g_mouse_on ? (g_mouse_px * 65536) / 640 : 0;
        case BP_MOUSE_Y:       return g_mouse_on ? (g_mouse_py * 65536) / 480 : 0;
        case BP_MOUSE_BUTTONS: return g_mouse_on ? g_mouse_buttons : 0;
        default:               return 0;
    }
}

/* The pointer's picture (pointer_art.h). The PVR draws it at the console's own 640 x 480, a texel
 * to a pixel with no filtering, so it stays sharp whatever resolution the game's picture has; it is
 * drawn in submission order like everything else (no depth, ADR-0011). */
#define POINTER_TEX_H 32                   /* a texture's sides are powers of two */

static uint16_t pointer_texel(char c) {
    const uint32_t v = pointer_argb(c);
    if(!(v >> 24)) return 0;               /* clear: the alpha bit off */
    return (uint16_t)(0x8000 | (((v >> 19) & 31) << 10) | (((v >> 11) & 31) << 5) | ((v >> 3) & 31));
}

static pvr_poly_hdr_t g_pointer_hdr __attribute__((aligned(32)));
static pvr_ptr_t g_pointer_tex;
static int g_pointer_ready;                /* 1 the texture, -1 no texture memory: plain arrows */

/* Once, at the first pointer drawn: the art into a texture through the store queues. */
static void pointer_prepare(void) {
    static uint16_t texels[POINTER_W * POINTER_TEX_H] __attribute__((aligned(32)));
    for(int y = 0; y < POINTER_TEX_H; y++)
        for(int x = 0; x < POINTER_W; x++)
            texels[y * POINTER_W + x] = y < POINTER_H ? pointer_texel(k_pointer[y][x]) : 0;
    g_pointer_tex = pvr_mem_malloc(sizeof texels);
    pvr_poly_cxt_t cxt;
    if(g_pointer_tex) {
        txr_put(texels, g_pointer_tex, sizeof texels);
        pvr_poly_cxt_txr(&cxt, PVR_LIST_TR_POLY, PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_NONTWIDDLED,
                         POINTER_W, POINTER_TEX_H, g_pointer_tex, PVR_FILTER_NONE);
        cxt.txr.env = PVR_TXRENV_REPLACE;
        cxt.txr.uv_clamp = PVR_UVCLAMP_UV;
    } else {
        pvr_poly_cxt_col(&cxt, PVR_LIST_TR_POLY);
    }
    cxt.gen.culling = PVR_CULLING_NONE;
    cxt.depth.comparison = PVR_DEPTHCMP_ALWAYS;
    cxt.depth.write = false;
    pvr_poly_compile(&g_pointer_hdr, &cxt);
    g_pointer_ready = g_pointer_tex ? 1 : -1;
}

static void pointer_tri(float x0, float y0, float x1, float y1, float x2, float y2, uint32_t argb) {
    pvr_vertex_t v __attribute__((aligned(32)));
    v.flags = PVR_CMD_VERTEX;
    v.z = 2.0f;
    v.u = v.v = 0.0f;
    v.argb = argb;
    v.oargb = 0;
    v.x = x0; v.y = y0; put_vtx(&v);
    v.x = x1; v.y = y1; put_vtx(&v);
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = x2; v.y = y2; put_vtx(&v);
}

void draw_mouse_pointer(void) {
    if(!g_mouse_on || !g_pointer_shown) return;
    if(!g_pointer_ready) pointer_prepare();
    const float x = (float)g_mouse_px, y = (float)g_mouse_py;
    put_hdr(&g_pointer_hdr);
    if(g_pointer_ready > 0) {
        pvr_vertex_t v __attribute__((aligned(32)));
        v.flags = PVR_CMD_VERTEX;
        v.z = 2.0f;
        v.argb = 0xFFFFFFFFu;
        v.oargb = 0;
        v.x = x;             v.y = y;                 v.u = 0.0f; v.v = 0.0f; put_vtx(&v);
        v.x = x + POINTER_W; v.y = y;                 v.u = 1.0f; v.v = 0.0f; put_vtx(&v);
        v.x = x;             v.y = y + POINTER_TEX_H; v.u = 0.0f; v.v = 1.0f; put_vtx(&v);
        v.flags = PVR_CMD_VERTEX_EOL;
        v.x = x + POINTER_W; v.y = y + POINTER_TEX_H; v.u = 1.0f; v.v = 1.0f; put_vtx(&v);
    } else {
        pointer_tri(x - 1.0f, y - 2.0f, x - 1.0f, y + 20.0f, x + 15.0f, y + 14.0f, 0xFF000000u);
        pointer_tri(x, y, x, y + 16.0f, x + 11.0f, y + 12.0f, 0xFFFFFFFFu);
    }
}
