package kernel;

import core.CpuState;
import core.Runtime;
import mem.Memory;

/**
	Threads, and the non-local jumps that share their machinery.

	The PlayStation kernel's threads are cooperative and there are four of them. Nothing switches
	on its own: a game calls `ChangeTh` and the kernel swaps the register image. That makes them
	straightforward here — a thread is a saved `CpuState`, and switching is a copy.

	`setjmp` and `longjmp` belong in the same file because they are the same idea with a smaller
	register set, and because both have to answer the same awkward question: how does control get
	back somewhere it has already left, in a program whose stack is the host's?

	The answer is that it does not go back. `longjmp` restores the emulated registers, marks the
	unwind, and lets every native frame return; the top of the runtime then makes a *fresh* call to
	the address that was saved. The emulated `sp` and `ra` carry the real continuation, so the
	native stack being shallower afterwards changes nothing the game can observe — which is the
	whole reason the emulated state is kept in `CpuState` rather than in host locals.

	`jmp_buf` layout, from psx-spx and confirmed against OpenBIOS `kernel/setjmp.s` (MIT,
	Copyright (c) 2019 PCSX-Redux authors): twelve words, `ra sp fp s0..s7 gp`.
**/
class KThreads {
	// jmp_buf offsets.
	static inline var JB_RA = 0;
	static inline var JB_SP = 4;
	static inline var JB_FP = 8;
	static inline var JB_S0 = 12;   // s0..s7 run to +40
	static inline var JB_GP = 44;

	/** Threads the kernel offers. Four, as on hardware. */
	static inline var THREADS = 4;

	static var image:Array<CpuState>;
	static var used:Array<Bool>;
	static var current = 0;

	/** Non-zero once a longjmp is in flight; the resume address lives in `ctx.pc`. */
	public static var longjmps(default, null) = 0;

	public static function init():Void {
		image = [for (_ in 0...THREADS) new CpuState()];
		used = [for (i in 0...THREADS) i == 0];
		current = 0;
		longjmps = 0;
		hookEntries = 0;
	}

	// ---- setjmp / longjmp -----------------------------------------------------------------------

	/** `setjmp(buf)` — record where to come back to. Returns 0, as it must on the way in. */
	public static function setjmp(ctx:CpuState, buf:Int):Int {
		Memory.write32(buf + JB_RA, ctx.ra);
		Memory.write32(buf + JB_SP, ctx.sp);
		Memory.write32(buf + JB_FP, ctx.fp);
		Memory.write32(buf + JB_S0 + 0, ctx.s0);
		Memory.write32(buf + JB_S0 + 4, ctx.s1);
		Memory.write32(buf + JB_S0 + 8, ctx.s2);
		Memory.write32(buf + JB_S0 + 12, ctx.s3);
		Memory.write32(buf + JB_S0 + 16, ctx.s4);
		Memory.write32(buf + JB_S0 + 20, ctx.s5);
		Memory.write32(buf + JB_S0 + 24, ctx.s6);
		Memory.write32(buf + JB_S0 + 28, ctx.s7);
		Memory.write32(buf + JB_GP, ctx.gp);
		return 0;
	}

	/**
		`longjmp(buf, value)` — go back there, with `value` as setjmp's answer.

		Returning zero is not allowed by C, and the BIOS enforces it the same way every libc does:
		a request for 0 becomes 1, because otherwise the code at the landing site cannot tell it
		arrived by longjmp.
	**/
	public static function longjmp(ctx:CpuState, buf:Int, value:Int):Void {
		ctx.ra = Memory.read32(buf + JB_RA);
		ctx.sp = Memory.read32(buf + JB_SP);
		ctx.fp = Memory.read32(buf + JB_FP);
		ctx.s0 = Memory.read32(buf + JB_S0 + 0);
		ctx.s1 = Memory.read32(buf + JB_S0 + 4);
		ctx.s2 = Memory.read32(buf + JB_S0 + 8);
		ctx.s3 = Memory.read32(buf + JB_S0 + 12);
		ctx.s4 = Memory.read32(buf + JB_S0 + 16);
		ctx.s5 = Memory.read32(buf + JB_S0 + 20);
		ctx.s6 = Memory.read32(buf + JB_S0 + 24);
		ctx.s7 = Memory.read32(buf + JB_S0 + 28);
		ctx.gp = Memory.read32(buf + JB_GP);
		ctx.v0 = value != 0 ? value : 1;

		// Where to resume, and the flag that makes every frame between here and the top return.
		ctx.pc = ctx.ra;
		ctx.unwindToken = 1;
		longjmps++;
	}

