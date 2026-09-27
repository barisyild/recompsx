/* backend_kos.c — the Sega Dreamcast implementation of backend_c_api.h.
 *
 * This directory is the ONLY place in the project that includes KallistiOS. It is the second
 * machine the emulator has ever run on, and the first console, so it is also the proof that the
 * boundary drawn in docs/specs/backend.md is real: nothing above this line changed to make it
 * exist — not the runtime, not the shims, not a single line of generated code.
 *
 * One implementation, split by subsystem; dc_internal.h declares what the files share.
 *   backend_kos.c   lifecycle (bp_init, bp_shutdown, bp_caps), launch parameters, time and logs
 *   dc_video.c      the framebuffer texture, the background slots, presenting and pacing a frame
 *   dc_scene.c      the GPU's primitives in hardware mode: recorded (bp_gpu_*), built into a scene
 *   dc_textures.c   texture pages, palettes and bakes as PVR textures; bp_gpu_vram
 *   dc_audio.c      the sample stream, and the SPU's voices on the AICA (bp_spu_*, bp_audio_*)
 *   dc_input.c      maple controllers as pads (bp_input_poll, bp_pad_*), the reset combo
 *   dc_files.c      saves (bp_storage_*) and the disc with its read-ahead thread (bp_file_*)
 *   dc_prof.c       where the frame went, the benchmark range, the PC sampler, the overlay
 *   dc_fastmem.c    the fastmem feasibility test (`--dc-fastmem-test`)
 *
 * Written against KallistiOS as documented at https://kos-docs.dreamcast.wiki/. Every call here
 * was checked against the upstream headers of both the current release (v2.2.2) and the
 * development branch, and only the intersection is used: `timer_us_gettime64`, for one, exists
 * in the release and has been removed from master, so time comes from `gettimeofday` — which is
 * standard C, present in every version, and backed by the same 80 ns timer underneath.
 *
 * Keep it boring: no emulation logic belongs here, and nothing here may influence emulated state.
 */

#include "dc_internal.h"

/* What KallistiOS should bring up before main() runs. INIT_DEFAULT covers the maple bus (so
 * controllers and the VMU filesystem exist), the GD-ROM with its ISO9660 driver (so /cd exists)
 * and dcload (so /pc exists when launched over a coder's cable or BBA).
 *
 * This macro has to live in a C file. It expands to definitions of ordinary global function
 * pointers whose *names* are what the kernel's weak symbols resolve against; compiled as C++
 * those names would be mangled, the overrides would silently not take, and the console would
 * boot with no controller and no disc. */
KOS_INIT_FLAGS(INIT_DEFAULT);

/* ---- launch state ---------------------------------------------------------------------------- */

#define MAX_ARGS 8
#define ARG_LEN  128

static char g_args[MAX_ARGS][ARG_LEN];
static int  g_argc;

static int file_exists(const char* path) {
    FILE* f = fopen(path, "rb");
    if(!f) return 0;
    fclose(f);
    return 1;
}

/* ---- launch parameters -----------------------------------------------------------------------
 * A Dreamcast has no command line unless one is running under dcload, so the arguments arrive
 * the way the ABI says console arguments arrive: out of storage. One argument per line of a text
 * file, which keeps paths with spaces intact and needs no quoting rules. */

static void arg_add(const char* s) {
    if(g_argc >= MAX_ARGS || !s || !*s) return;
    snprintf(g_args[g_argc], ARG_LEN, "%s", s);
    g_argc++;
}

static int has_arg(const char* s) {
    for(int i = 0; i < g_argc; i++) if(strcmp(g_args[i], s) == 0) return 1;
    return 0;
}

/* What follows `prefix` in the first argument that starts with it (`--name=value`), or NULL. */
static const char* arg_value(const char* prefix) {
    const size_t n = strlen(prefix);
    for(int i = 0; i < g_argc; i++) if(strncmp(g_args[i], prefix, n) == 0) return g_args[i] + n;
    return NULL;
}

