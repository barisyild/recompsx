package spu;

import core.Runtime;
import core.Scheduler;
import core.TimeBase;
import shim.Backend;
import shim.RawBuf;
import shim.IntMath;
import shim.RawMem;

/**
	The sound processor: twenty-four ADPCM voices, their envelopes, and the mix they add up to.

	The PlayStation has no sample playback in software. A game writes compressed waveforms into
	512 KB of sound RAM, points twenty-four voices at them, and the SPU produces one stereo pair
	every 768 CPU cycles — exactly 44100 of them a second, which is why that number is the machine's
	clock divided by 768 and not a coincidence. Everything here follows from that one tick.

	Three things happen per voice per tick, in this order, because each depends on the last:

	1. **The envelope moves.** ADSR is a rate and a direction, not a curve: a shift and a step
	   decide how often the level changes and by how much, and "exponential" means the step is
	   scaled by the level itself. A voice at zero level is silent no matter what its sample says.
	2. **The pitch counter advances**, in twelve fractional bits, and crossing an integer boundary
	   moves to the next decoded sample — decoding another sixteen-byte block when it runs out.
	3. **The sample is scaled** by envelope and then by the voice's two volumes, and added to the
	   left and right sums.

	**What is not here yet, and is not pretended to be.** Interpolation: hardware resamples with a
	four-tap gaussian filter and this holds each sample instead, which is audibly rougher on
	low-pitched voices and exactly right on ones playing at their recorded rate. Noise, pitch
	modulation and reverb are read and stored but do nothing. Volume sweeps take their target
	immediately rather than gliding. Each of those is a fidelity gap with a known shape, recorded
	in docs/specs/runtime.md section 7.6 — none of them is silence, and none is a reason to wait
	before making a sound.

	Register map and the ADSR and ADPCM arithmetic from psx-spx "Sound Processing Unit (SPU)".
**/
class Spu {
	/** Sound RAM: 512 KB, addressed in 8-byte units by every register that names it. */
	public static inline var RAM_BYTES = 0x80000;

	/** Voices. Twenty-four, as on hardware, and the number every global register has bits for. */
	public static inline var VOICES = 24;

	/** One stereo pair per this many CPU cycles: 33868800 / 768 is 44100 exactly. */
	public static inline var CYCLES_PER_SAMPLE = 768;

	/** Samples generated per scheduled batch. Small enough to stay ahead of a frame, large
	    enough that the scheduler is not the cost. */
	static inline var BATCH = 128;

	static inline var BASE = 0x1F801C00;
	static inline var END = 0x1F801E80;

	static inline var VOICE_REGS_END = 0x1F801D80;

	// Globals.
	static inline var REG_MAIN_VOL_L = 0x1F801D80;
	static inline var REG_MAIN_VOL_R = 0x1F801D82;
	static inline var REG_KON_LO = 0x1F801D88;
	static inline var REG_KON_HI = 0x1F801D8A;
	static inline var REG_KOFF_LO = 0x1F801D8C;
	static inline var REG_KOFF_HI = 0x1F801D8E;
	static inline var REG_PMON_LO = 0x1F801D90;
	static inline var REG_PMON_HI = 0x1F801D92;
	static inline var REG_NON_LO = 0x1F801D94;
	static inline var REG_NON_HI = 0x1F801D96;
	static inline var REG_EON_LO = 0x1F801D98;
	static inline var REG_EON_HI = 0x1F801D9A;
	static inline var REG_ENDX_LO = 0x1F801D9C;
	static inline var REG_ENDX_HI = 0x1F801D9E;
	static inline var REG_REVERB_BASE = 0x1F801DA2;
	static inline var REG_IRQ_ADDR = 0x1F801DA4;
	static inline var REG_TRANSFER_ADDR = 0x1F801DA6;
	static inline var REG_FIFO = 0x1F801DA8;
	static inline var REG_CONTROL = 0x1F801DAA;
	static inline var REG_TRANSFER_CTRL = 0x1F801DAC;
	static inline var REG_STATUS = 0x1F801DAE;

	public static var ram(default, null):RawBuf;

	// ---- voice state ------------------------------------------------------------------------

	static var volL:Array<Int>;         // raw register value
	static var volR:Array<Int>;
	static var pitch:Array<Int>;
	static var startAddr:Array<Int>;    // byte address in sound RAM
	static var repeatAddr:Array<Int>;
	static var adsrLo:Array<Int>;
	static var adsrHi:Array<Int>;

	static var curAddr:Array<Int>;      // byte address of the block being played
	static var blockPos:Array<Int>;     // 0..27 within the decoded block
	static var counter:Array<Int>;      // 12-bit fractional position
	static var older:Array<Int>;        // the two samples the ADPCM filter looks back at
	static var old:Array<Int>;
	static var decoded:Array<Int>;      // VOICES * 28 samples
	static var envLevel:Array<Int>;     // 0..0x7FFF
	static var envPhase:Array<Int>;
	static var envCounter:Array<Int>;

	static inline var PHASE_OFF = 0;
	static inline var PHASE_ATTACK = 1;
	static inline var PHASE_DECAY = 2;
	static inline var PHASE_SUSTAIN = 3;
	static inline var PHASE_RELEASE = 4;

	static inline var SAMPLES_PER_BLOCK = 28;
	static inline var BLOCK_BYTES = 16;

	// ---- global state -----------------------------------------------------------------------

	static var mainVolL = 0;
	static var mainVolR = 0;
	static var pmon = 0;
	static var non = 0;
	static var eon = 0;
	static var endx = 0;
	static var control = 0;
	static var transferControl = 0;
	static var irqAddr = 0;
	static var reverbBase = 0;
	static var transferAddr = 0;

	/** Halfwords written into sound RAM. The first evidence a game's audio data arrived. */
	public static var written(default, null) = 0;

	/** Stereo pairs handed to the platform. The first evidence it will be heard. */
	public static var samplesOut(default, null) = 0;

	/** Pairs whose left or right is non-zero — silence and sound are different failures. */
	public static var nonSilent(default, null) = 0;

	// ---- the output buffer --------------------------------------------------------------------

	static inline var OUT_PAIRS = 2048;
	static var out:RawBuf;
	static var outCount = 0;

	/** The cycle the last sample was generated at. Time is caught up to, never stepped through. */
	static var lastSample = 0;

