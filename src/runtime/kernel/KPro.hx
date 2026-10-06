package kernel;

import core.CpuState;

/**
	The "PS1 Pro" system calls (ADR-0060): what this HLE kernel offers a game beyond a retail BIOS,
	reached the PlayStation's own way — the `syscall` instruction with the function in $a0, arguments
	in $a1-$a3, the result in $v0 — so that a game, a homebrew program or a mod can ask for it.

	Sony's kernel defines SYSCALL functions 00h-03h only, and answers every other number by
	delivering event F0000010h/4000h and returning with every register as it was (psx-spx "BIOS
	Function Summary"; OpenBIOS handlers/syscall.c, MIT). So a PS1 Pro call is harmless on any
	PlayStation: there it does nothing, and $v0 keeps whatever the caller left in it. That is how a
	program finds out where it runs — zero $v0, call `IDENTIFY`, and only here is the answer `MAGIC`.

	The numbers are 50524F00h + n ("PRO" in the top three bytes), far from Sony's four:

	| $a0       | name            | arguments      | $v0                                              |
	|-----------|-----------------|----------------|--------------------------------------------------|
	| 50524F00h | Identify        | —              | 50524F31h ("PRO1"): PS1 Pro, these calls          |
	| 50524F10h | GetVideoScale   | —              | the picture's scale, percent of the PlayStation's |
	| 50524F11h | SetVideoScale   | $a1 percent    | the scale in effect now (25..400), kept           |
	| 50524F12h | GetVideoLines   | $a1 percent, 0 for the scale now | the lines the display is drawn at |
	| 50524F13h | HoldPicture     | $a1 vblanks, 0 to show again | the vblanks it is held for (at most 60) |
	| 50524F14h | GetWidescreen   | —              | the console's screen: 0 4:3, 1 16:9, 2 STRETCH   |
	| 50524F15h | SetWidescreen   | $a1 0, 1 or 2  | the shape now (0 where 16:9 cannot be shown), kept |
	| 50524F16h | SetWidePicture  | $a1 1 or 0     | 1: the program's wide pictures are shown on 16:9 |

	The video calls are the console's resolution setting (`kernel.KVideo`, ADR-0056): what a
	backend that draws the primitives itself renders them at. A game's options menu offers it:
	SetVideoScale on a choice, GetVideoLines for what to call it ("240P" at 100 on a 240-line
	display; the Dreamcast, which stops at 480 lines, answers 480 at 300). A program that then draws
	its picture anew keeps the old one on screen meanwhile with HoldPicture. The screen's shape is the
	console's too (ADR-0064): a menu offers 16:9 and STRETCH with SetWidescreen, and a program that
	draws for 16:9 — anamorphic, its horizontal squeezed by 3/4, when GetWidescreen answers 1 — says
	so with SetWidePicture; until it does, its pictures are shown at 4:3, between black bars on a 16:9
	screen, or stretched over it on STRETCH. docs/specs/ps1pro.md has the calls for a program to copy,
	in C and assembly.

	Every register but $v0 is left as it was, as the kernel's return from the exception leaves
	them; an unknown PS1 Pro number leaves $v0 too, as a retail kernel does, and is reported once.
**/
class KPro {
	public static inline var BASE = 0x50524F00;
	public static inline var MAGIC = 0x50524F31;

	public static inline var IDENTIFY = 0x50524F00;
	public static inline var GET_VIDEO_SCALE = 0x50524F10;
	public static inline var SET_VIDEO_SCALE = 0x50524F11;
	public static inline var GET_VIDEO_LINES = 0x50524F12;
	public static inline var HOLD_PICTURE = 0x50524F13;
	public static inline var GET_WIDESCREEN = 0x50524F14;
	public static inline var SET_WIDESCREEN = 0x50524F15;
	public static inline var SET_WIDE_PICTURE = 0x50524F16;

	/** Whether $a0 names a PS1 Pro call: 50524F00h..50524FFFh. */
	public static inline function isPro(fn:Int):Bool return (fn & 0xFFFFFF00) == BASE;

	/** A PS1 Pro `syscall`, the function in $a0 (Kernel.syscall sends it here). */
	public static function syscall(ctx:CpuState):Void {
		final fn = ctx.a0;
		if (fn == IDENTIFY) ctx.v0 = MAGIC;
		else if (fn == GET_VIDEO_SCALE) ctx.v0 = KVideo.scale;
		else if (fn == SET_VIDEO_SCALE) {
			KVideo.set(ctx.a1);
			ctx.v0 = KVideo.scale;
		} else if (fn == GET_VIDEO_LINES) {
			final percent = ctx.a1 == 0 ? KVideo.scale : ctx.a1;
			ctx.v0 = KVideo.linesAt(percent, gpu.Scanout.height(gpu.Gpu.displayModeBits()));
		} else if (fn == HOLD_PICTURE) {
			KVideo.hold(ctx.a1);
			ctx.v0 = KVideo.held;
		} else if (fn == GET_WIDESCREEN) ctx.v0 = KVideo.shape;
		else if (fn == SET_WIDESCREEN) {
			KVideo.setShape(ctx.a1);
			ctx.v0 = KVideo.shape;
		} else if (fn == SET_WIDE_PICTURE) {
			KVideo.setWidePicture(ctx.a1 != 0);
			ctx.v0 = KVideo.wide() && KVideo.widePicture ? 1 : 0;
		} else {
			core.Runtime.reportOnce(fn, "PS1 Pro syscall " + StringTools.hex(fn, 8) + " is not one");
		}
	}
}
