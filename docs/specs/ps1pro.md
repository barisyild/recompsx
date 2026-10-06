# Spec — PS1 Pro system calls (for programs that run on recompsx)

What recompsx's HLE kernel offers a PlayStation program beyond a retail BIOS, and how a program —
a game being recompiled, a homebrew title, a mod — asks for it. The decision is ADR-0060; the
first call family, the picture's resolution, is ADR-0056, and the screen's shape in it ADR-0064.
The implementation is `src/runtime/kernel/KPro.hx`.

## The call

A PS1 Pro call is the PlayStation's own `syscall` instruction:

| register | holds |
|---|---|
| `$a0` (R4) | the function, 50524F00h + n ("PRO" in its top three bytes) |
| `$a1`-`$a3` (R5-R7) | its arguments |
| `$v0` (R2) | its answer |

Every other register comes back as it was, as from any `syscall`.

**It is safe on every PlayStation.** Sony's kernel defines SYSCALL functions 00h-03h only; any
other number delivers event F0000010h/4000h and returns with every register restored (psx-spx
"BIOS Function Summary": `SYS(04h..FFFFFFFFh) calls DeliverEvent(F0000010h,4000h)`; OpenBIOS
`handlers/syscall.c`). So on a console, or an emulator with a real BIOS, a PS1 Pro call does
nothing, and `$v0` keeps what the caller put in it. A program finds out where it runs by zeroing
`$v0` and calling **Identify**: only recompsx answers `50524F31h` ("PRO1").

(Do not reach these through the A0h/B0h/C0h tables: an unused function number there jumps to
address 0 on a retail kernel — psx-spx lists `B(5Eh..FFh) N/A ;jump_to_00000000h`.)

## Functions

| `$a0` | name | arguments | `$v0` |
|---|---|---|---|
| 50524F00h | **Identify** | — | 50524F31h ("PRO1") on recompsx; untouched elsewhere |
| 50524F10h | **GetVideoScale** | — | the picture's scale, in percent of the PlayStation's resolution (100 = its own) |
| 50524F11h | **SetVideoScale** | `$a1` percent | the scale in effect now (held to 25..400), kept as the console's setting |
| 50524F12h | **GetVideoLines** | `$a1` percent, or 0 for the scale now | the lines the display is drawn at, at that scale, on this console |
| 50524F13h | **HoldPicture** | `$a1` vblanks, or 0 to show the next picture at once | the vblanks the picture is held for (at most 60) |
| 50524F14h | **GetWidescreen** | — | the console's screen: 0 4:3, 1 16:9, 2 STRETCH (16:9, every picture stretched over it) |
| 50524F15h | **SetWidescreen** | `$a1` 0, 1 or 2 | the shape now (0 where the console cannot show 16:9), kept as the console's setting |
| 50524F16h | **SetWidePicture** | `$a1` 1: the program draws for 16:9 from the next picture; 0: for 4:3 | 1 when its wide pictures are shown on a 16:9 screen |

**The video calls** are the console's resolution setting (`video.scale`, ADR-0056): the scale at
which a backend that draws the primitives itself renders them — the browser's WebGL renderer, the
Dreamcast's PVR. It changes the picture only; VRAM and everything a program can read are the same
at every scale, so a program may offer it freely. It is the console's, not the program's: kept
across sessions and shared by every program on that console.

What each console draws differs, which is what **GetVideoLines** is for — the text an options
menu shows. On a 240-line display: the browser answers 240, 480, 720 at 100, 200, 300 (and 192 at 80);
the Dreamcast stops at its screen's 480 lines, so it answers 480 at 300 too; a console that cannot
scale (SDL2 on the desktop, which is handed the finished picture) answers 240 at every scale. Offer
a scale only where it draws lines no other offered scale draws, and call it by them ("240P").
Interlaced 480-line displays answer twice as many.

**HoldPicture** keeps the picture on screen up while a program draws it anew — after a change of
scale, a frozen pause picture drawn again at the new one, say: call it before the first frame of the
redraw with enough vblanks to cover it, and with 0 once the picture is whole again. Meanwhile the
console shows the picture from before, neither the old one stretched nor the frames in between. It
is presentation only — the machine runs exactly as without it — and a console that cannot keep a
picture (or a retail one) simply shows the frames. Crash Bandicoot: Warped's RES line holds for its
redraw's eight game frames (the redraw's four, the menu over both pictures, and a frame in hand).