	/**
		Enters a `JmpBuf` as the exception handler's exit does: restore its registers and go.

		Not a return — a jump. `HookEntryInt` hands the kernel a buffer of exactly the `setjmp`
		shape and the exception dispatcher leaves through it, which OpenBIOS makes explicit as
		`g_exceptionJmpBufPtr` (`kernel/handlers.c`, MIT): its default is a buffer whose `ra` is
		`returnFromException` on a dedicated stack, and installing a hook swaps that pointer for
		the game's own.

		So the hooked code runs on the stack the buffer names, with the saved-register set the
		buffer holds, and control arrives at `ra`. Everything the interrupt disturbed has already
		been put back by `Irq.dispatch` before this is called.
	**/
	public static function enterJmpBuf(ctx:CpuState, buf:Int):Void {
		ctx.sp = Memory.read32(buf + JB_SP);
		ctx.fp = Memory.read32(buf + JB_FP);
		ctx.s0 = Memory.read32(buf + JB_S0 + 0);
		ctx.s1 = Memory.read32(buf + JB_S0 + 4);
		ctx.s2 = Memory.read32(buf + JB_S0 + 8);
		ctx.s3 = Memory.read32(buf + JB_S0 + 12);
		ctx.s4 = Memory.read32(buf + JB_S0 + 16);
		ctx.s5 = Memory.read32(buf + JB_S0 + 20);
		ctx.s6 = Memory.read32(buf + JB_S0 + 24);
		ctx.s7 = Memory.read32(buf + JB_S0 + 28);
		ctx.gp = Memory.read32(buf + JB_GP);
		final target = Memory.read32(buf + JB_RA);
		if (target == 0) return;
		else {}
		hookEntries++;
		Runtime.call(ctx, target);
		// A hook that leaves through ReturnFromException has done its job; the token stops here
		// rather than unwinding past the dispatcher.
		if (ctx.unwindToken == Kernel.UNWIND_FROM_EXCEPTION) ctx.unwindToken = 0;
		else {}
	}

	/** How many times a game's exception hook has been entered. */
	public static var hookEntries(default, null) = 0;

	// ---- threads --------------------------------------------------------------------------------

	/**
		`OpenTh(pc, sp_fp, gp)` — a thread that is not running yet.

		Returns a handle of the form FF000000h + index, which is what `ChangeTh` expects back.
	**/
	public static function openTh(ctx:CpuState, pc:Int, spFp:Int, gp:Int):Int {
		for (i in 0...THREADS) {
			if (!used[i]) return startThread(i, pc, spFp, gp);
			else {}
		}
		Runtime.reportOnce(0x5B000000, "OpenTh with all " + THREADS + " threads in use");
		return -1;
	}

	static function startThread(i:Int, pc:Int, spFp:Int, gp:Int):Int {
		used[i] = true;
		final t = image[i];
		t.pc = pc;
		t.sp = spFp;
		t.fp = spFp;
		t.gp = gp;
		return 0xFF000000 | i;
	}

	public static function closeTh(ctx:CpuState, handle:Int):Int {
		final i = slotOf(handle);
		if (i < 0) return 0;
		else {}
		// Thread 0 is the one the game is running on and closing it is meaningless.
		if (i != 0) used[i] = false;
		else {}
		return 1;
	}

	/**
		`ChangeTh(handle)` — save this thread's registers and load another's.

		The switch itself is honest, but the *resumption* has the same shape as a longjmp: the new
		thread continues at its own `pc`, which is not where the host stack is. So it uses the same
		unwind, and the top of the runtime dispatches to the incoming thread's address.
	**/
	public static function changeTh(ctx:CpuState, handle:Int):Int {
		final i = slotOf(handle);
		if (i < 0 || !used[i]) return 0;
		else {}
		if (i == current) return 1;
		else {}
		copyInto(image[current], ctx);
		copyInto(ctx, image[i]);
		current = i;
		ctx.unwindToken = 1;
		return 1;
	}

	static function slotOf(handle:Int):Int {
		final i = handle & 0xFFFF;
		if ((handle & 0xFF000000) != 0xFF000000 || i >= THREADS) return badHandle(handle);
		else return i;
	}

	static function badHandle(handle:Int):Int {
		Runtime.reportOnce(0x5B000001, "thread handle that we did not hand out");
		return -1;
	}

	static function copyInto(dst:CpuState, src:CpuState):Void {
		dst.at = src.at;
		dst.v0 = src.v0; dst.v1 = src.v1;
		dst.a0 = src.a0; dst.a1 = src.a1; dst.a2 = src.a2; dst.a3 = src.a3;
		dst.t0 = src.t0; dst.t1 = src.t1; dst.t2 = src.t2; dst.t3 = src.t3;
		dst.t4 = src.t4; dst.t5 = src.t5; dst.t6 = src.t6; dst.t7 = src.t7;
		dst.s0 = src.s0; dst.s1 = src.s1; dst.s2 = src.s2; dst.s3 = src.s3;
		dst.s4 = src.s4; dst.s5 = src.s5; dst.s6 = src.s6; dst.s7 = src.s7;
		dst.t8 = src.t8; dst.t9 = src.t9;
		dst.k0 = src.k0; dst.k1 = src.k1;
		dst.gp = src.gp; dst.sp = src.sp; dst.fp = src.fp; dst.ra = src.ra;
		dst.hi = src.hi; dst.lo = src.lo;
		dst.pc = src.pc;
	}
}
