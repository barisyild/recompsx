package core;

import shim.Backend;

/**
	The services recompiled code calls into that are not memory and not arithmetic.

	Everything here is reached from generated code, so the surface is fixed by the emitter's
	contract (docs/specs/tool.md Appendix A) and nothing else may be added to it casually — a new
	entry point here means a new thing the code generator has to know how to produce.

	Most of it is unimplemented so far. What matters at this stage is that each stub *reports*
	rather than silently doing nothing: a game reaching an unimplemented path should say so once,
	with the address, and keep going if it can. Silence here would turn a missing feature into an
	unexplained hang.
**/
class Runtime {
	/** Set once by the generated program's own bootstrap; see `Runtime.bindDispatch`. */
	// Null<> is required, not decoration: reflaxe.CPP compiles with null-safety enforced, so a
	// field that can be null has to say so.
	static var dispatcher:Null<Int -> CpuState -> Bool> = null;

	/** How many distinct unimplemented things have been reported, so a run can be judged. */
	public static var reportedGaps(default, null) = 0;

	/**
		How many times the generated table has dispatched.

		This exists to answer one question that nothing else could: when a dispatch fails, was it
		the *first* one — meaning the switch itself is wrong — or a later one from inside a
		function that did run? Those two have the same error message and completely different
		causes. One integer settles it.
	**/
	public static var dispatches = 0;

	/** The slot value a shard's dispatcher was handed, observed at entry, before its switch. */
	public static var lastSlot = -999;

	static final reported:Map<Int, Bool> = new Map();

	/**
		Connects the generated `FnTable` to the runtime.

		The runtime cannot reference generated code directly — it is compiled against a program it
		has never seen — so the program hands its dispatcher over at startup. One indirect call
		per dynamic dispatch, on a path that is already dynamic by definition.
	**/
	public static function bindDispatch(f:Int -> CpuState -> Bool):Void {
		dispatcher = f;
	}

	/**
		Brings the machine up, in the one order that works.

		Memory before anything that can touch it, the interrupt controller before the scheduler
		that raises into it, and the scheduler last because arming vblank needs a cycle count to
		measure from. A launcher should call this and nothing else.
	**/
	public static function boot(ctx:CpuState):Void {
		// Region first: every video constant derives from it, and they are computed once.
		TimeBase.setRegion(false);
		mem.Memory.init();
		Irq.init();
		gpu.Gpu.init();
		cd.Iso9660.init();
		cd.Cdrom.init();
		sio.Sio0.init();
		timers.Timers.init();
		dma.Dma.init();
		kernel.Kernel.init();
		Scheduler.init(ctx);
	}

	/**
		Calls the function at an emulated address.

		This is where every jump the analysis could not resolve statically ends up: calls through
		a register, computed jumps without a recoverable table, and calls into an overlay that is
		resident but was compiled separately.
	**/
	/**
		Runs `addr`, and then wherever a `longjmp` out of it wants to continue.

		The unwind leaves every frame between the jump and here, so this is where control comes
		back to. Dispatching again from the saved `pc` is what completes the jump — a fresh native
		frame, but the emulated `sp` and `ra` are the ones `setjmp` recorded, so the game cannot
		tell the difference.
	**/
	public static function callAndResume(ctx:CpuState, addr:Int):Void {
		call(ctx, addr);
		var guard = 0;
		while (ctx.unwindToken != 0) {
			ctx.unwindToken = 0;
			guard++;
			// A longjmp loop that never settles would otherwise hang with no explanation.
			if (guard > 1024) return unwindStuck(ctx);
			else {}
			call(ctx, ctx.pc);
		}
	}

	static function unwindStuck(ctx:CpuState):Void {
		reportOnce(0x5A00FFFF, "1024 unwinds without settling — a longjmp loop");
	}

	public static function call(ctx:CpuState, addr:Int):Void {
		final d = dispatcher;
		if (d != null && d(addr, ctx)) {
			// Dispatched.
		} else {
			notInProgram(ctx, addr);
		}
	}

