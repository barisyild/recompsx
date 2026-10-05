/* dc_prof.c — measurement: where each frame went, the benchmark range, the PC sampler and the
 * on-screen overlay. Nothing here may influence emulated state. */

#include "dc_internal.h"
#include <dc/syscalls.h>

/* The overlay's text: a texture of its own (TXT_W x TXT_H, dc_internal.h), drawn over the game. */
#if RECOMPSX_DC_PROFILE_OVERLAY
#define TXT_USED 120
#define TXT_LINE 24
#define TXT_LINES 5
pvr_ptr_t      g_txt;
pvr_poly_hdr_t g_txt_hdr;
/* One row of the texture at a time: built here, where it stays in the operand cache, and sent to
 * texture memory through the store queues. The whole texture had a 128 KB buffer, cleared, drawn
 * and sent in one present every two seconds — ~4.7 ms of that present under the cache model, which
 * put Ballistix's heavy present over two frames' worth once in every 120 (ledger E-108). */
static uint16_t g_txt_row[TXT_W] __attribute__((aligned(32)));
_Static_assert(sizeof(g_txt_row) % 32 == 0, "g_txt_row is cleared by shz_memset8 and sent by txr_put");
static char     g_txt_text[TXT_LINES][48];
static int      g_txt_next = TXT_LINES;   /* the line the next present draws; TXT_LINES: none */
static int      g_txt_ready;

/* The overlay's glyphs, copied out of the BIOS font once. The font is in the boot ROM, on the G1
 * bus the GD-ROM's DMA uses, and the BIOS lends it (syscall_font_lock) only while no G1 DMA is
 * under way — "you can't access the BIOS font during G1 DMA" (dc/syscalls.h). bfont_draw_str_ex
 * asks for it on every string and polls with no timeout, so once the disc streamed the first
 * report never returned: on a real BIOS, booted from the disc, the emulation froze at its first
 * frame and the screen stayed black. Flycast's HLE BIOS has no such lock and dcload never uses
 * the drive, which is why neither showed it. So the lock is taken once, at init, before the
 * disc streams, and not waited on for long: a busy font costs the overlay its text, not the
 * machine its game. */
#define GLYPH_FIRST 32
#define GLYPH_COUNT 95
static uint8_t g_glyph[GLYPH_COUNT][BFONT_BYTES_PER_CHAR];
static int     g_glyphs_ok;

void glyphs_load(void) {
    const uint64_t until = bp_time_us() + 1000000;
    while(syscall_font_lock() != 0) {
        if(bp_time_us() >= until) {
            bp_log(BP_LOG_WARN, "--dc-overlay: the BIOS font stayed busy; the overlay has no text");
            return;
        } else {}
        thd_pass();
    }
    for(int i = 0; i < GLYPH_COUNT; i++)
        shz_memcpy(g_glyph[i], bfont_find_char(GLYPH_FIRST + i), BFONT_BYTES_PER_CHAR);
    syscall_font_unlock();
    g_glyphs_ok = 1;
}

/* Row y of a line of text into g_txt_row, the rest of the row clear, as bfont_draw_str_ex(buf,
 * TXT_W, 0xFFFF, 0, 16, true, s) drew it — two 12-bit rows in every three bytes of a glyph,
 * leftmost pixel in the top bit — except that a line stops at the texture's edge instead of running
 * on into the next. */
static void txt_row(int y, const char* s) {
    shz_memset8(g_txt_row, 0, sizeof(g_txt_row));
    if(!g_glyphs_ok) return;
    else {}
    for(int cx = 0; *s && cx + BFONT_THIN_WIDTH <= TXT_W; s++, cx += BFONT_THIN_WIDTH) {
        const int c = (uint8_t)*s;
        const uint8_t* g = g_glyph[(c >= GLYPH_FIRST && c < GLYPH_FIRST + GLYPH_COUNT) ? c - GLYPH_FIRST : 0]
                           + (y >> 1) * 3;
        const unsigned w = (y & 1) ? (((unsigned)(g[1] & 0x0F) << 8) | g[2]) : (((unsigned)g[0] << 4) | (g[1] >> 4));
        for(int x = 0; x < BFONT_THIN_WIDTH; x++)
            g_txt_row[cx + x] = (w & (0x800u >> x)) ? 0xFFFF : 0;
    }
}

/* The pending line into its rows of the texture, one row at a time, and the next line pending:
 * the five a report formats are drawn by the five presents after it. */
static void txt_step(void) {
    const int k = g_txt_next;
    for(int y = 0; y < TXT_LINE; y++) {
        txt_row(y, g_txt_text[k]);
        txr_put(g_txt_row, (pvr_ptr_t)((uintptr_t)g_txt + (uintptr_t)(k * TXT_LINE + y) * TXT_W * 2u),
                sizeof(g_txt_row));
    }
    sq_wait();
    g_txt_next = k + 1;
    if(g_txt_next == TXT_LINES) g_txt_ready = 1;
    else {}
}
#endif

/* ---- counters the other files keep, reported here -------------------------------------------- */

/* How many presents arrived with no primitives submitted since the last one. The theory that
 * half of them are redundant comes from the game flipping every second vblank — but it submits
 * ~772 primitives on every vblank in this scene, which would mean it draws each frame across
 * two of them and this counter stays at zero. Measure before skipping anything: presenting a
 * half-built scene and presenting nothing are different mistakes. */
int      g_empty_presents;
int      g_prof_skipped;
/* `submit` covers two very different things — walking the command buffer into TA commands, and
 * handing the finished scene to the hardware — and its spikes have now survived two confident
 * explanations of mine. Splitting it is cheaper than a third guess. */
uint64_t g_prof_build;
/* Textured primitives drawn twice this window, for colours above the PVR's 1.0 (put_tri). */
int      g_bright_prims;
/* Texture decodes this window, by cache: 4bpp page mirrors, pool slots, baked palette patches.
 * The overlay's `dec m/s/b`: what tells an invalidated texture from a cache that is too small. */
