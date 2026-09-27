/* dc_audio.c — sound: the stream the SPU mixes into, and the SPU's voices on the AICA
 * (BP_CAP_SPU_VOICES, --audio-hw; ADR-0024). */

#include "dc_internal.h"

/* ---- audio state ----------------------------------------------------------------------------
 * The ABI is push-shaped and the AICA's stream driver is pull-shaped, so a ring sits between
 * them. Both ends run on the emulator thread — `snd_stream_poll` invokes the callback inline —
 * so there is nothing to lock, and this file would be wrong if that ever stopped being true. */
#define RING_FRAMES 8192                       /* stereo frames; 32 KB, ~186 ms of headroom */

snd_stream_hnd_t g_stream = SND_STREAM_INVALID;
int     g_snd_up;                       /* snd_stream_init succeeded */
static int16_t g_ring[RING_FRAMES * 2];
static int     g_ring_head, g_ring_tail;       /* in stereo frames; head == tail means empty */
static int16_t g_pull[STREAM_BYTES_PER_CHANNEL] __attribute__((aligned(32)));

/* Audio is the one backend call the runtime makes from INSIDE the emulated frame, so its cost
 * has always been hiding inside `emu`. PC sampling put 24% of the machine in KOS's idle task,
 * which means something is blocking rather than computing, and snd_stream_poll waits on a G2 DMA
 * into sound RAM. This column says whether that is the 24%. */
uint64_t g_prof_audio;
int      g_prof_polls;

/* Hands the AICA whatever has accumulated. Must be called often enough that the stream buffer
 * never runs dry — and it is called from the waiting paths too, because a frame spent waiting is
 * exactly when a stream left unattended would starve.
 *
 * Rate-limited, because the runtime's pacing asks `bp_audio_buffered` roughly six times a frame
 * (the SPU batches 128 samples at a time) and `snd_stream_poll` is not a cheap read — it walks
 * the AICA's play position and can copy and de-interleave a block. Polling cannot simply move to
 * `bp_present` either: a machine running at five frames a second would present five times a
 * second, and the buffer holds 93 ms. Four milliseconds is far below the half-buffer that decides
 * an underrun, and far above the rate the SPU asks at. */
int g_hw_voices;   /* the AICA plays the SPU's voices; the stream carries the ones it declines */

void pump_audio(void) {
    static uint64_t last_us;
    if(g_stream == SND_STREAM_INVALID) return;

    const uint64_t now = bp_time_us();
    if(now - last_us < 4000ull) return;
    last_us = now;

    snd_stream_poll(g_stream);
#if RECOMPSX_DC_PROFILE
    g_prof_audio += bp_time_us() - now;
    g_prof_polls++;
#endif
}

/* ---- the SPU's voices on the AICA (BP_CAP_SPU_VOICES, --audio-hw; ADR-0024) ----------------
 * The runtime's SPU keeps every state a game can read, as it does with no listener, and says
 * which voices sound, from where, at what pitch and how loud. Here each of its twenty-four voices
 * is an AICA channel. A sample is the PlayStation's ADPCM from where the voice starts to the
 * block that ends it, decoded once to 16-bit PCM with the SPU's own arithmetic and kept in sound
 * RAM, keyed by its start address; the loop point is found the way the SPU finds it, from the
 * block flags. Envelopes are the SPU's, arriving as volumes once a batch (every 2.9 ms), because
 * the AICA's own ADSR has other curves. What is heard is an approximation: no reverb, no noise
 * voices, no pitch modulation, and a loop's seam restarts the ADPCM filter from the first pass.
 * The mixing that cost 8 ms a vblank of SH-4 time is the AICA's now.
 *
 * A note the AICA cannot hold is declined at its key-on and the runtime mixes that one voice into
 * the ordinary stream, which therefore stays up. The case that forced it: Crash Bash's intro
 * cutscene streams its sound through two halves of sound RAM, each played as one ten-second note
 * of 220,528 samples, and an AICA channel's loop registers are sixteen bits. Cut at 65,534 the
 * cutscene went silent for seven seconds in every ten. */