	/**
		An address the program has no function at.

		Usually a kernel stub: a game that read an entry out of the A0/B0/C0 tables and jumped
		through it lands in the BIOS window, where `KTables` can say which call it meant. That is a
		real and supported route into the kernel, not a failure — libraries that hook a BIOS
		function do exactly this to reach the original.

		Anything else is a genuine gap, and worth the address.
	**/
	static function notInProgram(ctx:CpuState, addr:Int):Void {
		// The vectors themselves. On hardware 0xA0/0xB0/0xC0 hold real code — a jump into the
		// dispatcher — and libraries call them through registers, which arrives here rather than
		// through the emitter's constant-target path. The function number rides in $t1, exactly
		// as it does for a direct call.
		final p = addr & 0x1FFFFFFF;
		if (p == 0xA0 || p == 0xB0 || p == 0xC0) return kernel.Kernel.call(ctx, p, ctx.t1);
		else {}
		final index = kernel.KTables.callAt(addr);
		if (index >= 0) kernelStub(ctx, index);
		// Target AND caller, as the failure-mode policy always required (docs/specs/tool.md §6.8).
		// The address-less form hid N distinct misses behind one identical line — and an
		// unresolved call is a black hole: it does nothing, silently, so whatever side effects
		// the callee had (installing a handler, unmasking a line) simply never happen.
		else if (dma.Dma.wasLoaded(addr)) reportOnce(addr, "no function at " + hex(addr)
			+ " (ra=" + hex(ctx.ra) + ") — but this address was read in from the disc, into "
			+ hex(0x80000000 | dma.Dma.loadedLo) + ".." + hex(0x80000000 | dma.Dma.loadedHi)
			+ ". It is an overlay: code the executable never contained, so the tool never saw it. "
			+ "Add it to games/<id>/game.json as an overlay rather than looking for a missed "
			+ "function.");
		else reportOnce(addr, "no function at " + hex(addr) + " (ra=" + hex(ctx.ra) + ")");
	}

	static function kernelStub(ctx:CpuState, index:Int):Void {
		final vector = index < 0x100 ? 0xA0 : (index < 0x200 ? 0xB0 : 0xC0);
		kernel.Kernel.call(ctx, vector, index & 0xFF);
	}

	/**
		A handle that named a shard or slot that does not exist — a generator bug, not a game one.

		`where` names the switch that fell through: `"table"` for the shard selector, or the
		shard's own class name. The two were indistinguishable from their message until a C++-only
		failure made the difference the whole question — a diagnostic that cannot say *which* of
		two call sites produced it is only half a diagnostic.
	**/
	public static function badHandle(ctx:CpuState, where:String, shard:Int, slot:Int):Void {
		Backend.fatal("recompsx: " + where + " dispatch fell through for shard " + shard
			+ " slot " + slot + " (entry saw " + lastSlot + ") on dispatch #" + dispatches
			+ ", which should exist. This is a code-generation defect.");
	}

	/**
		Time has reached the next deadline: run what is due, then deliver any interrupt.

		The only place recompiled code re-enters the runtime for reasons other than a memory access
		or a kernel call, and the only place an interrupt can be delivered. Generated code calls it
		guarded — `if (ctx.cycles - ctx.nextEvent >= 0) Runtime.pump(ctx);` — at function entry and
		every back-edge, so the common cost is a subtraction and a branch (ADR-0005 §2).

		Order matters: events first, because firing one is what raises the interrupt that the
		second half then delivers. Reversing them would cost a whole pump of latency on every
		vblank.
	**/
	public static function pump(ctx:CpuState):Void {
		// Registers whose value follows the clock read it from here; see Memory.cycleHint.
		mem.Memory.cycleHint = ctx.cycles;
		Scheduler.runDue(ctx);
		Irq.dispatch(ctx);
	}

