package kernel;

import core.CpuState;
import core.Runtime;

/**
	The PlayStation kernel, high-level emulated.

	This is the one part of the machine recompsx does not recompile. The BIOS is in ROM, not in
	the game, so there is nothing to translate — and reimplementing it natively means no BIOS
	image is ever needed, which is what lets a recompiled game be distributed as an ordinary
	program.

	Games reach it three ways, all of which land here: the A0/B0/C0 vectors (`jr` through a
	register holding 0xA0, with the function number in $t1), `syscall` for the handful of
	operations that use it, and `break` for the divide-by-zero guards Psy-Q emits.

	Unimplemented so far. Each call reports once with its vector and number, which is exactly the
	list a bring-up session works through — see docs/specs/runtime.md §3 for what P0 needs.
**/
class Kernel {
	/**
		A BIOS call through one of the three vectors. `fn` is the value in $t1.

		The kernel returns to $ra, exactly as a called function would, so an unimplemented call is
		survivable: it reports and the game carries on. That is deliberate — a stub that halted
		would only ever show the first gap, and the whole value of this stage is seeing the list.
	**/
	public static function call(ctx:CpuState, vector:Int, fn:Int):Void {
		if (vector == 0xA0) a0(ctx, fn);
		else reportCall(ctx, vector, fn);
	}

	/**
		The A0 vector.

		Function names and semantics are from psx-spx "BIOS Function Summary" — never from memory,
		per golden rule 6. Each one implemented here cites what it is; the rest report and return.
	**/
	static function a0(ctx:CpuState, fn:Int):Void {
		// FlushCache: "Flushes the Code Cache, so opcodes are ensured to be loaded from RAM".
		// Nothing to do under static recompilation — there is no instruction fetch to invalidate.
		// It is still a signal worth having: games call it right after copying code into RAM, so
		// it is where an overlay has just landed, and where overlay activation will hook in (M6).
		if (fn == 0x44) noteOnce(0xA0044, "A0(44h) FlushCache — no cache to flush");
		else reportCall(ctx, 0xA0, fn);
	}

	static function reportCall(ctx:CpuState, vector:Int, fn:Int):Void {
		Runtime.reportOnce((vector << 16) | (fn & 0xFFFF), vectorName(vector) + "(" + hex2(fn) + ")");
	}

	/** Reported once, like a gap, but as a thing handled rather than a thing missing. */
	static function noteOnce(key:Int, what:String):Void {
		Runtime.noteOnce(key, what);
	}

	/**
		`syscall`.

		The function is selected by **$a0**, not by the instruction's 20-bit code field — compilers
		emit that field as 0 essentially always. Reporting the code field therefore said "syscall 0"
		for every call the game made, which is a diagnostic that cannot distinguish anything.
		Both are reported now, with the one that decides the behaviour first.
	**/
	public static function syscall(ctx:CpuState, code:Int):Void {
		// psx-spx: SYS(01h) EnterCriticalSection disables interrupts by clearing SR bits 2 and 10;
		// SYS(02h) ExitCriticalSection sets them again. Under HLE the interrupt state that matters
		// is ours, so this is a depth counter: delivery is gated on it reaching zero, which lets
		// nested critical sections work the way the hardware's flag never had to.
		if (ctx.a0 == 1) enterCritical(ctx);
		else if (ctx.a0 == 2) exitCritical(ctx);
		else Runtime.reportOnce(0x51000000 | (ctx.a0 & 0xFFFF), "syscall a0=" + ctx.a0);
	}

	static function enterCritical(ctx:CpuState):Void {
		// v0 reports whether interrupts *were* enabled, which is what callers save and restore.
		ctx.v0 = ctx.critDepth == 0 ? 1 : 0;
		ctx.critDepth++;
		noteOnce(0x51000001, "SYS(01h) EnterCriticalSection");
	}

	static function exitCritical(ctx:CpuState):Void {
		// Never below zero: a game that exits more than it enters would otherwise leave the
		// counter negative and interrupts permanently gated off.
		if (ctx.critDepth > 0) ctx.critDepth--;
		else {}
		noteOnce(0x51000002, "SYS(02h) ExitCriticalSection");
	}

	/** `break`. Psy-Q emits `break 0x400` after a divide as its divide-by-zero check. */
	public static function brk(ctx:CpuState, code:Int):Void {
		Runtime.reportOnce(0x52000000 | code, "break " + code);
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
