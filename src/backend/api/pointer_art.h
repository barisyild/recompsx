/* pointer_art.h — the machine's pointer, as the backends that show one show it (ADR-0038).
 *
 * 16 x 24 pixels, a letter a pixel: K the outline, W and H the highlights, G the body, B the shaded
 * edge, D the inner shadow, '.' clear — the owner's art (ps1_cursor.svg, its colours exactly). Its
 * tip, the hotspot, is the top left. The Dreamcast draws it as a texture at the console's own
 * 640 x 480 (dc_input.c), SDL2 makes the host's cursor of it (backend_sdl2.c), and the page's
 * cursor is the same picture as PNG at 1x and 2x (web/index.html) — change it here, then there. */
#ifndef RECOMPSX_POINTER_ART_H
#define RECOMPSX_POINTER_ART_H

#include <stdint.h>

#define POINTER_W 16
#define POINTER_H 24

static const char* const k_pointer[POINTER_H] = {
    "KK..............",
    "KKK.............",
    "KWBK............",
    "KHWBK...........",
    "KHGHBK..........",
    "KHGGHBK.........",
    "KHGGGHBK........",
    "KHGGGGHBK.......",
    "KHGGGGGHBK......",
    "KHGGGGGGHBK.....",
    "KHGGGGGGGHBK....",
    "KHGGGGGGGGHBK...",
    "KHGGGGGGGGGHBK..",
    "KHGGGGGGGGGGHBK.",
    "KHGGGGGGDDDDDDBK",
    "KHGGGGGGDKKKKKKK",
    "KHGGGBGGDK......",
    "KHGGBKGGGBK.....",
    "KHGBK.KGGBK.....",
    "KDBK..KGGGBK....",
    "KKK....KGGBK....",
    ".......KGGGBK...",
    "........KGGBK...",
    ".........KKK....",
};

/* A letter's colour, 0xAARRGGBB; clear is 0. */
static inline uint32_t pointer_argb(char c) {
    switch(c) {
        case 'K': return 0xFF202024u;
        case 'W': return 0xFFFAFAF9u;
        case 'H': return 0xFFDFDEDEu;
        case 'G': return 0xFFBABABBu;
        case 'B': return 0xFF53638Au;
        case 'D': return 0xFF838994u;
        default:  return 0;
    }
}

#endif