	/**
		Advances emulated time to the next deadline and runs it.

		What an idle kernel wait uses. There is no thread to block, so waiting means moving the
		clock — and moving it straight to the deadline rather than by some step, which is exact and
		makes an idle wait cost one iteration per event instead of one per N cycles (ADR-0005 §3).
	**/
	public static function idleToNextEvent(ctx:CpuState):Void {
		// Never backwards: if a deadline has already passed, just run it. `| 0` because the
		// comparison has to survive the counter wrapping, and JavaScript does not wrap `-`.
		if (((ctx.nextEvent - ctx.cycles) | 0) > 0) ctx.cycles = ctx.nextEvent;
		else {}
		pump(ctx);
	}

	// ---- COP0 ------------------------------------------------------------------------------------

	/**
		The system coprocessor, of which the PlayStation implements a small part.

		Games touch it mainly to enable and disable interrupts around critical sections, which the
		kernel HLE also mediates; the breakpoint registers are used by almost nothing.
	**/
	public static function mfc0(ctx:CpuState, reg:Int):Int {
		if (reg == 12) return ctx.sr;
		// CAUSE's pending field is not stored; it is whatever the controller says right now.
		else if (reg == 13) return (ctx.cause & ~Irq.CAUSE_IP_HW) | Irq.causeBits();
		else if (reg == 14) return ctx.pc;   // EPC
		else return unknownCop0(reg);
	}

	static function unknownCop0(reg:Int):Int {
		reportOnce(0xC0000000 | reg, "mfc0 from COP0 register " + reg);
		return 0;
	}

	public static function mtc0(ctx:CpuState, reg:Int, value:Int):Void {
		if (reg == 12) ctx.sr = value;
		else if (reg == 13) ctx.cause = value;
		else reportOnce(0xC1000000 | reg, "mtc0 to COP0 register " + reg);
	}

	/**
		`rfe` — pop the interrupt-enable stack in SR.

		SR bits 0..5 are three pairs, current/previous/old, and returning from an exception shifts
		them down two: previous becomes current, old becomes previous. The old pair is left as it
		is, which is what the hardware does — it does not clear, it just stops being read.
	**/
	public static function rfe(ctx:CpuState):Void {
		final stack = ctx.sr & 0x3F;
		ctx.sr = (ctx.sr & ~0xF) | (stack >> 2);
	}

	// ---- diagnostics -------------------------------------------------------------------------------

	/**
		Reports something unimplemented, once per distinct thing.

		Once per *thing*, not once per occurrence: a game calling an unimplemented kernel function
		in its main loop would otherwise produce a hundred thousand identical lines and hide
		everything else. The count is what a bring-up session actually watches.
	**/
	/** For hot paths: whether a key has reported, so the caller can skip building the message. */
	public static function alreadyReported(key:Int):Bool {
		return reported.exists(key);
	}

	public static function reportOnce(key:Int, what:String):Void {
		if (reported.exists(key)) return;
		reported.set(key, true);
		reportedGaps++;
		Backend.log(Backend.LOG_WARN, "unimplemented: " + what);
	}

	/**
		Reports something the runtime *does* handle, once.

		Separate from `reportOnce` so the gap count stays honest: a bring-up session judges a run
		by how many distinct unimplemented things it hit, and a handled call must not inflate that
		number just because it is worth seeing in the log.
	**/
	public static function noteOnce(key:Int, what:String):Void {
		if (reported.exists(key)) return;
		reported.set(key, true);
		Backend.log(Backend.LOG_INFO, "handled: " + what);
	}

	/** An ordinary progress line — not a gap, not once-only. */
	public static function note(what:String):Void {
		Backend.log(Backend.LOG_INFO, what);
	}

	public static function trap(ctx:CpuState, what:String):Void {
		Backend.fatal("recompsx: " + what + " at pc=" + hex(ctx.pc));
	}

	static function hex(v:Int):String {
		final digits = "0123456789abcdef";
		var out = "";
		var shift = 28;
		while (shift >= 0) {
			out += digits.charAt((v >>> shift) & 0xF);
			shift -= 4;
		}
		return "0x" + out;
	}
}