#define SPU_RAM_BYTES   (512 * 1024)
#define SPU_VOICES      24
#define SPU_SAMPLES      192
#define SPU_SAMPLE_MAX    65534          /* an AICA channel's loop registers are sixteen bits */

typedef struct {
    int      start;       /* byte address in sound RAM; -1 for an empty slot */
    int      bytes;       /* sound RAM the decode read, for invalidation */
    uint32_t aica;        /* sound RAM address on the AICA side */
    int      len;         /* samples */
    int      loop_start;  /* sample index the end jumps back to */
    int      loops;
    int      stale;       /* the PlayStation RAM under it changed: never found again, freed when idle */
    int      refs;        /* voices playing it */
    uint32_t used_at;
} spu_samp_t;

static const uint8_t* g_spu_ram;
static spu_samp_t g_spu_samp[SPU_SAMPLES];
static uint32_t   g_spu_samp_clock;
static int        g_vchn[SPU_VOICES];
static int        g_vkey[SPU_VOICES];
static int        g_vsamp[SPU_VOICES];
static int        g_vvol[SPU_VOICES], g_vpan[SPU_VOICES], g_vfreq[SPU_VOICES];
static int16_t    g_spu_pcm[SPU_SAMPLE_MAX + 64] __attribute__((aligned(32)));
#if RECOMPSX_DC_PROFILE
uint64_t   g_prof_aica;        /* decoding, uploading and commanding, inside `emu` */
int        g_prof_aica_decodes;
int        g_prof_aica_declined;
#endif

/* Blocks from `start` through the one that ends the sample, or -1 if none does within what a
 * channel holds: read from the flags alone, so a note that will be declined costs no decode. */
static int spu_sample_blocks(int start) {
    int at = start & (SPU_RAM_BYTES - 1);
    for(int b = 1; b * 28 <= SPU_SAMPLE_MAX; b++) {
        if(g_spu_ram[(at + 1) & (SPU_RAM_BYTES - 1)] & 0x01) return b;
        at = (at + 16) & (SPU_RAM_BYTES - 1);
    }
    return -1;
}

static inline int spu_sat16(int v) { return v > 32767 ? 32767 : (v < -32768 ? -32768 : v); }

/* The SPU's decode (Spu.decodeBlock) and its loop rule (Spu.advanceBlock), over a whole sample:
 * blocks from `start` until one carries the end flag, the most recent loop-start block (or the
 * start, as a key-on leaves the repeat address) being where a looping end goes back to. */
static int spu_decode(int start, int* len, int* loop_start, int* loops, int* bytes) {
    static const int f0[5] = { 0, 60, 115, 98, 122 };
    static const int f1[5] = { 0, 0, -52, -55, -60 };
    int at = start & (SPU_RAM_BYTES - 1);
    int old = 0, older = 0, n = 0, read = 0, loop_at = 0;
    *loops = 0;
    for(;;) {
        const int header = g_spu_ram[at];
        const int flags = g_spu_ram[(at + 1) & (SPU_RAM_BYTES - 1)];
        int shift = header & 0x0F;
        if(shift > 12) shift = 9;
        int f = (header >> 4) & 0x0F;
        if(f > 4) f = 4;
        if(flags & 0x04) loop_at = n;
        for(int i = 0; i < 28; i++) {
            const int byte = g_spu_ram[(at + 2 + (i >> 1)) & (SPU_RAM_BYTES - 1)];
            const int nib = (i & 1) == 0 ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
            const int t = ((nib > 7 ? nib - 16 : nib) << 12) >> shift;
            const int smp = spu_sat16(t + ((old * f0[f] + older * f1[f] + 32) >> 6));
            g_spu_pcm[n + i] = (int16_t)smp;
            older = old;
            old = smp;
        }
        n += 28;
        read += 16;
        if(flags & 0x01) { *loops = (flags & 0x02) != 0; break; }
        if(n + 28 > SPU_SAMPLE_MAX) break;           /* longer than a channel can hold: cut */
        at = (at + 16) & (SPU_RAM_BYTES - 1);
    }
    *len = n;
    *loop_start = loop_at;
    *bytes = read;
    return n;
}