int      g_win_mir, g_win_slot, g_win_bake, g_win_patch;
/* The pictures this window (ADR-0053): renders into one, those of them over the picture as it was
 * (a copy of the whole buffer first), and screen passes. The bench's line: what a frame costs the PVR. */
int      g_pic_renders, g_pic_copies, g_pic_screens;
int      g_bake_live_max, g_bake_miss_all;
uint32_t g_mir_pages;

/* `--dc-bench=FROM:TO`, read at init; the benchmark itself is with profile_report. With
 * `--dc-rxprof` as well, the range is also announced on the serial port — "@@rxprof start" as it
 * begins, "@@rxprof stop" and "@@rxprof exit" when it ends — for the profiling Flycast build
 * (branch recompsx-prof), which records the guest's PCs between the two and then quits. */
#if RECOMPSX_DC_PROFILE
int g_bench_from = -1, g_bench_to = -1;
int g_rxprof;
/* `--dc-shots=FROM:TO:STEP`: with `--dc-rxprof`, a picture every STEP presents from FROM to TO as
 * well, named as the every-150 ones are — a moment that lasts a second, such as a transition, seen
 * frame by frame against the reference's VRAM dumps of the same presents. */
int g_shot_from = -1, g_shot_to = -1, g_shot_step;
#endif

/* ---- the runtime's brackets (bp_profile_mark) ------------------------------------------------- */

/* The runtime's own brackets (bp_profile_mark): the SPU's decoding and mixing, each stretch of the
 * GPU's list walk, each GTE command. Taken out of `emu` and printed beside it; the runtime never
 * sees the clock, only says where a stretch begins and ends.
 *
 * None of them is timed. The emulation is noted as being inside one, and the 1 kHz sampler
 * (samp_tick) counts the ticks that land there: a tick is a millisecond, the unit of every other
 * number. A GTE command was always done so, being too short and too frequent to time; the GPU's
 * and the SPU's brackets were timed with two clock reads each until 2026-09-30, and the list walk
 * opens one ~150 times a frame, so that was 0.2-0.3 ms of every frame on reading the clock
 * (gettimeofday, under the cache model on Crash 3). Only ticks that interrupt the emulation thread
 * count; the disc and audio threads can run while it is preempted in the middle of a bracket. */
#define WHERE_DEPTH 4
static volatile int      g_where = -1;
static int               g_where_outer[WHERE_DEPTH];
static int               g_where_depth;
kthread_t*        g_emu_thread;
static volatile uint32_t g_samp_where[BP_PROFILE_SECTIONS];

void bp_profile_mark(int section, int begin) {
    /* A GTE command is not bracketed at all: entered ~2500 times a vblank, its one store to
     * g_where was a line the game's code had evicted in between, allocated again by the write —
     * ~14 cycles of every RTPS on Crash 3 under the cache model (E-026), ~0.2 ms a frame. The GTE's
     * share is in the model's profile by function; the overlay counts it in `emu`. (The stack below
     * had cost ~20 instructions a mark, ~15 ms of a window, before it was a single store.) */
    if(section == BP_PROFILE_GTE) { (void)begin; return; }
    if(section < 0 || section >= BP_PROFILE_SECTIONS) return;
    if(begin) {
        if(g_where_depth < WHERE_DEPTH) g_where_outer[g_where_depth++] = g_where;
        g_where = section;
    } else {
        g_where = g_where_depth > 0 ? g_where_outer[--g_where_depth] : -1;
    }
}

/* ---- where the frame went ---------------------------------------------------------------------
 * A frame rate that is the same on a still title card and on a spinning character model is not a
 * frame rate set by how much work the emulated machine is doing — it is set by something that
 * costs the same every frame, and everything of that shape lives in this backend. So the backend
 * is what has to answer for itself.
 *
 * Four numbers, one line every 30 presents: the time NOT inside bp_present (which is the emulator
 * proper, plus everything else the runtime does), and the three phases inside it. Whichever is
 * largest is where to work next, and the answer is no longer a guess. */

#if RECOMPSX_DC_PROFILE
uint64_t g_prof_emu, g_prof_wait, g_prof_upload, g_prof_submit, g_prof_end;
uint64_t g_prof_pace;   /* held back to the video rate: not work, but part of the frame */

/* The SH-4's own performance counters, aimed at the one window that matters: everything between
 * the end of one present and the start of the next, which is the emulated frame.
 *
 * They are here because guessing has already cost this project two rounds. Removing a quarter of
 * .text measured nothing on the console, which is only explicable if instruction COUNT is not
 * what the machine is short of — and the candidates that remain (instruction cache, data cache,
 * branches, load-use interlocks) are indistinguishable from the disassembly and trivially
 * distinguishable from these registers. One counter, rotating through the modes a few seconds
 * apiece; cycles come from the wall clock at 200 MHz, so PRFC0 stays untouched for KOS. */
static const struct { perf_cntr_event_t ev; const char* name; uint8_t is_cycles; } g_pc_modes[] = {
    { PMCR_INSTRUCTION_ISSUED_MODE,              "instructions issued",   0 },
    { PMCR_PIPELINE_FREEZE_BY_ICACHE_MISS_MODE,  "stall: I-cache",        1 },
    { PMCR_PIPELINE_FREEZE_BY_DCACHE_MISS_MODE,  "stall: D-cache",        1 },
    { PMCR_PIPELINE_FREEZE_BY_BRANCH_MODE,       "stall: branch",         1 },
    { PMCR_PIPELINE_FREEZE_BY_CPU_REGISTER_MODE, "stall: load-use",       1 },
    { PMCR_INSTRUCTION_CACHE_MISS_MODE,          "I-cache misses",        0 },
    { PMCR_OPERAND_CACHE_MISS_MODE,              "D-cache misses",        0 },
    { PMCR_SUBROUTINE_ISSUED_MODE,               "calls issued",          0 },
};
#define PC_MODES   ((int)(sizeof(g_pc_modes) / sizeof(g_pc_modes[0])))
#define PC_WINDOW  60
static int g_pc_mode;
int      g_pc_frames, g_pc_armed;
static uint64_t g_pc_total, g_pc_us;