static int args_from_file(const char* path) {
    FILE* f = fopen(path, "rb");
    if(!f) return 0;

    char line[ARG_LEN];
    int  n = 0;
    while(g_argc < MAX_ARGS && fgets(line, sizeof(line), f)) {
        size_t len = strlen(line);
        while(len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r' || line[len - 1] == ' '))
            line[--len] = '\0';
        if(len == 0 || line[0] == '#') continue;
        arg_add(line);
        n++;
    }
    fclose(f);
    return n;
}

static void load_args(void) {
    if(g_argc > 0) return;    /* dcload passed a command line; it wins */

    static const char* candidates[] = {
        "/pc/recompsx.cfg", "/cd/RECOMPSX.CFG", "/cd/recompsx.cfg"
    };
    char msg[64];
    for(size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if(args_from_file(candidates[i]) > 0) {
            snprintf(msg, sizeof(msg), "launch parameters from %s", candidates[i]);
            bp_log(BP_LOG_INFO, msg);
            return;
        }
    }

    /* Nothing configured: assume the conventional names on the disc that booted us. ISO9660
     * level 1 stores them upper-case; a disc mastered with Joliet or Rock Ridge may not. */
    static const char* exes[]  = { "/cd/BOOT.EXE",  "/cd/boot.exe"  };
    static const char* discs[] = { "/cd/DISC.BIN",  "/cd/disc.bin"  };
    for(size_t i = 0; i < 2; i++) if(file_exists(exes[i]))  { arg_add(exes[i]);  break; }
    for(size_t i = 0; i < 2; i++) if(file_exists(discs[i])) { arg_add(discs[i]); break; }

    if(g_argc == 0)
        bp_log(BP_LOG_WARN, "no recompsx.cfg and no /cd/BOOT.EXE — nothing to run");
}

void bp_set_args(int argc, const char** argv) {
    g_argc = 0;
    for(int i = 0; i < argc; i++) arg_add(argv[i]);
}

int bp_arg_count(void) { return g_argc; }

const char* bp_arg(int index) {
    if(index < 0 || index >= g_argc) return NULL;
    return g_args[index];
}

/* ---- lifecycle ------------------------------------------------------------------------------- */

int bp_init(const char* title) {
    (void)title;

    /* Idempotent on purpose. On a console the entry point must bring the platform up before the
     * program starts — there is no window server to do it lazily — and the runtime's own
     * skeleton also calls this on its way in. Bringing the PVR up twice fails; noticing that we
     * are already up costs nothing. */
    if(g_inited) return 0;
    g_inited = 1;

    /* A 2D mode has to exist before the PVR will initialise. 640x480 is what the tile
     * accelerator wants and what every cable can show: with a VGA box this is 60 Hz progressive,
     * on composite or RGB it is the interlaced television mode, and vid_set_mode picks between
     * them by looking at what is plugged in. */
    vid_set_mode(DM_640x480, PM_RGB565);

    /* Three lists, not the default two: opaque, translucent, and punch-through — the last is what
     * makes a texel the PlayStation calls "nothing" actually disappear, rather than being drawn as
     * black. Autosorting is off because the order is not ours to choose: a PlayStation draws in
     * submission order and the Z values built in build_scene encode exactly that. */
    /* The vertex buffer is sized to the command buffer, not to a habit. A triangle costs one
     * 32-byte header plus three 32-byte vertices, so 12,288 primitives need about 1.5 MB — and a
     * scene that overruns this is not reported by anything, it simply loses its last polygons.
     * That is what "most of the model, and one arm missing" looks like from the inside.
     *
     * But it is bought from the same 8 MB the textures live in, and **KOS allocates the vertex
     * buffer twice** — one being filled while the other renders — so this number costs double.
     * Asking for 1.5 MB here once cost 3 MB, pushed the total to 9 MB on an 8 MB machine, and
     * left a third of the texture slots unallocated: the model came back wearing garbage.
     * The budget, honestly: framebuffers 1.17 + vertex 2x0.75 + OPB 0.44 + textures 2 + the
     * framebuffer blit 1 = 6.99 MB with the object pointer buffers at 1.32, and the count below
     * is checked rather than assumed. */
    pvr_init_params_t params = {
        /* The object pointer buffers are per 32x32 screen tile, and a tile that runs out drops
         * the geometry that would not fit — silently, and only where the picture is busy. A
         * character model occupying a third of the screen puts hundreds of polygons into a
         * handful of tiles while the background puts one into each of the rest, which is why the
         * missing surfaces were all on the model and never on the backdrop. Doubled, with five
         * overflow blocks rather than three; the budget below is checked, not hoped for. */
        /* 32-word tile bins. Dense geometry — a character model filling a handful of tiles —
         * overflows a 16-word bin and the accelerator drops what did not fit, silently and
         * exactly where the picture is busiest, which is what "the mouth is missing, now the
         * leg" looks like. Tried once before, untestable then: the slot-conflict corruption was
         * sitting on top of everything. Texture budget: two pools, floor-checked at arming time rather than promised here. */
        /* ONE list — translucent, autosort off — because that is what a PlayStation is: a
         * painter's-algorithm machine, later-submitted wins, no depth anywhere. The previous
         * design split submission order across three hardware lists and rebuilt it with a
         * per-primitive depth ramp; surfaces of the character model went missing under it and
         * survived every other fix, which is exactly what a cross-list depth subtlety looks
         * like. This shape has no depth to be subtle about: submission order in, submission
         * order out. Opacity is a blend mode (ONE/ZERO), texel transparency is alpha reaching
         * a blend that keeps the destination — no punch-through list, no alpha threshold. */
        .opb_sizes = { PVR_BINSIZE_0, PVR_BINSIZE_0, PVR_BINSIZE_32, PVR_BINSIZE_0,
                       PVR_BINSIZE_0 },
        .vertex_buf_size = 768 * 1024,
        .dma_enabled = 0,
        .fsaa_enabled = 0,
        .autosort_disabled = 1,
        .opb_overflow_count = 3
    };
    if(pvr_init(&params) < 0) {
        bp_log(BP_LOG_ERROR, "pvr_init failed");
        return 1;
    }
    pvr_set_bg_color(0.0f, 0.0f, 0.0f);
    /* Punch-through keeps a pixel only if its alpha clears this. Texels decode to alpha 0 or 255,
     * so anything off the floor separates them. */
    PVR_SET(PVR_PT_ALPHA_REF, 0x20);
    /* Palette RAM holds ARGB1555, matching the page decode; set once, format is global. */
    pvr_set_pal_format(PVR_PAL_ARGB1555);

    g_txr = pvr_mem_malloc(TXR_MAX_W * TXR_MAX_H * 2);
    if(!g_txr) {
        bp_log(BP_LOG_ERROR, "no PVR memory for the framebuffer texture");
        return 2;
    }
    g_ready = 1;
#if RECOMPSX_DC_PROFILE
    g_emu_thread = thd_get_current();        /* bp_init runs on the thread that emulates */
    samp_start();
#endif
    twid_init();

    if(snd_stream_init() == 0) {
        g_snd_up = 1;
        g_stream = snd_stream_alloc(audio_pull, STREAM_BYTES_PER_CHANNEL);
        if(g_stream != SND_STREAM_INVALID) {
            snd_stream_volume(g_stream, 255);
            snd_stream_start(g_stream, 44100, 1);
        } else {
            bp_log(BP_LOG_WARN, "no sound stream available");
        }
    } else {
        bp_log(BP_LOG_WARN, "snd_stream_init failed — running silent");
    }

    cont_btn_callback(0, CONT_RESET_BUTTONS, reset_combo);

    find_storage();
    load_args();

#if RECOMPSX_DC_PROFILE
    if(has_arg("--dc-fastmem-test")) fastmem_test();
    else {}
    g_rxprof = has_arg("--dc-rxprof");
    {
        const char* b = arg_value("--dc-bench=");
        int from, to;
        if(b && sscanf(b, "%d:%d", &from, &to) == 2 && from >= 0 && to > from) {
            g_bench_from = from;
            g_bench_to = to;
        } else if(b) {
            bp_log(BP_LOG_WARN, "--dc-bench=FROM:TO wants two present counts, FROM below TO");
        } else {}
    }
#endif

#if RECOMPSX_DC_PROFILE_OVERLAY
    /* After the arguments, because they are what asks for it. */
    if(has_arg("--dc-overlay")) {
        g_txt = pvr_mem_malloc(TXT_W * TXT_H * 2);
        if(g_txt) {
            pvr_poly_cxt_t tc;
            pvr_poly_cxt_txr(&tc, PVR_LIST_TR_POLY,
                             PVR_TXRFMT_ARGB1555 | PVR_TXRFMT_NONTWIDDLED,
                             TXT_W, TXT_H, g_txt, PVR_FILTER_NONE);
            tc.gen.culling = PVR_CULLING_NONE;
            tc.txr.uv_clamp = PVR_UVCLAMP_UV;
            tc.txr.env = PVR_TXRENV_REPLACE;
            pvr_poly_compile(&g_txt_hdr, &tc);
            bp_log(BP_LOG_INFO, "profile overlay on");
#if RECOMPSX_DC_PROFILE
            syms_load();
#endif
        } else {
            bp_log(BP_LOG_WARN, "--dc-overlay: no PVR memory for the text texture");
        }
    }
#endif
    return 0;
}

void bp_shutdown(void) {
    for(int i = 0; i < MAX_FILES; i++) bp_file_close(i);

    if(g_stream != SND_STREAM_INVALID) {
        snd_stream_stop(g_stream);
        snd_stream_destroy(g_stream);
        g_stream = SND_STREAM_INVALID;
    }
    spu_voices_off();
    if(g_snd_up) { snd_stream_shutdown(); g_snd_up = 0; }

    if(g_ready) {
        if(g_txr) { pvr_mem_free(g_txr); g_txr = NULL; }
        pvr_shutdown();
        g_ready = 0;
    }
    g_inited = 0;
}

int bp_caps(int cap_id) {
    switch(cap_id) {
        case BP_CAP_MAX_PADS:        return MAX_PADS;
        case BP_CAP_HAS_AUDIO:       return g_stream != SND_STREAM_INVALID;
        case BP_CAP_HAS_STORAGE:     return g_storage_root != NULL;
        case BP_CAP_PREFERRED_SCALE: return 2;
        /* This machine has a rasteriser of its own and would rather use it. Whether the runtime
         * takes the offer is the host's decision, not ours — see --video-hw and ADR-0011. */
        case BP_CAP_GPU_DRAW:        return 1;
        /* And a sampler of its own: the AICA plays the SPU's voices (--audio-hw, ADR-0024). */
        case BP_CAP_SPU_VOICES:      return g_snd_up;
        default:                     return 0;
    }
}

/* ---- time and diagnostics ---------------------------------------------------------------------
 * gettimeofday rather than KOS's own timer calls: it is standard C, it exists in every version of
 * KallistiOS, and underneath it is the same 80 ns hardware timer the KOS-specific spellings read.
 * The KOS-specific ones are not stable — timer_us_gettime64 is in the current release and gone
 * from the development branch — and a backend that only builds against one of them is a backend
 * that stops building. */

uint64_t bp_time_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ull + (uint64_t)tv.tv_usec;
}

