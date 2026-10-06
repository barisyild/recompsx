/* dc_hotcode.c — the hot code laid out at run time (ADR-0063).
 *
 * The SH-4's instruction cache is 8 KB and direct-mapped: which functions evict each other is where they
 * sit, and a link decides that before anything runs. A JIT gets this for free — its code cache fills in the
 * order the program first runs, so what runs together sits together — and a placement made offline from a
 * trace of the game does it better still, for that game and that build only. This does the trace's work
 * on the console, for whatever game is running: for a window of presents the emulation thread's PC is
 * sampled at a high rate; then the functions that held most of the samples are copied into an arena, each
 * at the colour (its first line's index, mod 256) where its sampled lines meet least of what the samples
 * say runs beside it, and every word that pointed at one of them points at its copy.
 *
 * What may move, and which words point at it, comes from the link (scripts/dc-hotcode.py, HOTCODE.BIN):
 * our own functions, none of which reaches outside itself relative to the PC, and every 32-bit absolute
 * relocation that targets one. The originals stay where they are and as they were but for those words:
 * a frame that is live in one when the code moves returns into it and goes on there, correctly, and calls
 * the copies from then on. When the code moves again, the words point at the new copies (or back at the
 * originals) — the older copies' own words too, or a frame that never leaves one would call that arena's
 * copies for good — and an older arena is given back once no thread's stack or registers point into it (a
 * conservative scan: a word that only looks like a pointer keeps it, never the other way). Nothing here
 * touches emulated state; a copy is the same instructions.
 *
 * The layout, from the samples (each a section and a line in it, in time order; a sample in a copy is
 * its original's):
 *   heat      samples per section; the hottest, while the arena's budget lasts, are the ones moved
 *   lines     samples per line of each moved section
 *   W(p, q)   how often p and q were sampled within HC_WINDOW samples of each other (a temporal
 *             relationship graph, Gloy and Smith 1997): how much they run together, so how much it
 *             costs when they share lines of the cache
 *   colour    hottest first, each section at the colour where its lines meet the least W-weighted line
 *             heat of its HC_NEAR strongest neighbours already given one
 *   half      each sample's operand too, decoded from the interrupted instruction and its registers (a
 *             statistical operand trace): which of the 16 KB operand cache's two halves a moved section goes in,
 *             so that its literal pools — read through that cache — meet less of the sampled data
 *   arena     the sections in the order that pads least, each at its colour and half (keeping its offset into
 *             its first line, so every alignment up to a line holds), in memory aligned to 16 KB
 * The work after a window is done in the time a game spends waiting for its vblank (hotcode_idle, from
 * the pacer) when it has any, and a slice a present (HC_SLICE_US) when it has none, so moving the code costs
 * no present more than a few milliseconds (a new phase of a game is laid out ~2.5 s after it begins, in
 * auto mode); the words are rewritten a slice at a time too, which is safe: every word
 * points at good code at every moment — an original, an older copy or a new one, all the same instructions.
 *
 * When: `--dc-hotcode=FROM:TO[,FROM:TO...]` samples from present FROM to present TO and moves the code
 * after TO, for each window given, and `--dc-hotcode=off` never. Otherwise (`--dc-hotcode=auto`, or nothing
 * said) it watches: the profiler's own 250 Hz samples
 * (samp_tick, hotcode_tick) say, every HC_AUTO_CHECK presents, how much of the time spent in movable code
 * was spent in the copies, and the pacer how long the game waited for its vblanks (hotcode_slack). From
 * present HC_AUTO_FIRST, when there are no copies yet or that share is under HC_AUTO_KEEP percent at
 * HC_AUTO_LOOKS looks in a row — the game has moved on to code the copies do not hold — then if the game is
 * behind its rate (it waited less than HC_AUTO_SLACK a vblank) a window of HC_AUTO_LEN presents opens, at
 * least HC_AUTO_GAP presents after the last layout; and if it keeps its rate, the layout is given back and
 * the game runs as linked, which a layout made for another of its phases can be worse than. Each condition
 * holds at HC_AUTO_LOOKS looks in a row. `--dc-hotcode-kb=N` is an arena's budget of code (192 KB). */
#include "dc_internal.h"

#if RECOMPSX_HOTCODE
#include <kos/cache.h>
#include <kos/irq.h>
#include <malloc.h>
#include <unistd.h>
#include <arch/irq.h>
#include <arch/stack.h>
#include <arch/timer.h>
#include <stdarg.h>

/* HOTCODE.BIN names this function's address: a table from another build is refused. */
__attribute__((noinline, used)) void hotcode_anchor(void) { __asm__ volatile("" ::: "memory"); }

#define HC_LINE       32u
#define HC_COLOURS    256u
#define HC_OCOLOURS   512u    /* lines of the 16 KB operand cache */
#define HC_HZ         20000   /* samples a second while a window is open */
#define HC_WINDOW     4       /* samples that count as "beside" one another */
#define HC_MAX        320     /* sections moved at most (W is HC_MAX^2 halfwords) */
#define HC_NEAR       32      /* neighbours a section's colour is chosen against, at most */
#define HC_FIXED      32      /* pinned sections, hottest first, the others are coloured around (where they are) */
#define HC_CM_ONE     64u     /* a section's whole heat, in its colour map */
#define HC_WINDOWS    8       /* windows a command line gives at most */
#define HC_ARENAS     4       /* arenas held at once (an old one stays while a frame may be live in it) */
#define HC_SLICE_US   3000    /* a present's share of the layout's work */
#define HC_IDLE_GRACE 4       /* presents without spare time at the vblank before a present gives a slice: a game
                               * that waits at some vblanks has the work done there (Crash Bash's 30 Hz match:
                               * every other present waits ~13 ms), not added to the ones that are late */
#define HC_RESERVE    (512u * 1024u)   /* heap left free after an arena, at least */
#define HC_REAP_EVERY 120     /* presents between looks at whether an older arena can be given back */
#define HC_HELD_PIN   8       /* looks an arena is found held at before what holds it is pinned: a conservative scan
                               * also finds stale words in live frames, and at 3 looks those pinned hot functions for
                               * good (Crash 3: portRead32 and the like, held by the title's layout: 20.02 a present
                               * in auto mode against 19.0-19.2 with one explicit window, the same binary) */
#define HC_AUTO_FIRST 300     /* presents before the first window: past the boot's own code */
#define HC_AUTO_LOOKS 3       /* looks in a row under the share before a window: a load or a cut is not laid out for */
#define HC_AUTO_CHECK 20      /* presents between looks at the share of time in the copies */
#define HC_AUTO_MIN   40      /* low-rate samples in movable code a look needs */
#define HC_AUTO_KEEP  70      /* the share, in percent, under which the code is laid out again */
#define HC_AUTO_LEN   45      /* a window's presents */
#define HC_AUTO_GAP   300     /* presents from one layout to the next window, at least */
#define HC_MIN_SHARE  40      /* percent of a window's samples at full load (HC_HZ through its presents at 60 a second)
                               * that must fall in movable code before anything is laid out by it */
#define HC_AUTO_SLACK 1000    /* microseconds a present the game may wait for its vblank, on average over a look,
                               * and still be behind its rate: a game with more is at full speed as linked, and
                               * nothing is laid out for it (a layout for another phase is given back instead) */

static uint32_t  g_hc_nsec, g_hc_nref, g_hc_site, g_hc_nsite;
static uint32_t* g_hc_sec;        /* nsec x (start, size), by start */
static uint32_t* g_hc_ref;        /* nref addresses of words that may point at a movable section */
/* Sections never moved again: a copy of each was found under a frame still live when its arena was to be
 * given back — a function that does not return (a game's main loop, the runner), which would keep every
 * arena it is copied into for good. */
static uint8_t*  g_hc_pin;        /* per section: the arenas that pinned it (never moved while any does) */
static int       g_hc_win[HC_WINDOWS][2];
static int       g_hc_nwin, g_hc_wnext, g_hc_auto;
static int       g_hc_from = -1, g_hc_to = -1;    /* the window open or next */
static uint32_t  g_hc_budget = 192u * 1024u;
static int       g_hc_off;        /* no table, or no more windows */
static uint32_t  g_hc_last;       /* the present of the last layout */
static int       g_hc_low;        /* looks in a row that found the share under HC_AUTO_KEEP */
static int       g_hc_behind, g_hc_ahead;   /* looks in a row that found the game behind its rate, keeping it */
static uint32_t  g_hc_layouts;    /* layouts made since boot */
static int       g_hc_current;    /* the newest arena is the layout in use (not given back by a revert) */
static uint32_t  g_hc_slack, g_hc_slack_n;   /* microseconds the game waited for its vblanks since the last look,
                                                * and the vblanks (the pacer) */