void perf_window_close(uint64_t emu_us) {
    if(!g_pc_armed) return;
    g_pc_total += perf_cntr_count(PRFC1);
    g_pc_us += emu_us;
    if(++g_pc_frames < PC_WINDOW) return;

    /* A counter that stayed at zero across a whole window of real work is not measuring; it is
     * absent. Flycast does not implement the SH-4's performance registers, so the honest move is
     * to say it once and stop printing rows of zeroes that look like findings. */
    if(g_pc_total == 0) {
        static int said;
        if(!said) {
            said = 1;
            bp_log(BP_LOG_WARN,
                   "perf: SH-4 counters read zero — not implemented here (emulator); "
                   "PC sampling below is the measurement that works");
        } else {}
        g_pc_armed = 0;
        return;
    } else {}

    /* 200 MHz, so a microsecond of emulated frame is two hundred cycles. Percentages are of the
     * frame's whole cycle budget, which is what makes them comparable across modes. */
    const uint64_t cycles = g_pc_us * 200ull;
    const unsigned long per_frame = (unsigned long)(g_pc_total / (uint64_t)g_pc_frames);
    const unsigned long cyc_frame = (unsigned long)(cycles / (uint64_t)g_pc_frames);
    char msg[144];
    if(g_pc_modes[g_pc_mode].is_cycles)
        snprintf(msg, sizeof(msg), "perf: %-20s %10lu /frame = %2lu%% of %lu cycles",
                 g_pc_modes[g_pc_mode].name, per_frame,
                 cycles ? (unsigned long)(g_pc_total * 100ull / cycles) : 0ul, cyc_frame);
    else if(g_pc_mode == 0)
        snprintf(msg, sizeof(msg), "perf: %-20s %10lu /frame, IPC %lu.%02lu of %lu cycles",
                 g_pc_modes[g_pc_mode].name, per_frame,
                 cycles ? (unsigned long)(g_pc_total / cycles) : 0ul,
                 cycles ? (unsigned long)((g_pc_total * 100ull / cycles) % 100ull) : 0ul, cyc_frame);
    else
        snprintf(msg, sizeof(msg), "perf: %-20s %10lu /frame (%lu cycles/frame)",
                 g_pc_modes[g_pc_mode].name, per_frame, cyc_frame);
    bp_log(BP_LOG_INFO, msg);

    g_pc_mode = (g_pc_mode + 1) % PC_MODES;
    g_pc_frames = 0;
    g_pc_total = 0;
    g_pc_us = 0;
}

/* Where the time actually goes, sampled rather than reasoned about.
 *
 * The SH-4's performance counters answer this exactly — and read zero under Flycast, which does
 * not implement them, so on the machine this project is actually tested on they answer nothing.
 * A timer interrupt does work anywhere: TMU1 is documented free (TMU0 is the scheduler's, TMU2
 * backs every gettime function), it fires a thousand times a second, and the handler is handed
 * the interrupted context. Bucket its PC and after a minute the histogram names the hot code
 * without a single assumption about caches, expansion factors or instruction counts.
 *
 * Addresses are reported raw, at 1 KB granularity, and resolved off-device against the ELF —
 * carrying a symbol table on the disc to print names would change what is being measured. */
/* 128-byte granules, not kilobyte ones: at a kilobyte the hottest bucket held a KOS idle task,
 * a stack tracer and a dozen syscall thunks at once, and no amount of staring could say which of
 * them was burning fourteen percent. A granule has to be smaller than the functions it means to
 * name. */
#define SAMP_SLOTS 1024
#define SAMP_GRAN  7
static uint32_t g_samp_key[SAMP_SLOTS] __attribute__((aligned(8))), g_samp_hit[SAMP_SLOTS] __attribute__((aligned(8)));
/* The function a bucket's last sample fell in (samp_tick), or -1: kept with the bucket. */
static int32_t g_samp_fn[SAMP_SLOTS];
static uint32_t g_samp_total, g_samp_lost;
uint32_t g_samp_frames;

/* Function names for the overlay, from SYMS.BIN (scripts/dc-syms.py, written by build-dc.sh):
 * each sample's PC is looked up here, in the interrupt, and the overlay prints the functions with
 * the most samples in the window — a sample is a millisecond, as everywhere else. Loaded once at
 * init and only with the overlay on; without the file the overlay says so and nothing is counted.
 * A file from another build is refused by its anchor, samp_tick's own address. */
#define SYM_NAME 12
static uint32_t*          g_sym_range;          /* count x (start, end), sorted */
static char             (*g_sym_name)[SYM_NAME];
static volatile uint32_t* g_sym_hits;           /* samples per function this window */
static volatile int       g_sym_count;          /* set last: the interrupt reads it */
static volatile uint32_t  g_sym_other;          /* samples in no listed function */
static const char*        g_sym_state = "no SYMS.BIN on the disc";

static void samp_tick(irq_t code, irq_context_t* ctx, void* data);

/* The sampler's rate: a tick is SAMP_US microseconds. 250 a second, where it was 1,000: each tick hashes
 * the PC and finds its function, and at 1 kHz that was 0.083 ms of every present of Crash 3's gameplay
 * demo under the cache model (docs/perf/dreamcast-ledger.md, E-155) — the measurement's own cost, in
 * the window it measures and on the console. A 300-present bench still takes 1,250 samples. */
#define SAMP_HZ 250
#define SAMP_US (1000000 / SAMP_HZ)
static void syms_clear(void);

