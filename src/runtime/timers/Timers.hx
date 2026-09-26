package timers;

import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;
import core.TimeBase;
import shim.IntMath;

/**
	The three root counters at 1F801100h, computed rather than stepped.

	No per-tick counting: a read derives the value from the cycle count and an anchor, which is
	both exact and free — the plan's §7.10 design. What forced them into existence now is libpad,
	which measures its acknowledge timeout on **timer 2**: a counter that reads a constant zero is
	a timeout that never expires, and the pad probe that should conclude "no controller" in
	microseconds spins forever instead.

	Implemented: free-running value reads for all three, every source — system clock, system clock
	over eight, the dot clock and the horizontal blank — reset on mode write, reset-at-target (mode
	bit 3), the reached-target/overflow flags, and the interrupts: the next target or 0xFFFF is
	solved from the counter's position and armed as a scheduler deadline, never stepped towards.
	Still missing: the sync modes that gate a counter on the blanking intervals. Register map from
	psx-spx "Timers", as recorded in docs/specs/runtime.md §10.
**/
class Timers {
	static var anchor:Array<Int>;
	static var base:Array<Int>;
	static var mode:Array<Int>;
	static var target:Array<Int>;
	static var reached:Array<Int>;   // bits 11/12, read-then-clear
	/** Mode bit 10, the interrupt request: 0x400 is "none", and a mode write sets it. */
	static var request:Array<Int>;
	/** A one-shot counter that has raised its interrupt stays quiet until the mode is written. */
	static var spent:Array<Bool>;
	/** The cycle the armed interrupt is due at, and which condition that is: 1 target, 2 0xFFFF. */
	static var due:Array<Int>;
	static var dueKind:Array<Int>;