static uint32_t  g_hc_reverts;    /* layouts given back since boot */
static volatile uint32_t  g_hc_lo_total, g_hc_lo_in;   /* low-rate samples in movable code, in the copies */
static uint32_t* volatile g_hc_buf;
static volatile uint32_t  g_hc_n;
static uint32_t  g_hc_cap;

/* The arenas held: each copy by its address, with its original's, for a sample taken in a copy and for a
 * word that points into one when the code moves again; the newest last. g_hc_nar is raised last when one
 * is added and an arena is taken out with interrupts off, so the profiler's interrupt (hotcode_original)
 * sees each whole or not at all. */
#define HC_PINS       8       /* sections an arena may pin */
typedef struct { int n; uint32_t* copy; uint32_t* orig; uint32_t* size; uint8_t* mem; uint32_t lo, hi; int held;
                 uint16_t pins[HC_PINS]; int npins; } hc_arena_t;   /* pins: unpinned when the arena goes */
static hc_arena_t    g_hc_ar[HC_ARENAS];
static volatile int  g_hc_nar;

/* The profiling run's lines (`--dc-rxprof`): the layouts, their maps of copies, the looks. Kept here and printed
 * when the bench stops (hotcode_flush): the serial port takes ~4 ms a line, so a layout's map printed as it
 * was made was a quarter-second stall wherever it fell, a bench window too. Each line names its present. */
#define HC_LOG_BYTES (128u * 1024u)
static char*    g_hc_log;
static uint32_t g_hc_logn, g_hc_logp;
static void hc_logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void hc_logf(const char* fmt, ...) {
#if RECOMPSX_DC_PROFILE
    if(!g_rxprof) return;
    else {}
    if(!g_hc_log) g_hc_log = malloc(HC_LOG_BYTES);
    else {}
    if(!g_hc_log || g_hc_logn + 256u > HC_LOG_BYTES) return;
    else {}
    g_hc_logn += (uint32_t)snprintf(g_hc_log + g_hc_logn, 32, "@@hc p%lu ", (unsigned long)g_hc_logp);
    va_list ap;
    va_start(ap, fmt);
    const int n = vsnprintf(g_hc_log + g_hc_logn, HC_LOG_BYTES - g_hc_logn, fmt, ap);
    va_end(ap);
    if(n > 0) g_hc_logn += (uint32_t)n < HC_LOG_BYTES - g_hc_logn ? (uint32_t)n : HC_LOG_BYTES - g_hc_logn - 1u;
    else {}
#else
    (void)fmt;
#endif
}
void hotcode_flush(void) {
    if(!g_hc_log || g_hc_logn == 0) return;
    else {}
    fwrite(g_hc_log, 1, g_hc_logn, stdout);
    fflush(stdout);
    g_hc_logn = 0;
}

uint32_t hotcode_original(uint32_t a) {
    for(int k = g_hc_nar - 1; k >= 0; k--) {
        const hc_arena_t* r = &g_hc_ar[k];
        if(a < r->lo || a >= r->hi) continue;
        else {}
        int lo = 0, hi = r->n - 1;
        while(lo <= hi) {
            const int mid = (lo + hi) >> 1;
            if(a < r->copy[mid]) hi = mid - 1;
            else if(a >= r->copy[mid] + r->size[mid]) lo = mid + 1;
            else return r->orig[mid] + (a - r->copy[mid]);
        }
        return a;     /* the arena's padding */
    }
    return a;
}

static int hc_find(uint32_t pc) {
    int lo = 0, hi = (int)g_hc_nsec - 1;
    while(lo <= hi) {
        const int mid = (lo + hi) >> 1;
        const uint32_t s = g_hc_sec[mid * 2];
        if(pc < s) hi = mid - 1;
        else if(pc >= s + g_hc_sec[mid * 2 + 1]) lo = mid + 1;
        else return mid;
    }
    return -1;
}

static void hc_next_window(void) {
    if(g_hc_auto) {
        g_hc_from = 0x7FFFFFFF;           /* opened by hotcode_present's look, not by a present count */
        g_hc_to = 0x7FFFFFFF;
    } else if(g_hc_wnext < g_hc_nwin) {
        g_hc_from = g_hc_win[g_hc_wnext][0];
        g_hc_to = g_hc_win[g_hc_wnext][1];
        g_hc_wnext++;
    } else {
        g_hc_off = 1;
    }
}

void hotcode_init(const char* window, const char* kb) {
    g_hc_off = 1;
    if(window && strcmp(window, "off") == 0) return;
    else {}
    if(!window || strncmp(window, "auto", 4) == 0) g_hc_auto = 1;
    else {
        const char* p = window;
        while(*p && g_hc_nwin < HC_WINDOWS) {
            int from, to, used = 0;
            if(sscanf(p, "%d:%d%n", &from, &to, &used) != 2 || from < 0 || to <= from
               || (g_hc_nwin > 0 && from < g_hc_win[g_hc_nwin - 1][1])) {
                bp_log(BP_LOG_WARN, "--dc-hotcode=FROM:TO[,FROM:TO...] wants present counts, each window after the last");
                return;
            } else {}
            g_hc_win[g_hc_nwin][0] = from;
            g_hc_win[g_hc_nwin][1] = to;
            g_hc_nwin++;
            p += used;
            if(*p == ',') p++;
            else break;
        }
    }
    int k;
    if(kb && sscanf(kb, "%d", &k) == 1 && k >= 16 && k <= 4096) g_hc_budget = (uint32_t)k * 1024u;
    else {}
    static const char* paths[] = { "/pc/HOTCODE.BIN", "/cd/HOTCODE.BIN", "/cd/hotcode.bin" };
    FILE* f = NULL;
    for(size_t i = 0; i < sizeof(paths) / sizeof(paths[0]) && !f; i++) f = fopen(paths[i], "rb");
    if(!f) { bp_log(BP_LOG_WARN, "hotcode: no HOTCODE.BIN — the code stays where the link put it"); return; }
    uint32_t head[6];
    const char* why = NULL;
    if(fread(head, 4, 6, f) != 6 || memcmp(head, "RHC1", 4) != 0) why = "HOTCODE.BIN unreadable";
    else if(head[1] != (uint32_t)(uintptr_t)hotcode_anchor) why = "HOTCODE.BIN is from another build";
    else {
        g_hc_nsec = head[2]; g_hc_nref = head[3]; g_hc_site = head[4]; g_hc_nsite = head[5];
        g_hc_sec = malloc(g_hc_nsec * 8u);
        g_hc_ref = malloc(g_hc_nref * 4u);
        g_hc_pin = calloc(g_hc_nsec, 1u);
        if(!g_hc_sec || !g_hc_ref || !g_hc_pin || fread(g_hc_sec, 8, g_hc_nsec, f) != g_hc_nsec
           || fread(g_hc_ref, 4, g_hc_nref, f) != g_hc_nref) {
            free(g_hc_sec); free(g_hc_ref); free(g_hc_pin); g_hc_sec = NULL; g_hc_ref = NULL; g_hc_pin = NULL;
            why = "HOTCODE.BIN unreadable";
        } else {}
    }
    fclose(f);
    if(why) { bp_log(BP_LOG_WARN, why); return; }
    else {}
    g_hc_off = 0;
    hc_next_window();
    char msg[120];
    snprintf(msg, sizeof(msg), "hotcode: %lu movable sections, %lu references; %s, first window %d..%d",
             (unsigned long)g_hc_nsec, (unsigned long)g_hc_nref, g_hc_auto ? "auto" : "windows", g_hc_from, g_hc_to);
    bp_log(BP_LOG_INFO, msg);
}

/* ---- sampling --------------------------------------------------------------------------------------- */

/* The operand address of the SH-4 instruction `op` about to run at `pc`, with registers r[] and gbr as the
 * interrupted context has them; 0 for one that reaches no memory (or a form not decoded: the rare ones —
 * mac, tas, the logical ops on @(R0,GBR) — count as none). With the PC, a statistical operand trace: where
 * in the 16 KB operand cache the time's data lives, and which literal pools the code reads. */