void syms_load(void) {
    static const char* paths[] = { "/pc/SYMS.BIN", "/cd/SYMS.BIN", "/cd/syms.bin" };
    FILE* f = NULL;
    for(size_t i = 0; i < sizeof(paths) / sizeof(paths[0]) && !f; i++) f = fopen(paths[i], "rb");
    if(!f) { bp_log(BP_LOG_INFO, "syms: no SYMS.BIN — the overlay profile is off"); return; }
    uint8_t head[12];
    uint32_t count = 0, anchor = 0;
    if(fread(head, 1, sizeof(head), f) == sizeof(head) && memcmp(head, "RSY1", 4) == 0) {
        shz_memcpy(&count, head + 4, 4);
        shz_memcpy(&anchor, head + 8, 4);
    } else {}
    if(count == 0 || count > 16384) {
        g_sym_state = "SYMS.BIN unreadable";
    } else if(anchor != (uint32_t)(uintptr_t)samp_tick) {
        g_sym_state = "SYMS.BIN is from another build";
    } else {
        uint32_t* range = malloc(count * 8u);
        char (*name)[SYM_NAME] = malloc(count * (size_t)SYM_NAME);
        uint32_t* hits = calloc(count, 4u);
        if(range && name && hits && fread(range, 8, count, f) == count
           && fread(name, SYM_NAME, count, f) == count) {
            for(uint32_t i = 0; i < count; i++) name[i][SYM_NAME - 1] = '\0';
            g_sym_range = range;
            g_sym_name = name;
            g_sym_hits = hits;
            g_sym_count = (int)count;
            g_sym_state = NULL;
        } else {
            free(range); free(name); free(hits);
            g_sym_state = "SYMS.BIN unreadable";
        }
    }
    fclose(f);
    char msg[80];
    snprintf(msg, sizeof(msg), "syms: %s", g_sym_state ? g_sym_state : "function names loaded");
    bp_log(g_sym_state ? BP_LOG_WARN : BP_LOG_INFO, msg);
}

/* The function holding `pc`, or -1. Binary search, in the interrupt: a dozen steps a millisecond. */
static int sym_find(uint32_t pc) {
    int lo = 0, hi = g_sym_count - 1;
    while(lo <= hi) {
        const int mid = (lo + hi) >> 1;
        if(pc < g_sym_range[mid * 2]) hi = mid - 1;
        else if(pc >= g_sym_range[mid * 2 + 1]) lo = mid + 1;
        else return mid;
    }
    return -1;
}

/* The two overlay lines: the six functions with the most samples in the window, three a line,
 * then the window's counts are cleared. */
static void syms_top(char* a, char* b, size_t len) {
    if(g_sym_count <= 0) {
        snprintf(a, len, "prof: %s", g_sym_state ? g_sym_state : "-");
        b[0] = '\0';
        return;
    }
    /* The six with the most samples, in one pass: each function with any goes into its place
     * among the six kept so far, after those with as many (the earlier one first on a tie, as the
     * six passes over every function it replaced had it — ~500,000 instructions a report, which
     * the overlay's own profile showed at 0.08 ms a frame). */
    int top[6] = { -1, -1, -1, -1, -1, -1 };
    for(int i = 0; i < g_sym_count; i++) {
        const uint32_t h = g_sym_hits[i];
        if(h == 0 || (top[5] >= 0 && g_sym_hits[top[5]] >= h)) continue;
        else {}
        int k = 5;
        while(k > 0 && (top[k - 1] < 0 || g_sym_hits[top[k - 1]] < h)) { top[k] = top[k - 1]; k--; }
        top[k] = i;
    }
    char* out[2] = { a, b };
    for(int line = 0; line < 2; line++) {
        int n = 0;
        out[line][0] = '\0';
        for(int k = line * 3; k < line * 3 + 3; k++) {
            if(top[k] < 0) break;
            n += snprintf(out[line] + n, len - (size_t)n, "%-10.10s%3lu ",
                          g_sym_name[top[k]], (unsigned long)g_sym_hits[top[k]]);
            if(n >= (int)len) break;
        }
    }
    syms_clear();
}

/** A new window for the function samples. */
static void syms_clear(void) {
    for(int i = 0; i < g_sym_count; i++) g_sym_hits[i] = 0;
    g_sym_other = 0;
}

static void samp_tick(irq_t code, irq_context_t* ctx, void* data) {
    (void)code; (void)data;
    /* Acknowledge FIRST and unconditionally. An SH-4 timer holds its underflow flag until
     * software clears it, so a handler that returns without clearing is re-entered immediately,
     * forever: the machine stops making progress and the symptom is simply "it does not boot".
     * KOS's own millisecond handler clears the same bit for the same reason. */
    timer_clear(TMU1);
    const int where = g_where;
    if(where >= 0 && thd_get_current() == g_emu_thread) g_samp_where[where]++;
    const uint32_t pc = CONTEXT_PC(*ctx);
    const uint32_t k = pc >> SAMP_GRAN;
    const uint32_t h = (k * 2654435761u) & (SAMP_SLOTS - 1);
    int slot = -1;
    for(int i = 0; i < 8; i++) {
        const uint32_t c = (h + (uint32_t)i) & (SAMP_SLOTS - 1);
        if(g_samp_hit[c] == 0) { g_samp_key[c] = k; g_samp_fn[c] = -1; slot = (int)c; break; }
        if(g_samp_key[c] == k) { slot = (int)c; break; }
    }
    if(slot >= 0) { g_samp_hit[slot]++; g_samp_total++; }
    else g_samp_lost++;
    if(g_sym_count > 0) {
        /* The function the bucket's last sample fell in, if this one falls there too — nearly
         * always: two compares where the binary search took a dozen dependent loads, most of them
         * misses, at every tick (~0.07 ms a frame of Crash 3 under the cache model, E-041). */
        int fn = slot >= 0 ? g_samp_fn[slot] : -1;
        if(fn < 0 || pc < g_sym_range[fn * 2] || pc >= g_sym_range[fn * 2 + 1]) {
            fn = sym_find(pc);
            if(slot >= 0) g_samp_fn[slot] = fn;
            else {}
        } else {}
        if(fn >= 0) g_sym_hits[fn]++;
        else g_sym_other++;
    } else {}
}

void samp_start(void) {
    if(timer_prime(TMU1, SAMP_HZ, 1) < 0) {
        bp_log(BP_LOG_WARN, "samp: TMU1 unavailable — no PC sampling");
        return;
    }
    irq_set_handler(EXC_TMU1_TUNI1, samp_tick, NULL);
    timer_enable_ints(TMU1);
    timer_start(TMU1);
}