	/**
		The mix in progress: every voice's contribution to each sample of one catch-up, summed.
		Sized for the longest catch-up the guard allows, and allocated once — the portable subset
		allocates nothing after init.
	**/
	static var accL:Array<Int>;
	static var accR:Array<Int>;
	static inline var MAX_CATCHUP = 4097;

	/**
		Whether the mixer produces samples at all.

		Presentation only, like `Gpu.hw` (ADR-0008): a host with nobody listening turns it off
		with `--no-audio`, and the SPU still does everything a game can observe. Envelopes step,
		voices advance through their blocks, ENDX and the loop flags are raised on time, the
		current-volume registers read what they would have read. What stops is the arithmetic
		that only a listener needs — the envelope and volume multiplies, the accumulators, the
		main-volume pass and the buffer — which is the larger half of a voice's cost. `nonSilent`
		and the peak diagnostics then measure nothing, so this is never a digest mode.

		Meant to be set before the first sample. A voice advanced silently skips its samples'
		decode, so the ADPCM filter's memory is stale for two blocks after sound is turned back on.
	**/
	public static var outputEnabled = true;

	public static function init():Void {
		ram = RawMem.alloc(RAM_BYTES);
		out = RawMem.alloc(OUT_PAIRS * 4);

		mixRegs = [for (_ in 0...MIX_COUNT) 0];
		reverbRegs = [for (_ in 0...REVERB_COUNT) 0];

		volL = [for (_ in 0...VOICES) 0];
		volR = [for (_ in 0...VOICES) 0];
		pitch = [for (_ in 0...VOICES) 0];
		startAddr = [for (_ in 0...VOICES) 0];
		repeatAddr = [for (_ in 0...VOICES) 0];
		adsrLo = [for (_ in 0...VOICES) 0];
		adsrHi = [for (_ in 0...VOICES) 0];
		curAddr = [for (_ in 0...VOICES) 0];
		blockPos = [for (_ in 0...VOICES) SAMPLES_PER_BLOCK];
		counter = [for (_ in 0...VOICES) 0];
		older = [for (_ in 0...VOICES) 0];
		old = [for (_ in 0...VOICES) 0];
		decoded = [for (_ in 0...VOICES * SAMPLES_PER_BLOCK) 0];
		accL = [for (_ in 0...MAX_CATCHUP) 0];
		accR = [for (_ in 0...MAX_CATCHUP) 0];
		envLevel = [for (_ in 0...VOICES) 0];
		envPhase = [for (_ in 0...VOICES) PHASE_OFF];
		envCounter = [for (_ in 0...VOICES) 0];

		mainVolL = 0;
		mainVolR = 0;
		pmon = 0;
		non = 0;
		eon = 0;
		endx = 0;
		control = 0;
		transferControl = 0;
		irqAddr = 0;
		reverbBase = 0;
		transferAddr = 0;
		written = 0;
		samplesOut = 0;
		nonSilent = 0;
		outCount = 0;
		lastSample = 0;
	}

	/** Arms the first batch. Separate from `init` because it needs the machine's clock. */
	public static function start(cycles:Int):Void {
		lastSample = cycles;
		Scheduler.scheduleAt(Scheduler.SPU_BATCH, (cycles + CYCLES_PER_SAMPLE * BATCH) | 0);
	}

	public static inline function contains(p:Int):Bool {
		return p >= BASE && p < END;
	}

	// ---- registers ------------------------------------------------------------------------------

	public static function read16(p:Int):Int {
		if (p < VOICE_REGS_END) return readVoice(p);
		else if (p == REG_MAIN_VOL_L) return mainVolL;
		else if (p == REG_MAIN_VOL_R) return mainVolR;
		else if (p == REG_PMON_LO) return pmon & 0xFFFF;
		else if (p == REG_PMON_HI) return (pmon >>> 16) & 0xFF;
		else if (p == REG_NON_LO) return non & 0xFFFF;
		else if (p == REG_NON_HI) return (non >>> 16) & 0xFF;
		else if (p == REG_EON_LO) return eon & 0xFFFF;
		else if (p == REG_EON_HI) return (eon >>> 16) & 0xFF;
		else if (p == REG_ENDX_LO) return endx & 0xFFFF;
		else if (p == REG_ENDX_HI) return (endx >>> 16) & 0xFF;
		else if (p == REG_IRQ_ADDR) return (irqAddr >> 3) & 0xFFFF;
		else if (p == REG_REVERB_BASE) return (reverbBase >> 3) & 0xFFFF;
		else if (p == REG_TRANSFER_ADDR) return (transferAddr >> 3) & 0xFFFF;
		else if (p == REG_CONTROL) return control;
		else if (p == REG_TRANSFER_CTRL) return transferControl;
		else if (p == REG_STATUS) return status();
		else if (p == REG_CUR_VOL_L) return mainVolL;
		else if (p == REG_CUR_VOL_R) return mainVolR;
		else if (isMixReg(p)) return mixRegs[(p - MIX_BASE) >> 1];
		else if (isReverbReg(p)) return reverbRegs[(p - REVERB_BASE_REG) >> 1];
		else if (isVoiceCurrentVol(p)) return voiceCurrentVol(p);
		else return quietRead(p);
	}

	// ---- the registers the mixer does not read yet ------------------------------------------------
	//
	// Reverb output volume, CD input volume, external input volume, and the thirty-two words that
	// configure the reverb itself. Stored and handed back, exactly as written.
	//
	// Storing them is not the same as implementing reverb, and the difference is worth being clear
	// about: none of these change a sample yet. What they change is what a game *sees*. libspu
	// writes a reverb preset as a block and then reads parts of it back — `SpuGetReverbDepth` is a
	// read — and a register file that answers zero to a game that just wrote to it is a machine
	// that does not exist. The warnings these replaced were also misleading: half of these
	// addresses are not reverb at all, they are the CD and external audio inputs.
	//
	// The two "current main volume" registers are the same idea with a real answer available:
	// there are no volume sweeps in this SPU, so the current volume *is* the set volume.

	static inline var REG_CUR_VOL_L = 0x1F801DB8;
	static inline var REG_CUR_VOL_R = 0x1F801DBA;

	/**
		1D84..1DB6: reverb output volume, the CD input volume, the external input volume.

		Covered as one span rather than three, because the named registers that sit between them —
		KON, KOFF, PMON, NON, EON, ENDX and the addresses — are matched earlier in the chain and
		never reach here. Twenty-six halfwords, of which six are real and the rest unreachable.
	**/
	static inline var MIX_BASE = 0x1F801D84;
	static inline var MIX_COUNT = 26;

