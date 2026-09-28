/* dc_input.c — maple controllers as PlayStation pads, the reset combo, a keyboard as text, and a
 * mouse as the HLE kernel's pointer. */

#include "dc_internal.h"
#include <dc/maple/keyboard.h>
#include <dc/maple/mouse.h>

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
 * queues its presses, repeats included, and translates each by the keyboard's own region into
 * ISO-8859-1 — the first 256 code points of Unicode, so a translated key already is what
 * bp_key_next returns. Enter comes as 13 (10 with Shift), Escape as 27, Backspace as 8; a key KOS
 * cannot translate comes back as its key code shifted up a byte, and of those only the keypad's
 * Enter means anything here. The keyboard is never a pad, so nothing else changes while typing;
 * without one, nothing is typed. */

static int g_typing;

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
    if(kbd) while(kbd_queue_pop(kbd, true) != KBD_QUEUE_END) {}
}

int bp_key_next(void) {
    maple_device_t* kbd = g_typing ? keyboard() : NULL;
    if(!kbd) return -1;
    for(;;) {
        const int k = kbd_queue_pop(kbd, true);
        if(k == KBD_QUEUE_END) return -1;
        if(k == 13) return BP_KEY_ENTER;
        if(k < 0x100) return k;   /* the kernel drops what is not a character (Tab, say) */
        if((k >> 8) == KBD_KEY_PAD_ENTER) return BP_KEY_ENTER;
        /* an arrow, a function key: nothing typed — on to the next */
    }
}

/* ---- mouse (bp_mouse) -----------------------------------------------------------------------------
 * A maple mouse on any port is the pointer (backend_c_api.h). KallistiOS hands over the motion of
 * its last bus frame (dx, dy) and the buttons; the pointer itself is kept here, on the 640 x 480
 * screen the picture fills, and reported as a fraction of it. A frame of motion the emulator did
 * not poll for — it runs below 60 frames a second — is not seen, so the pointer is slower then;
 * that is the whole cost. The console draws no pointer of its own, so the backend draws one:
 * draw_mouse_pointer, the last thing in each scene. Left, right and the side button are the
 * mouse's; there is no middle one. */

static int g_mouse_on;                     /* a mouse is attached */
static int g_mouse_px = 320, g_mouse_py = 240;
static int g_mouse_buttons;

static void poll_mouse(void) {
    maple_device_t* dev = NULL;
#if RECOMPSX_DC_PROFILE
    if(!g_rxprof) dev = maple_enum_type(0, MAPLE_FUNC_MOUSE);
#else
    dev = maple_enum_type(0, MAPLE_FUNC_MOUSE);
#endif
    const mouse_state_t* st = dev ? (const mouse_state_t*)maple_dev_status(dev) : NULL;
    g_mouse_on = st != NULL;
    if(!st) {
        g_mouse_buttons = 0;
        return;
    }
    g_mouse_px += st->dx;
    g_mouse_py += st->dy;
    if(g_mouse_px < 0) g_mouse_px = 0;
    if(g_mouse_px > 639) g_mouse_px = 639;
    if(g_mouse_py < 0) g_mouse_py = 0;
    if(g_mouse_py > 479) g_mouse_py = 479;
    int b = 0;
    if(st->buttons & MOUSE_LEFTBUTTON)  b |= 1;
    if(st->buttons & MOUSE_RIGHTBUTTON) b |= 2;
    if(st->buttons & MOUSE_SIDEBUTTON)  b |= 8;
    g_mouse_buttons = b;
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

/* An arrow: a black one, then a white one inside it, untextured, in submission order like
 * everything else in the list (no depth, ADR-0011). */
static pvr_poly_hdr_t g_pointer_hdr __attribute__((aligned(32)));
static int g_pointer_ready;

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
    if(!g_mouse_on) return;
    if(!g_pointer_ready) {
        pvr_poly_cxt_t cxt;
        pvr_poly_cxt_col(&cxt, PVR_LIST_TR_POLY);
        cxt.gen.culling = PVR_CULLING_NONE;
        cxt.depth.comparison = PVR_DEPTHCMP_ALWAYS;
        cxt.depth.write = false;
        pvr_poly_compile(&g_pointer_hdr, &cxt);
        g_pointer_ready = 1;
    }
    const float x = (float)g_mouse_px, y = (float)g_mouse_py;
    put_hdr(&g_pointer_hdr);
    pointer_tri(x - 1.0f, y - 2.0f, x - 1.0f, y + 20.0f, x + 15.0f, y + 14.0f, 0xFF000000u);
    pointer_tri(x, y, x, y + 16.0f, x + 11.0f, y + 12.0f, 0xFFFFFFFFu);
}
