package timers;

import core.Runtime;
import shim.IntMath;

/**
	The three root counters at 1F801100h, computed rather than stepped.

	No per-tick counting: a read derives the value from the cycle count and an anchor, which is
	both exact and free — the plan's §7.10 design. What forced them into existence now is libpad,
	which measures its acknowledge timeout on **timer 2**: a counter that reads a constant zero is
	a timeout that never expires, and the pad probe that should conclude "no controller" in
	microseconds spins forever instead.

	Implemented: free-running value reads for all three, the divide-by-8 source on timer 2, reset
	on mode write, reset-at-target (mode bit 3), and the reached-target/overflow flags. Reported
	and left honest-zero: dotclock and hblank sources (they need the video clock chain), and timer
	IRQs (they need someone to wait on them). Register map from psx-spx "Timers", as recorded in
	docs/specs/runtime.md §7.10.
**/
class Timers {
	static var anchor:Array<Int>;
	static var base:Array<Int>;
	static var mode:Array<Int>;
	static var target:Array<Int>;
	static var reached:Array<Int>;   // bits 11/12, read-then-clear

	public static function init():Void {
		anchor = [0, 0, 0];
		base = [0, 0, 0];
		mode = [0, 0, 0];
		target = [0, 0, 0];
		reached = [0, 0, 0];
	}

	public static function read(addr:Int, cycles:Int):Int {
		final t = timerOf(addr);
		final reg = addr & 0xF;
		if (reg == 0x0) return value(t, cycles);
		else if (reg == 0x4) return readMode(t, cycles);
		else if (reg == 0x8) return target[t];
		else return 0;
	}

	public static function write(addr:Int, v:Int, cycles:Int):Void {
		final t = timerOf(addr);
		final reg = addr & 0xF;
		if (reg == 0x0) writeValue(t, v, cycles);
		else if (reg == 0x4) writeMode(t, v, cycles);
		else if (reg == 0x8) target[t] = v & 0xFFFF;
		else {}
	}

	static inline function timerOf(addr:Int):Int {
		return (addr >> 4) & 3;
	}

	/**
		The counter's current value: elapsed cycles over the divider, wrapped where the mode says.

		Reset-at-target (bit 3) wraps at target+1; otherwise the counter runs to 0xFFFF and wraps.
		Both wraps set their flag, computed here from elapsed time rather than observed by
		stepping — the counter "reached" its target however many times ago, whether anyone was
		reading or not, which is exactly how the hardware's flag behaves.
	**/
	static function value(t:Int, cycles:Int):Int {
		// `>>>`, not a divide, and no sign check anywhere.
		//
		// The cycle counter wraps past 2^31 about once a minute of emulated time, so `cycles -
		// anchor` is routinely negative even though no time has run backwards — it is a wrapped
		// difference, and ADR-0004 says to read it as one. A guard that clamped it to zero
		// "defensively" froze every counter permanently the first time the clock wrapped, which
		// is how libpad came to wait on a timeout that could never expire.
		//
		// A logical shift is the whole fix: it treats the difference as the unsigned quantity it
		// is, and because 2^32 divides exactly by both dividers and by the 65536 wrap, the answer
		// stays congruent across as many wraps as the machine cares to do.
		final elapsed = (cycles - anchor[t]) | 0;
		final ticks = (base[t] + (elapsed >>> dividerShift(t))) | 0;
		final wrapAt = wrapPoint(t);
		if (ticks >= wrapAt || ticks < 0) markWrapped(t);
		else {}
		return unsignedMod(ticks, wrapAt);
	}

	/**
		`v mod m`, reading `v` as the unsigned 32-bit quantity it is.

		A shift of zero leaves the top bit in place, so an elapsed count past 2^31 arrives here as
		a negative Int and an ordinary `%` hands back a negative counter — which a game reads as a
		clock that has run backwards. Halving first makes the value provably non-negative, and the
		low bit is carried across by hand: `u = 2*(u>>>1) + (u&1)`, so the same identity holds
		under the modulus. Every intermediate stays well inside 32 bits because `m` is at most
		65536.
	**/
	static function unsignedMod(v:Int, m:Int):Int {
		if (v >= 0) return IntMath.mod(v, m);
		else {}
		final half = IntMath.mod(v >>> 1, m);
		return IntMath.mod(IntMath.mul(half, 2) + (v & 1), m);
	}

	static function wrapPoint(t:Int):Int {
		// Reset-at-target only means something with a target above zero; a zero target would make
		// the counter sit at zero forever, which no game means.
		if ((mode[t] & 0x08) != 0 && target[t] > 0) return target[t] + 1;
		else return 0x10000;
	}

	static function markWrapped(t:Int):Void {
		if ((mode[t] & 0x08) != 0) reached[t] |= 0x800;    // reached target
		else reached[t] |= 0x1000;                          // overflowed 0xFFFF
	}

	/**
		The clock behind a counter, in CPU cycles per tick.

		Timer 2's sources are the system clock and system clock over eight (mode bits 8–9).
		Timers 0 and 1 offer the dotclock and hblank, which need the video clock chain this
		runtime does not carve up yet — they run at system clock for now, and say so once, because
		a game timing against them would run fast and that must be traceable to a line in a log.
	**/
	static function dividerShift(t:Int):Int {
		final src = (mode[t] >> 8) & 3;
		if (t == 2) return src >= 2 ? 3 : 0;               // sysclk/8 or sysclk
		else if (src == 1 || src == 3) return unusualSource(t);
		else return 0;
	}

	static function unusualSource(t:Int):Int {
		Runtime.reportOnce(0x68000000 | t, "timer " + t
			+ " uses a dotclock/hblank source — running at sysclk until the video chain exists");
		return 0;
	}

	static function readMode(t:Int, cycles:Int):Int {
		value(t, cycles);   // fold any pending wrap into the flags first
		final m = (mode[t] & 0x7FF) | reached[t];
		// Bits 11 and 12 clear on read, as the hardware's do.
		reached[t] = 0;
		return m;
	}

	static function writeValue(t:Int, v:Int, cycles:Int):Void {
		base[t] = v & 0xFFFF;
		anchor[t] = cycles;
	}

	/** A mode write resets the counter to zero — the idiom every driver uses to start timing. */
	static function writeMode(t:Int, v:Int, cycles:Int):Void {
		mode[t] = v & 0x3FF;
		base[t] = 0;
		anchor[t] = cycles;
		reached[t] = 0;
		if ((v & 0x30) != 0) Runtime.reportOnce(0x69000000 | t,
			"timer " + t + " asked for IRQs, which are not delivered yet");
		else {}
	}
}
