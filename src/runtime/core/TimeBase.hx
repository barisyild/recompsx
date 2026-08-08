package core;

import shim.IntMath;

/**
	Where the machine is in its video frame, as a function of the cycle count.

	Nothing here is stepped. Every value is computed from `cycles` at the moment it is asked for,
	which is what lets a game poll `GPUSTAT` bit 31 between two scheduled events and still see it
	move — one of the three ways PS1 games wait for vblank, so not a corner case (ADR-0005 §1).

	All of it is exact integer arithmetic. The video clock is not a whole multiple of the CPU
	clock, so the ratio is kept as the fraction it actually is and divided once, rather than
	rounded into a constant that would drift a frame every few minutes.

	Numbers from psx-spx "GPU Timings":

	- CPU 33,868,800 Hz (= 44100 x 768, which is why an SPU tick is exactly 768 cycles)
	- NTSC video clock 53,693,175 Hz = CPU x 715909/451584, 3413 video clocks per scanline,
	  263 lines per frame
	- PAL  video clock 53,203,425 Hz = CPU x 709379/451584, 3406 clocks per line, 314 lines
**/
class TimeBase {
	public static inline var CPU_HZ = 33868800;

	/** Video clocks per scanline, and lines per frame, for the two regions. */
	static inline var NTSC_CLOCKS_PER_LINE = 3413;
	static inline var NTSC_LINES = 263;
	static inline var PAL_CLOCKS_PER_LINE = 3406;
	static inline var PAL_LINES = 314;

	// video = cpu * NUM / DEN. Kept as a fraction so the per-line cycle count stays exact.
	static inline var NTSC_NUM = 715909;
	static inline var PAL_NUM = 709379;
	static inline var DEN = 451584;

	/** False for NTSC. Set once at boot from the game's region; never changes mid-run. */
	public static var pal(default, null) = false;

	// Derived once per region rather than per call. `line()` is read on every GPUSTAT poll, and a
	// game polling GPUSTAT in a loop should not pay two divisions for it.
	static var perLine = 0;
	static var perFrame = 0;
	static var lastLine = 0;

	public static function setRegion(isPal:Bool):Void {
		pal = isPal;
		perLine = computeCyclesPerLine();
		perFrame = computeCyclesPerFrame();
		lastLine = lines() - 1;
	}

	/**
		CPU cycles in one scanline.

		A scanline is `clocksPerLine` video clocks, and video clocks run at `cpu * NUM / DEN`, so
		one line is `clocksPerLine * DEN / NUM` CPU cycles — 2153 on NTSC, 2168 on PAL. The
		division truncates, and the remainder is what `lineCycleRemainder` exists to carry, so a
		frame's worth of lines adds up to the frame length rather than drifting.
	**/
	public static function cyclesPerLine():Int return perLine;

	/** CPU cycles in one whole frame. */
	public static function cyclesPerFrame():Int return perFrame;

	static function computeCyclesPerLine():Int {
		return IntMath.div(IntMath.mul(clocksPerLine(), DEN), num());
	}

	/**
		CPU cycles in one whole frame, exactly, without leaving 32 bits.

		The obvious expression — `clocksPerLine * lines * DEN / num` — overflows badly: the NTSC
		numerator is about 4.05e11, two hundred times what an Int holds. It wrapped to something
		small, every deadline landed in the past, and the scheduler fired events forever. Its
		runaway guard is what surfaced this.

		Nor can it be `cyclesPerLine * lines`: that truncated line length loses 227 cycles per NTSC
		frame, which is a drifting frame rate rather than a wrong one — the kind of error that
		looks fine for a minute.

		So: divide first, then multiply, and carry the remainder. With `X = clocksPerLine * DEN`,

		    frame = lines * (X / num) + (lines * (X % num)) / num

		Every intermediate fits — the largest is `lines * (num-1)`, about 2.2e8 on PAL — and the
		result is the exact quotient, not an approximation of it.
	**/
	static function computeCyclesPerFrame():Int {
		final x = IntMath.mul(clocksPerLine(), DEN);
		final n = num();
		final whole = IntMath.div(x, n);
		final rem = IntMath.mod(x, n);
		return (IntMath.mul(lines(), whole) + IntMath.div(IntMath.mul(lines(), rem), n)) | 0;
	}

	/**
		Which line the beam is on, 0..lines()-1.

		Clamped at the end. A line is a whole number of cycles here but the real one is not, so the
		truncation leaves the last line a little long, and without the clamp a cycle near the end
		of a frame would report a line that does not exist.
	**/
	public static function line(cycles:Int):Int {
		final l = IntMath.div(intoFrame(cycles), perLine);
		return l > lastLine ? lastLine : l;
	}

	/** Cycles elapsed since the start of the current frame. */
	public static function intoFrame(cycles:Int):Int {
		final frame = cyclesPerFrame();
		var into = IntMath.mod(cycles, frame);
		// `cycles` wraps through negative values once a run passes 2^31 (about a minute), and a
		// negative remainder would put the beam on a line that does not exist.
		if (into < 0) into += frame;
		else {}
		return into;
	}

	/** How many whole frames have elapsed. Wraps with `cycles`, which is what the game sees too. */
	public static function frame(cycles:Int):Int {
		return IntMath.div(cycles, cyclesPerFrame());
	}

	/**
		Vertical blanking.

		The real window comes from GP1(07h), which the GPU does not exist to provide yet; until it
		does this uses the hardware default the BIOS programs — lines 16..255 are active, so
		everything at or past 256 is blanking (psx-spx "GP1(07h) Vertical Display Range").
	**/
	public static inline var DEFAULT_VBLANK_LINE = 256;

	public static function inVblank(cycles:Int):Bool {
		return line(cycles) >= DEFAULT_VBLANK_LINE;
	}

	/** The cycle at which the next vblank starts, strictly after `cycles`. */
	public static function nextVblankStart(cycles:Int):Int {
		final start = IntMath.mul(DEFAULT_VBLANK_LINE, perLine);
		final into = intoFrame(cycles);
		final delta = into < start ? start - into : (cyclesPerFrame() - into) + start;
		return (cycles + delta) | 0;
	}

	/** The cycle at which the current or next vblank ends — the top of the following frame. */
	public static function nextVblankEnd(cycles:Int):Int {
		final into = intoFrame(cycles);
		return (cycles + (cyclesPerFrame() - into)) | 0;
	}

	/**
		GPUSTAT bit 31 in 240p: it toggles per scanline, and reads 0 during blanking.

		Interlaced modes toggle per frame instead; that distinction arrives with the GPU, which is
		what knows which mode it is in.
	**/
	public static function evenOddBit(cycles:Int):Int {
		if (inVblank(cycles)) return 0;
		else {}
		return line(cycles) & 1;
	}

	static inline function clocksPerLine():Int return pal ? PAL_CLOCKS_PER_LINE : NTSC_CLOCKS_PER_LINE;
	static inline function lines():Int return pal ? PAL_LINES : NTSC_LINES;
	static inline function num():Int return pal ? PAL_NUM : NTSC_NUM;
}