static uint32_t hc_operand(uint16_t op, uint32_t pc, const uint32_t* r, uint32_t gbr) {
    const uint32_t n = (op >> 8) & 15, m = (op >> 4) & 15, lo = op & 15;
    switch(op >> 12) {
    case 0x0:
        if((lo == 4 || lo == 5 || lo == 6)) return r[0] + r[n];                  /* mov.x Rm,@(R0,Rn) */
        else if(lo == 0xC || lo == 0xD || lo == 0xE) return r[0] + r[m];         /* mov.x @(R0,Rm),Rn */
        else if((op & 0xFF) == 0xC3 || (op & 0xFF) == 0x83) return r[n];         /* movca.l, pref */
        else return 0;
    case 0x1: return r[n] + lo * 4u;                                              /* mov.l Rm,@(disp,Rn) */
    case 0x2:
        if(lo <= 2) return r[n];                                                  /* mov.x Rm,@Rn */
        else if(lo >= 4 && lo <= 6) return r[n] - (1u << (lo - 4));              /* mov.x Rm,@-Rn */
        else return 0;
    case 0x4:
        if((op & 0xF) == 0x2 || (op & 0xF) == 0x3) return r[n] - 4u;             /* sts.l/stc.l x,@-Rn */
        else if((op & 0xF) == 0x6 || (op & 0xF) == 0x7) return r[n];             /* lds.l/ldc.l @Rm+,x */
        else return 0;
    case 0x5: return r[m] + lo * 4u;                                              /* mov.l @(disp,Rm),Rn */
    case 0x6:
        if(lo <= 2 || (lo >= 4 && lo <= 6)) return r[m];                          /* mov.x @Rm(+),Rn */
        else return 0;
    case 0x8:
        if(n == 0x0) return r[m] + lo;                                            /* mov.b R0,@(disp,Rn) */
        else if(n == 0x1) return r[m] + lo * 2u;                                  /* mov.w R0,@(disp,Rn) */
        else if(n == 0x4) return r[m] + lo;                                       /* mov.b @(disp,Rm),R0 */
        else if(n == 0x5) return r[m] + lo * 2u;                                  /* mov.w @(disp,Rm),R0 */
        else return 0;
    case 0x9: return pc + 4u + (op & 0xFF) * 2u;                                  /* mov.w @(disp,PC),Rn */
    case 0xC: {
        const uint32_t k = n, d = op & 0xFF;
        if(k == 0 || k == 4) return gbr + d;                                      /* mov.b ...GBR */
        else if(k == 1 || k == 5) return gbr + d * 2u;                            /* mov.w ...GBR */
        else if(k == 2 || k == 6) return gbr + d * 4u;                            /* mov.l ...GBR */
        else return 0;
    }
    case 0xD: return (pc & ~3u) + 4u + (op & 0xFF) * 4u;                          /* mov.l @(disp,PC),Rn */
    case 0xF:
        if(lo == 0x8 || lo == 0x9) return r[m];                                   /* fmov @Rm(+),FRn */
        else if(lo == 0xA) return r[n];                                           /* fmov FRm,@Rn */
        else if(lo == 0xB) return r[n] - 4u;                                      /* fmov FRm,@-Rn */
        else if(lo == 0x6) return r[0] + r[m];                                    /* fmov @(R0,Rm),FRn */
        else if(lo == 0x7) return r[0] + r[n];                                    /* fmov FRm,@(R0,Rn) */
        else return 0;
    default: return 0;
    }
}

/* A sample of the profiler's own (samp_tick, 250 Hz, the emulation thread's), in auto mode: whether it fell
 * in movable code, and whether in the newest arena's copies. In the interrupt. */
void hotcode_tick(uint32_t pc) {
    if(!g_hc_auto || g_hc_off || g_hc_buf || !g_hc_sec) return;
    else {}
    const int k = g_hc_current ? g_hc_nar - 1 : -1;
    if(k >= 0 && pc >= g_hc_ar[k].lo && pc < g_hc_ar[k].hi) {
        g_hc_lo_in++;
        g_hc_lo_total++;
        return;
    } else {}
    if(hc_find(hotcode_original(pc)) >= 0) g_hc_lo_total++;
    else {}
}

static void hc_tick(irq_t code, irq_context_t* ctx, void* data) {
    (void)code; (void)data;
    timer_clear(TMU1);       /* first and always: the underflow flag holds until cleared (samp_tick) */
    if(thd_get_current() != g_emu_thread) return;
    else {}
    const uint32_t n = g_hc_n;
    if(n < g_hc_cap) {
        const uint32_t pc = CONTEXT_PC(*ctx);
        g_hc_buf[n * 2] = pc;
        g_hc_buf[n * 2 + 1] = hc_operand(*(const uint16_t*)(uintptr_t)pc, pc, ctx->r, ctx->gbr);
        g_hc_n = n + 1;
    } else {}
}

/* ---- the job: the work after a window, a slice a present ----------------------------------------------- */

enum { J_NONE, J_SAMPLE, J_CLASSIFY, J_GRAPH, J_COLOUR, J_PLACE, J_COPY, J_PATCH, J_PATCH_OLD, J_FINISH };

static struct {
    int phase;
    uint32_t i;                   /* how far the phase has got */
    uint32_t n, kept, npool, in_last;
    uint32_t* heat; int16_t* slot; uint16_t* order; uint32_t* pool; uint32_t* dheat;
    uint16_t* lines; uint16_t* W; uint8_t* cm;
    int N, F, M, recent[HC_WINDOW], nrecent, rhead, lastsec;   /* members: F fixed (pinned) first, then M moved */
    uint32_t used, lines_total, span, patched;
    uint8_t* arena;
    uint32_t us[6];               /* each phase's time, for the log */
    uint32_t presents;            /* presents the job's work took */
    int window;                   /* the window's presents */
    int revert;                   /* the job gives the code back to the link's layout: words only */
} J;

static uint16_t g_hc_chosen[HC_MAX];
static uint32_t g_hc_loff[HC_MAX], g_hc_nlines[HC_MAX], g_hc_colour[HC_MAX], g_hc_offs[HC_MAX];
static uint32_t g_hc_ostart[HC_MAX], g_hc_osize[HC_MAX], g_hc_base[HC_MAX];
static int      g_hc_idx[HC_MAX];
static uint32_t g_hc_hole_s[HC_MAX + 2], g_hc_hole_e[HC_MAX + 2];   /* the arena's holes while it is packed */
static uint32_t g_hc_ocost[HC_MAX * 2];   /* data heat a section's pools meet in each half */

static void hc_job_free(void) {
    free(J.heat); free(J.slot); free(J.order); free(J.pool); free(J.dheat);
    free(J.lines); free(J.W); free(J.cm);
    J.heat = NULL; J.slot = NULL; J.order = NULL; J.pool = NULL; J.dheat = NULL;
    J.lines = NULL; J.W = NULL; J.cm = NULL;
    free(g_hc_buf);
    g_hc_buf = NULL;
    J.phase = J_NONE;
}

static void hc_job_abort(const char* why) {
    bp_log(BP_LOG_WARN, why);
    hc_job_free();
}

static void hc_open(void) {
    /* Room for the window at 25 ms a present, the slowest a game this is worth doing for runs. */
    g_hc_cap = (uint32_t)(g_hc_to - g_hc_from) * (HC_HZ / 40) + 1024;
    g_hc_buf = malloc(g_hc_cap * 8u);   /* a PC and an operand address a sample */
    if(!g_hc_buf) { bp_log(BP_LOG_WARN, "hotcode: no memory for the samples"); hc_next_window(); return; }
    else {}
    g_hc_n = 0;
    timer_stop(TMU1);
    irq_set_handler(EXC_TMU1_TUNI1, hc_tick, NULL);
    timer_prime(TMU1, HC_HZ, 1);
    timer_start(TMU1);
    memset(&J, 0, sizeof J);            /* a struct of no promised alignment: shz_memset8 wants 8 */
    J.phase = J_SAMPLE;
    J.lastsec = -1;
}

/* The moved section holding `a`, or -1: start[] is sorted. */
static int hc_moved(const uint32_t* start, const uint32_t* size, int n, uint32_t a) {
    int lo = 0, hi = n - 1;
    while(lo <= hi) {
        const int mid = (lo + hi) >> 1;
        if(a < start[mid]) hi = mid - 1;
        else if(a >= start[mid] + size[mid]) lo = mid + 1;
        else return mid;
    }
    return -1;
}

static uint32_t* g_hc_heat_for_sort;
static int hc_by_heat(const void* a, const void* b) {
    const uint32_t x = g_hc_heat_for_sort[*(const uint16_t*)a], y = g_hc_heat_for_sort[*(const uint16_t*)b];
    if(x != y) return x > y ? -1 : 1;
    else return *(const uint16_t*)a < *(const uint16_t*)b ? -1 : 1;
}

/* 1. each sample a section and a line in it ((section << 16) | line, in place), and each operand a literal
 *    pool of a movable section (J.pool) or data, counted by its line of the operand cache (J.dheat) */