/** The histogram, in MILLISECONDS PER FRAME rather than percentages.
 *
 *  The conversion is free and exact: the timer fires a thousand times a second, so one sample IS
 *  one millisecond of wall clock. Divide a bucket's samples by the frames that elapsed while it
 *  was collecting and the answer is what that code costs a frame — the number an optimisation is
 *  actually judged by, where a percentage only says how the cake was cut.
 *
 *  Windowed, not cumulative: a running total blends a loading screen into a fight and reports
 *  neither. Each report describes the period since the last one, so the numbers belong to the
 *  scene on screen when they are printed. */
void samp_report(void) {
    if(g_samp_total < 200 * SAMP_HZ / 1000 || g_samp_frames < 10) return;
    uint8_t taken[SAMP_SLOTS] __attribute__((aligned(8)));
    shz_memset8(taken, 0, sizeof(taken));
    char msg[260];
    /* Tenths of a millisecond, because the interesting buckets are under 10 ms and integers
     * would round most of them to the same number. */
    int n = snprintf(msg, sizeof(msg), "samp: %lu ms/frame over %lu frames (%lu lost) |",
                     (unsigned long)((uint64_t)g_samp_total * (SAMP_US / 1000) / g_samp_frames),
                     (unsigned long)g_samp_frames, (unsigned long)g_samp_lost);
    for(int k = 0; k < 10; k++) {
        int best = -1;
        for(int i = 0; i < SAMP_SLOTS; i++)
            if(!taken[i] && g_samp_hit[i] && (best < 0 || g_samp_hit[i] > g_samp_hit[best])) best = i;
        if(best < 0) break;
        taken[best] = 1;
        const unsigned tenths =
            (unsigned)((uint64_t)g_samp_hit[best] * (10ull * SAMP_US / 1000) / (uint64_t)g_samp_frames);
        if(tenths == 0) break;
        n += snprintf(msg + n, sizeof(msg) - (size_t)n, " %08lx:%u.%ums",
                      (unsigned long)g_samp_key[best] << SAMP_GRAN, tenths / 10, tenths % 10);
        if(n >= (int)sizeof(msg) - 16) break;
    }
    bp_log(BP_LOG_INFO, msg);

    /* The window closes with the report. */
    shz_memset8(g_samp_key, 0, sizeof(g_samp_key));
    shz_memset8(g_samp_hit, 0, sizeof(g_samp_hit));
    g_samp_total = 0;
    g_samp_lost = 0;
    g_samp_frames = 0;
}

void perf_window_open(void) {
    perf_cntr_stop(PRFC1);
    perf_cntr_clear(PRFC1);
    perf_cntr_start(PRFC1, g_pc_modes[g_pc_mode].ev, PMCR_COUNT_CPU_CYCLES);
    g_pc_armed = 1;
}
static int      g_prof_frames;
/* Logging is measured too, and not as an afterthought: on a console booted from a disc, stdout
 * goes to the serial port, and a line nobody is listening to still costs a spin on the transmit
 * FIFO. If that is where the frames are going, it would look exactly like an emulator that is
 * slow for no reason. */
uint64_t g_prof_log_us;
int      g_prof_logs;

/* Every ten presents, not thirty. The period is counted in frames because that is what the numbers
 * are about, but it is *read* in seconds by a person watching a log — and on a machine managing a
 * couple of frames a second, thirty of them is half a minute between signs of life. */
#define PROFILE_EVERY 30
#define OVERLAY_EVERY 4

/* ---- the benchmark range ------------------------------------------------------------------------
 * `--dc-bench=FROM:TO` in recompsx.cfg measures presents FROM..TO counted from boot as one block and
 * leaves the result on the overlay's last line. There is one present per emulated frame and the
 * emulation is deterministic, so a game left in its attract loop replays the same frames on every
 * boot: two builds measured over the same range differ by what changed between them. The rolling
 * window cannot promise that — it moves by five percent with whatever is on screen, which is as
 * much as most single optimisations are worth. The range is measured in whole windows, starting
 * with a fresh one at FROM. */
static int      g_bench_state;        /* 0 waiting, 1 on, 2 done; the range is g_bench_from/to */
static uint32_t g_presents;
static uint64_t g_bench_sum[5];       /* total, emu, gte, gpu, build — microseconds */
/* The rest of the total, for the serial log only: the PVR's wait, uploads, the submission less the
 * build, the pacer's hold and the disc — where a frame's time went that is not the emulator's. */
static uint64_t g_bench_rest[5];
static uint32_t g_bench_pic[3];       /* the pictures' counters, summed */
/* Presents by what they cost (bench_frame_busy), for the serial log: whether a bench's average hides
 * frames far over 16.7 ms behind others far under it, which the pacer then sleeps through. */
#define BENCH_BINS 10
static const uint16_t g_bench_edge[BENCH_BINS - 1] = { 10000, 13000, 15000, 16683, 18000, 20000, 23000, 27000, 33000 };
static uint32_t g_bench_bin[BENCH_BINS];
static uint64_t g_bench_bin_us[BENCH_BINS];
static uint64_t g_bench_bin_emu[BENCH_BINS], g_bench_bin_pres[BENCH_BINS];
uint32_t g_frame_emu_us, g_frame_present_us;

/* The bench's slowest presents (over two frames' worth, 33.4 ms), by their number from boot, for
 * the serial log: which frames a game's spikes are, so they can be looked at on JavaScript. */
#define BENCH_SLOW 24
static uint32_t g_bench_slow_n, g_bench_slow_at[BENCH_SLOW], g_bench_slow_us[BENCH_SLOW];
static uint32_t g_bench_slow_emu[BENCH_SLOW];

void bench_frame_busy(uint64_t busy_us) {
    if(g_bench_state != 1) return;
    else {}
    int i = 0;
    while(i < BENCH_BINS - 1 && busy_us >= g_bench_edge[i]) i++;
    g_bench_bin[i]++;
    g_bench_bin_us[i] += busy_us;
    g_bench_bin_emu[i] += g_frame_emu_us;
    g_bench_bin_pres[i] += g_frame_present_us;
    if(busy_us > 33400 && g_bench_slow_n < BENCH_SLOW) {
        g_bench_slow_at[g_bench_slow_n] = g_presents;
        g_bench_slow_us[g_bench_slow_n] = (uint32_t)busy_us;
        g_bench_slow_emu[g_bench_slow_n] = g_frame_emu_us;
        g_bench_slow_n++;
    } else {}
}
static uint32_t g_bench_frames;
static char     g_bench_line[48];
#if RECOMPSX_FASTMEM
static uint32_t g_bench_traps0;       /* g_fm_traps when the window started */
#endif

