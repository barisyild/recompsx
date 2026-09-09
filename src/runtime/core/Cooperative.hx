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
	static var deadline = 0;
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

	public static function init():Void {
		resumeDispatch = null;
		functions = [for (_ in 0...CAPACITY) 0];
		entries = [for (_ in 0...CAPACITY) 0];
		pumps = [for (_ in 0...CAPACITY) 0];
		nextFunctions = [for (_ in 0...CAPACITY) 0];
		nextEntries = [for (_ in 0...CAPACITY) 0];
		nextPumps = [for (_ in 0...CAPACITY) 0];
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
		resumePump = false;
	}

	/** Checked BEFORE a pump, so resumption never pumps twice at the suspension point. */
	public static function wantsYield(ctx:CpuState):Bool {
		if (!enabled || blocked != 0 || ctx.unwindToken != 0) return false;
		else {}
		checks = (checks + 1) | 0;
		final forced = every > 0 && checks >= every;
		if (!forced && ((ctx.cycles - deadline) | 0) < 0) return false;
		else {}
		// Re-entering the same safe point must make progress, including in stress mode.
		return !hasYielded || ctx.cycles != lastCycles;
	}

	public static function suspend(ctx:CpuState, fn:Int, entry:Int, entryPump:Bool):Void {
		checks = 0; hasYielded = true; lastCycles = ctx.cycles; yields = (yields + 1) | 0;
		captured = 0;
		ctx.unwindToken = TOKEN;
		capture(ctx, fn, entry, entryPump ? 1 : 0);
	}

	/** Called after a guest call, with the block AFTER that call and its delay slot. */
	public static function afterCall(ctx:CpuState, fn:Int, entry:Int):Bool {
		if (ctx.unwindToken == TOKEN && entry >= 0) capture(ctx, fn, entry, 0);
		else {}
		return ctx.unwindToken != 0;
	}

	static function capture(ctx:CpuState, fn:Int, entry:Int, pump:Int):Void {
		if (captured >= CAPACITY) {
			ctx.unwindToken = kernel.Kernel.UNWIND_HALT;
			shim.Backend.fatal("cooperative continuation capacity exceeded");
		} else {
			nextFunctions[captured] = fn;
			nextEntries[captured] = entry;
			nextPumps[captured] = pump;
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
				cursor++;
				final d = resumeDispatch;
				if (d != null) {
					d(fn, resumeEntry, ctx);
					Runtime.settle(ctx);
				} else Runtime.callAndResume(ctx, fn); // standalone fixtures use addresses
				if (ctx.unwindToken != 0) break;
				else {}
			}
		}
		if (ctx.unwindToken != TOKEN) return false;
		else {}
		while (cursor < count) {
			capture(ctx, functions[cursor], entries[cursor], pumps[cursor]);
			cursor++;
		}
		if (ctx.unwindToken != TOKEN) return false;
		else {}
		final oldFunctions = functions; functions = nextFunctions; nextFunctions = oldFunctions;
		final oldEntries = entries; entries = nextEntries; nextEntries = oldEntries;
		final oldPumps = pumps; pumps = nextPumps; nextPumps = oldPumps;
		count = captured; captured = 0; cursor = 0;
		return true;
	}
}
