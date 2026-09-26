package core;

/**
	Optional, integer-only suspension of generated code. Frames contain a compiled function handle,
	its stable block ID, and whether its entry pump still has to run. Scalar locals are already
	published when a frame is recorded. No guest instruction or call delay slot is replayed.

	The unwound frames arrive innermost first. Resume that continuation, then its callers;
	if it suspends again, prepend its new frames to the still-pending callers. Two fixed buffers
	avoid allocations and rebuilding a native call stack on every browser slice. HLE calls and
	scheduler callbacks are atomic: their native continuations are not generated MIPS blocks.
**/
class Cooperative {
	public static inline final TOKEN = 0x5949454c;
	static inline final CAPACITY = 4096;
	public static var enabled = false;
	public static var blocked = 0;
	/** Diagnostic stress mode; zero uses only the cycle budget. */
	public static var every = 0;
	public static var yields(default, null) = 0;
	public static var resumeEntry = -1;
	public static var resumePump = false;
	static var resumeDispatch:Null<Int -> Int -> CpuState -> Void> = null;
	/** Public only so the inline check below can read it from generated code on every target. */
	public static var deadline = 0;
	static var checks = 0;
	static var lastCycles = 0;
	static var hasYielded = false;
	static var started = false;
	static var cursor = 0;
	static var count = 0;
	static var captured = 0;
	static var functions:Array<Int>;
	static var entries:Array<Int>;
	static var pumps:Array<Int>;
	static var nextFunctions:Array<Int>;
	static var nextEntries:Array<Int>;
	static var nextPumps:Array<Int>;
	/** Each frame's relocatable base (ADR-0025); zero for code at a fixed address. */
	static var bases:Array<Int>;
	static var nextBases:Array<Int>;
	/**
		Each frame's continuation: the guest address the call it was suspended in returns to, so a
		return to elsewhere can find the frame it lands in (ADR-0027); -1 for the innermost frame.
	**/
	static var conts:Array<Int>;
	static var nextConts:Array<Int>;
	/** Each frame's `$ra` at entry, for a function with returns checked against it (ADR-0027). */
	static var ras:Array<Int>;
	static var nextRas:Array<Int>;
	/** The resumed frame's `$ra` at entry; read by its prologue with `resumeEntry`. */
	public static var resumeRa = 0;

	public static function init():Void {
		resumeDispatch = null;
		functions = [for (_ in 0...CAPACITY) 0];
		entries = [for (_ in 0...CAPACITY) 0];
		pumps = [for (_ in 0...CAPACITY) 0];
		nextFunctions = [for (_ in 0...CAPACITY) 0];
		nextEntries = [for (_ in 0...CAPACITY) 0];
		nextPumps = [for (_ in 0...CAPACITY) 0];
		bases = [for (_ in 0...CAPACITY) 0];
		nextBases = [for (_ in 0...CAPACITY) 0];
		conts = [for (_ in 0...CAPACITY) 0];
		nextConts = [for (_ in 0...CAPACITY) 0];
		ras = [for (_ in 0...CAPACITY) 0];
		nextRas = [for (_ in 0...CAPACITY) 0];
		reset();
	}

	/** Bind the generated handle table, pinning active code even when an overlay changes. */
	public static function bind(f:Int -> Int -> CpuState -> Void):Void { resumeDispatch = f; }

	public static function reset():Void {
		enabled = false; blocked = 0; every = 0; yields = 0;
		deadline = 0; checks = 0; lastCycles = 0; hasYielded = false; started = false;
		discard();
	}

	/** A nonlocal guest jump abandons the suspended callers too. */
	public static function discard():Void {
		cursor = 0; count = 0; captured = 0; resumeEntry = -1;
		resumePump = false; resumeRa = 0;
	}

	/**
		The check every safe point makes. Inline, so the hot path is two static loads and a
		compare in the generated code; the full test runs only when a yield is possible — the
		slice deadline has passed, or stress mode (`every`) is forcing one, which is also the
		mode that counts calls. Same answer as the full test in every case: the pre-check is a
		condition the full test requires.
	**/
	public static inline function wantsYield(ctx:CpuState):Bool {
		return enabled && (every > 0 || ((ctx.cycles - deadline) | 0) >= 0) && wantsYieldSlow(ctx);
	}

	/** Checked BEFORE a pump, so resumption never pumps twice at the suspension point. */
	public static function wantsYieldSlow(ctx:CpuState):Bool {
		if (!enabled || blocked != 0 || ctx.unwindToken != 0) return false;
		else {}
		checks = (checks + 1) | 0;
		final forced = every > 0 && checks >= every;
		if (!forced && ((ctx.cycles - deadline) | 0) < 0) return false;
		else {}
		// Re-entering the same safe point must make progress, including in stress mode.
		return !hasYielded || ctx.cycles != lastCycles;
	}

	/** `entryRa` is the frame's `$ra` at entry, for a function whose returns check it. */
	public static function suspend(ctx:CpuState, fn:Int, entry:Int, entryPump:Bool, entryRa:Int = 0):Void {
		suspendAt(ctx, fn, entry, entryPump, 0, entryRa);
	}