	/** 1DC0..1DFF: the reverb configuration block. */
	static inline var REVERB_BASE_REG = 0x1F801DC0;
	static inline var REVERB_COUNT = 32;

	static var mixRegs:Array<Int>;
	static var reverbRegs:Array<Int>;

	static inline function isMixReg(p:Int):Bool
		return p >= MIX_BASE && p < MIX_BASE + MIX_COUNT * 2;

	static inline function isReverbReg(p:Int):Bool
		return p >= REVERB_BASE_REG && p < REVERB_BASE_REG + REVERB_COUNT * 2;

	/** 1E00..1E7F — each voice's current volume, which without sweeps is its envelope level. */
	static inline function isVoiceCurrentVol(p:Int):Bool
		return p >= 0x1F801E00 && p < 0x1F801E80;

	static function voiceCurrentVol(p:Int):Int {
		final v = (p - 0x1F801E00) >> 2;
		if (v < 0 || v >= VOICES) return 0;
		else {}
		final level = envLevel[v];
		// The left word of the pair, then the right; both are the same here because a voice's
		// two volumes are applied at mix time rather than tracked separately.
		return ((level * volumeOf((p & 2) == 0 ? volL[v] : volR[v])) >> 15) & 0xFFFF;
	}

	public static function write16(p:Int, v:Int):Void {
		final w = v & 0xFFFF;
		if (p < VOICE_REGS_END) writeVoice(p, w);
		else if (p == REG_MAIN_VOL_L) mainVolL = w;
		else if (p == REG_MAIN_VOL_R) mainVolR = w;
		else if (p == REG_KON_LO) keyOn(w);
		else if (p == REG_KON_HI) keyOn(w << 16);
		else if (p == REG_KOFF_LO) keyOff(w);
		else if (p == REG_KOFF_HI) keyOff(w << 16);
		else if (p == REG_PMON_LO) pmon = (pmon & 0xFFFF0000) | w;
		else if (p == REG_PMON_HI) pmon = (pmon & 0xFFFF) | (w << 16);
		else if (p == REG_NON_LO) non = (non & 0xFFFF0000) | w;
		else if (p == REG_NON_HI) non = (non & 0xFFFF) | (w << 16);
		else if (p == REG_EON_LO) eon = (eon & 0xFFFF0000) | w;
		else if (p == REG_EON_HI) eon = (eon & 0xFFFF) | (w << 16);
		// ENDX is set by the voices and cleared by writing it, which is how a game asks
		// "which of my sounds have finished" and then starts listening again.
		else if (p == REG_ENDX_LO) endx = endx & 0xFFFF0000;
		else if (p == REG_ENDX_HI) endx = endx & 0xFFFF;
		else if (p == REG_IRQ_ADDR) irqAddr = w << 3;
		else if (p == REG_REVERB_BASE) reverbBase = w << 3;
		else if (p == REG_TRANSFER_ADDR) transferAddr = w << 3;
		else if (p == REG_FIFO) pushHalfword(w);
		else if (p == REG_CONTROL) control = w;
		else if (p == REG_TRANSFER_CTRL) transferControl = w;
		else if (isMixReg(p)) mixRegs[(p - MIX_BASE) >> 1] = w;
		else if (isReverbReg(p)) reverbRegs[(p - REVERB_BASE_REG) >> 1] = w;
		// The current-volume registers are read-only on hardware; a write is not an error, it is
		// simply ignored, and saying so once would be noise.
		else if (p == REG_CUR_VOL_L || p == REG_CUR_VOL_R) {}
		else if (isVoiceCurrentVol(p)) {}
		else quietWrite(p);
	}

	static function readVoice(p:Int):Int {
		final v = (p - BASE) >> 4;
		final reg = p & 0x0F;
		if (v >= VOICES) return 0;
		else if (reg == 0x0) return volL[v];
		else if (reg == 0x2) return volR[v];
		else if (reg == 0x4) return pitch[v];
		else if (reg == 0x6) return (startAddr[v] >> 3) & 0xFFFF;
		else if (reg == 0x8) return adsrLo[v];
		else if (reg == 0xA) return adsrHi[v];
		else if (reg == 0xC) return envLevel[v];
		else if (reg == 0xE) return (repeatAddr[v] >> 3) & 0xFFFF;
		else return 0;
	}

	static function writeVoice(p:Int, w:Int):Void {
		final v = (p - BASE) >> 4;
		final reg = p & 0x0F;
		// Which of a voice's eight registers a game ever writes, once each. A register nobody
		// writes reads as zero forever, and a zero in the wrong one of these is silence.
		final noteKey = 0x6A000000 | reg;
		if (!Runtime.alreadyReported(noteKey)) {
			Runtime.noteOnce(noteKey, "SPU voice register +" + reg + " written, first value "
				+ hex(w));
		} else {}
		if (v >= VOICES) return;
		else if (reg == 0x0) volL[v] = w;
		else if (reg == 0x2) volR[v] = w;
		else if (reg == 0x4) pitch[v] = w;
		else if (reg == 0x6) startAddr[v] = (w << 3) & (RAM_BYTES - 1);
		else if (reg == 0x8) adsrLo[v] = w;
		else if (reg == 0xA) adsrHi[v] = w;
		else if (reg == 0xC) envLevel[v] = w & 0x7FFF;
		else if (reg == 0xE) repeatAddr[v] = (w << 3) & (RAM_BYTES - 1);
		else {}
	}

	/**
		SPUSTAT, of which only two things are true here.

		The low six bits mirror the control register, which games read back. Bit 10 is "busy", and
		it is always zero because every transfer completes inside the write that started it — a
		game that polls for the transfer to finish finds it already has.
	**/
	static function status():Int {
		return control & 0x3F;
	}

	// ---- key on / key off -------------------------------------------------------------------