static void spu_samp_release(int s) {
    if(s < 0) return;
    if(g_spu_samp[s].refs > 0) g_spu_samp[s].refs--;
    if(g_spu_samp[s].stale && g_spu_samp[s].refs == 0) {
        if(g_spu_samp[s].aica) snd_mem_free(g_spu_samp[s].aica);
        g_spu_samp[s].aica = 0;
        g_spu_samp[s].start = -1;
        g_spu_samp[s].stale = 0;
    }
}

/* Frees the least recently used idle sample; 0 if there was none to free. */
static int spu_evict_one(void) {
    int best = -1;
    for(int i = 0; i < SPU_SAMPLES; i++) {
        if(g_spu_samp[i].start < 0 || g_spu_samp[i].refs > 0) continue;
        if(best < 0 || g_spu_samp[i].used_at < g_spu_samp[best].used_at) best = i;
    }
    if(best < 0) return 0;
    if(g_spu_samp[best].aica) snd_mem_free(g_spu_samp[best].aica);
    g_spu_samp[best].aica = 0;
    g_spu_samp[best].start = -1;
    g_spu_samp[best].stale = 0;
    return 1;
}

/* The sample a voice starting at `start` plays: kept, or decoded and uploaded now. -1 when it
 * cannot be had: longer than a channel holds, or no sound RAM to put it in. */
static int spu_samp_for(int start) {
    for(int i = 0; i < SPU_SAMPLES; i++)
        if(g_spu_samp[i].start == start && !g_spu_samp[i].stale) {
            g_spu_samp[i].used_at = ++g_spu_samp_clock;
            return i;
        }
    if(spu_sample_blocks(start) < 0) return -1;
    int slot = -1;
    for(int i = 0; i < SPU_SAMPLES && slot < 0; i++) if(g_spu_samp[i].start < 0) slot = i;
    while(slot < 0) {
        if(!spu_evict_one()) return -1;
        for(int i = 0; i < SPU_SAMPLES && slot < 0; i++) if(g_spu_samp[i].start < 0) slot = i;
    }
    int len, loop_start, loops, bytes;
    spu_decode(start, &len, &loop_start, &loops, &bytes);
    const size_t size = ((size_t)len * 2 + 31) & ~(size_t)31;
    uint32_t mem = snd_mem_malloc(size);
    while(!mem) {
        if(!spu_evict_one()) return -1;
        mem = snd_mem_malloc(size);
    }
    spu_memload_sq(mem, g_spu_pcm, size);
#if RECOMPSX_DC_PROFILE
    g_prof_aica_decodes++;
#endif
    spu_samp_t* e = &g_spu_samp[slot];
    e->start = start; e->bytes = bytes; e->aica = mem; e->len = len;
    e->loop_start = loop_start; e->loops = loops; e->stale = 0; e->refs = 0;
    e->used_at = ++g_spu_samp_clock;
    return slot;
}

static void aica_chan(int chn, uint32_t what, uint32_t base, int len, int loops, int loop_start,
                      int freq, int vol, int pan) {
    AICA_CMDSTR_CHANNEL(tmp, cmd, chan);
    cmd->cmd = AICA_CMD_CHAN;
    cmd->timestamp = 0;
    cmd->size = AICA_CMDSTR_CHANNEL_SIZE;
    cmd->cmd_id = (uint32_t)chn;
    chan->cmd = what;
    chan->base = base;
    chan->type = AICA_SM_16BIT;
    chan->length = (uint32_t)len;
    chan->loop = (uint32_t)loops;
    chan->loopstart = (uint32_t)loop_start;
    chan->loopend = (uint32_t)len;
    chan->freq = (uint32_t)freq;
    chan->vol = (uint32_t)vol;
    chan->pan = (uint32_t)pan;
    snd_sh4_to_aica(tmp, cmd->size);
}

