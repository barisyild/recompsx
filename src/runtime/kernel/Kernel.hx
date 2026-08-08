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
	/** A BIOS call through one of the three vectors. `fn` is the value in $t1. */
	public static function call(ctx:CpuState, vector:Int, fn:Int):Void {
		Runtime.reportOnce((vector << 16) | (fn & 0xFFFF), vectorName(vector) + "(" + hex2(fn) + ")");
		// The kernel returns to $ra, exactly as a called function would.
	}

	/** `syscall`. Code 0 is a general entry; 1 and 2 are Enter/ExitCriticalSection. */
	public static function syscall(ctx:CpuState, code:Int):Void {
		Runtime.reportOnce(0x51000000 | code, "syscall " + code);
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
