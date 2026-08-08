package kernel;

import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;

/**
	The PlayStation kernel, high-level emulated.

	This is the one part of the machine recompsx does not recompile. The BIOS is in ROM, not in
	the game, so there is nothing to translate — and reimplementing it natively means no BIOS image
	is ever needed, which is what lets a recompiled game be distributed as an ordinary program.

	Games reach it three ways, all of which land here: the A0/B0/C0 vectors (`jr` through a
	register holding 0xA0, with the function number in $t1), `syscall` for the handful of
	operations that use it, and `break` for the divide-by-zero guards Psy-Q emits.

	Function numbers and semantics come from psx-spx "BIOS Function Summary", with OpenBIOS
	(MIT, pcsx-redux `src/mips/openbios`) settling the numeric details psx-spx leaves in prose.
	Never from memory — golden rule 6. An unimplemented call reports once and returns, because a
	stub that halted would only ever show the first gap.
**/
class Kernel {
	public static function init():Void {
		KEvents.init();
		KHandlers.init();
	}

	/** A BIOS call through one of the three vectors. `fn` is the value in $t1. */
	public static function call(ctx:CpuState, vector:Int, fn:Int):Void {
		if (vector == 0xA0) a0(ctx, fn);
		else if (vector == 0xB0) b0(ctx, fn);
		else if (vector == 0xC0) c0(ctx, fn);
		else reportCall(ctx, vector, fn);
	}

	// ---- A0 ------------------------------------------------------------------------------------

	static function a0(ctx:CpuState, fn:Int):Void {
		// InitHeap(addr, size): the game gives the kernel a region of its own RAM to allocate in.
		if (fn == 0x39) KHeap.init(ctx.a0, ctx.a1);
		// FlushCache: nothing to do under static recompilation — there is no instruction fetch to
		// invalidate. Still worth logging: it marks where a game just copied code, so it is where
		// overlay activation will hook in at M6.
		else if (fn == 0x44) noteOnce(0xA0044, "A0(44h) FlushCache — no cache to flush");
		else reportCall(ctx, 0xA0, fn);
	}

	// ---- B0 ------------------------------------------------------------------------------------

	static function b0(ctx:CpuState, fn:Int):Void {
		if (fn == 0x07) ctx.v0 = deliverEvent(ctx);
		else if (fn == 0x08) ctx.v0 = KEvents.open(ctx, ctx.a0, ctx.a1, ctx.a2, ctx.a3);
		else if (fn == 0x09) ctx.v0 = KEvents.close(ctx, ctx.a0);
		else if (fn == 0x0A) ctx.v0 = KEvents.wait(ctx, ctx.a0);
		else if (fn == 0x0B) ctx.v0 = KEvents.test(ctx, ctx.a0);
		else if (fn == 0x0C) ctx.v0 = KEvents.enable(ctx, ctx.a0);
		else if (fn == 0x0D) ctx.v0 = KEvents.disable(ctx, ctx.a0);
		else if (fn == 0x20) ctx.v0 = undeliverEvent(ctx);
		else reportCall(ctx, 0xB0, fn);
	}