	/**
		Starting a voice, which is more than setting a flag.

		The playback position goes back to the start address, the ADPCM filter's memory of the two
		previous samples is cleared — otherwise the first block of a new sound is filtered against
		the tail of the old one — and the envelope begins at zero in attack. Hardware also clears
		this voice's ENDX, which is what lets a game tell a sound that has finished from one that
		never started.
	**/
	static function keyOn(mask:Int):Void {
		for (v in 0...VOICES) {
			if ((mask & (1 << v)) == 0) continue;
			else {}
			curAddr[v] = startAddr[v];
			repeatAddr[v] = startAddr[v];
			blockPos[v] = SAMPLES_PER_BLOCK;   // forces a decode on the first tick
			counter[v] = 0;
			old[v] = 0;
			older[v] = 0;
			envLevel[v] = 0;
			envCounter[v] = 0;
			envPhase[v] = PHASE_ATTACK;
			endx &= ~(1 << v);
			// The first voice to start, in full. A silent mixer has half a dozen possible causes
			// and they are all visible here: a pitch of zero, volumes of zero, an envelope whose
			// attack takes minutes, or a start address pointing at nothing.
			if (!Runtime.alreadyReported(0x69000000)) {
				Runtime.noteOnce(0x69000000, "SPU voice " + v + " keyed on: pitch "
					+ hex(pitch[v]) + " volL " + hex(volL[v]) + " volR " + hex(volR[v])
					+ " adsr " + hex(adsrHi[v]) + hex(adsrLo[v])
					+ " start " + hex(startAddr[v])
					+ " first block " + hex(RawMem.get8(ram, startAddr[v]))
					+ "," + hex(RawMem.get8(ram, startAddr[v] + 1))
					+ " | main vol " + hex(mainVolL) + "/" + hex(mainVolR)
					+ " control " + hex(control));
			} else {}
			keyedOn++;
		}
	}

	static function keyOff(mask:Int):Void {
		for (v in 0...VOICES) {
			if ((mask & (1 << v)) == 0) continue;
			else {}
			if (envPhase[v] != PHASE_OFF) envPhase[v] = PHASE_RELEASE;
			else {}
		}
	}

	/** Voices started. A game making no sound and a game starting no voices are different bugs. */
	public static var keyedOn(default, null) = 0;

	/** The mixer's inputs, as one line: what is set decides whether anything can be heard. */
	public static function settings():String {
		var loudest = 0;
		var active = 0;
		for (v in 0...VOICES) {
			if (envPhase[v] != PHASE_OFF) active++;
			else {}
			final a = volumeOf(volL[v]);
			if (a > loudest) loudest = a;
			else {}
		}
		return "cnt " + hex(control) + " main " + hex(mainVolL) + "/" + hex(mainVolR)
			+ " voices " + active + " loudest " + loudest
			+ " peaks smp=" + peakSample + " env=" + peakEnv + " vol=" + peakVoiceVol;
	}

	/** The largest each factor has ever been. Zero in one of them is the whole explanation. */
	public static var peakSample(default, null) = 0;
	public static var peakEnv(default, null) = 0;
	public static var peakVoiceVol(default, null) = 0;

	static inline function abs(v:Int):Int return v < 0 ? -v : v;

	// ---- generating sound ---------------------------------------------------------------------

	/**
		Catches the sound up to the clock, a batch of samples at a time.

		The scheduler arms a batch rather than a sample because a deadline every 768 cycles would
		cost more than the mixing does. Between batches the machine is silent in the sense that no
		sample exists yet — but no game can observe that, because nothing it can read depends on
		how far the mixer has got.
	**/
	public static function onBatch(cycles:Int):Void {
		// Decoding and mixing, bracketed for a backend that shows where a frame goes (the
		// Dreamcast's overlay); it hides inside the emulated frame otherwise. One-way markers.
		Backend.profileMark(Backend.PROFILE_SPU, 1);
		catchUp(cycles);
		Backend.profileMark(Backend.PROFILE_SPU, 0);
		flush();
		Scheduler.scheduleAt(Scheduler.SPU_BATCH, (cycles + CYCLES_PER_SAMPLE * BATCH) | 0);
	}

	static function catchUp(cycles:Int):Void {
		// Wrap-safe, like every other comparison against the cycle counter (ADR-0004).
		var due = 0;
		var last = lastSample;
		while (((cycles - last) | 0) >= CYCLES_PER_SAMPLE && due < MAX_CATCHUP) {
			last = (last + CYCLES_PER_SAMPLE) | 0;
			due++;
		}
		lastSample = last;
		if (due > 0) mixBatch(due);
		else {}
		// A catch-up longer than a frame means something stopped the scheduler, and grinding
		// through it a sample at a time would turn a stall into a hang. The bound mixes what the
		// old per-sample loop mixed before it gave up, then gives up the same way.
		if (due >= MAX_CATCHUP) fellBehind(cycles);
		else {}
	}

	static function fellBehind(cycles:Int):Void {
		lastSample = cycles;
		Runtime.reportOnce(0x68000000, "the SPU fell more than 4096 samples behind the clock");
	}

	/** One stereo pair: every voice, summed, scaled by the main volume. The fixture's unit. */
	static function mixOne():Void {
		mixBatch(1);
	}

	/**
		`n` stereo pairs, voice by voice rather than sample by sample.

		The sample-major loop this replaces asked every voice for one sample and paid, per voice
		and per sample, three volume decodes, two peak checks and the loop's own bookkeeping —
		about ten calls for one multiply-add, and the largest cost in the browser's profile. Here
		each voice runs its `n` samples in one tight loop into the accumulators, with its volumes
		decoded once, and the main volume and saturation are applied in one pass at the end.

		Same numbers, in the same order of emission: voices do not affect one another (nothing
		modulates a voice by its neighbour here), a voice's registers and the sound RAM change
		only between batches, addition wraps the same whichever voice comes first, and a voice
		that falls silent mid-batch stops contributing exactly where the per-sample loop skipped
		it. `SpuVoice` and the game digests hold it to that.
	**/
	static function mixBatch(n:Int):Void {
		if (!outputEnabled) advanceBatch(n);
		else {
			for (i in 0...n) {
				accL[i] = 0;
				accR[i] = 0;
			}
			for (v in 0...VOICES) {
				if (envPhase[v] == PHASE_OFF) continue;
				else {}
				mixVoice(v, n);
			}
			final mainL = volumeOf(mainVolL);
			final mainR = volumeOf(mainVolR);
			for (i in 0...n) emit((sat16(accL[i]) * mainL) >> 15, (sat16(accR[i]) * mainR) >> 15);
		}
	}

	/** `n` samples of every voice's state, and no sound: what `mixBatch` does with nobody listening. */
	static function advanceBatch(n:Int):Void {
		for (v in 0...VOICES) {
			if (envPhase[v] == PHASE_OFF) continue;
			else {}
			advanceVoice(v, n);
		}
		// What `emit` would have counted: a batch is never longer than the buffer it fills.
		samplesOut += n > OUT_PAIRS ? OUT_PAIRS : n;
	}