static int hc_classify(uint64_t until) {
    uint32_t* const buf = g_hc_buf;
    const uint32_t code_lo = g_hc_sec[0], code_hi = g_hc_sec[(g_hc_nsec - 1) * 2] + g_hc_sec[(g_hc_nsec - 1) * 2 + 1];
    const hc_arena_t* last = g_hc_current && g_hc_nar > 0 ? &g_hc_ar[g_hc_nar - 1] : NULL;
    while(J.i < J.n) {
        const uint32_t stop = J.i + 512 < J.n ? J.i + 512 : J.n;
        for(; J.i < stop; J.i++) {
            const uint32_t raw = buf[J.i * 2], ea = buf[J.i * 2 + 1];
            if(last && raw >= last->lo && raw < last->hi) J.in_last++;
            else {}
            const uint32_t pc = hotcode_original(raw);
            int s = J.lastsec;
            if(s < 0 || pc < g_hc_sec[s * 2] || pc >= g_hc_sec[s * 2] + g_hc_sec[s * 2 + 1]) {
                s = hc_find(pc);
                if(s >= 0) J.lastsec = s;
                else {}
            } else {}
            if(ea) {
                /* data, unless it is in the code (as linked, or a copy): most such reads are the pool of the
                 * code reading it */
                int inarena = 0;
                for(int k = 0; k < g_hc_nar; k++) if(ea >= g_hc_ar[k].lo && ea < g_hc_ar[k].hi) inarena = 1; else {}
                if(!inarena && (ea < code_lo || ea >= code_hi)) J.dheat[(ea / HC_LINE) & (HC_OCOLOURS - 1)]++;
                else {
                    const uint32_t o = hotcode_original(ea);
                    int se = s;
                    if(se < 0 || o < g_hc_sec[se * 2] || o >= g_hc_sec[se * 2] + g_hc_sec[se * 2 + 1]) se = hc_find(o);
                    else {}
                    if(se >= 0) J.pool[J.npool++] = ((uint32_t)se << 16) | ((g_hc_sec[se * 2] % HC_LINE + o - g_hc_sec[se * 2]) / HC_LINE);
                    else J.dheat[(ea / HC_LINE) & (HC_OCOLOURS - 1)]++;
                }
            } else {}
            if(s < 0) continue;
            else {}
            const uint32_t lead = g_hc_sec[s * 2] % HC_LINE;
            buf[J.kept++] = ((uint32_t)s << 16) | ((lead + pc - g_hc_sec[s * 2]) / HC_LINE);
            J.heat[s]++;
        }
        if(bp_time_us() >= until) return 0;
        else {}
    }
    return 1;
}

/* 2. the hottest, while the budget lasts; the arrays the graph needs. The pinned among the hottest take part
 *    too, first and where they are (HC_FIXED of them): a function that never leaves the stack (the runtime's
 *    pump, a game's loop) is hot and stays put, and the copies are coloured around it rather than onto it
 *    (Crash 3: the pump, 1.3 % of the time, pinned, met the copies at 0.03-0.17 ms a present from one layout
 *    to the next). */
static int hc_choose(void) {
    uint32_t hot = 0;
    for(uint32_t s = 0; s < g_hc_nsec; s++) if(J.heat[s]) J.order[hot++] = (uint16_t)s; else {}
    g_hc_heat_for_sort = J.heat;
    qsort(J.order, hot, 2, hc_by_heat);
    int N = 0, nfix = 0;
    uint32_t used = 0, lines_total = 0;
    for(uint32_t k = 0; k < hot && nfix < HC_FIXED; k++) {
        const uint32_t s = J.order[k];
        if(!g_hc_pin[s]) continue;
        else {}
        g_hc_chosen[N++] = (uint16_t)s;
        nfix++;
        lines_total += (g_hc_sec[s * 2] % HC_LINE + g_hc_sec[s * 2 + 1] + HC_LINE - 1) / HC_LINE;
    }
    for(uint32_t k = 0; k < hot && N < HC_MAX; k++) {
        const uint32_t s = J.order[k], lead = g_hc_sec[s * 2] % HC_LINE;
        if(g_hc_pin[s]) continue;
        else {}
        const uint32_t nl = (lead + g_hc_sec[s * 2 + 1] + HC_LINE - 1) / HC_LINE;
        if(used + nl * HC_LINE > g_hc_budget) continue;
        else {}
        g_hc_chosen[N++] = (uint16_t)s;
        used += nl * HC_LINE;
        lines_total += nl;
    }
    if(N == nfix) return 0;
    else {}
    J.F = nfix;
    J.M = N - nfix;
    J.N = N;
    J.used = used;
    J.lines_total = lines_total;
    for(uint32_t s = 0; s < g_hc_nsec; s++) J.slot[s] = -1;
    for(int k = 0; k < N; k++) J.slot[g_hc_chosen[k]] = (int16_t)k;
    J.lines = calloc(lines_total, 2u);
    J.W = calloc((size_t)N * (size_t)N, 2u);
    J.cm = calloc((size_t)N * HC_COLOURS, 1u);
    if(!J.lines || !J.W || !J.cm) return 0;
    else {}
    for(int k = 0, at = 0; k < N; k++) {
        const uint32_t s = g_hc_chosen[k], lead = g_hc_sec[s * 2] % HC_LINE;
        g_hc_loff[k] = (uint32_t)at;
        g_hc_nlines[k] = (lead + g_hc_sec[s * 2 + 1] + HC_LINE - 1) / HC_LINE;
        at += (int)g_hc_nlines[k];
    }
    J.i = 0;
    return 1;
}

/* 3. line heat and the relationship graph, over the moved sections */
static int hc_graph(uint64_t until) {
    uint32_t* const buf = g_hc_buf;
    const int N = J.N;
    while(J.i < J.kept) {
        const uint32_t stop = J.i + 512 < J.kept ? J.i + 512 : J.kept;
        for(; J.i < stop; J.i++) {
            const int s = (int)(buf[J.i] >> 16), k = J.slot[s];
            if(k >= 0) {
                uint16_t* l = &J.lines[g_hc_loff[k] + (buf[J.i] & 0xFFFF)];
                if(*l != 0xFFFF) (*l)++;
                else {}
                int seen[HC_WINDOW], ns = 0;
                for(int r = 0; r < J.nrecent; r++) {
                    const int q = J.recent[r];
                    if(q == s || J.slot[q] < 0) continue;
                    else {}
                    int dup = 0;
                    for(int t = 0; t < ns; t++) if(seen[t] == q) dup = 1; else {}
                    if(dup) continue;
                    else {}
                    seen[ns++] = q;
                    uint16_t* a = &J.W[(size_t)k * (size_t)N + (size_t)J.slot[q]];
                    uint16_t* b = &J.W[(size_t)J.slot[q] * (size_t)N + (size_t)k];
                    if(*a != 0xFFFF) (*a)++;
                    else {}
                    if(*b != 0xFFFF) (*b)++;
                    else {}
                }
            } else {}
            J.recent[J.rhead] = s;
            J.rhead = (J.rhead + 1) % HC_WINDOW;
            if(J.nrecent < HC_WINDOW) J.nrecent++;
            else {}
        }
        if(bp_time_us() >= until) return 0;
        else {}
    }
    J.i = 0;
    return 1;
}

/* 4. colours, hottest first, each against its HC_NEAR strongest neighbours placed before it: the rest of the
 *    graph's weight is spread thin, and the same layout comes out (a trace of Crash 3's demo: 32 as good as
 *    all, 16 2 % more misses) at a fraction of the work */
