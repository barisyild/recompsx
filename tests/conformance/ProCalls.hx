import core.CpuState;
import kernel.KPro;

/**
	The "PS1 Pro" system calls (`kernel.KPro`, ADR-0060) as a program makes them — `syscall` with the
	function in $a0 — answered the same on every target: Identify's magic, the picture's scale read,
	set (held to 25..400) and read back, the lines a 240-line display is drawn at, a picture held for
	so many vblanks (held to 60) and counted down by the scanout, the screen's shape where no backend
	shows 16:9 (4:3 whatever is asked — 16:9, STRETCH — and pictures drawn for 16:9 not shown so), the
	scanout's flags for it, and an unknown PS1
	Pro number leaving $v0 as a retail kernel leaves it. A headless run keeps no setting, so nothing
	is written anywhere.
**/
class ProCalls {
	public static function main():Void {
		Conf.feedName("ProCalls");
		kernel.Kernel.haltAt = 1;
		final ctx = new CpuState();

		Conf.expect("identify", call(ctx, KPro.IDENTIFY, 0, 0), KPro.MAGIC);
		Conf.expect("unknown leaves v0", call(ctx, KPro.BASE + 0x7F, 0, 12345), 12345);
		Conf.expect("not ours: a retail number", call(ctx, 7, 0, 777), 777);
		Conf.expect("scale at boot", call(ctx, KPro.GET_VIDEO_SCALE, 0, 0), 100);
		Conf.expect("set 0.8", call(ctx, KPro.SET_VIDEO_SCALE, 80, 0), 80);
		Conf.expect("read back", call(ctx, KPro.GET_VIDEO_SCALE, 0, 0), 80);
		Conf.expect("set too small", call(ctx, KPro.SET_VIDEO_SCALE, 1, 0), 25);
		Conf.expect("set too large", call(ctx, KPro.SET_VIDEO_SCALE, 1000, 0), 400);
		// No backend scales here (KVideo.boot never ran): every scale draws the display's own 240.
		for (p in [0, 80, 100, 200, 300]) {
			final n = call(ctx, KPro.GET_VIDEO_LINES, p, 0);
			Conf.expect("lines at " + p, n, 240);
			Conf.feed(n);
		}
		Conf.expect("hold 10", call(ctx, KPro.HOLD_PICTURE, 10, 0), 10);
		var kept = 0;
		for (i in 0...3) if (kernel.KVideo.holdOne()) kept++;
		else {}
		Conf.expect("three vblanks held", kept, 3);
		Conf.expect("seven left", kernel.KVideo.held, 7);
		Conf.expect("hold too long", call(ctx, KPro.HOLD_PICTURE, 1000, 0), 60);
		Conf.expect("hold negative", call(ctx, KPro.HOLD_PICTURE, -5, 0), 0);
		Conf.expect("nothing held", kernel.KVideo.holdOne() ? 1 : 0, 0);
		// No backend shows 16:9 here: the screen stays 4:3, and a picture drawn for 16:9 is not shown so.
		Conf.expect("4:3 at boot", call(ctx, KPro.GET_WIDESCREEN, 0, 7), 0);
		Conf.expect("16:9 asked for", call(ctx, KPro.SET_WIDESCREEN, 1, 7), 0);
		Conf.expect("STRETCH asked for", call(ctx, KPro.SET_WIDESCREEN, 2, 7), 0);
		Conf.expect("still 4:3", call(ctx, KPro.GET_WIDESCREEN, 0, 7), 0);
		Conf.expect("wide picture not shown wide", call(ctx, KPro.SET_WIDE_PICTURE, 1, 7), 0);
		Conf.expect("the program's word kept", kernel.KVideo.widePicture ? 1 : 0, 1);
		Conf.expect("4:3 picture", call(ctx, KPro.SET_WIDE_PICTURE, 0, 7), 0);
		Conf.expect("a 4:3 screen", kernel.KVideo.wide() ? 1 : 0, 0);
		Conf.expect("nothing filled", kernel.KVideo.fills() ? 1 : 0, 0);
		// Nothing but $v0 moves.
		ctx.a2 = 0x1234; ctx.a3 = 0x5678; ctx.t1 = 0x9ABC;
		call(ctx, KPro.SET_VIDEO_SCALE, 200, 0);
		Conf.expect("a2 kept", ctx.a2, 0x1234);
		Conf.expect("a3 kept", ctx.a3, 0x5678);
		Conf.expect("t1 kept", ctx.t1, 0x9ABC);
		Conf.expect("a1 kept", ctx.a1, 200);
		Conf.report("ProCalls");
	}

	/** `syscall` with $a0 = fn, $a1 = arg and $v0 = before; what $v0 holds after. */
	static function call(ctx:CpuState, fn:Int, arg:Int, before:Int):Int {
		ctx.a0 = fn;
		ctx.a1 = arg;
		ctx.v0 = before;
		kernel.Kernel.syscall(ctx, 0);
		Conf.feed(ctx.v0);
		return ctx.v0;
	}
}
