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
	/**
		Set once by the generated program's own bootstrap; see `Runtime.bindDispatch`. Never null:
		until a program binds one, `noProgram` answers. As `Null<>` it compiled to an optional
		std::function that every dynamic call copied twice — into a local, then out through
		`value_or` — so each call paid two clones and two destroys in `_M_manager`: 1.4 % of
		Crash Bandicoot: Warped on the Dreamcast, on its own.
	**/
	static var dispatcher:Int -> CpuState -> Bool = noProgram;

	static function noProgram(addr:Int, ctx:CpuState):Bool return false;

	/**
		What `call` hands its address to: the program's `FnTable.run` once bound (ADR-0028), this
		file's own loop until then. The runtime's calls into guest code are few, but a tail chain
		left for `unwinding` — a renderer hopping once per primitive — continues in whatever loop
		takes it, and that loop should be the one with the program's answers in front of it.
	**/
	static var runner:CpuState -> Int -> Void = callLoop;

	/** How many distinct unimplemented things have been reported, so a run can be judged. */
	public static var reportedGaps(default, null) = 0;

	/**
		How many times the generated table has dispatched.

		This exists to answer one question that nothing else could: when a dispatch fails, was it
		the *first* one — meaning the switch itself is wrong — or a later one from inside a
		function that did run? Those two have the same error message and completely different
		causes. One integer settles it.

		Counted only with `-D recompsx_insns`, beside the instruction counts: on the SH-4 counting
		every dynamic call was a literal-pool address, a load and a store each time. A build
		chasing a failed dispatch turns it on; elsewhere the message says #0.
	**/
	public static var dispatches = 0;
	/** Optional instruction/block profiling; excluded from the emulated-state digest. */
	public static var insns = 0;
	public static var blocks = 0;

	/** The slot value a shard's dispatcher was handed, observed at entry, before its switch. */
	public static var lastSlot = -999;

	static final reported:Map<Int, Bool> = new Map();

	/**
		Connects the generated `FnTable` to the runtime.

		The runtime cannot reference generated code directly — it is compiled against a program it
		has never seen — so the program hands its dispatcher over at startup. The runtime's own
		calls into guest code take it: callbacks, handlers, a thread switch, a longjmp. Generated
		code does not — its calls through registers go to the program's `FnTable.run`, which asks
		here (`callOnce`) only when it has no answer of its own.
	**/
	public static function bindDispatch(f:Int -> CpuState -> Bool):Void {
		dispatcher = f;
	}

	/** Hands `call` the program's own loop, `FnTable.run`. */
	public static function bindRun(f:CpuState -> Int -> Void):Void {
		runner = f;
	}

	/**
		Brings the machine up, in the one order that works.

		Memory before anything that can touch it, the interrupt controller before the scheduler
		that raises into it, and the scheduler last because arming vblank needs a cycle count to
		measure from. A launcher should call this and nothing else.
	**/
	public static function boot(ctx:CpuState):Void {
		insns = 0;
		blocks = 0;
		#if recompsx_cooperative
		Cooperative.init();
		#end
		Reloc.reset();
		// Region first: every video constant derives from it, and they are computed once.
		TimeBase.setRegion(false);
		mem.Memory.init();
		mem.Memory.machine = ctx;
		Irq.init();
		gpu.Gpu.init();
		gpu.Scanout.init();
		gte.Gte.init();
		spu.Spu.init();
		cd.Iso9660.init();
		cd.Cdrom.init();
		sio.Pads.init();
		sio.MemoryCard.init();
		sio.Sio0.init();
		timers.Timers.init();
		dma.Dma.init();
		kernel.Kernel.init();
		kernel.OverlayMgr.init();
		Scheduler.init(ctx);
		// After the scheduler, because the mixer's first deadline is one of its slots.
		spu.Spu.start(ctx.cycles);
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
		#if recompsx_cooperative
		settle(ctx);
	}

	/** Handles a guest nonlocal jump after either address or pinned-handle dispatch. */
	public static function settle(ctx:CpuState):Void {
		#end
		var guard = 0;
		while (ctx.unwindToken != 0) {
			// A halt is the one token nobody resumes from: a headless run has reached the frame it
			// was told to stop at, and the emulated stack has just been left behind on purpose.
			if (ctx.unwindToken == kernel.Kernel.UNWIND_HALT) return;
			else {}
			// A tail jump left by a resumed frame: run it where the frame would have returned.
			if (ctx.unwindToken == TAIL) {
				ctx.unwindToken = 0;
				call(ctx, ctx.tailTarget);
				continue;
			} else {}
			#if recompsx_cooperative
			if (ctx.unwindToken == Cooperative.TOKEN) return;
			else {}
			Cooperative.discard();
			#end
			// A return to an address no frame continues at (ADR-0027) is completed as a longjmp
			// is: from here, where every frame it passed has been left.
			final target = ctx.unwindToken == RETURN ? strayReturn(ctx) : ctx.pc;
			ctx.unwindToken = 0;
			guard++;
			// A longjmp loop that never settles would otherwise hang with no explanation.
			if (guard > 1024) return unwindStuck(ctx);
			else {}
			call(ctx, target);
		}
	}

	static function strayReturn(ctx:CpuState):Int {
		reportOnce(0x5A00FFFE, "a return to " + hex(ctx.returnTarget)
			+ ", which no caller continues at — run from there, like a longjmp");
		return ctx.returnTarget;
	}

	static function unwindStuck(ctx:CpuState):Void {
		reportOnce(0x5A00FFFF, "1024 unwinds without settling — a longjmp loop");
	}

	/**
		A computed jump that does not come back (ADR-0026).

		`jr $t9` to code that ends by returning to *our* caller is a jump on hardware, not a call:
		the stack does not grow. Emitted as a call it does, one host frame per jump, and threaded
		code that hops between routines through pointers — Crash Bandicoot: Warped's renderer, one
		hop per primitive — exhausted the host stack within a frame. So the jump leaves its
		target here and returns; the nearest caller that continues after it (`call`, or generated
		code through `unwinding`) runs it, and further tail jumps loop there at a fixed depth.
	**/
	public static inline var TAIL = 0x5441494C;   // 'TAIL'

	public static inline function tail(ctx:CpuState, addr:Int):Void {
		ctx.tailTarget = addr;
		ctx.unwindToken = TAIL;
	}

	/**
		A return to somewhere other than the caller (ADR-0027).

		`jr $ra` is a return when `$ra` holds the address the function was called with, and a
		jump to wherever it points otherwise. Hand-written code does the second on purpose: a
		helper loads the return address its caller saved and leaves both at once. The generated
		return compares `$ra` with the value it was entered with and, when they differ, leaves
		the target here and returns; every caller's after-call check (`unwinding`) then either
		continues — its own continuation is the target — or returns in turn. A target no frame
		continues at is run from the top, as a longjmp is (`settle`).
	**/
	public static inline var RETURN = 0x52455455;   // 'RETU'

	public static inline function returnTo(ctx:CpuState, addr:Int):Void {
		ctx.returnTarget = addr;
		ctx.unwindToken = RETURN;
	}

	/**
		After a call that returns to `cont`: runs the tail jumps the callee left, ends a return
		to elsewhere whose target is `cont`, then says whether the caller must still leave — a
		longjmp, a halt, a cooperative suspension or a return aimed further out all return true.

		Out of line on C++, like `call`: every generated call site reaches this, behind its own
		test of the token, and only when a token is set. Inlined, it took `call` and the bound
		loop's `std::function` with it into each of them — 2,000 copies in Crash Bash, 600 bytes
		more in its hottest function, and a slower frame (ADR-0028).
	**/
	@:specifier("__attribute__((noinline))")
	public static function unwinding(ctx:CpuState, cont:Int):Bool {
		if (ctx.unwindToken == TAIL) {
			ctx.unwindToken = 0;
			call(ctx, ctx.tailTarget);
		} else {}
		if (ctx.unwindToken == RETURN && ctx.returnTarget == cont) ctx.unwindToken = 0;
		else {}
		return ctx.unwindToken != 0;
	}

	@:specifier("__attribute__((noinline))")
	public static function call(ctx:CpuState, addr:Int):Void {
		// A callback cannot enter guest code while a halt or nonlocal jump is leaving it.
		// Direct generated callers check their own return boundaries; guard external entry here.
		if (ctx.unwindToken != 0) return;
		else {}
		runner(ctx, addr);
	}

	/** `call` without a program's loop: each address through the dispatcher, then its tails. */
	static function callLoop(ctx:CpuState, addr:Int):Void {
		var target = addr;
		while (true) {
			callOnce(ctx, target);
			if (ctx.unwindToken != TAIL) return;
			else {}
			ctx.unwindToken = 0;
			target = ctx.tailTarget;
		}
	}

	/**
		One call by address, without the tail loop: the program's dispatcher, then a rescan of a
		window, then a report. The generated `FnTable.run` falls back to this.

		Out of line on C++: inlined, its cold paths would lend `run` — the one caller that is hot —
		a frame saving every register they use, on every dynamic call.
	**/
	@:specifier("__attribute__((noinline))")
	public static function callOnce(ctx:CpuState, addr:Int):Void {
		if (dispatcher(addr, ctx)) return;
		else {}
		// Nothing answered. If this address is inside a window the game loads code into, what is
		// sitting there may have changed without anything telling us — a loader that writes
		// through the CPU rather than a DMA channel leaves no trace to watch. Looking once is
		// cheap and turns an unrecognised loader into a working program.
		if (kernel.OverlayMgr.windowOf(addr) >= 0 && kernel.OverlayMgr.rescan() > 0
				&& dispatcher(addr, ctx)) {
			return;
		} else {}
		notInProgram(ctx, addr);
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
		final device = kernel.KDevices.callAt(addr);
		if (index >= 0) kernelStub(ctx, index);
		// A device's function, through the pointer a game saved from the device table before it put
		// one of its own there (kernel.KDevices).
		else if (device >= 0 && kernel.KDevices.callStub(ctx, device)) {}
		// Target AND caller, as the failure-mode policy always required (docs/specs/tool.md §6.8).
		// The address-less form hid N distinct misses behind one identical line — and an
		// unresolved call is a black hole: it does nothing, silently, so whatever side effects
		// the callee had (installing a handler, unmasking a line) simply never happen.
		// An address the disc wrote to is a different failure in kind: not a function the analysis
		// missed, but code the executable never held. `OverlayMgr` knows which of those this is
		// and answers with the window — which is what a person needs to write the config.
		else if (kernel.OverlayMgr.reportMiss(addr, ctx.ra)) {}
		else if (!alreadyReported(addr)) reportOnce(addr, "no function at " + hex(addr)
			+ " (ra=" + hex(ctx.ra) + ")" + registersAtMiss(ctx));
		else {}
	}

	/**
		The argument and saved registers, for a miss.

		A wild jump is usually the end of a longer story, and the caller's state is the first page
		of it: an interpreter's program counter, an object pointer, the word it decoded. Built only
		the first time an address is reported, so a game that keeps missing pays nothing.
	**/
	static function registersAtMiss(ctx:CpuState):String {
		return " a0=" + hex(ctx.a0) + " a1=" + hex(ctx.a1) + " a2=" + hex(ctx.a2)
			+ " a3=" + hex(ctx.a3) + " v0=" + hex(ctx.v0) + " v1=" + hex(ctx.v1)
			+ " s0=" + hex(ctx.s0) + " s1=" + hex(ctx.s1) + " s2=" + hex(ctx.s2)
			+ " s3=" + hex(ctx.s3) + " s4=" + hex(ctx.s4) + " s5=" + hex(ctx.s5)
			+ " s6=" + hex(ctx.s6) + " s7=" + hex(ctx.s7) + " sp=" + hex(ctx.sp);
	}

	static function kernelStub(ctx:CpuState, index:Int):Void {
		final vector = index < 0x100 ? 0xA0 : (index < 0x200 ? 0xB0 : 0xC0);
		kernel.Kernel.call(ctx, vector, index & 0xFF);
	}

	/**
		A handle that named a shard or slot that does not exist — a generator bug, not a game one.

		`where` names the switch that fell through: -1 for the table's shard selector, or the
		shard whose own slot switch did. The two were indistinguishable from their message until a
		C++-only failure made the difference the whole question — a diagnostic that cannot say
		*which* of two call sites produced it is only half a diagnostic.

		An integer, where it was the class name: the string built at every call site made each
		dispatch switch reserve a frame for it, hit or not. Out of line on C++ for the same reason.
	**/
	@:specifier("__attribute__((noinline))")
	public static function badHandle(ctx:CpuState, where:Int, shard:Int, slot:Int):Void {
		Backend.fatal("recompsx: " + (where < 0 ? "table" : "shard " + where)
			+ " dispatch fell through for shard " + shard + " slot " + slot
			+ " (entry saw " + lastSlot + ") on dispatch #" + dispatches
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
		#if recompsx_cooperative
		Cooperative.blocked++;
		pumpAtomic(ctx);
		Cooperative.blocked--;
	}

	static function pumpAtomic(ctx:CpuState):Void {
		#end
		Scheduler.runDue(ctx);
		if (ctx.unwindToken != 0) return;
		else {}
		// Events a device raised from inside one of the game's own instructions, where there was
		// no safe way back into game code. Here there is.
		kernel.KEvents.drain(ctx);
		if (ctx.unwindToken != 0) return;
		else {}
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