	static function deliverEvent(ctx:CpuState):Int {
		KEvents.deliver(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	static function undeliverEvent(ctx:CpuState):Int {
		KEvents.undeliver(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	// ---- C0 ------------------------------------------------------------------------------------

	static function c0(ctx:CpuState, fn:Int):Void {
		if (fn == 0x02) ctx.v0 = enqIntRP(ctx);
		else if (fn == 0x03) ctx.v0 = deqIntRP(ctx);
		else if (fn == 0x0A) ctx.v0 = changeClearRCnt(ctx);
		else reportCall(ctx, 0xC0, fn);
	}

	static function enqIntRP(ctx:CpuState):Int {
		KHandlers.enqueue(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	static function deqIntRP(ctx:CpuState):Int {
		KHandlers.dequeue(ctx, ctx.a0, ctx.a1);
		return 0;
	}

	/**
		`ChangeClearRCnt(timer, flag)` — whether the kernel's own handler acknowledges a timer IRQ.

		Returns the previous setting, which callers save and put back.
	**/
	static function changeClearRCnt(ctx:CpuState):Int {
		final t = ctx.a0 & 3;
		final was = clearRCnt[t] ? 1 : 0;
		clearRCnt[t] = ctx.a1 != 0;
		return was;
	}

	static var clearRCnt:Array<Bool> = [true, true, true, true];

	// ---- what the interrupt controller hands us -------------------------------------------------

	/**
		An interrupt reached the CPU: turn hardware bits into kernel events.

		On hardware this work is done by the BIOS's own handlers sitting in the priority chains.
		Under HLE those handlers are not game code, so the delivery is ours: the game's chains run
		first — they are the ones that may acknowledge the hardware — and whatever is still
		pending afterwards becomes an event.

		Called from `Irq.dispatch`, which has already saved the registers.
	**/
	public static function onInterrupt(ctx:CpuState):Void {
		KHandlers.runChains(ctx);
		deliverPending(ctx);
	}

	static function deliverPending(ctx:CpuState):Void {
		final live = Irq.stat & Irq.mask;
		if ((live & (1 << Irq.VBLANK)) != 0) vblank(ctx);
		else {}
	}

	/**
		Vblank: deliver the class, and acknowledge on the game's behalf.

		The kernel's own vblank handler acks the controller, so a game that only opened an event
		never has to touch I_STAT. Acknowledging here is what stops the same vblank being
		re-delivered on the next pump, forever.
	**/
	static function vblank(ctx:CpuState):Void {
		vblankCount++;
		heartbeat(ctx);
		KEvents.deliver(ctx, KEvents.CLASS_VBLANK, SPEC_INTERRUPTED);
		KEvents.deliver(ctx, CLASS_RCNT3, SPEC_INTERRUPTED);
		Irq.writeStat(~(1 << Irq.VBLANK));
	}

	/** The spec every hardware-interrupt event is opened with. */
	public static inline var SPEC_INTERRUPTED = 0x0002;

	/** Vblank doubles as root counter 3, which is what libetc's VSync actually waits on. */
	public static inline var CLASS_RCNT3 = 0xF2000003;

	/** Frames elapsed. Deterministic, and the first number a bring-up session watches. */
	public static var vblankCount(default, null) = 0;

	/**
		A line per emulated second, because a game's main loop never returns.

		Without it a bring-up run is silent once the startup log stops, and silence looks the same
		whether the machine is running a hundred frames a second or wedged in a spin. Every number
		here is deterministic, so two runs that disagree have diverged.
	**/
	static function heartbeat(ctx:CpuState):Void {
		if (vblankCount % 60 != 0) return;
		else {}
		core.Runtime.note("frame " + vblankCount
			+ " | events " + core.Scheduler.fired
			+ " | irqs " + core.Irq.delivered
			+ " | handlers " + KHandlers.calls
			+ " | delivered " + KEvents.delivered + "/" + KEvents.callbacks + "cb");
	}

	// ---- syscall / break -------------------------------------------------------------------------

	/**
		`syscall`.

		The function is selected by **$a0**, not by the instruction's 20-bit code field — compilers
		emit that field as 0 essentially always. Reporting the code field said "syscall 0" for
		every call, which is a diagnostic that cannot distinguish anything.
	**/
	public static function syscall(ctx:CpuState, code:Int):Void {
		if (ctx.a0 == 1) enterCritical(ctx);
		else if (ctx.a0 == 2) exitCritical(ctx);
		else Runtime.reportOnce(0x51000000 | (ctx.a0 & 0xFFFF), "syscall a0=" + ctx.a0);
	}

	/**
		`EnterCriticalSection` / `ExitCriticalSection`.

		**Not a nesting counter.** psx-spx is unambiguous: SYS(01h) clears SR bits and SYS(02h)
		sets them. There is no depth anywhere, and the return value is what makes that workable —
		Enter reports whether interrupts *were* on, so the caller can decide whether its own Exit
		should happen at all. Psy-Q code is written to that idiom.

		This started life as a counter here, on the reasoning that nesting ought to work properly.
		It cost an afternoon: Crash Bash enters four times, is told "were enabled" only on the
		first, exits once — and on real hardware that single exit turns interrupts back on, while
		the counter sat at three and delivered nothing for the rest of the run. Improving on the
		hardware is a bug whenever a game can tell, and the game could.

		The bit numbers psx-spx gives, 2 and 10, look wrong until you notice the BIOS runs this
		*inside* a syscall exception, where bit 2 is IEp — the value that becomes IEc on return.
		No exception is taken under HLE, so the equivalent is to drive IEc itself.
	**/
	static function enterCritical(ctx:CpuState):Void {
		ctx.v0 = (ctx.sr & Irq.SR_IEC) != 0 ? 1 : 0;
		ctx.sr = ctx.sr & ~(Irq.SR_IEC | Irq.SR_IM_HW);
		noteOnce(0x51000001, "SYS(01h) EnterCriticalSection");
	}

	static function exitCritical(ctx:CpuState):Void {
		ctx.sr = ctx.sr | Irq.SR_IEC | Irq.SR_IM_HW;
		noteOnce(0x51000002, "SYS(02h) ExitCriticalSection");
	}

	/** `break`. Psy-Q emits `break 0x400` after a divide as its divide-by-zero check. */
	public static function brk(ctx:CpuState, code:Int):Void {
		Runtime.reportOnce(0x52000000 | code, "break " + code);
	}

	// ---- plumbing -------------------------------------------------------------------------------

	static function reportCall(ctx:CpuState, vector:Int, fn:Int):Void {
		Runtime.reportOnce((vector << 16) | (fn & 0xFFFF), vectorName(vector) + "(" + hex2(fn) + ")");
	}

	static function noteOnce(key:Int, what:String):Void {
		Runtime.noteOnce(key, what);
	}

	static function vectorName(v:Int):String {
		if (v == 0xA0) return "A0";
		if (v == 0xB0) return "B0";
		if (v == 0xC0) return "C0";
		return "vector " + v;
	}

	static function hex2(v:Int):String {
		final digits = "0123456789abcdef";
		return "0x" + digits.charAt((v >> 4) & 0xF) + digits.charAt(v & 0xF);
	}
}