/* Silences and gives back every channel the voices hold; their samples go with the sound RAM
 * allocator when the sound system shuts down. */
void spu_voices_off(void) {
    if(!g_hw_voices) return;
    for(int v = 0; v < SPU_VOICES; v++) {
        if(g_vchn[v] < 0) continue;
        snd_sfx_stop(g_vchn[v]);
        snd_sfx_chn_free(g_vchn[v]);
        g_vchn[v] = -1;
    }
    g_spu_ram = 0;
    g_hw_voices = 0;
}

void bp_spu_ram(const uint8_t* ram) {
    if(!g_snd_up || g_hw_voices) return;       /* no sound system, or already handed over */
    g_spu_ram = ram;
    for(int i = 0; i < SPU_SAMPLES; i++) { g_spu_samp[i].start = -1; g_spu_samp[i].aica = 0; g_spu_samp[i].refs = 0; }
    int got = 0;
    for(int v = 0; v < SPU_VOICES; v++) {
        g_vchn[v] = snd_sfx_chn_alloc();
        if(g_vchn[v] >= 0) got++;
        g_vkey[v] = -1; g_vsamp[v] = -1; g_vvol[v] = g_vpan[v] = g_vfreq[v] = -1;
    }
    /* The stream stays: it carries the voices declined at their key-on (see above), and is
     * silent the rest of the time. */
    g_hw_voices = 1;
    char msg[96];
    snprintf(msg, sizeof(msg), "audio: %d of %d SPU voices on AICA channels", got, SPU_VOICES);
    bp_log(got == SPU_VOICES ? BP_LOG_INFO : BP_LOG_WARN, msg);
}

void bp_spu_dirty(int addr, int len) {
    if(!g_spu_ram) return;
    for(int i = 0; i < SPU_SAMPLES; i++) {
        spu_samp_t* e = &g_spu_samp[i];
        if(e->start < 0 || e->stale) continue;
        if(e->start + e->bytes <= addr || addr + len <= e->start) continue;
        if(e->refs == 0) {
            if(e->aica) snd_mem_free(e->aica);
            e->aica = 0;
            e->start = -1;
        } else {
            e->stale = 1;
        }
    }
}

int bp_spu_voice(int v, int key, int on, int start, int pitch, int vol_l, int vol_r) {
    if(!g_spu_ram || v < 0 || v >= SPU_VOICES || g_vchn[v] < 0) return 0;
#if RECOMPSX_DC_PROFILE
    const uint64_t t0 = bp_time_us();
#endif
    const int chn = g_vchn[v];
    const int loud = vol_l > vol_r ? vol_l : vol_r;
    const int vol = loud >> 7;                                  /* 0..0x7FFF to 0..255 */
    const int pan = (vol_l + vol_r) > 0 ? (vol_r * 255) / (vol_l + vol_r) : 128;
    const int freq = (int)(((uint32_t)pitch * 44100u) >> 12);  /* 0x1000 is the recorded rate */

    if(on && key != g_vkey[v]) {
        g_vkey[v] = key;
        spu_samp_release(g_vsamp[v]);
        g_vsamp[v] = -1;
        const int s = spu_samp_for(start);
        if(s < 0) {
            /* Declined: the runtime mixes this note, and the channel falls silent for it. */
            snd_sfx_stop(chn);
#if RECOMPSX_DC_PROFILE
            g_prof_aica += bp_time_us() - t0;
            g_prof_aica_declined++;
#endif
            return 0;
        } else {
            g_spu_samp[s].refs++;
            g_vsamp[v] = s;
            aica_chan(chn, AICA_CH_CMD_START, g_spu_samp[s].aica, g_spu_samp[s].len, g_spu_samp[s].loops,
                      g_spu_samp[s].loop_start, freq, vol, pan);
            g_vvol[v] = vol; g_vpan[v] = pan; g_vfreq[v] = freq;
        }
    } else if(!on) {
        g_vkey[v] = key;
        if(g_vsamp[v] >= 0) {
            snd_sfx_stop(chn);
            spu_samp_release(g_vsamp[v]);
            g_vsamp[v] = -1;
        }
    } else if(g_vsamp[v] >= 0) {
        uint32_t what = 0;
        if(vol != g_vvol[v]) what |= AICA_CH_UPDATE_SET_VOL;
        if(pan != g_vpan[v]) what |= AICA_CH_UPDATE_SET_PAN;
        if(freq != g_vfreq[v]) what |= AICA_CH_UPDATE_SET_FREQ;
        if(what) {
            const spu_samp_t* e = &g_spu_samp[g_vsamp[v]];
            aica_chan(chn, AICA_CH_CMD_UPDATE | what, e->aica, e->len, e->loops, e->loop_start,
                      freq, vol, pan);
            g_vvol[v] = vol; g_vpan[v] = pan; g_vfreq[v] = freq;
        }
    }
#if RECOMPSX_DC_PROFILE
    g_prof_aica += bp_time_us() - t0;
#endif
    return 1;
}