static void profile_reset(void);


static void bench_add(uint64_t total, uint64_t emu, uint64_t gte, uint64_t gpu, uint64_t build) {
    g_bench_sum[0] += total; g_bench_sum[1] += emu; g_bench_sum[2] += gte;
    g_bench_sum[3] += gpu;   g_bench_sum[4] += build;
    g_bench_rest[0] += g_prof_wait; g_bench_rest[1] += g_prof_upload;
    g_bench_rest[2] += g_prof_submit - g_prof_build; g_bench_rest[3] += g_prof_pace;
    g_bench_rest[4] += g_prof_disc_us;
    g_bench_pic[0] += (uint32_t)g_pic_renders; g_bench_pic[1] += (uint32_t)g_pic_copies;
    g_bench_pic[2] += (uint32_t)g_pic_screens;
    g_bench_frames += (uint32_t)g_prof_frames;
    if(g_presents < (uint32_t)g_bench_to) return;
    g_bench_state = 2;
    /* The recording ends here, before the lines below: ~900 characters spun out of the serial port
     * were the profile's last ~40 ms, 0.13 ms of each of a 300-frame window's frames (scif_write).
     * The profiling Flycast quits at "exit", after them. */
    if(g_rxprof) { printf("@@rxprof stop\n"); fflush(stdout); }
    else {}
    /* Milliseconds per frame, tenths: full speed is 16.7. */
    unsigned long t[5];
    for(int i = 0; i < 5; i++) t[i] = (unsigned long)(g_bench_sum[i] / ((uint64_t)g_bench_frames * 100u));
    snprintf(g_bench_line, sizeof(g_bench_line), "B%lu %lu.%lu emu %lu.%lu gte %lu.%lu gpu %lu.%lu bld %lu.%lu",
             (unsigned long)g_bench_frames, t[0] / 10, t[0] % 10, t[1] / 10, t[1] % 10,
             t[2] / 10, t[2] % 10, t[3] / 10, t[3] % 10, t[4] / 10, t[4] % 10);
    char msg[96];
    snprintf(msg, sizeof(msg), "bench %d..%d: %s (ms a frame)", g_bench_from, g_bench_to, g_bench_line);
    bp_log(BP_LOG_WARN, msg);   /* WARN: the overlay silences INFO, and this line is the point */
    unsigned long r[5];
    for(int i = 0; i < 5; i++) r[i] = (unsigned long)(g_bench_rest[i] / ((uint64_t)g_bench_frames * 10u));
    char rest[128];
    snprintf(rest, sizeof(rest), "bench rest: pvr-wait %lu.%02lu upload %lu.%02lu submit %lu.%02lu pace %lu.%02lu disc %lu.%02lu (ms a frame)",
             r[0] / 100, r[0] % 100, r[1] / 100, r[1] % 100, r[2] / 100, r[2] % 100, r[3] / 100, r[3] % 100,
             r[4] / 100, r[4] % 100);
    bp_log(BP_LOG_WARN, rest);
    if(g_bench_pic[0] | g_bench_pic[2]) {
        unsigned long q[3];
        for(int i = 0; i < 3; i++) q[i] = (unsigned long)((uint64_t)g_bench_pic[i] * 100u / g_bench_frames);
        snprintf(rest, sizeof(rest), "bench pictures: %lu.%02lu renders (%lu.%02lu over a picture) %lu.%02lu screens a frame",
                 q[0] / 100, q[0] % 100, q[1] / 100, q[1] % 100, q[2] / 100, q[2] % 100);
        bp_log(BP_LOG_WARN, rest);
    } else {}
    {
        /* What the texture pools have to spare since boot (ADR-0055): the bake pool's busiest frame
         * and the patches that found none, and the 4bpp mirror's pages sampled — the rest lend their
         * memory to the pool. */
        char vr[160];
        snprintf(vr, sizeof(vr), "bench vram: bake %d patches, at most %d bound in a frame, %d misses;"
                 " 4bpp mirror %d of %d pages used (%08lx)",
                 bake_pool_size(), g_bake_live_max, g_bake_miss_all,
                 __builtin_popcount(g_mir_pages), PAGE4_N, (unsigned long)g_mir_pages);
        bp_log(BP_LOG_WARN, vr);
    }
#if RECOMPSX_FASTMEM
    /* Guest accesses the MMU sent to the slow path over the window (ADR-0049): ports and the like. */
    snprintf(rest, sizeof(rest), "bench fastmem: %lu traps a frame", (unsigned long)((g_fm_traps - g_bench_traps0) / g_bench_frames));
    bp_log(BP_LOG_WARN, rest);
#if RECOMPSX_FM_HIST
    fm_hist_report(g_bench_frames);
#endif
#endif
    /* Each bin: its upper edge in ms, the presents in it, their mean cost in tenths of a ms. */
    char hist[256];
    int at = snprintf(hist, sizeof(hist), "bench presents by cost:");
    for(int i = 0; i < BENCH_BINS && at < (int)sizeof(hist) - 24; i++) {
        const unsigned long mean = g_bench_bin[i] ? (unsigned long)(g_bench_bin_us[i] / g_bench_bin[i] / 100u) : 0;
        if(i < BENCH_BINS - 1)
            at += snprintf(hist + at, sizeof(hist) - (size_t)at, " <%u.%u:%lu@%lu.%lu", (unsigned)(g_bench_edge[i] / 1000u),
                           (unsigned)(g_bench_edge[i] / 100u % 10u), (unsigned long)g_bench_bin[i], mean / 10, mean % 10);
        else
            at += snprintf(hist + at, sizeof(hist) - (size_t)at, " more:%lu@%lu.%lu", (unsigned long)g_bench_bin[i],
                           mean / 10, mean % 10);
    }
    bp_log(BP_LOG_WARN, hist);
    /* And of each bin's cost, how much was the emulation and how much the present (tenths of ms). */
    at = snprintf(hist, sizeof(hist), "bench presents emu/present:");
    for(int i = 0; i < BENCH_BINS && at < (int)sizeof(hist) - 24; i++) {
        if(g_bench_bin[i] == 0) continue;
        const unsigned long e = (unsigned long)(g_bench_bin_emu[i] / g_bench_bin[i] / 100u);
        const unsigned long q = (unsigned long)(g_bench_bin_pres[i] / g_bench_bin[i] / 100u);
        at += snprintf(hist + at, sizeof(hist) - (size_t)at, " [%d] %lu.%lu/%lu.%lu", i, e / 10, e % 10, q / 10, q % 10);
    }
    bp_log(BP_LOG_WARN, hist);
    /* The slowest presents: number, cost and its emulation, in tenths of a ms. */
    at = snprintf(hist, sizeof(hist), "bench slow presents:");
    for(uint32_t k = 0; k < g_bench_slow_n && at < (int)sizeof(hist) - 24; k++)
        at += snprintf(hist + at, sizeof(hist) - (size_t)at, " %lu:%lu/%lu", (unsigned long)g_bench_slow_at[k],
                       (unsigned long)(g_bench_slow_us[k] / 100u), (unsigned long)(g_bench_slow_emu[k] / 100u));
    bp_log(BP_LOG_WARN, hist);
    if(g_rxprof) { printf("@@rxprof exit\n"); fflush(stdout); }
    else {}
}