**The screen's shape** is the console's too (`video.wide`, ADR-0064): 4:3, the PlayStation's; 16:9;
or STRETCH, a 16:9 screen with every picture stretched over it. Every program's pictures are drawn
for 4:3 until it says otherwise, and on 16:9 they are shown at 4:3 in the middle of the screen,
between black bars — never stretched, so a program that knows nothing of widescreen is safe on a
16:9 console. A program that can draw for 16:9 does so when **GetWidescreen** answers 1: anamorphic,
its horizontal squeezed by 3/4 (scale the x row of its view matrix — every projected x then comes
out three quarters as far from the centre, and a third more of its world is seen on each side), and
says so with **SetWidePicture** 1; its pictures then fill the screen. It says 0 again for pictures it
draws for 4:3 — a film, a loading screen — which are then kept to the middle. On STRETCH a program
draws as it always has, and the console stretches its pictures. **SetWidescreen** is what an options
menu offers; it keeps the choice for every program on that console. The browser shows a 16:9 screen
as a 16:9 element; the Dreamcast fills its 640x480 frame, which a 16:9 television stretches, as the
Dreamcast's own widescreen games are shown. A console that cannot show 16:9 answers 0 to all three.
Crash Bandicoot: Warped's WIDESCREEN option (`games/SCUS94244/mods/widescreen`) offers 4:3, 16:9 and
STRETCH, and on 16:9 squeezes the game's own aspect routine and what faces the screen — its sprites,
billboards, HUD and texts, each in its own matrix or polygons — and keeps its pause screen 4:3.

## In a program

C (GCC for MIPS):

```c
/* PS1 Pro system calls (recompsx, docs/specs/ps1pro.md). Harmless on any PlayStation. */
#define PS1PRO_IDENTIFY        0x50524F00
#define PS1PRO_MAGIC           0x50524F31
#define PS1PRO_GET_VIDEO_SCALE 0x50524F10
#define PS1PRO_SET_VIDEO_SCALE 0x50524F11
#define PS1PRO_GET_VIDEO_LINES 0x50524F12
#define PS1PRO_GET_WIDESCREEN  0x50524F14   /* 0 4:3, 1 16:9, 2 STRETCH */
#define PS1PRO_SET_WIDESCREEN  0x50524F15
#define PS1PRO_SET_WIDE_PICTURE 0x50524F16

static inline int ps1pro_call(int fn, int arg) {
    register int a0 __asm__("a0") = fn;
    register int a1 __asm__("a1") = arg;
    register int v0 __asm__("v0") = 0;          /* stays 0 where the call does not exist */
    __asm__ volatile("syscall" : "+r"(v0) : "r"(a0), "r"(a1) : "memory");
    return v0;
}

static int ps1pro_present(void) { return ps1pro_call(PS1PRO_IDENTIFY, 0) == PS1PRO_MAGIC; }
```

Psy-Q assembly, the same call as a function `int Ps1ProCall(int fn, int arg)` (fn in a0, arg in a1
by the calling convention):

```
Ps1ProCall:
        move    v0, zero        ; the answer where the call does not exist
        syscall 0
        jr      ra
        nop
```

An options line for the resolution:

```c
static const int scales[] = { 100, 200, 300 };

/* The lines to call the current choice by, e.g. sprintf(text, "RES: %dP", lines). */
int lines = ps1pro_call(PS1PRO_GET_VIDEO_LINES, 0);

/* Right: the first offered scale that draws more lines; left: the last that draws fewer. */
int next = -1, now = lines;
for (int i = 0; i < 3; i++) {
    int n = ps1pro_call(PS1PRO_GET_VIDEO_LINES, scales[i]);
    if (right ? (next < 0 && n > now) : (n < now)) next = i;
}
if (next >= 0) ps1pro_call(PS1PRO_SET_VIDEO_SCALE, scales[next]);
```

Drawing for the screen's shape, at start and after an options menu changed it:

```c
/* 16:9: the view's x squeezed by 3/4, and the console told; 4:3 and STRETCH: as always. */
int wide = ps1pro_call(PS1PRO_GET_WIDESCREEN, 0) == 1;
view_x_scale = wide ? 3072 : 4096;                 /* 4.12 fixed point, in the view matrix's x row */
ps1pro_call(PS1PRO_SET_WIDE_PICTURE, wide);
```

Crash Bandicoot: Warped's RES line (`games/SCUS94244/mods/resolution`) is a mod doing exactly
this through `ModHost.syscall`, which runs the kernel's `syscall` with the game's registers as the
instruction would (`menu.Pro`, which every line of its OPTIONS shares). A mod is compiled with the game for one console, so it may also fix its list
there: the Dreamcast's build lists 100 and 200 (`#if dreamcast`, ADR-0033). A PlayStation program
built once for every console finds the same by GetVideoLines, as above.

## Adding a call

A new PS1 Pro function takes the next number in its family (50524F1xh video; a new family takes
the next 10h), is answered in `KPro.syscall`, leaves every register but `$v0`, and is listed here
and in `KPro`'s table. Numbers are never reused or changed: a program built against one keeps
working. `ProCalls` in tests/conformance holds every call to one digest on every target.