static int hc_colour(uint64_t until) {
    const int N = J.N;
    while((int)J.i < N) {
        const int k = (int)J.i;
        if(k < J.F) {
            /* a pinned member: where it runs — the copy its live frame is in (the oldest arena holding one: a
             * loop that never returns stays in the copy it was in when it was pinned), else the original — with
             * its own line heat in its colour map */
            uint32_t at = g_hc_sec[g_hc_chosen[k] * 2];
            for(int r = 0; r < g_hc_nar; r++) {
                const hc_arena_t* ar = &g_hc_ar[r];
                for(int j = 0; j < ar->n; j++) if(ar->orig[j] == at) { at = ar->copy[j]; r = g_hc_nar; break; } else {}
            }
            const uint32_t c = (at / HC_LINE) & (HC_COLOURS - 1);
            const uint16_t* hl = &J.lines[g_hc_loff[k]];
            uint32_t acc[HC_COLOURS];
            for(uint32_t q = 0; q < HC_COLOURS; q++) acc[q] = 0;
            for(uint32_t l = 0; l < g_hc_nlines[k]; l++) acc[(c + l) & (HC_COLOURS - 1)] += hl[l];
            const uint32_t h = J.heat[g_hc_chosen[k]] ? J.heat[g_hc_chosen[k]] : 1;
            uint8_t* m = &J.cm[(size_t)k * HC_COLOURS];
            for(uint32_t q = 0; q < HC_COLOURS; q++) m[q] = (uint8_t)((acc[q] * HC_CM_ONE + h / 2) / h);
            g_hc_colour[k] = c;
            J.i++;
            continue;
        } else {}
        uint32_t occ[HC_COLOURS];
        for(uint32_t c = 0; c < HC_COLOURS; c++) occ[c] = 0;
        int nq = 0;
        uint16_t nw[HC_NEAR];
        uint16_t nqi[HC_NEAR];
        for(int q = 0; q < k; q++) {
            const uint16_t w = J.W[(size_t)k * (size_t)N + (size_t)q];
            if(w == 0 || (nq == HC_NEAR && w <= nw[HC_NEAR - 1])) continue;
            else {}
            int t = nq < HC_NEAR ? nq++ : HC_NEAR - 1;
            while(t > 0 && nw[t - 1] < w) { nw[t] = nw[t - 1]; nqi[t] = nqi[t - 1]; t--; }
            nw[t] = w;
            nqi[t] = (uint16_t)q;
        }
        for(int t = 0; t < nq; t++) {
            const uint32_t w = nw[t];
            const uint8_t* m = &J.cm[(size_t)nqi[t] * HC_COLOURS];
            for(uint32_t c = 0; c < HC_COLOURS; c++) occ[c] += w * m[c];
        }
        const uint16_t* hl = &J.lines[g_hc_loff[k]];
        const uint32_t nl = g_hc_nlines[k];
        /* The cost at each colour, in 32 bits: what the others put on each colour scaled to 15 bits, the
         * section's line heat folded onto the 256 colours, and only the colours holding 95 % of its heat,
         * hottest first. A section's heat is its samples (well under 2^16), so a cost stays under 2^31. */
        uint32_t mx = 0;
        for(uint32_t c = 0; c < HC_COLOURS; c++) if(occ[c] > mx) mx = occ[c]; else {}
        uint32_t sh = 0;
        while((mx >> sh) > 32767u) sh++;
        uint16_t o16[HC_COLOURS];
        for(uint32_t c = 0; c < HC_COLOURS; c++) o16[c] = (uint16_t)(occ[c] >> sh);
        uint32_t hf[HC_COLOURS];
        for(uint32_t c = 0; c < HC_COLOURS; c++) hf[c] = 0;
        for(uint32_t l = 0; l < nl; l++) hf[l & (HC_COLOURS - 1)] += hl[l];
        uint8_t  nzj[HC_COLOURS];
        uint32_t nzh[HC_COLOURS], nz = 0, total = 0;
        for(uint32_t j = 0; j < HC_COLOURS; j++) if(hf[j]) { nzj[nz] = (uint8_t)j; nzh[nz] = hf[j]; nz++; total += hf[j]; } else {}
        for(uint32_t a = 1; a < nz; a++) {
            const uint32_t h = nzh[a];
            const uint8_t j = nzj[a];
            uint32_t b = a;
            while(b > 0 && nzh[b - 1] < h) { nzh[b] = nzh[b - 1]; nzj[b] = nzj[b - 1]; b--; }
            nzh[b] = h;
            nzj[b] = j;
        }
        {
            uint32_t acc = 0, keep = 0;
            while(keep < nz && acc * 20u < total * 19u) acc += nzh[keep++];
            nz = keep;
        }
        uint32_t best = UINT32_MAX;
        uint32_t bestc = 0;
        for(uint32_t c = 0; c < HC_COLOURS; c++) {
            uint32_t cost = 0;
            for(uint32_t t = 0; t < nz; t++) cost += nzh[t] * o16[(c + nzj[t]) & (HC_COLOURS - 1)];
            if(cost < best) { best = cost; bestc = c; }
            else {}
        }
        g_hc_colour[k] = bestc;
        uint32_t acc[HC_COLOURS];
        for(uint32_t c = 0; c < HC_COLOURS; c++) acc[c] = 0;
        for(uint32_t l = 0; l < nl; l++) acc[(bestc + l) & (HC_COLOURS - 1)] += hl[l];
        const uint32_t h = J.heat[g_hc_chosen[k]] ? J.heat[g_hc_chosen[k]] : 1;
        uint8_t* m = &J.cm[(size_t)k * HC_COLOURS];
        for(uint32_t c = 0; c < HC_COLOURS; c++) m[c] = (uint8_t)((acc[c] * HC_CM_ONE + h / 2) / h);
        J.i++;
        if(bp_time_us() >= until) return 0;
        else {}
    }
    J.i = 0;
    return 1;
}

/* The heap that can still be had: what malloc holds free, and what sbrk can still give before the
 * kernel's stack. */
static uint32_t hc_heap_free(void) {
    const struct mallinfo mi = mallinfo();
    const uintptr_t brk = (uintptr_t)sbrk(0);
    const uintptr_t top = (uintptr_t)_arch_mem_top - THD_KERNEL_STACK_SIZE;
    return (uint32_t)mi.fordblks + (brk < top ? (uint32_t)(top - brk) : 0u);
}