	/** `suspend` for relocatable code, which also needs its base back when it resumes. */
	public static function suspendAt(ctx:CpuState, fn:Int, entry:Int, entryPump:Bool, base:Int,
			entryRa:Int = 0):Void {
		checks = 0; hasYielded = true; lastCycles = ctx.cycles; yields = (yields + 1) | 0;
		captured = 0;
		ctx.unwindToken = TOKEN;
		capture(ctx, fn, entry, entryPump ? 1 : 0, base, -1, entryRa);
	}

	/**
		Called after a guest call, with the block AFTER that call and its delay slot, and `cont`,
		the guest address that call returns to.
	**/
	public static function afterCall(ctx:CpuState, fn:Int, entry:Int, cont:Int, entryRa:Int = 0):Bool {
		return afterCallAt(ctx, fn, entry, 0, cont, entryRa);
	}

	/** `afterCall` for relocatable code. */
	public static function afterCallAt(ctx:CpuState, fn:Int, entry:Int, base:Int, cont:Int,
			entryRa:Int = 0):Bool {
		// A tail jump the callee left runs first, as part of the call, and a return to elsewhere
		// ends here if this is where it goes (Runtime.unwinding).
		if (ctx.unwindToken == Runtime.TAIL || ctx.unwindToken == Runtime.RETURN) Runtime.unwinding(ctx, cont);
		else {}
		if (ctx.unwindToken == TOKEN && entry >= 0) capture(ctx, fn, entry, 0, base, cont, entryRa);
		else {}
		return ctx.unwindToken != 0;
	}

	static function capture(ctx:CpuState, fn:Int, entry:Int, pump:Int, base:Int, cont:Int, ra:Int):Void {
		if (captured >= CAPACITY) {
			ctx.unwindToken = kernel.Kernel.UNWIND_HALT;
			shim.Backend.fatal("cooperative continuation capacity exceeded");
		} else {
			nextFunctions[captured] = fn;
			nextEntries[captured] = entry;
			nextPumps[captured] = pump;
			nextBases[captured] = base;
			nextConts[captured] = cont;
			nextRas[captured] = ra;
			captured++;
		}
	}

	/** Runs one bounded slice. Host clocks belong to the driver, never this machine state. */
	public static function step(ctx:CpuState, root:Int, budget:Int):Bool {
		if (ctx.unwindToken == kernel.Kernel.UNWIND_HALT) return false;
		else {}
		enabled = true;
		deadline = (ctx.cycles + budget) | 0;
		if (!started) {
			started = true;
			Runtime.callAndResume(ctx, root);
		} else {
			ctx.unwindToken = 0;
			while (cursor < count) {
				final fn = functions[cursor];
				resumeEntry = entries[cursor]; resumePump = pumps[cursor] != 0;
				resumeRa = ras[cursor];
				// Relocatable code reads its base in its first statement; fixed code ignores it.
				Reloc.base = bases[cursor];
				cursor++;
				final d = resumeDispatch;
				if (d != null) {
					d(fn, resumeEntry, ctx);
					// A tail jump the frame left runs where the frame would have returned.
					if (ctx.unwindToken == Runtime.TAIL) Runtime.unwinding(ctx, -1);
					else {}
					if (ctx.unwindToken == Runtime.RETURN) returnInto(ctx);
					else {}
					Runtime.settle(ctx);
				} else Runtime.callAndResume(ctx, fn); // standalone fixtures use addresses
				if (ctx.unwindToken != 0) break;
				else {}
			}
		}
		if (ctx.unwindToken != TOKEN) return false;
		else {}
		while (cursor < count) {
			capture(ctx, functions[cursor], entries[cursor], pumps[cursor], bases[cursor], conts[cursor],
				ras[cursor]);
			cursor++;
		}
		if (ctx.unwindToken != TOKEN) return false;
		else {}
		final oldFunctions = functions; functions = nextFunctions; nextFunctions = oldFunctions;
		final oldEntries = entries; entries = nextEntries; nextEntries = oldEntries;
		final oldPumps = pumps; pumps = nextPumps; nextPumps = oldPumps;
		final oldBases = bases; bases = nextBases; nextBases = oldBases;
		final oldConts = conts; conts = nextConts; nextConts = oldConts;
		final oldRas = ras; ras = nextRas; nextRas = oldRas;
		count = captured; captured = 0; cursor = 0;
		return true;
	}

	/**
		A resumed frame returned to somewhere other than its caller (ADR-0027). Its callers are
		the frames still pending, innermost first: the first whose call returns to the target is
		where execution continues, and the ones before it are left, as their host frames would
		have been. With no such frame the token stays for `Runtime.settle`.
	**/
	static function returnInto(ctx:CpuState):Void {
		var k = cursor;
		while (k < count && conts[k] != ctx.returnTarget) k++;
		if (k < count) {
			cursor = k;
			ctx.unwindToken = 0;
		} else {}
	}
}