	// ---- the state without the sound ---------------------------------------------------------
	//
	// With nobody listening a voice still has to arrive at the same place: the same block at the
	// same tick, the same envelope level, ENDX raised on the same sample. Sample by sample that
	// is `stepEnvelope` and `voiceSample` with the value thrown away, and it costs nearly what
	// mixing costs. But between two *events* nothing a game can read changes: the envelope's
	// counter climbs towards its period and the position climbs towards the end of its block. So
	// a silent voice moves in runs — the shorter of the two distances, capped by the batch — and
	// the event that ends a run is applied by the very code the per-sample path uses, in the
	// order that path would reach it: the envelope's tick, then the block header. `SpuAdvance`
	// holds the two paths to the same state batch by batch, and the `--no-audio` game digest
	// holds them over nine thousand frames of a real game.

	static inline var NEVER = 0x7FFFFFFF;

	/** The state half of `mixVoice`, from event to event, until silent. */
	static function advanceVoice(v:Int, n:Int):Void {
		var left = n;
		while (left > 0 && envPhase[v] != PHASE_OFF) {
			final period = envelopePeriod(v);
			final pinned = envelopePinned(v);
			final envRun = pinned ? NEVER : envelopeRun(period, v);
			final posRun = positionRun(v);
			if (period == 1 && !pinned) {
				// An event on every tick — a fast attack, an exponential release — is the common
				// case in a game, and there the phase's own code, tick by tick, is the cheapest
				// walk there is; the run machinery would only be overhead around it. The position
				// follows in one step, and a phase change ends the run on the tick that made it.
				var m = posRun < left ? posRun : left;
				final phase = envPhase[v];
				var i = 0;
				while (i < m) {
					stepEnvelope(v);
					i++;
					if (envPhase[v] != phase) m = i;
					else {}
				}
				advancePosition(v, i);
				left -= i;
				continue;
			} else {}
			var run = envRun < posRun ? envRun : posRun;
			if (run > left) run = left;
			else {}
			if (run < envRun) {
				// Quiet ticks are the counter climbing — and, on a pinned level, wrapping at the
				// period, since every firing tick there resets it and changes nothing else.
				if (pinned) envCounter[v] = IntMath.mod((envCounter[v] + run) | 0, period);
				else envCounter[v] += run;
			} else {
				// A run that reaches the period ends with the tick that moves the level, taken by
				// the phase's own code.
				envCounter[v] += run - 1;
				stepEnvelope(v);
			}
			advancePosition(v, run);
			left -= run;
		}
	}

	/** Ticks until `ready` next lets this phase through, counting the one that does. */
	static function envelopeRun(period:Int, v:Int):Int {
		final k = (period - envCounter[v]) | 0;
		return k < 1 ? 1 : k;
	}

	/**
		A sustain that has reached its rail.

		Most of a game's voices spend their lives here: sustain rising, at the top, with a shift
		below twelve — so `ready` lets every tick through and `sustain` adds a step that the clamp
		takes straight back off. The level, the phase and the peak are what they were after any
		number of such ticks; only the counter moves, and it moves modulo the period. Treating
		that as "no event" is what lets a steady voice advance a block at a time rather than a
		sample at a time. Falling at zero is the same rail from below.
	**/
	static function envelopePinned(v:Int):Bool {
		if (envPhase[v] != PHASE_SUSTAIN) return false;
		else {
			final rising = (adsrHi[v] & 0x4000) == 0;
			return rising ? envLevel[v] >= 0x7FFF : envLevel[v] <= 0;
		}
	}

	/** The period `ready` would compute for the current phase at the current level. */
	static function envelopePeriod(v:Int):Int {
		final phase = envPhase[v];
		var shift = 0;
		var slower = false;
		if (phase == PHASE_ATTACK) {
			final lo = adsrLo[v];
			shift = (lo >> 10) & 0x1F;
			slower = (lo & 0x8000) != 0 && envLevel[v] > 0x6000;
		} else if (phase == PHASE_DECAY) {
			shift = (adsrLo[v] >> 4) & 0x0F;
		} else if (phase == PHASE_SUSTAIN) {
			final hi = adsrHi[v];
			shift = (hi >> 8) & 0x1F;
			slower = (hi & 0x8000) != 0 && (hi & 0x4000) == 0 && envLevel[v] > 0x6000;
		} else {
			shift = adsrHi[v] & 0x1F;
		}
		return periodOf(shift, slower);
	}

	/** Ticks until the position leaves its block, counting the one that does. */
	static function positionRun(v:Int):Int {
		// A block not yet started is started on the next tick, as `voiceSample` would.
		if (blockPos[v] >= SAMPLES_PER_BLOCK) return 1;
		else {}
		final step = pitchStep(v);
		if (step == 0) return NEVER;
		else {}
		final room = ((SAMPLES_PER_BLOCK << 12) - ((blockPos[v] << 12) + counter[v])) | 0;
		return IntMath.div((room + step - 1) | 0, step);
	}

	static inline function pitchStep(v:Int):Int {
		final step = pitch[v] & 0xFFFF;
		return step > 0x4000 ? 0x4000 : step;
	}

	/** `run` ticks of `voiceSample`'s position arithmetic at once, with the block header where it falls. */
	static function advancePosition(v:Int, run:Int):Void {
		if (blockPos[v] >= SAMPLES_PER_BLOCK) startBlock(v);
		else {}
		var p = ((blockPos[v] << 12) + counter[v] + IntMath.mul(run, pitchStep(v))) | 0;
		if (p >= (SAMPLES_PER_BLOCK << 12)) {
			p -= SAMPLES_PER_BLOCK << 12;
			startBlock(v);
		} else {}
		blockPos[v] = p >> 12;
		counter[v] = p & 0xFFF;
	}

	/** A block's header without its samples: the part of `decodeBlock` a game can see. */
	static function startBlock(v:Int):Void {
		final at = curAddr[v] & (RAM_BYTES - 1);
		final flags = RawMem.get8(ram, at + 1);
		blockPos[v] = 0;
		advanceBlock(v, flags);
	}

	/** `mixBatch` for a test: the batch the scheduler would run, without a scheduler. */
	public static function mixBatchForTest(n:Int):Void {
		mixBatch(n);
		outCount = 0;
	}

	/** What a voice will do next, folded into one word: the state the silent path must keep. */
	public static function voiceState(v:Int):Int {
		var h = core.Hash.word(core.Hash.FNV_OFFSET, envLevel[v]);
		h = core.Hash.word(h, envPhase[v]);
		h = core.Hash.word(h, envCounter[v]);
		h = core.Hash.word(h, counter[v]);
		h = core.Hash.word(h, blockPos[v]);
		h = core.Hash.word(h, curAddr[v]);
		return core.Hash.word(h, repeatAddr[v]);
	}