/* 5. each moved section's half of the operand cache, the arena's order, and the copies */
static int hc_place(void) {
    const int N = J.N, F = J.F, M = J.M;     /* members F..N-1 move; 0..F-1 stay */
    uint16_t* const chosen = g_hc_chosen;
    free(J.W); free(J.cm); free(J.lines);
    J.W = NULL; J.cm = NULL; J.lines = NULL;
    /* The half where a section's literal pools meet less of the sampled data; a pool of a section that
     * stays is data where it is. */
    for(uint32_t i = 0; i < J.npool; i++) {
        const uint32_t s0 = J.pool[i] >> 16;
        if(J.slot[s0] < F) J.dheat[(g_hc_sec[s0 * 2] / HC_LINE + (J.pool[i] & 0xFFFF)) & (HC_OCOLOURS - 1)]++;
        else {}
    }
    uint32_t* const ocost = g_hc_ocost;
    for(int k = 0; k < N; k++) { ocost[k * 2] = 0; ocost[k * 2 + 1] = 0; }
    for(uint32_t i = 0; i < J.npool; i++) {
        const int k = J.slot[J.pool[i] >> 16];
        if(k < F) continue;
        else {}
        const uint32_t c = g_hc_colour[k] + (J.pool[i] & 0xFFFF);
        ocost[k * 2] += J.dheat[c & (HC_OCOLOURS - 1)];
        ocost[k * 2 + 1] += J.dheat[(c + HC_COLOURS) & (HC_OCOLOURS - 1)];
    }
    /* Largest first, each at its colour in the half its pools prefer (either, when the two are within an eighth
     * of each other: whichever fits first), in the first hole of the arena where it fits — what one section
     * leaves as padding a later, smaller one fills, so none gives up its half for the arena's memory (packed in
     * order with a limit on the padding instead, Crash 3's f_8003fc50 put a literal pool on the operand cache's
     * line of the CPU state's hottest word, 9 % of every operand access, for 25 times the cost of its other
     * half). Largest first packs a seventh tighter than hottest first (~270 KB for 190 KB of Crash 3's code). */
    uint32_t* const off = g_hc_offs;
    uint32_t* const hs = g_hc_hole_s;
    uint32_t* const he = g_hc_hole_e;
    int* const by = g_hc_idx;
    for(int r = 0; r < M; r++) by[r] = F + r;
    for(int a = 1; a < M; a++) {
        const int v = by[a];
        int b = a - 1;
        while(b >= 0 && g_hc_sec[chosen[by[b]] * 2 + 1] < g_hc_sec[chosen[v] * 2 + 1]) { by[b + 1] = by[b]; b--; }
        by[b + 1] = v;
    }
    /* An arena over twice its code (Crash 3, once: 528 KB for 177 KB) is packed again with the sections that
     * care less about their half let go of it: first those within a factor of two, then all. */
    uint32_t span = 0;
    for(int pass = 0; pass < 3; pass++) {
        int nh = 1;
        hs[0] = 0;
        he[0] = UINT32_MAX;
        span = 0;
        for(int r = 0; r < M; r++) {
            const int k = by[r];
            const uint32_t lead = g_hc_sec[chosen[k] * 2] % HC_LINE, size = g_hc_sec[chosen[k] * 2 + 1];
            const uint32_t c0 = ocost[k * 2], c1 = ocost[k * 2 + 1];
            const uint32_t lo = c0 < c1 ? c0 : c1, hi = c0 < c1 ? c1 : c0;
            uint32_t best = UINT32_MAX;
            int besti = -1;
            for(uint32_t h = 0; h < 2; h++) {
                const uint32_t ch = h ? c1 : c0;
                const int either = pass == 2 || (pass == 1 ? hi <= 2u * lo : hi - lo <= hi / 8u);
                if(ch != lo && !either) continue;
                else {}
                const uint32_t t = g_hc_colour[k] + h * HC_COLOURS;
                for(int i = 0; i < nh; i++) {
                    /* the first start in hole i whose first line is on set t */
                    const uint32_t first = (hs[i] + HC_LINE - 1 - lead) / HC_LINE * HC_LINE;
                    const uint32_t o = first + ((t - (first / HC_LINE) % HC_OCOLOURS) % HC_OCOLOURS) * HC_LINE + lead;
                    if(o + size > he[i]) continue;
                    else {}
                    if(o < best) { best = o; besti = i; }
                    else {}
                    break;
                }
            }
            off[k] = best;
            /* hole besti becomes what is left before the section and what is left after it */
            const uint32_t s0 = hs[besti], e0 = he[besti];
            for(int j = nh; j > besti + 1; j--) { hs[j] = hs[j - 1]; he[j] = he[j - 1]; }
            hs[besti] = s0;
            he[besti] = best;
            hs[besti + 1] = best + size;
            he[besti + 1] = e0;
            nh++;
            if(best + size > span) span = best + size;
            else {}
        }
        if(span <= 2u * J.used) break;
        else {}
    }
    J.span = span;
    const uint32_t room = (J.span + 7u) & ~7u;
    if(hc_heap_free() < room + HC_RESERVE + (uint32_t)M * 12u) {
        char msg[96];
        snprintf(msg, sizeof(msg), "hotcode: %lu KB of heap free, an arena wants %lu — the code stays",
                 (unsigned long)(hc_heap_free() / 1024), (unsigned long)(room / 1024));
        bp_log(BP_LOG_WARN, msg);
        return 0;
    } else {}
    if(g_hc_nar == HC_ARENAS) {
        bp_log(BP_LOG_WARN, "hotcode: every arena held by a live frame — the code stays");
        return 0;
    } else {}
    J.arena = memalign(16384, room);
    hc_arena_t* ar = &g_hc_ar[g_hc_nar];
    ar->copy = malloc((size_t)M * 4u);
    ar->orig = malloc((size_t)M * 4u);
    ar->size = malloc((size_t)M * 4u);
    if(!J.arena || !ar->copy || !ar->orig || !ar->size) {
        free(J.arena); free(ar->copy); free(ar->orig); free(ar->size);
        J.arena = NULL;
        return 0;
    } else {}
    shz_memset8(J.arena, 0, room);     /* the padding is never run */
    int* const idx = g_hc_idx;
    for(int r = 0; r < M; r++) idx[r] = F + r;
    for(int a = 1; a < M; a++) {       /* by original start, for hc_moved */
        const int v = idx[a];
        int b = a - 1;
        while(b >= 0 && g_hc_sec[chosen[idx[b]] * 2] > g_hc_sec[chosen[v] * 2]) { idx[b + 1] = idx[b]; b--; }
        idx[b + 1] = v;
    }
    for(int j = 0; j < M; j++) {
        const int k = idx[j];
        g_hc_ostart[j] = g_hc_sec[chosen[k] * 2];
        g_hc_osize[j] = g_hc_sec[chosen[k] * 2 + 1];
        g_hc_base[j] = (uint32_t)(uintptr_t)J.arena + off[k];
    }
    J.i = 0;
    return 1;
}

/* 5b. the copies, a section at a time: written, then out of the operand cache and fresh in the instruction
 *     cache (icache_sync_range), before anything points at them. The originals do not change until the words
 *     are rewritten, so a copy made a few presents before another is the same as one made with it. */
static int hc_copy(uint64_t until) {
    while((int)J.i < J.M) {
        const int j = (int)J.i;
        shz_memcpy((void*)(uintptr_t)g_hc_base[j], (const void*)(uintptr_t)g_hc_ostart[j], g_hc_osize[j]);
        icache_sync_range(g_hc_base[j], g_hc_osize[j]);
        J.i++;
        if(bp_time_us() >= until) return 0;
        else {}
    }
    return 1;
}

/* 5c. the arena's map, by copy address (the arena order), published before any word points into it */
static void hc_publish(void) {
    const int N = J.M;
    int* const idx = g_hc_idx;
    hc_arena_t* ar = &g_hc_ar[g_hc_nar];
    for(int k = 0; k < N; k++) idx[k] = k;
    for(int a = 1; a < N; a++) {
        const int v = idx[a];
        int b = a - 1;
        while(b >= 0 && g_hc_base[idx[b]] > g_hc_base[v]) { idx[b + 1] = idx[b]; b--; }
        idx[b + 1] = v;
    }
    for(int k = 0; k < N; k++) { ar->copy[k] = g_hc_base[idx[k]]; ar->orig[k] = g_hc_ostart[idx[k]]; ar->size[k] = g_hc_osize[idx[k]]; }
    ar->n = N;
    ar->held = 0;
    ar->npins = 0;
    ar->mem = J.arena;
    ar->lo = (uint32_t)(uintptr_t)J.arena;
    ar->hi = (uint32_t)(uintptr_t)J.arena + J.span;
    g_hc_nar = g_hc_nar + 1;
    g_hc_current = 1;
    J.i = 0;
    J.patched = 0;
}

/* 6. every word that points at a moved section — or into an older arena's copy of it — points at its new
 *    copy; one into an older copy of a section not moved now, at its original. A slice at a time: each word
 *    is a pointer at good code before and after. */
static int hc_patch(uint64_t until) {
    const int N = J.M;
    while(J.i < g_hc_nref) {
        const uint32_t stop = J.i + 1024 < g_hc_nref ? J.i + 1024 : g_hc_nref;
        for(; J.i < stop; J.i++) {
            const uint32_t loc = g_hc_ref[J.i];
            uint32_t* w = (uint32_t*)(uintptr_t)loc;
            const uint32_t v = *w, o = hotcode_original(v);
            const int j = hc_moved(g_hc_ostart, g_hc_osize, N, o);
            uint32_t nv;
            if(j >= 0) nv = g_hc_base[j] + (o - g_hc_ostart[j]);
            else if(o != v) nv = o;
            else continue;
            *w = nv;
            const int h = hc_moved(g_hc_ostart, g_hc_osize, N, loc);
            if(h >= 0) *(uint32_t*)(uintptr_t)(g_hc_base[h] + (loc - g_hc_ostart[h])) = nv;
            else {}
            J.patched++;
        }
        if(bp_time_us() >= until) return 0;
        else {}
    }
    /* The generated code's per-site answers (FnTable, ADR-0062): pointers it filled since boot. */
    if(g_hc_site) {
        uint32_t* site = (uint32_t*)(uintptr_t)g_hc_site;
        for(uint32_t i = 0; i < g_hc_nsite; i++) {
            const uint32_t v = site[i * 2 + 1], o = hotcode_original(v);
            const int j = hc_moved(g_hc_ostart, g_hc_osize, N, o);
            if(j >= 0) site[i * 2 + 1] = g_hc_base[j] + (o - g_hc_ostart[j]);
            else if(o != v) site[i * 2 + 1] = o;
            else {}
        }
    } else {}
    return 1;
}

/* 6b. the words inside the older arenas' copies — and, giving the code back, the newest's — each as its
 *     original's word is now: a frame live in an older copy (a loop that does not return, a call under way)
 *     calls through its own copy's words, which would keep it in that arena's copies for good (Crash Bash: a
 *     minigame's loop in layout 8's arena kept 58 % of the match's samples there after layout 9). A word in
 *     code is a literal, never written by the program, so the original's is the copy's. */
static int hc_patch_old(uint64_t until) {
    const int last = J.revert ? g_hc_nar : g_hc_nar - 1;
    while((int)(J.i / HC_MAX) < last) {
        const int k = (int)(J.i / HC_MAX), j = (int)(J.i % HC_MAX);
        const hc_arena_t* r = &g_hc_ar[k];
        if(j >= r->n) { J.i = (uint32_t)(k + 1) * HC_MAX; continue; }
        else {}
        const uint32_t lo = r->orig[j], hi = lo + r->size[j];
        uint32_t a = 0, b = g_hc_nref;      /* the first word at lo or after */
        while(a < b) {
            const uint32_t m = (a + b) >> 1;
            if(g_hc_ref[m] < lo) a = m + 1;
            else b = m;
        }
        for(; a < g_hc_nref && g_hc_ref[a] < hi; a++) {
            const uint32_t loc = g_hc_ref[a];
            uint32_t* w = (uint32_t*)(uintptr_t)(r->copy[j] + (loc - lo));
            const uint32_t v = *(const uint32_t*)(uintptr_t)loc;
            if(*w != v) { *w = v; J.patched++; }
            else {}
        }
        J.i++;
        if(bp_time_us() >= until) return 0;
        else {}
    }
    return 1;
}

