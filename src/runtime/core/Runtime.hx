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
	static var dispatcher:Int -> CpuState -> Bool = null;

	/** How many distinct unimplemented things have been reported, so a run can be judged. */
	public static var reportedGaps(default, null) = 0;

	static var reported:Map<Int, Bool> = new Map();

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
		Calls the function at an emulated address.

		This is where every jump the analysis could not resolve statically ends up: calls through
		a register, computed jumps without a recoverable table, and calls into an overlay that is
		resident but was compiled separately.
	**/
	public static function call(ctx:CpuState, addr:Int):Void {
		if (dispatcher != null && dispatcher(addr, ctx)) return;
		reportOnce(addr, "no function at this address");
	}

	/** A handle that named a shard or slot that does not exist — a generator bug, not a game one. */
	public static function badHandle(ctx:CpuState, shard:Int, slot:Int):Void {
		Backend.fatal("recompsx: dispatch to shard " + shard + " slot " + slot
			+ ", which does not exist. This is a code-generation defect.");
	}

	// ---- COP0 ------------------------------------------------------------------------------------

	/**
		The system coprocessor, of which the PlayStation implements a small part.

		Games touch it mainly to enable and disable interrupts around critical sections, which the
		kernel HLE also mediates; the breakpoint registers are used by almost nothing.
	**/
	public static function mfc0(ctx:CpuState, reg:Int):Int {
		reportOnce(0xC0000000 | reg, "mfc0 from COP0 register " + reg);
		return 0;
	}

	public static function mtc0(ctx:CpuState, reg:Int, value:Int):Void {
		reportOnce(0xC1000000 | reg, "mtc0 to COP0 register " + reg);
	}

	/** Returns from an exception by restoring the interrupt-enable stack in SR. */
	public static function rfe(ctx:CpuState):Void {
		reportOnce(0xC2000000, "rfe");
	}

	// ---- diagnostics -------------------------------------------------------------------------------

	/**
		Reports something unimplemented, once per distinct thing.

		Once per *thing*, not once per occurrence: a game calling an unimplemented kernel function
		in its main loop would otherwise produce a hundred thousand identical lines and hide
		everything else. The count is what a bring-up session actually watches.
	**/
	public static function reportOnce(key:Int, what:String):Void {
		if (reported.exists(key)) return;
		reported.set(key, true);
		reportedGaps++;
		Backend.log(Backend.LOG_WARN, "unimplemented: " + what);
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