void profile_report(void) {
    g_presents++;
    /* A picture every 150 presents for the profiling Flycast, named by the present: the same name
     * is the same frame in every build and every emulator, which is how a bench range is found. */
    if(g_rxprof && (g_presents % 150 == 0
                    || (g_shot_step > 0 && g_presents >= (uint32_t)g_shot_from && g_presents <= (uint32_t)g_shot_to
                        && (g_presents - (uint32_t)g_shot_from) % (uint32_t)g_shot_step == 0))) {
        printf("@@rxprof shot p%05lu\n", (unsigned long)g_presents); fflush(stdout);
    } else {}
#if RECOMPSX_DC_PROFILE_OVERLAY
    if(g_txt_next < TXT_LINES) txt_step();
    else {}
#endif
    if(g_bench_state == 0 && g_bench_from >= 0 && g_presents == (uint32_t)g_bench_from) {
        profile_reset();        /* the range starts with a window of its own */
        g_bench_state = 1;
#if RECOMPSX_FASTMEM
        g_bench_traps0 = g_fm_traps;
#if RECOMPSX_FM_HIST
        fm_hist_reset();
#endif
#endif
        if(g_rxprof) { printf("@@rxprof start\n"); fflush(stdout); }
        else {}
        return;
    } else {}
    if(++g_prof_frames < PROFILE_EVERY) return;

    const uint64_t total = g_prof_emu + g_prof_wait + g_prof_upload + g_prof_submit + g_prof_pace;
    /* Everything the emulated frame contains that has a column of its own is taken out of `emu`
     * rather than left inside it: the disc's reads, the SPU, the AICA, the GTE and the GPU's
     * drawing. Leaving the disc in credited the CPU with the drive's bill, and leaving the drawing
     * in read as if the CPU were slow when the GPU was — so `emu` is what remains, the recompiled
     * code with the kernel, memory and timers it calls, and every number on the overlay is its own
     * and they add up to the total. GTE time is sampled (a tick is a millisecond), the rest timed,
     * so the remainder is clamped rather than trusted to the last millisecond. */
    const uint64_t spu_us = (uint64_t)g_samp_where[BP_PROFILE_SPU] * SAMP_US;
    const uint64_t gpu_us = (uint64_t)g_samp_where[BP_PROFILE_GPU] * SAMP_US;
    const uint64_t gte_us = (uint64_t)g_samp_where[BP_PROFILE_GTE] * SAMP_US;
    const uint64_t inside = g_prof_disc_us + spu_us + gpu_us + gte_us + g_prof_aica;
    const uint64_t emu = g_prof_emu > inside ? g_prof_emu - inside : 0;
    if(g_bench_state == 1) bench_add(total, emu, gte_us, gpu_us, g_prof_build);
    else {}

    /* The serial line, spun out only where it is written: with the overlay on it is not, and its
     * twenty-five fields were formatted every window for nothing. */
#if RECOMPSX_DC_PROFILE_OVERLAY
    const int log_line = !g_txt;
#else
    const int log_line = 1;
#endif
    char msg[300];
    msg[0] = '\0';
    if(log_line) snprintf(msg, sizeof(msg),
             "dc: %d frames in %lu ms | emu %lu | gte %lu | gpu %lu | spu %lu | aica %lu/%d/%d | disc %lu (%d rd, %d miss)"
             " | pvr-wait %lu | audio %lu (%d) | upload %lu | build %lu (%d hdr, %d cc) | submit %lu | pace %lu | empty %d | log %d in %lu",
             g_prof_frames,
             (unsigned long)(total / 1000),
             (unsigned long)(emu / 1000), (unsigned long)(gte_us / 1000), (unsigned long)(gpu_us / 1000),
             (unsigned long)(spu_us / 1000),
             (unsigned long)(g_prof_aica / 1000), g_prof_aica_decodes, g_prof_aica_declined,
             (unsigned long)(g_prof_disc_us / 1000), g_prof_reads, g_prof_misses,
             (unsigned long)(g_prof_wait / 1000),
             (unsigned long)(g_prof_audio / 1000), g_prof_polls,
             (unsigned long)(g_prof_upload / 1000),
             (unsigned long)(g_prof_build / 1000), g_hdr_hits, g_hdr_compiles,
             (unsigned long)((g_prof_submit - g_prof_build) / 1000),
             (unsigned long)(g_prof_pace / 1000), g_empty_presents,
             g_prof_logs,
             (unsigned long)(g_prof_log_us / 1000));

#if RECOMPSX_DC_PROFILE_OVERLAY
    /* The on-screen copy is built before the serial one is written, so the log counters describe
     * the period they belong to rather than including the cost of reporting themselves. */
    /* The overlay's text redrawn every OVERLAY_EVERY windows, two seconds: formatting it, finding
     * the six hottest functions among every symbol, drawing five lines a pixel at a time and
     * uploading them was ~0.14 ms of every frame under the cache model, for numbers a person reads
     * once a second at best. The window itself (bench_add above) is still every PROFILE_EVERY.
     * Here the lines are formatted; the five presents after this one draw and send one each. */
    static int s_overlay_window;
    if(g_txt && (s_overlay_window++ % OVERLAY_EVERY) == 0) {
        char* l0 = g_txt_text[0];
        char* l1 = g_txt_text[1];
        char* l2 = g_txt_text[2];
        char* l3 = g_txt_text[3];
        char* l4 = g_txt_text[4];
        const unsigned long tenths = total ? (unsigned long)((uint64_t)g_prof_frames * 10000000u / total) : 0;
        /* The window is always PROFILE_EVERY presents, so it is not printed; the disc's wait is
         * followed by what the drive delivered in it, which is what tells a slow drive from a busy
         * one. */
        snprintf(l0, sizeof(g_txt_text[0]), "%lu ms %lu.%lu fps pace %lu disc %lu/%luk",
                 (unsigned long)(total / 1000), tenths / 10, tenths % 10,
                 (unsigned long)(g_prof_pace / 1000), (unsigned long)(g_prof_disc_us / 1000),
                 (unsigned long)(g_prof_disc_bytes / 1024));
        /* Line 1 is the emulated frame, line 2 the drawing: the GPU's share of the frame, then the
         * texture uploads, the scene build and hand-over at present, and the wait for the PVR. */
        if(g_hw_voices)
            snprintf(l1, sizeof(g_txt_text[0]), "emu %lu gte %lu spu %lu aica %lu/%d/%d",
                     (unsigned long)(emu / 1000), (unsigned long)(gte_us / 1000),
                     (unsigned long)(spu_us / 1000),
                     (unsigned long)(g_prof_aica / 1000), g_prof_aica_decodes, g_prof_aica_declined);
        else
            snprintf(l1, sizeof(g_txt_text[0]), "emu %lu gte %lu spu %lu",
                     (unsigned long)(emu / 1000), (unsigned long)(gte_us / 1000),
                     (unsigned long)(spu_us / 1000));
        /* fin and wait (hand-over and the PVR's wait) have read 0 for a long while; they stay in the
         * serial line, and their room goes to the texture decodes. */
        snprintf(l2, sizeof(g_txt_text[0]), "gpu %lu up %lu build %lu x2 %d dec %d/%d/%d+%d",
                 (unsigned long)(gpu_us / 1000),
                 (unsigned long)(g_prof_upload / 1000), (unsigned long)(g_prof_build / 1000),
                 g_bright_prims, g_win_mir, g_win_slot, g_win_bake, g_win_patch);
        /* Lines 3 and 4: where the samples landed, by function, in ms of this window. The skip and
         * header counts that were here are in the serial line. */
        syms_top(l3, l4, sizeof(g_txt_text[0]));
        if(g_bench_state == 2) shz_memcpy(l4, g_bench_line, sizeof(g_txt_text[0]));
        else if(g_fm_line[0]) shz_memcpy(l4, g_fm_line, sizeof(g_txt_text[0]));
        else {}

        g_txt_next = 0;     /* drawn by the next five presents (txt_step) */
    } else syms_clear();
#endif

    g_prof_logs = 0;
    g_prof_log_us = 0;
    /* Not while the overlay shows the same numbers. A line of this length is ~280 characters
     * spun out of the serial port a byte at a time whether or not anything listens, and the
     * overlay's own profile put that spin (scif_write) at 54 ms of an 824 ms window. */
    if(log_line) bp_log(BP_LOG_INFO, msg);
    else {}

    profile_reset();
}

