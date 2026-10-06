package menu;

import core.CpuState;
import mod.ModHost;

/**
	The "PS1 Pro" system calls (`kernel.KPro`, ADR-0060; docs/specs/ps1pro.md) as the game's own
	`syscall` makes them, for the mods that put lines in its OPTIONS: the function in $a0, an argument
	in $a1, the answer in $v0. A console without them leaves $v0 as it was, so Identify is asked once
	and nothing else is asked where it does not answer.
**/
class Pro {
	public static inline var IDENTIFY = 0x50524F00;         // $v0 MAGIC on a PS1 Pro, untouched elsewhere
	public static inline var MAGIC = 0x50524F31;
	public static inline var GET_VIDEO_SCALE = 0x50524F10;  // $v0 the scale in effect, percent
	public static inline var SET_VIDEO_SCALE = 0x50524F11;  // $a1 percent; $v0 the scale in effect
	public static inline var GET_VIDEO_LINES = 0x50524F12;  // $a1 percent, 0 for now; $v0 lines
	public static inline var HOLD_PICTURE = 0x50524F13;     // $a1 vblanks the picture stays up, 0 to show again
	public static inline var GET_WIDESCREEN = 0x50524F14;   // $v0 the console's screen: 0 4:3, 1 16:9, 2 STRETCH
	public static inline var SET_WIDESCREEN = 0x50524F15;   // $a1 the shape; $v0 the shape now, kept
	public static inline var SET_WIDE_PICTURE = 0x50524F16; // $a1 1: pictures drawn for 16:9; $v0 1 shown so

	/** The console answered Identify: 1, it has the calls; 0, it does not; -1 before it was asked. */
	static var answered = -1;

	/** A new boot: Identify is asked again. */
	public static function boot():Void {
		answered = -1;
	}

	/** Whether this console has the PS1 Pro calls: asked once. */
	public static function present(ctx:CpuState):Bool {
		if (answered < 0) answered = call(ctx, IDENTIFY, 0) == MAGIC ? 1 : 0;
		else {}
		return answered == 1;
	}

	/**
		A system call as the game's own `syscall` makes it: the function in $a0, the argument in $a1,
		the answer in $v0 — zeroed first, since a console without the call leaves it as it was. The
		game's registers are put back around it: the hooks run inside its functions.
	**/
	public static function call(ctx:CpuState, fn:Int, arg:Int):Int {
		final a0 = ctx.a0;
		final a1 = ctx.a1;
		final v0 = ctx.v0;
		ctx.a0 = fn;
		ctx.a1 = arg;
		ctx.v0 = 0;
		ModHost.syscall(ctx);
		final answer = ctx.v0;
		ctx.a0 = a0;
		ctx.a1 = a1;
		ctx.v0 = v0;
		return answer;
	}
}