static int ring_count(void) {
    const int n = g_ring_head - g_ring_tail;
    return n >= 0 ? n : n + RING_FRAMES;
}

/* The AICA asking for its next block. `req` is in bytes across both channels, interleaved, which
 * is the shape the emulator produces, so this is a copy and nothing more.
 *
 * A shortfall is filled with silence rather than reported: the stream keeps its cadence, and
 * silence is what an underrun sounds like anyway. */
void* audio_pull(snd_stream_hnd_t hnd, int req, int* got) {
    (void)hnd;

    int want = req / 4;                          /* stereo frames */
    if(want > (int)(sizeof(g_pull) / 4)) want = (int)(sizeof(g_pull) / 4);

    int have = ring_count();
    if(have > want) have = want;

    for(int i = 0; i < have; i++) {
        g_pull[i * 2 + 0] = g_ring[g_ring_tail * 2 + 0];
        g_pull[i * 2 + 1] = g_ring[g_ring_tail * 2 + 1];
        g_ring_tail = (g_ring_tail + 1) % RING_FRAMES;
    }
    for(int i = have; i < want; i++) {
        g_pull[i * 2 + 0] = 0;
        g_pull[i * 2 + 1] = 0;
    }

    *got = want * 4;
    return g_pull;
}

/* ---- audio ------------------------------------------------------------------------------------ */

void bp_audio_push(const int16_t* frames, int frame_count) {
    if(g_stream == SND_STREAM_INVALID || frame_count <= 0) return;

    for(int i = 0; i < frame_count; i++) {
        const int next = (g_ring_head + 1) % RING_FRAMES;
        if(next == g_ring_tail) break;      /* full: the runtime's own cap should prevent this */
        g_ring[g_ring_head * 2 + 0] = frames[i * 2 + 0];
        g_ring[g_ring_head * 2 + 1] = frames[i * 2 + 1];
        g_ring_head = next;
    }
}

/* What the host still holds, which is the ring plus whatever of the AICA's own buffer has not
 * been played. The second part cannot be read back, so it is counted as the average — half the
 * buffer. Getting it approximately right matters: the runtime caps total latency against this
 * number, and reporting only the ring would let the true delay settle a whole AICA buffer
 * higher than asked for. */
int bp_audio_buffered(void) {
    if(g_stream == SND_STREAM_INVALID) return 0;
    pump_audio();
    /* 16-bit samples, so a channel's buffer holds STREAM_BYTES_PER_CHANNEL/2 samples, which is
     * the same number of stereo frames. Half of it is the average still unplayed. */
    const int aica_frames = STREAM_BYTES_PER_CHANNEL / 2 / 2;
    return ring_count() + aica_frames;
}