	/**
		One voice's next `n` samples into the accumulators, until it goes silent — in runs.

		The per-sample form called `stepEnvelope` and `voiceSample` for every sample of every
		voice, and those calls were most of the mixer. Between two events — the envelope's next
		change and the block's end — every sample does the same thing: read the decoded sample,
		advance the position, multiply by the level and the volume, accumulate. So the voice
		moves in runs, as the silent path does (`advanceVoice`): a run's quiet samples go through
		one loop with no calls and the position in locals, the envelope's counter jumps by the
		run, and the sample on which the envelope changes gets its `stepEnvelope` first, as it
		always did. With a period of one every sample is an event, and then the loop steps the
		envelope itself, ending where the phase changes. What each sample does, and in what
		order, is unchanged — the level is read after the position advances, because a block
		that ends a one-shot zeroes it on that very sample — so the output is bit for bit the
		per-sample form's; `SpuVoice` and the sound-on digests hold it to that.
	**/
	static function mixVoice(v:Int, n:Int):Void {
		final vl = volumeOf(volL[v]);
		final vr = volumeOf(volR[v]);
		// Three factors multiply into every sample, and a silent mixer is one of them being
		// zero. Watching all three separately is the difference between "no sound" and a
		// specific wrong register.
		if (abs(vl) > peakVoiceVol) peakVoiceVol = abs(vl);
		else {}
		var i = 0;
		while (i < n && envPhase[v] != PHASE_OFF) {
			final period = envelopePeriod(v);
			final pinned = envelopePinned(v);
			final posRun = positionRun(v);
			if (period == 1 && !pinned) {
				final m = posRun < n - i ? posRun : n - i;
				i += mixRun(v, i, m, vl, vr, true);
				continue;
			} else {}
			final envRun = pinned ? NEVER : envelopeRun(period, v);
			var run = envRun < posRun ? envRun : posRun;
			if (run > n - i) run = n - i;
			else {}
			// The samples before the envelope's change, if it falls inside the run: on a pinned
			// level every tick fires and changes nothing, so the counter only wraps.
			final quiet = run < envRun ? run : run - 1;
			if (quiet > 0) {
				if (pinned) envCounter[v] = IntMath.mod((envCounter[v] + quiet) | 0, period);
				else envCounter[v] += quiet;
				mixRun(v, i, quiet, vl, vr, false);
				i += quiet;
			} else {}
			if (run == envRun) {
				stepEnvelope(v);
				mixRun(v, i, 1, vl, vr, false);
				i++;
			} else {}
		}
	}

	/**
		`m` samples of one voice, accumulated from `at`: the per-sample work of `voiceSample`
		and the multiply, in one loop with the position in locals. A block that ends inside it
		is decoded where the per-sample form decoded it — while advancing, right after the
		sample that crossed — and the level is read after that, as `mixVoice` always read it.
		`stepping` is the period-one case: the envelope is stepped before every sample and the
		run ends on the sample whose step changes the phase. Returns the samples done.
	**/
	static function mixRun(v:Int, at:Int, m:Int, vl:Int, vr:Int, stepping:Bool):Int {
		final base = v * SAMPLES_PER_BLOCK;
		final step = pitchStep(v);
		final phase = envPhase[v];
		var pos = blockPos[v];
		var cnt = counter[v];
		var peak = peakSample;
		var k = 0;
		while (k < m) {
			if (stepping) stepEnvelope(v);
			else {}
			if (pos >= SAMPLES_PER_BLOCK) {
				decodeBlock(v);
				pos = 0;
			} else {}
			final raw = decoded[base + pos];
			cnt = (cnt + step) | 0;
			while (cnt >= 0x1000) {
				cnt -= 0x1000;
				pos++;
				if (pos >= SAMPLES_PER_BLOCK) {
					decodeBlock(v);
					pos = 0;
				} else {}
			}
			final s = (raw * envLevel[v]) >> 15;
			final magnitude = raw < 0 ? -raw : raw;
			if (magnitude > peak) peak = magnitude;
			else {}
			accL[at + k] = (accL[at + k] + ((s * vl) >> 15)) | 0;
			accR[at + k] = (accR[at + k] + ((s * vr) >> 15)) | 0;
			k++;
			if (stepping && envPhase[v] != phase) break;
			else {}
		}
		blockPos[v] = pos;
		counter[v] = cnt;
		peakSample = peak;
		return k;
	}

	/**
		One stereo pair, returned rather than queued — the conformance test's way in.

		The mixer is otherwise reachable only through a scheduler deadline and leaves only through
		the platform, and a test can supply neither. This is the same `mixOne` the machine runs,
		with the pair handed back packed as two halves rather than pushed at a backend.
	**/
	public static function mixForTest():Int {
		final before = outCount;
		mixOne();
		if (outCount == before) return 0;
		else {}
		final at = before * 4;
		final l = RawMem.get8(out, at) | (RawMem.get8(out, at + 1) << 8);
		final r = RawMem.get8(out, at + 2) | (RawMem.get8(out, at + 3) << 8);
		// The buffer is the machine's, not the test's: leave it where it was.
		outCount = before;
		return (l & 0xFFFF) | (r << 16);
	}

	static function emit(l:Int, r:Int):Void {
		if (outCount >= OUT_PAIRS) return;
		else {}
		final ls = sat16(l);
		final rs = sat16(r);
		// Two halfword stores, little-endian on both targets by the shim's contract: the same
		// four bytes the byte stores wrote.
		RawMem.set16Index(out, outCount * 2, ls);
		RawMem.set16Index(out, outCount * 2 + 1, rs);
		outCount++;
		samplesOut++;
		if (ls != 0 || rs != 0) nonSilent++;
		else {}
	}

	/**
		How many frames the host may be holding before the emulator stops adding to the pile.

		A hundred milliseconds. Below about fifty a browser starts running dry between callbacks;
		much above this and the delay is audible as sound arriving after the picture it belongs to.
	**/
	static inline var LATENCY_CAP = 4410;