	public static function init():Void {
		anchor = [0, 0, 0];
		base = [0, 0, 0];
		mode = [0, 0, 0];
		target = [0, 0, 0];
		reached = [0, 0, 0];
		request = [0x400, 0x400, 0x400];
		spent = [false, false, false];
		due = [0, 0, 0];
		dueKind = [0, 0, 0];
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
		else if (reg == 0x8) writeTarget(t, v, cycles);
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
	static inline function value(t:Int, cycles:Int):Int {
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
		fold(t, cycles);
		final elapsed = (cycles - anchor[t]) | 0;
		final ticks = (base[t] + ticksIn(t, elapsed)) | 0;
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
	static inline function unsignedMod(v:Int, m:Int):Int {
		if (v >= 0) return v < m ? v : IntMath.mod(v, m);
		else {
			final half = IntMath.mod(v >>> 1, m);
			return IntMath.mod(IntMath.mul(half, 2) + (v & 1), m);
		}
	}

	static inline function wrapPoint(t:Int):Int {
		// Reset-at-target only means something with a target above zero; a zero target would make
		// the counter sit at zero forever, which no game means.
		if ((mode[t] & 0x08) != 0 && target[t] > 0) return target[t] + 1;
		else return 0x10000;
	}

	static inline function markWrapped(t:Int):Void {
		if ((mode[t] & 0x08) != 0) reached[t] = reached[t] | 0x800;    // reached target
		else reached[t] = reached[t] | 0x1000;                          // overflowed 0xFFFF
	}

	/**
		The clock behind a counter, in CPU cycles per tick.

		Timer 2's sources are the system clock and system clock over eight (mode bits 8–9).
		Timers 0 and 1 offer the dotclock and hblank, which need the video clock chain this
		runtime does not carve up yet — they run at system clock for now, and say so once, because
		a game timing against them would run fast and that must be traceable to a line in a log.
	**/
	static inline function dividerShift(t:Int):Int {
		final src = (mode[t] >> 8) & 3;
		if (t == 2) return src >= 2 ? 3 : 0;               // sysclk/8 or sysclk
		else return 0;
	}

	// ---- the video sources --------------------------------------------------------------------
	//
	// Timer 0 can count dots and timer 1 can count scanlines, and neither divider is a power of
	// two — the dot clock is the CPU clock times 715909/451584 (NTSC) divided by 4, 5, 7, 8 or 10
	// depending on how wide the display is. Both used to fall back to the system clock and say so,
	// which made a game timing against them run several times too fast.
	//
	// Two steps, because neither the product nor the elapsed count fits in an Int on its own.
	// First **fold**: in exactly `VIDEO_DEN * divider` cycles exactly `numerator` dots pass, and in
	// exactly one line's cycles exactly one hblank passes, so whole periods are moved out of the
	// elapsed count and into the counter's base with no remainder and no drift. What is left is
	// less than one period. Then the residue is converted with the numerator split into
	// `high * 1024 + low`, which keeps every intermediate under 2^31 — the same shape `TimeBase`
	// uses for its own frame arithmetic, and for the same reason.

	static inline function isDotClock(t:Int):Bool {
		return t == 0 && ((mode[t] >> 8) & 1) != 0;
	}

	static inline function isHblank(t:Int):Bool {
		return t == 1 && ((mode[t] >> 8) & 1) != 0;
	}

	/** How many CPU cycles a whole period of the source takes, and how many ticks that is. */
	static inline function periodCycles(t:Int):Int {
		if (isDotClock(t)) return IntMath.mul(TimeBase.VIDEO_DEN, dotDivider());
		else if (isHblank(t)) return TimeBase.cyclesPerLine();
		else return 0;
	}

	static inline function periodTicks(t:Int):Int {
		if (isDotClock(t)) return TimeBase.videoNumerator();
		else return 1;
	}

	/**
		The dot clock's divider, from the display width the GPU is set to.

		psx-spx: 256, 320, 512, 640 and 368-pixel modes divide the video clock by 10, 8, 5, 4 and
		7. The bits are the ones `gpu.Scanout` reads to pick a width, which is why the rule is
		written the same way in both places — they are one decision seen from two sides.
	**/
	static inline function dotDivider():Int {
		final m = gpu.Gpu.displayModeBits();
		if ((m & 0x40) != 0) return 7;
		else if ((m & 3) == 0) return 10;
		else if ((m & 3) == 1) return 8;
		else if ((m & 3) == 2) return 5;
		else return 4;
	}

	/** Moves whole periods out of the elapsed cycles and into the counter, exactly. */
	static inline function fold(t:Int, cycles:Int):Void {
		final period = periodCycles(t);
		if (period > 0) {
			final elapsed = (cycles - anchor[t]) | 0;
			// Less than one period since the anchor is the common case by far — a game polling a
			// counter reads it every few dozen cycles, and a line is two thousand — and that case
			// is a compare, not a divide: `0 <= elapsed < period` is exactly when the quotient is
			// zero. The polling loop that made this the hottest read in the machine was libetc's
			// VSync, counting hblanks on timer 1.
			final n = (elapsed >= 0 && elapsed < period) ? 0 : unsignedDiv(elapsed, period);
			if (n > 0) {
				final wrapAt = wrapPoint(t);
				base[t] = IntMath.mod((base[t] + IntMath.mul(n, periodTicks(t))) | 0, wrapAt);
				anchor[t] = (anchor[t] + IntMath.mul(n, period)) | 0;
			} else {}
		} else {}
	}

	/** Ticks in a *folded* elapsed count — less than one period, so the arithmetic is small. */
	static inline function ticksIn(t:Int, elapsed:Int):Int {
		if (isDotClock(t)) return dotsIn(elapsed);
		// Folded, the residue is shorter than a line, so the quotient is zero without dividing;
		// the divide stays for a caller that has not folded.
		else if (isHblank(t)) return (elapsed >= 0 && elapsed < TimeBase.cyclesPerLine()) ? 0
			: IntMath.div(elapsed, TimeBase.cyclesPerLine());
		else return elapsed >>> dividerShift(t);
	}

	static inline function dotsIn(elapsed:Int):Int {
		// The divisor is one of five constants, but reaching it through a function makes it a
		// runtime value — and SH-4 has no integer divide instruction, so that is a call to
		// __sdivsi3 on every dot-clock read. Dividing inside the branches instead lets the
		// compiler strength-reduce each one to a multiply-high and a shift. Exact integer
		// arithmetic either way; this is the same division, spelled where the number is known.
		final v = videoClocksIn(elapsed);
		final m = gpu.Gpu.displayModeBits();
		if ((m & 0x40) != 0) return IntMath.div(v, 7);
		else if ((m & 3) == 0) return IntMath.div(v, 10);
		else if ((m & 3) == 1) return IntMath.div(v, 8);
		else if ((m & 3) == 2) return IntMath.div(v, 5);
		else return IntMath.div(v, 4);
	}

	/**
		`elapsed * numerator / VIDEO_DEN`, without ever forming the product.

		The numerator splits into `high * 1024 + low` so that no intermediate passes 2^31: the
		largest is the low part's `remainder * 1024`, which is under 2^29 for any residue this is
		called with.
	**/
	static inline function videoClocksIn(elapsed:Int):Int {
		final num = TimeBase.videoNumerator();
		final den = TimeBase.VIDEO_DEN;
		final hi = num >> 10;
		final lo = num & 0x3FF;
		// Each remainder is the dividend less the quotient times the divisor — the same value a
		// `%` gives under truncating division on both targets, for one multiply instead of a
		// second divide.
		final q = IntMath.div(elapsed, den);
		final r = (elapsed - IntMath.mul(q, den)) | 0;
		final b = IntMath.mul(r, hi);
		final b1 = IntMath.div(b, den);
		final b2 = (b - IntMath.mul(b1, den)) | 0;
		final low = (IntMath.mul(b2, 1024) + IntMath.mul(r, lo)) | 0;
		return (IntMath.mul(q, num) + IntMath.mul(b1, 1024) + IntMath.div(low, den)) | 0;
	}

	/**
		`v / m` reading `v` as unsigned, for the same reason `unsignedMod` exists.

		Halve, divide, and put the halving back: `u = 2*(u>>>1) + (u&1)`, so the quotient is twice
		the halved quotient plus whatever the doubled remainder contributes. Every intermediate
		stays inside 32 bits because `m` is at most a few million.
	**/
	static inline function unsignedDiv(v:Int, m:Int):Int {
		if (v >= 0) return IntMath.div(v, m);
		else {
			final half = v >>> 1;
			final q = IntMath.div(half, m);
			final r = (half - IntMath.mul(q, m)) | 0;
			return (IntMath.mul(q, 2) + IntMath.div((IntMath.mul(r, 2) + (v & 1)) | 0, m)) | 0;
		}
	}

	/**
		Reported once, and asked once.

		`dividerShift` runs on every read of a counter, and a game polling one polls it hard — so
		building the message here, only to have `reportOnce` discover the key was already seen, put
		string concatenation and a map lookup in the hottest loop the timers have. The same shape
		cost this runtime a thousandfold slowdown in the I/O path earlier today; the guard is the
		same one.
	**/
	/**
		Reported once, and the guard is a boolean — not a map lookup.

		The first attempt at this asked `Runtime.alreadyReported`, which does the very
		`Map.exists` that made it expensive: the check moved, the cost did not. A profile put
		`ObjectPrototypeHasOwnProperty` at 5% of all ticks with 98.6% of it arriving through here,
		down a chain from the game's own polling loop — `f_8003ebf8` to `f_800320ec` to a counter
		read, on every single iteration.

		A per-timer flag costs an array index. The rule this keeps arriving at: a report-once
		helper is only cheap where the *call* is rare, and on a hot path the guard has to be
		cheaper than the thing it guards.
	**/


	static inline function readMode(t:Int, cycles:Int):Int {
		value(t, cycles);   // fold any pending wrap into the flags first
		final m = (mode[t] & 0x3FF) | request[t] | reached[t];
		// Bits 11 and 12 clear on read, as the hardware's do.
		reached[t] = 0;
		return m;
	}

	static function writeValue(t:Int, v:Int, cycles:Int):Void {
		base[t] = v & 0xFFFF;
		anchor[t] = cycles;
		arm(t, cycles);
	}

	static function writeTarget(t:Int, v:Int, cycles:Int):Void {
		target[t] = v & 0xFFFF;
		arm(t, cycles);
	}

	/**
		A mode write resets the counter to zero — the idiom every driver uses to start timing —
		sets bit 10 (no request pending), and re-arms a one-shot.
	**/
	static function writeMode(t:Int, v:Int, cycles:Int):Void {
		mode[t] = v & 0x3FF;
		base[t] = 0;
		anchor[t] = cycles;
		reached[t] = 0;
		request[t] = 0x400;
		spent[t] = false;
		arm(t, cycles);
	}

	// ---- interrupts ---------------------------------------------------------------------------
	//
	// Mode bit 4 asks for an interrupt when the counter equals its target, bit 5 when it equals
	// 0xFFFF. Neither is polled for: the number of ticks to the next such value follows from where
	// the counter is now, and that becomes a deadline in the scheduler's TIMER0+n slot. Bit 6
	// chooses repeat over one-shot; bit 7 chooses toggle over pulse for bit 10, whose falling edge
	// is the request — so a pulse interrupts on every condition and a toggle on every second one.

	static inline function sysclkSource(t:Int):Bool {
		return !isDotClock(t) && !isHblank(t);
	}

	/** Arms the next interrupt this counter will raise, or disarms it if it will raise none. */
	static function arm(t:Int, cycles:Int):Void {
		final slot = Scheduler.TIMER0 + t;
		if ((mode[t] & 0x30) == 0 || spent[t]) {
			if (Scheduler.isActive(slot)) Scheduler.cancelSlot(slot);
			else {}
			return;
		} else {}
		fold(t, cycles);
		final elapsed = (cycles - anchor[t]) | 0;
		final ticks = ticksIn(t, elapsed);
		final wrapAt = wrapPoint(t);
		final now = unsignedMod((base[t] + ticks) | 0, wrapAt);

		// Ticks until each enabled condition next holds. A condition that holds now is a whole
		// wrap away: this is called at the moment one fired, and it must not fire twice.
		var ahead = 0x7FFFFFFF;
		var kind = 0;
		if ((mode[t] & 0x10) != 0) {
			final d = ticksUntil(target[t], now, wrapAt);
			if (d > 0) { ahead = d; kind = 1; } else {}
		} else {}
		if ((mode[t] & 0x20) != 0 && wrapAt == 0x10000) {
			final d = ticksUntil(0xFFFF, now, wrapAt);
			if (d > 0 && d < ahead) { ahead = d; kind = 2; }
			else if (d > 0 && d == ahead) kind |= 2;
			else {}
		} else {}
		if (kind == 0) {
			// Enabled, but on a value this counter never reaches (0xFFFF under a lower reset).
			if (Scheduler.isActive(slot)) Scheduler.cancelSlot(slot);
			else {}
			return;
		} else {}

		due[t] = deadline(t, cycles, ticks, ahead);
		dueKind[t] = kind;
		Scheduler.scheduleAt(slot, due[t]);
	}

	/** `(value - now) mod wrapAt`, or the whole wrap when the counter already sits on it. */
	static inline function ticksUntil(value:Int, now:Int, wrapAt:Int):Int {
		final d = value - now;
		return value >= wrapAt ? 0 : (d > 0 ? d : (d + wrapAt));
	}

	/**
		The cycle the counter is `ahead` ticks further on.

		Exact for the system clock (a tick boundary is `anchor + ticks << shift`) and for hblank
		(fold leaves less than one line since the anchor, so the next ticks are whole lines).
		The dot clock's cycles per tick are not an integer; its deadline rounds up in 1/256ths of
		a cycle per dot, so the interrupt is at most a cycle or two late and never early.
	**/
	static function deadline(t:Int, cycles:Int, ticks:Int, ahead:Int):Int {
		if (isHblank(t)) return (anchor[t] + IntMath.mul(ahead, TimeBase.cyclesPerLine())) | 0;
		else if (isDotClock(t)) {
			// VIDEO_DEN * 10 * 256 is 1.16e9: inside 31 bits for the widest divider.
			final per = IntMath.div((IntMath.mul(TimeBase.VIDEO_DEN, dotDivider()) << 8)
				+ TimeBase.videoNumerator() - 1, TimeBase.videoNumerator());
			return (cycles + (IntMath.mul(ahead, per) >> 8) + 1) | 0;
		}
		else return (anchor[t] + ((ticks + ahead) << dividerShift(t))) | 0;
	}

	/**
		The scheduler's TIMER0+n slot came due: the counter reached its target or 0xFFFF.

		On the system clock the counter is re-anchored at the exact tick the condition held, so
		the next deadline counts from there rather than from whenever the pump happened to run —
		and the anchor never drifts far enough behind for the elapsed count to wrap.
	**/
	public static function onEvent(ctx:CpuState, t:Int):Void {
		final at = due[t];
		final kind = dueKind[t];
		if (sysclkSource(t)) {
			final elapsed = (at - anchor[t]) | 0;
			base[t] = unsignedMod((base[t] + (elapsed >>> dividerShift(t))) | 0, wrapPoint(t));
			anchor[t] = at;
		} else {}
		if ((kind & 1) != 0) reached[t] = reached[t] | 0x800;
		else {}
		if ((kind & 2) != 0) reached[t] = reached[t] | 0x1000;
		else {}

		var raise = true;
		if ((mode[t] & 0x80) != 0) {
			request[t] = request[t] ^ 0x400;
			raise = request[t] == 0;
		} else {}
		if (raise) Irq.raise(ctx, Irq.TIMER0 + t);
		else {}
		if ((mode[t] & 0x40) == 0) spent[t] = true;
		else {}
		arm(t, sysclkSource(t) ? at : ctx.cycles);
	}
}