/* Whether any thread's stack or saved registers hold a word inside an arena: a frame may be live there.
 * The emulation thread's own callee-saved registers too (a caller may keep a pointer in one). The range is
 * held as its negation and its size, never as itself: the scan's own registers and frames must not hold a
 * word inside it, or every arena would look held by the code that looks (Crash 3: the arena's start in r8). */
static uint32_t g_hc_scan_neg, g_hc_scan_size;
static int      g_hc_scan_hit;
/* What the scan found, for the log: the first few words, and where (a register: 100 + its number for this
 * thread's, 200 + for another's; the stack: its address). */
static uint32_t g_hc_scan_val[4], g_hc_scan_at[4];
static void hc_scan_found(uint32_t v, uint32_t at) {
    if(g_hc_scan_hit < 4) { g_hc_scan_val[g_hc_scan_hit] = v; g_hc_scan_at[g_hc_scan_hit] = at; }
    else {}
    g_hc_scan_hit++;
}
static int hc_scan_thread(kthread_t* t, void* data) {
    (void)data;
    const uint32_t neg = g_hc_scan_neg, size = g_hc_scan_size;
#define HC_IN(v) ((uint32_t)((v) + neg) < size)
    uint32_t sp;
    if(t == thd_get_current()) {
        uint32_t regs[8];
        __asm__ volatile("mov r15,%0" : "=r"(sp));
        __asm__ volatile("mov.l r8,@(0,%0)\n\tmov.l r9,@(4,%0)\n\tmov.l r10,@(8,%0)\n\tmov.l r11,@(12,%0)\n\t"
                         "mov.l r12,@(16,%0)\n\tmov.l r13,@(20,%0)\n\tmov.l r14,@(24,%0)\n\tsts pr,r0\n\tmov.l r0,@(28,%0)"
                         : : "r"(regs) : "r0", "memory");
        for(int i = 0; i < 8; i++) if(HC_IN(regs[i])) hc_scan_found(regs[i], 100u + (uint32_t)i); else {}
    } else {
        const irq_context_t* c = &t->context;
        for(int i = 0; i < 16; i++) if(HC_IN(c->r[i])) hc_scan_found(c->r[i], 200u + (uint32_t)i); else {}
        if(HC_IN(c->pc)) hc_scan_found(c->pc, 216u);
        else {}
        if(HC_IN(c->pr)) hc_scan_found(c->pr, 217u);
        else {}
        sp = c->r[15];
    }
    const uint32_t end = (uint32_t)(uintptr_t)t->stack + (uint32_t)t->stack_size;
    if(t->stack && sp >= (uint32_t)(uintptr_t)t->stack && sp < end) {
        for(uint32_t p = sp & ~3u; p < end; p += 4) {
            const uint32_t v = *(const uint32_t*)(uintptr_t)p;
            if(HC_IN(v)) hc_scan_found(v, p);
            else {}
        }
    } else {}
#undef HC_IN
    return 0;
}

/* Every arena but the one in use given back if nothing on a stack or in a register points into it any more. */
/* The scan's range from arena k, and arena k taken out and freed: their own functions, so that hc_reap
 * never holds an arena's bounds in a register across the scan. */
__attribute__((noinline)) static void hc_scan_setup(int k) {
    g_hc_scan_neg = 0u - g_hc_ar[k].lo;
    g_hc_scan_size = g_hc_ar[k].hi - g_hc_ar[k].lo;
    g_hc_scan_hit = 0;
}
__attribute__((noinline)) static void hc_drop(int k) {
    hc_arena_t gone = g_hc_ar[k];
    const irq_mask_t old = irq_disable();
    for(int j = k; j < g_hc_nar - 1; j++) g_hc_ar[j] = g_hc_ar[j + 1];
    g_hc_nar = g_hc_nar - 1;
    irq_restore(old);
    free(gone.mem); free(gone.copy); free(gone.orig); free(gone.size);
    /* what held it has left: what it pinned may move again */
    for(int i = 0; i < gone.npins; i++) if(g_hc_pin[gone.pins[i]]) g_hc_pin[gone.pins[i]]--; else {}
}

static void hc_reap(void) {
    for(int k = g_hc_nar - (g_hc_current ? 2 : 1); k >= 0; k--) {
        hc_scan_setup(k);
        thd_each(hc_scan_thread, NULL);
        if(g_hc_scan_hit) {
            /* Held at HC_HELD_PIN looks in a row: a frame that does not leave (a loop that never returns).
             * What it was found under is not moved again, or every arena it went into would be held. */
            if(++g_hc_ar[k].held >= HC_HELD_PIN) {
                hc_arena_t* ar = &g_hc_ar[k];
                for(int i = 0; i < g_hc_scan_hit && i < 4; i++) {
                    const int s0 = hc_find(hotcode_original(g_hc_scan_val[i]));
                    int seen = s0 < 0;
                    for(int p = 0; p < ar->npins && !seen; p++) if(ar->pins[p] == (uint16_t)s0) seen = 1; else {}
                    if(!seen && ar->npins < HC_PINS && g_hc_pin[s0] < 255) {
                        ar->pins[ar->npins++] = (uint16_t)s0;
                        g_hc_pin[s0]++;
                    } else {}
                }
            } else {}
            hc_logf("arena %08lx held by %d words: %08lx (orig %08lx) at %08lx, %08lx (orig %08lx) at %08lx\n",
                    (unsigned long)(0u - g_hc_scan_neg), g_hc_scan_hit, (unsigned long)g_hc_scan_val[0],
                    (unsigned long)hotcode_original(g_hc_scan_val[0]), (unsigned long)g_hc_scan_at[0],
                    (unsigned long)(g_hc_scan_hit > 1 ? g_hc_scan_val[1] : 0u),
                    (unsigned long)(g_hc_scan_hit > 1 ? hotcode_original(g_hc_scan_val[1]) : 0u),
                    (unsigned long)(g_hc_scan_hit > 1 ? g_hc_scan_at[1] : 0u));
            continue;
        } else {}
        hc_drop(k);
    }
}

/* 7. older arenas given back when nothing on a stack points into them; the log */
static void hc_finish(void) {
    hc_reap();
    if(J.revert) {
        g_hc_reverts++;
        char m2[160];
        snprintf(m2, sizeof(m2), "hotcode: layout given back (%lu words rewritten over %lu presents): the game keeps its rate "
                 "as linked; %d arenas held", (unsigned long)J.patched, (unsigned long)J.presents, g_hc_nar);
        bp_log(BP_LOG_INFO, m2);
        hc_logf("%s\n", m2);
        return;
    } else {}
    g_hc_layouts++;
    uint32_t inside = 0;
    for(uint32_t i = 0; i < J.kept; i++) if(J.slot[g_hc_buf[i] >> 16] >= J.F) inside++; else {}
    char msg[280];
    snprintf(msg, sizeof(msg), "hotcode: layout %lu: %d sections (%lu KB; %d pinned kept clear of) into %lu KB at %08lx, %lu words rewritten; "
             "%lu of %lu samples in them (%lu in the last copies); over %lu presents: samples %lu, graph %lu, colours %lu, "
             "place %lu, words %lu ms; %d arenas held, %lu KB of heap free",
             (unsigned long)g_hc_layouts, J.M, (unsigned long)(J.used / 1024), J.F, (unsigned long)(J.span / 1024),
             (unsigned long)(uintptr_t)J.arena, (unsigned long)J.patched, (unsigned long)inside, (unsigned long)J.kept,
             (unsigned long)J.in_last, (unsigned long)J.presents, (unsigned long)(J.us[0] / 1000), (unsigned long)(J.us[1] / 1000),
             (unsigned long)(J.us[2] / 1000), (unsigned long)(J.us[3] / 1000), (unsigned long)(J.us[4] / 1000), g_hc_nar,
             (unsigned long)(hc_heap_free() / 1024));
    bp_log(BP_LOG_INFO, msg);          /* kept off the serial port while the overlay is on */
    /* The map, for scripts that name the profile's PCs: "@@hc copy original size" (dc-prof.py). */
    hc_logf("%s\n", msg);
    for(int j = 0; j < J.M; j++) hc_logf("%08lx %08lx %lx\n", (unsigned long)g_hc_base[j], (unsigned long)g_hc_ostart[j], (unsigned long)g_hc_osize[j]);
}