	/**
		Hands the batch over, unless sound is already running late.

		The emulator makes samples at the rate the emulated machine makes them and the host plays
		them at the rate its clock ticks, and those two are never exactly equal. Whichever way the
		difference goes it accumulates: too slow and the host runs dry, too fast and the surplus
		sits in the host's queue, which *is* the delay — sound arriving later and later behind the
		frame it belongs to, growing for as long as the game runs.

		Nothing anywhere used to notice. `bp_audio_buffered` has been in the backend ABI from the
		start, described there as being for pacing, and the SDL backend has always answered it
		honestly — but no caller existed, so the queue was free to grow without limit. This is that
		caller: over the cap, a batch is dropped rather than added. Three milliseconds of silence
		is a far smaller artefact than a second of lag, and because the surplus is a fraction of a
		percent, a drop is rare once the queue has settled at the cap.

		**It costs the host one function.** A page that does not implement `audioBuffered` is
		reported as holding nothing, which is correct for a host that plays what it is given
		immediately and leaves everything as it was for one that does not — the pacing simply does
		not engage, because nothing told it there was anything to pace.

		Determinism is untouched, deliberately: the decision is made *after* `emit` has counted
		every sample, so `samplesOut` and `nonSilent` — which the digest hashes — are what the
		emulated machine produced, whatever the host did with them.
	**/
	static function flush():Void {
		if (outCount == 0) return;
		else {}
		if (Backend.audioBuffered() > LATENCY_CAP) {
			outCount = 0;
			return;
		} else {}
		Backend.audioPush(out, outCount);
		outCount = 0;
	}

	/**
		A voice's current sample, advancing its position by one tick.

		The counter is twelve fractional bits, so a pitch of 0x1000 is the recorded rate. Crossing
		an integer moves to the next decoded sample and, when the block runs out, decodes another —
		which is also where looping is decided, because the flags that say so live in the block.
	**/
	static function voiceSample(v:Int):Int {
		if (blockPos[v] >= SAMPLES_PER_BLOCK) decodeBlock(v);
		else {}
		final s = decoded[v * SAMPLES_PER_BLOCK + blockPos[v]];

		var step = pitch[v] & 0xFFFF;
		// Hardware caps the rate at four times the recorded one.
		if (step > 0x4000) step = 0x4000;
		else {}
		counter[v] = (counter[v] + step) | 0;
		while (counter[v] >= 0x1000) {
			counter[v] -= 0x1000;
			blockPos[v]++;
			if (blockPos[v] >= SAMPLES_PER_BLOCK) decodeBlock(v);
			else {}
		}
		return s;
	}

	// The four-bit ADPCM predictors, as pairs of sixth-scaled coefficients.
	static inline function filter0(f:Int):Int {
		return f == 0 ? 0 : (f == 1 ? 60 : (f == 2 ? 115 : (f == 3 ? 98 : 122)));
	}

	static inline function filter1(f:Int):Int {
		return f == 0 ? 0 : (f == 1 ? 0 : (f == 2 ? -52 : (f == 3 ? -55 : -60)));
	}

	/**
		One sixteen-byte ADPCM block into twenty-eight samples.

		Two header bytes and fourteen of data, each nibble a difference from a prediction made out
		of the previous two samples. The shift is a range, not a volume: a block of quiet detail and
		a block of loud detail use the same nibbles and different shifts.
	**/
	static function decodeBlock(v:Int):Void {
		final at = curAddr[v] & (RAM_BYTES - 1);
		final header = RawMem.get8(ram, at);
		final flags = RawMem.get8(ram, at + 1);
		var shift = header & 0x0F;
		// A shift above twelve is not a valid encoding; hardware treats it as nine.
		if (shift > 12) shift = 9;
		else {}
		var f = (header >> 4) & 0x0F;
		if (f > 4) f = 4;
		else {}
		final f0 = filter0(f);
		final f1 = filter1(f);

		final base = v * SAMPLES_PER_BLOCK;
		for (i in 0...SAMPLES_PER_BLOCK) {
			final byte = RawMem.get8(ram, at + 2 + (i >> 1));
			final nibble = (i & 1) == 0 ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
			// Sign-extend four bits, then scale into sixteen.
			final t = ((nibble > 7 ? nibble - 16 : nibble) << 12) >> shift;
			final s = sat16(t + ((old[v] * f0 + older[v] * f1 + 32) >> 6));
			decoded[base + i] = s;
			older[v] = old[v];
			old[v] = s;
		}

		blockPos[v] = 0;
		advanceBlock(v, flags);
	}

	/**
		Where the next block comes from, which the block just decoded decides.

		Bit 2 marks a loop start and is remembered. Bit 0 marks the end: the voice jumps back to the
		remembered address and sets its ENDX. Bit 1 says whether that end is a loop or a stop — a
		sound that ends without it is released and silenced, which is how one-shot samples finish
		themselves without the game having to.
	**/
	static function advanceBlock(v:Int, flags:Int):Void {
		if ((flags & 0x04) != 0) repeatAddr[v] = curAddr[v];
		else {}
		if ((flags & 0x01) == 0) {
			curAddr[v] = (curAddr[v] + BLOCK_BYTES) & (RAM_BYTES - 1);
			return;
		} else {}
		endx |= 1 << v;
		curAddr[v] = repeatAddr[v];
		if ((flags & 0x02) == 0) {
			envPhase[v] = PHASE_RELEASE;
			envLevel[v] = 0;
		} else {}
	}

	// ---- the envelope ---------------------------------------------------------------------------

	/**
		One tick of ADSR.

		A phase is a shift, a step and a direction. The shift says how many ticks pass between
		changes and, past eleven, also scales the step; "exponential" means the step is scaled by
		the level, so a rise slows as it approaches the top and a fall slows as it approaches
		silence. Everything below is that one rule with different fields.
	**/
	static function stepEnvelope(v:Int):Void {
		final phase = envPhase[v];
		if (phase == PHASE_ATTACK) attack(v);
		else if (phase == PHASE_DECAY) decay(v);
		else if (phase == PHASE_SUSTAIN) sustain(v);
		else if (phase == PHASE_RELEASE) release(v);
		else {}
		// Read here rather than after the sample: decoding a block can end a sound and zero the
		// level, and a peak measured afterwards cannot tell an envelope that never rose from one
		// that rose and was cleared before anyone looked.
		if (envLevel[v] > peakEnv) peakEnv = envLevel[v];
		else {}
	}

	static function attack(v:Int):Void {
		final lo = adsrLo[v];
		final shift = (lo >> 10) & 0x1F;
		final step = 7 - ((lo >> 8) & 3);
		final exponential = (lo & 0x8000) != 0;
		if (!ready(v, shift, exponential && envLevel[v] > 0x6000)) return;
		else {}
		envLevel[v] += amount(step, shift);
		if (envLevel[v] >= 0x7FFF) {
			envLevel[v] = 0x7FFF;
			envPhase[v] = PHASE_DECAY;
		} else {}
	}

