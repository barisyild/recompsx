package kernel;

import core.CpuState;
import core.Runtime;

/**
	The kernel's root-counter wrapper, B0(02h..06h).

	These are a thin layer over the hardware timers at 0x1F801100, which do not exist yet. What
	they can do honestly today is keep the configuration a game hands over, so that when the timer
	registers arrive there is something to program them from — and so `get_timer` returns the same
	answer twice rather than a fresh zero each time.

	Root counter 3 is vblank and is not a hardware timer at all; the kernel synthesises it, and
	this runtime already delivers it from the scheduler.
**/
class KTimers {
	static inline var COUNTERS = 4;

	// Built in `init`, never at the declaration: a static initialised with an array comprehension
	// makes reflaxe emit a statement block at namespace scope, which is not valid C++.
	static var reload:Array<Int>;
	static var flags:Array<Int>;
	static var irqEnabled:Array<Bool>;

	public static function init():Void {
		reload = [for (_ in 0...COUNTERS) 0];
		flags = [for (_ in 0...COUNTERS) 0];
		irqEnabled = [for (_ in 0...COUNTERS) false];
	}

	public static function call(ctx:CpuState, fn:Int):Int {
		final t = ctx.a0 & 3;
		if (fn == 0x02) return initTimer(t, ctx.a1, ctx.a2);
		else if (fn == 0x03) return getTimer(t);
		else if (fn == 0x04) return setIrq(t, true);
		else if (fn == 0x05) return setIrq(t, false);
		else return restart(t);
	}

	static function initTimer(t:Int, reloadValue:Int, flagBits:Int):Int {
		reload[t] = reloadValue;
		flags[t] = flagBits;
		irqEnabled[t] = false;
		Runtime.noteOnce(0x5F000000 | t, "init_timer on root counter " + t
			+ " — kept, but the timer registers are not built yet");
		return 1;
	}

	/** Counter 3 is vblank, which the scheduler really does count. The others are not running. */
	static function getTimer(t:Int):Int {
		return t == 3 ? Kernel.vblankCount : 0;
	}

	static function setIrq(t:Int, on:Bool):Int {
		irqEnabled[t] = on;
		return 1;
	}

	static function restart(t:Int):Int {
		return 1;
	}
}