/* One present's share of the job. */
static void hc_step(uint64_t until) {
    int more = 1;
    while(more && bp_time_us() < until) {
        const int phase = J.phase;
        const uint64_t a = bp_time_us();
        switch(phase) {
        case J_CLASSIFY:
            if(hc_classify(until)) {
                /* A window the game spent waiting — a disc load, a fade — holds too few samples of its code
                 * to lay anything out by (Crash Bash's load at 19840: 4,102 of a full 15,000; its menus 9,500,
                 * Crash 3's title 10,300), and what it would lay out is the wait's: dropped, and the next look
                 * may open another at once. */
                const uint32_t full = (uint32_t)(J.window * (HC_HZ / 60));
                if(J.kept * 100u < full * HC_MIN_SHARE) {
                    char msg[96];
                    snprintf(msg, sizeof(msg), "hotcode: %lu samples in movable code — too few, no layout", (unsigned long)J.kept);
                    hc_logf("%s\n", msg);
                    g_hc_last = g_hc_last > HC_AUTO_GAP ? g_hc_last - HC_AUTO_GAP : 0;
                    hc_job_free();
                    return;
                } else {}
                if(!hc_choose()) { hc_job_abort("hotcode: nothing to move, or no memory"); return; }
                else {}
                J.phase = J_GRAPH;
            } else more = 0;
            break;
        case J_GRAPH:
            if(hc_graph(until)) J.phase = J_COLOUR;
            else more = 0;
            break;
        case J_COLOUR:
            if(hc_colour(until)) J.phase = J_PLACE;
            else more = 0;
            break;
        case J_PLACE:
            if(!hc_place()) { hc_job_free(); return; }
            else {}
            J.phase = J_COPY;
            break;
        case J_COPY:
            if(hc_copy(until)) { hc_publish(); J.phase = J_PATCH; }
            else more = 0;
            break;
        case J_PATCH:
            if(hc_patch(until)) { J.phase = J_PATCH_OLD; J.i = 0; }
            else more = 0;
            break;
        case J_PATCH_OLD:
            if(hc_patch_old(until)) J.phase = J_FINISH;
            else more = 0;
            break;
        case J_FINISH:
            hc_finish();
            hc_job_free();
            return;
        default:
            return;
        }
        const int col = phase == J_CLASSIFY ? 0 : phase == J_GRAPH ? 1 : phase == J_COLOUR ? 2 : phase <= J_COPY ? 3 : 4;
        J.us[col] += (uint32_t)(bp_time_us() - a);
    }
}

/* The pacer's spare time before a vblank (bp_pace_frame): a slice of the job, until `until`. */
static int g_hc_idle_ran, g_hc_noidle;
/* What the game waited for this vblank, from the pacer: whether it is behind its rate. */
void hotcode_slack(uint32_t us) { g_hc_slack += us; g_hc_slack_n++; }
int hotcode_pending(void) { return J.phase >= J_CLASSIFY; }
void hotcode_idle(uint64_t until) {
    if(J.phase < J_CLASSIFY) return;
    else {}
    g_hc_idle_ran = 1;
    hc_step(until);
}

/* The code given back to the link's layout: every word that points into an arena points at its original
 * again, the arenas' own words too; the arenas go when nothing runs in them. */
static void hc_revert(void) {
    memset(&J, 0, sizeof J);
    J.revert = 1;
    J.lastsec = -1;
    g_hc_current = 0;
    J.phase = J_PATCH;
}

void hotcode_present(uint32_t presents) {
    g_hc_logp = presents;
    if(J.phase == J_NONE && g_hc_nar > (g_hc_current ? 1 : 0) && presents % HC_REAP_EVERY == 0) hc_reap();
    else {}
    if(g_hc_off && J.phase == J_NONE) return;
    else {}
    if(J.phase >= J_CLASSIFY) {
        J.presents++;
        /* A game with time to spare at its vblanks has the job done there (hotcode_idle, from the pacer); one
         * that has had none for HC_IDLE_GRACE presents gives a slice of each. */
        if(g_hc_idle_ran) g_hc_noidle = 0;
        else g_hc_noidle++;
        if(!g_hc_idle_ran && g_hc_noidle >= HC_IDLE_GRACE) hc_step(bp_time_us() + HC_SLICE_US);
        else {}
        g_hc_idle_ran = 0;
        return;
    } else {}
    if(g_hc_auto && J.phase == J_NONE && presents >= HC_AUTO_FIRST && presents % HC_AUTO_CHECK == 0) {
        const uint32_t total = g_hc_lo_total, in = g_hc_lo_in, slack = g_hc_slack, vblanks = g_hc_slack_n;
        g_hc_lo_total = 0;
        g_hc_lo_in = 0;
        g_hc_slack = 0;
        g_hc_slack_n = 0;
        /* Behind its rate: it waited for its vblanks less than HC_AUTO_SLACK a present. Only then is code laid
         * out: a game that keeps its rate as linked gains nothing it can show, and a layout made for another of
         * its phases can cost it more than the link's (Crash Bash's Ballistix, 16.6 as linked: 17.1 on a
         * layout made for the screens before it). */
        const int behind = vblanks == 0 || slack < vblanks * (uint32_t)HC_AUTO_SLACK;   /* no pacer: no telling */
        /* Either for HC_AUTO_LOOKS looks in a row, as the share: a moment behind (a transition between two scenes)
         * laid out for is a layout for neither (Crash Bash: a window at 17620, behind for two looks, gave the match
         * after it 2.75 ms of instruction-cache conflicts a present; given back there instead, 0.75). */
        if(behind) { g_hc_behind++; g_hc_ahead = 0; }
        else { g_hc_ahead++; g_hc_behind = 0; }
        /* HC_AUTO_LOOKS looks in a row under the share: a moment's other code (a load, a cut) is not laid out for
         * (Crash Bash's Ballistix: with two, its disc load at 19840 was laid out for, and the match after it ran on that). */
        if(total >= HC_AUTO_MIN && (!g_hc_current || in * 100u < total * (uint32_t)HC_AUTO_KEEP)) g_hc_low++;
        else g_hc_low = 0;
        const char* what = "";
        if(g_hc_low >= HC_AUTO_LOOKS && g_hc_ahead >= HC_AUTO_LOOKS && g_hc_current) {
            hc_revert();
            g_hc_low = 0;
            what = " — given back";
        } else if(g_hc_behind >= HC_AUTO_LOOKS && g_hc_low >= HC_AUTO_LOOKS
                  && (g_hc_layouts == 0 || presents >= g_hc_last + HC_AUTO_GAP)) {
            /* No window on a timer as well: one every 3600 presents whatever the share opened where it fell, and
             * in Crash Bash that was a transition behind its rate for three looks (instruction conflicts in the
             * match after it 3.34 ms a present, 0.8 laid out for the match). */
            g_hc_from = (int)presents;
            g_hc_to = (int)presents + HC_AUTO_LEN;
            g_hc_low = 0;
            what = " — a window";
        } else {}
        hc_logf("look: %lu of %lu in the copies, waited %lu us over %lu vblanks%s\n", (unsigned long)in, (unsigned long)total,
                (unsigned long)slack, (unsigned long)vblanks, what);
        if(J.phase != J_NONE) return;
        else {}
    } else {}
    if(J.phase == J_NONE && !g_hc_off && presents >= (uint32_t)g_hc_from) { hc_open(); return; }
    else {}
    if(J.phase == J_SAMPLE && presents >= (uint32_t)g_hc_to) {
        timer_stop(TMU1);
#if RECOMPSX_DC_PROFILE
        samp_start();                      /* the profiler's sampler again, at its own rate */
#endif
        J.n = g_hc_n;
        J.window = g_hc_to - g_hc_from;
        J.heat = calloc(g_hc_nsec, 4u);
        J.slot = malloc(g_hc_nsec * 2u);
        J.order = malloc(g_hc_nsec * 2u);
        J.pool = malloc((J.n ? J.n : 1) * 4u);
        J.dheat = calloc(HC_OCOLOURS, 4u);
        if(!J.heat || !J.slot || !J.order || !J.pool || !J.dheat) { hc_job_abort("hotcode: no memory"); hc_next_window(); return; }
        else {}
        J.phase = J_CLASSIFY;
        J.i = 0;
        g_hc_last = presents;
        hc_next_window();
    } else {}
}

#endif