	static function decay(v:Int):Void {
		final shift = (adsrLo[v] >> 4) & 0x0F;
		if (!ready(v, shift, false)) return;
		else {}
		// Decay is always an exponential fall, with a fixed step.
		envLevel[v] -= (amount(8, shift) * envLevel[v]) >> 15;
		final target = (((adsrLo[v] & 0x0F) + 1) * 0x800);
		if (envLevel[v] <= target) {
			envLevel[v] = target > 0x7FFF ? 0x7FFF : target;
			envPhase[v] = PHASE_SUSTAIN;
		} else {}
	}

	static function sustain(v:Int):Void {
		final hi = adsrHi[v];
		final shift = (hi >> 8) & 0x1F;
		final rising = (hi & 0x4000) == 0;
		final exponential = (hi & 0x8000) != 0;
		final step = rising ? 7 - ((hi >> 6) & 3) : 8 - ((hi >> 6) & 3);
		if (!ready(v, shift, exponential && rising && envLevel[v] > 0x6000)) return;
		else {}
		final by = exponential && !rising
			? (amount(step, shift) * envLevel[v]) >> 15
			: amount(step, shift);
		// Added or taken away, never added negated: on JavaScript `-by` is -0 when `by` is 0 (a
		// slow exponential fall rounds to nothing), and `level + -0` is a double. Stored once, it
		// turned this array into doubles, every level read from it arrived boxed — through the
		// voice registers into the CPU's register fields — and the whole recompiled program
		// allocated a number on every such read, in the browser's collector.
		if (rising) envLevel[v] += by;
		else envLevel[v] -= by;
		clampLevel(v);
	}

	static function release(v:Int):Void {
		final hi = adsrHi[v];
		final shift = hi & 0x1F;
		final exponential = (hi & 0x20) != 0;
		if (!ready(v, shift, false)) return;
		else {}
		final by = exponential
			? (amount(8, shift) * envLevel[v]) >> 15
			: amount(8, shift);
		envLevel[v] -= by < 1 ? 1 : by;
		if (envLevel[v] <= 0) {
			envLevel[v] = 0;
			envPhase[v] = PHASE_OFF;
		} else {}
	}

	static function clampLevel(v:Int):Void {
		if (envLevel[v] > 0x7FFF) envLevel[v] = 0x7FFF;
		else if (envLevel[v] < 0) envLevel[v] = 0;
		else {}
	}

	/**
		Whether this tick is one of the ones the shift lets through.

		Past a shift of eleven the envelope changes less often than every tick, and four times less
		often again while an exponential rise is above three quarters — which is the whole of the
		"exponential attack" shape, expressed as a rate rather than a curve.
	**/
	static inline function periodOf(shift:Int, slower:Bool):Int {
		final period = 1 << (shift > 11 ? shift - 11 : 0);
		return slower ? period * 4 : period;
	}

	static function ready(v:Int, shift:Int, slower:Bool):Bool {
		final period = periodOf(shift, slower);
		envCounter[v]++;
		if (envCounter[v] < period) return false;
		else {}
		envCounter[v] = 0;
		return true;
	}

	/** How much the level moves when it moves. Below a shift of eleven the step is scaled up. */
	static function amount(step:Int, shift:Int):Int {
		final by = step << (shift < 11 ? 11 - shift : 0);
		return by < 1 ? 1 : by;
	}

	// ---- volumes ----------------------------------------------------------------------------

	/**
		A volume register as a factor in fifteen bits.

		Bit 15 selects a sweep — a volume that glides to a target over time — and this takes the
		target immediately instead. That is wrong for a fade and right for everything that sets a
		volume and leaves it, which is most of what a game does; the gliding version needs the same
		rate machinery as ADSR and belongs with it.
	**/
	static function volumeOf(reg:Int):Int {
		if ((reg & 0x8000) == 0) {
			// Bits 0..14 are the volume halved, signed.
			final half = (reg & 0x7FFF) > 0x3FFF ? (reg & 0x7FFF) - 0x8000 : (reg & 0x7FFF);
			final full = half << 1;
			return full > 0x7FFF ? 0x7FFF : (full < -0x8000 ? -0x8000 : full);
		} else return sweepTarget(reg);
	}

	static function sweepTarget(reg:Int):Int {
		// Bit 13 is the direction: a sweep that is falling is heading for silence.
		return (reg & 0x2000) != 0 ? 0 : 0x7FFF;
	}

	static inline function sat16(v:Int):Int {
		return v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
	}

	// ---- transfers ------------------------------------------------------------------------------

	/** One halfword through the manual FIFO at 1F801DA8, which advances the transfer address. */
	public static function pushHalfword(v:Int):Void {
		store16(transferAddr, v);
		transferAddr = (transferAddr + 2) & (RAM_BYTES - 1);
	}

	/**
		A word from DMA channel 4, which is how a game of any size actually loads sound.

		Little-endian halfword order, matching the FIFO: the low half is written first, so a
		transfer through the channel and the same bytes pushed one at a time leave sound RAM
		identical. That equivalence is worth keeping — libspu uses both.
	**/
	public static function dmaWord(v:Int):Void {
		pushHalfword(v & 0xFFFF);
		pushHalfword((v >>> 16) & 0xFFFF);
	}

	static function store16(addr:Int, v:Int):Void {
		final a = addr & (RAM_BYTES - 2);
		RawMem.set8(ram, a, v & 0xFF);
		RawMem.set8(ram, a + 1, (v >>> 8) & 0xFF);
		written++;
	}

	// ---- what is still missing ------------------------------------------------------------------

	static function quietRead(p:Int):Int {
		final key = 0x12000000 | (p & 0xFFFF);
		if (!Runtime.alreadyReported(key)) {
			Runtime.reportOnce(key, "read from SPU register " + hex(p) + " — no such register here");
		} else {}
		return 0;
	}

	static function quietWrite(p:Int):Void {
		final key = 0x13000000 | (p & 0xFFFF);
		if (!Runtime.alreadyReported(key)) {
			Runtime.reportOnce(key, "write to SPU register " + hex(p) + " — no such register here");
		} else {}
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var s = 28;
		while (s >= 0) { out += digits.charAt((v >>> s) & 0xF); s -= 4; }
		return "0x" + out;
	}
}
