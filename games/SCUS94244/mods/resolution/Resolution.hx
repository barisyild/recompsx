package resolution;

import core.CpuState;
import menu.Menu;
import menu.Pro;
import mod.ModHost;

/**
	RESOLUTION, an option in OPTIONS on the pause screen (ADR-0056): the picture's resolution, a
	multiplier of the PlayStation's own — 1, 2, 3 — said in lines, as the console will draw it: 240P at
	1 for a 240-line display, 480P, 720P. Nothing below the PlayStation's own is offered (the owner's call: no
	192P). Only what the console can draw is offered, and the list is the build's (`#if dreamcast`): the
	Dreamcast's screen has 480 lines, so a game built for it offers 1 and 2 — 240P and 480P — and every
	other build 1, 2 and 3. Scales a console draws at the same lines are one choice (a 480-line display
	at 2 and 3), so one that cannot scale has one; a scale in effect that draws lines none of them does
	— kept from elsewhere — is a choice too, in its place. Until a scale is chosen the console draws at
	its own, which the kernel takes from the backend: 240P in the browser, the screen's 480P on the
	Dreamcast.

	The resolution is not this mod's: it is the kernel's, a "PS1 Pro" system call any game may make
	(`kernel.KPro`, ADR-0060; docs/specs/ps1pro.md). The mod makes the calls a game would — `syscall`
	with the function in $a0 — through `menu.Pro`: Identify (on a console without the calls there are
	no choices, and no RESOLUTION), GetVideoLines for the choices and the one in effect, GetVideoScale for a
	scale kept from elsewhere, and SetVideoScale on a choice, which the kernel keeps as the console's
	setting and the backend draws at from the next frame.

	How it is shown and chosen is the menu mod's (`Menu.option`; this mod needs it): a button that opens
	its choices. After a choice the pause screen's frozen picture, drawn at the old scale, is drawn anew
	at the new one (`Menu.redraw`).
**/
class Resolution {
	/**
		The scales offered, in percent of the PlayStation's resolution, fixed by the build: the
		Dreamcast shows at most its screen's 480 lines, so 1 and 2 (240P, 480P); elsewhere 1, 2, 3.
	**/
	static final SCALES = #if dreamcast [100, 200] #else [100, 200, 300] #end;

	/** The choices, in order: the scale each sets, and the lines it draws. */
	static final scales:Array<Int> = [];
	static final drawn:Array<Int> = [];

	public static function install():Void {
		Menu.option(Menu.OPTIONS, "RESOLUTION", choices, current, choose);
	}

	/** The choices (see the class), offered by the lines each draws: none without the PS1 Pro calls. */
	static function choices(ctx:CpuState):Void {
		while (scales.length > 0) scales.pop();
		while (drawn.length > 0) drawn.pop();
		if (Pro.present(ctx)) {
			final now = Pro.call(ctx, Pro.GET_VIDEO_LINES, 0);
			var before = 0;
			for (i in 0...SCALES.length) {
				final lines = Pro.call(ctx, Pro.GET_VIDEO_LINES, SCALES[i]);
				if (now > before && now < lines) put(Pro.call(ctx, Pro.GET_VIDEO_SCALE, 0), now);
				else {}
				if (lines > before) {
					put(SCALES[i], lines);
					before = lines;
				} else {}
			}
			if (now > before) put(Pro.call(ctx, Pro.GET_VIDEO_SCALE, 0), now);
			else {}
		} else {}
	}

	/** A choice: its scale and the lines it draws, offered by them. */
	static function put(scale:Int, lines:Int):Void {
		scales.push(scale);
		drawn.push(lines);
		Menu.offer(Std.string(lines) + "P");
	}

	/** The choice in effect: the one that draws the lines the console draws now. */
	static function current(ctx:CpuState):Int {
		final now = Pro.call(ctx, Pro.GET_VIDEO_LINES, 0);
		var at = 0;
		for (i in 0...drawn.length) {
			if (drawn[i] == now) at = i;
			else {}
		}
		return at;
	}

	/**
		A choice: its scale kept and drawn at, and the pause screen's picture drawn anew at it — unless
		it draws the lines drawn now.
	**/
	static function choose(ctx:CpuState, at:Int):Void {
		if (drawn[at] != Pro.call(ctx, Pro.GET_VIDEO_LINES, 0)) {
			final set = Pro.call(ctx, Pro.SET_VIDEO_SCALE, scales[at]);
			ModHost.log("resolution: " + set + " %, " + Pro.call(ctx, Pro.GET_VIDEO_LINES, 0) + " lines");
			Menu.redraw();
		} else {}
	}
}