void bp_sleep_us(uint64_t us) {
    if(us >= 1000ull) thd_sleep((unsigned)(us / 1000ull));
}

void bp_pace_frame(int target_us) {
    static uint64_t next_deadline;
    const uint64_t now = bp_time_us();

    if(target_us <= 0 || next_deadline == 0) {   /* first call, or an explicit reset */
        next_deadline = now + (uint64_t)(target_us > 0 ? target_us : 0);
        return;
    }

    for(;;) {
        /* Sleeping hands the CPU to whatever else KOS is running, but it also stops feeding the
         * AICA, so the stream is topped up on every pass. thd_sleep's granularity is a
         * millisecond; the last one is spun out, because a whole millisecond of slop is visible
         * at 60 Hz.
         *
         * The clock is read once per pass and the remaining time computed from that one reading.
         * Reading it twice would let the deadline pass between them, and on unsigned arithmetic
         * that is not a small error — it is a sleep of about six hundred thousand years. */
        pump_audio();
        const uint64_t at = bp_time_us();
        if(at >= next_deadline) break;
        const uint64_t left = next_deadline - at;
        if(left <= 2000ull) break;
        thd_sleep((unsigned)((left - 1000ull) / 1000ull));
    }
    while(bp_time_us() < next_deadline) { /* spin */ }

    next_deadline += (uint64_t)target_us;

    /* Falling behind is the ordinary case on a 200 MHz SH-4. The debt is capped at four frames,
     * so a stall is never sprinted through, but it is kept rather than wiped: wiping it set the
     * next deadline a whole frame ahead, and a quick frame (a present whose scene was not rebuilt)
     * then waited for it even though the game as a whole ran behind: 53 ms of every 30 frames in
     * Crash Bash's menu at 38 fps. Kept, a game that is behind never waits, and one that is ahead
     * is still held to the rate. */
    const uint64_t after = bp_time_us();
    if(next_deadline + (uint64_t)target_us * 4ull < after) next_deadline = after - (uint64_t)target_us * 4ull;
}

void bp_log(int level, const char* msg) {
#if RECOMPSX_DC_PROFILE_OVERLAY
    /* With the overlay on, nobody is reading the serial port, and every line is still spun out of
     * it a byte at a time: the runtime's heartbeat alone kept scif_write in the overlay's top six.
     * Warnings and errors still go out. */
    if(g_txt && level < BP_LOG_WARN) return;
    else {}
#endif
    static const char* names[] = { "debug", "info", "warn", "error" };
    const char* n = (level >= 0 && level <= 3) ? names[level] : "?";
#if RECOMPSX_DC_PROFILE
    const uint64_t at = bp_time_us();
#endif
    printf("[%s] %s\n", n, msg ? msg : "");
    fflush(stdout);
#if RECOMPSX_DC_PROFILE
    g_prof_log_us += bp_time_us() - at;
    g_prof_logs++;
#endif
}

void bp_fatal(const char* msg) {
    bp_log(BP_LOG_ERROR, msg);
    bp_shutdown();
    arch_exit();
}
