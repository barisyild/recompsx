package core;

import shim.IntMath;

/**
	The arithmetic behind a skipped idle loop.

	A game waiting for the next vertical blank spins: it reads a counter that an interrupt
	handler will raise, decrements a timeout in a stack slot, and branches back — libetc's
	`VSync` is thirty-two cycles a turn, tens of thousands of turns a frame, and every one of
	them was executed. Between two pumps nothing can change what such a loop reads: the machine
	is single-threaded, devices act only through the scheduler, and the scheduler acts only in
	`Runtime.pump`. So the number of turns before the next pump is a function of the cycle
	counter, and the number before the timeout branch fires is a function of the slot; the
	recompiler proves the loop has that shape (`recomp.codegen.IdleLoopPlan`) and emits, at the
	loop's head, the arithmetic that takes all but the last of those turns at once. The last
	turn runs as generated code, so every register leaves the loop with the value the loop
	itself computes, and the pump that ends the wait fires at exactly the cycle it would have.

	Nothing here is presentation: the emulated machine passes through the same states, and the
	digests say so. What is removed is only the host's execution of turns whose every effect is
	known in advance.
**/
class IdleLoop {
	/** A first exiting turn that lies beyond any pump bound; nothing this counts reaches it. */
	public static inline var NEVER = 0x7FFFFFFF;

	/** Turns taken by arithmetic rather than by code — a diagnostic, never in a digest. */
	public static var skipped(default, null) = 0;
	/** Loop heads that skipped at least one turn. */
	public static var entries(default, null) = 0;

	/**
		How many turn tops fit before the next event: the tops at `cycles`, `cycles + per`, …
		that are still short of `nextEvent`, comparing across wraparound (ADR-0004). Zero when
		the event is due or the distance cannot be represented, and then nothing is skipped.
	**/
	public static function untilEvent(cycles:Int, nextEvent:Int, per:Int):Int {
		final d = (nextEvent - cycles) | 0;
		if (d <= 0) return 0;
		else return IntMath.div(d - 1, per) + 1;
	}

	/**
		The first turn i ≥ 1 at which `value + i * delta` equals `target`, with wrapping
		arithmetic and a delta of one either way; NEVER when no such turn is within reach.
	**/
	public static function untilEqual(value:Int, delta:Int, target:Int):Int {
		final k = delta < 0 ? (value - target) | 0 : (target - value) | 0;
		return k >= 1 ? k : NEVER;
	}

	/** Records that `n` turns were taken by arithmetic. Diagnostics only. */
	public static function note(n:Int):Void {
		skipped = (skipped + n) | 0;
		entries++;
	}
}