/** A new window: every per-window counter back to zero. */
static void profile_reset(void) {
    g_prof_frames = 0;
    g_prof_emu = g_prof_wait = g_prof_upload = g_prof_submit = g_prof_audio = 0;
    g_prof_pace = 0;
    g_prof_polls = 0;
    g_empty_presents = 0;
    g_prof_build = 0;
    g_prof_skipped = 0;
    g_bright_prims = 0;
    g_win_mir = g_win_slot = g_win_bake = g_win_patch = 0;
    g_pic_renders = g_pic_copies = g_pic_screens = 0;
    for(int i = 0; i < BP_PROFILE_SECTIONS; i++) g_samp_where[i] = 0;
    g_prof_aica = 0;
    g_prof_aica_decodes = 0;
    g_prof_aica_declined = 0;
    g_hdr_hits = g_hdr_compiles = 0;
    g_prof_disc_us = 0;
    g_prof_disc_bytes = 0;
    g_prof_reads = g_prof_misses = 0;
}

#if RECOMPSX_DC_PROFILE_OVERLAY
/** The overlay quad, bottom-left, drawn in front of the picture (larger z is nearer on a PVR). */
void draw_profile_overlay(void) {
    if(!g_txt_ready) return;

    put_hdr(&g_txt_hdr);

    pvr_vertex_t v;
    v.flags = PVR_CMD_VERTEX;
    v.argb = 0xFFFFFFFFu;
    v.oargb = 0;
    v.z = 2.0f;

    const float vmax = (float)TXT_USED / (float)TXT_H;
    v.x = 0.0f;   v.y = 480.0f - TXT_USED; v.u = 0.0f; v.v = 0.0f; put_vtx(&v);
    v.x = 512.0f; v.y = 480.0f - TXT_USED; v.u = 1.0f; v.v = 0.0f; put_vtx(&v);
    v.x = 0.0f;   v.y = 480.0f; v.u = 0.0f; v.v = vmax; put_vtx(&v);
    v.flags = PVR_CMD_VERTEX_EOL;
    v.x = 512.0f; v.y = 480.0f; v.u = 1.0f; v.v = vmax; put_vtx(&v);
}
#endif
#endif
