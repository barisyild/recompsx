package kernel;

import shim.Backend;
import shim.IntMath;

/**
	The picture's resolution, a console setting of "PS1 Pro" (ADR-0034, ADR-0056): the scale at which
	a backend that draws the primitives itself (`gpu.Gpu.hw`, BP_CAP_GPU_DRAW) renders them, in percent
	of the PlayStation's own resolution — 80 is four fifths of it, 100 the PlayStation's, 200 twice,
	300 three times.

	It is kept as a multiplier, `video.scale` in `system.cfg` ("0.8", "1", "2", "3"), shared by every
	game, and it is only ever the picture's: VRAM, the digest and everything a game can read are the
	same at every scale. A headless run draws in software and reads no settings, so it never sees one.
	A backend that is handed the finished picture (SDL2's) cannot scale and keeps the PlayStation's
	resolution whatever the setting says; one that can draws at the scale, or at the most it is able
	to: the Dreamcast stops at its screen's 480 lines (BP_CAP_GPU_LINES), which is what a menu shows
	(`linesAt`).

	And the screen's shape (ADR-0064), the console's like the scale — `video.wide` in `system.cfg`:
	"0" 4:3, the PlayStation's; "1" 16:9; "2" 16:9 with the pictures stretched over it (STRETCH). A
	program says whether it draws its pictures for a 16:9 screen (`widePicture`, anamorphic: its
	horizontal squeezed by 3/4); none does until it says so. On 16:9 a picture drawn for 4:3 is shown
	at 4:3 between black bars, never stretched; on STRETCH every picture fills the screen, which is
	what a player who asked for it wants of a game drawn for 4:3. Presentation only, as the scale is:
	the scanout passes PRESENT_WIDE and PRESENT_WIDE_FILL, and nothing the machine does depends on
	them.
**/
class KVideo {
	public static inline var KEY = "video.scale";
	/** BP_CAP_GPU_SCALE: the scale a backend draws at until it is told one, in percent; 0 if it cannot scale. */
	static inline var CAP_GPU_SCALE = 8;
	/** BP_CAP_GPU_LINES: the most lines it draws a picture at; 0 for no limit. */
	static inline var CAP_GPU_LINES = 9;
	/** BP_CAP_WIDESCREEN: nonzero when a backend can show pictures on a 16:9 screen. */
	static inline var CAP_WIDESCREEN = 10;
	public static inline var WIDE_KEY = "video.wide";
	/** The screen's shapes, as `video.wide` and the PS1 Pro calls have them. */
	public static inline var NARROW = 0;
	public static inline var WIDE = 1;
	public static inline var STRETCH = 2;
	public static inline var MIN = 25;
	public static inline var MAX = 400;

	/** The scale chosen, in percent of the PlayStation's resolution. */
	public static var scale(default, null) = 100;

	/** The backend draws the primitives and can scale them: it hears of the scale. */
	static var scaling = false;
	/** The most lines it draws a picture at, 0 for no limit. */
	static var mostLines = 0;

	/** HoldPicture's most, in vblanks: a second at 60 Hz. */
	public static inline var HOLD_MOST = 60;
	/**
		Vblanks the picture on screen stays up for (the PS1 Pro call HoldPicture): a program drawing
		it anew — at a new scale, say — has its in-between frames kept off the screen. Presentation
		only: the scanout passes PRESENT_HOLD, and nothing the machine does depends on it.
	**/
	public static var held(default, null) = 0;

	/** The backend can show pictures on a 16:9 screen (BP_CAP_WIDESCREEN). */
	static var widescreen = false;
	/** The console's screen: NARROW, WIDE or STRETCH (the setting `video.wide`); NARROW on a backend
	    that cannot show 16:9. */
	public static var shape(default, null) = NARROW;
	/** The program draws its pictures for a 16:9 screen (SetWidePicture); 4:3 until it says so. */
	public static var widePicture(default, null) = false;

	/**
		The launcher, once it has decided how the picture is drawn (`drawing`: the backend draws the
		primitives): the scale kept as a setting, or the backend's own if none is — which need not be
		the PlayStation's: the Dreamcast draws at its screen's resolution unless told otherwise. The
		screen's shape is the one kept, and the program's pictures are drawn for 4:3 until it says.
	**/
	public static function boot(drawing:Bool):Void {
		final own = drawing ? Backend.caps(CAP_GPU_SCALE) : 0;
		scaling = own > 0;
		mostLines = scaling ? Backend.caps(CAP_GPU_LINES) : 0;
		final kept = parse(KSettings.get(KEY));
		if (kept > 0) {
			scale = kept;
			if (scaling) Backend.gpuScale(kept);
			else {}
		} else if (scaling) {
			scale = own;
		} else {}
		widescreen = Backend.caps(CAP_WIDESCREEN) != 0;
		final kept = KSettings.get(WIDE_KEY);
		shape = !widescreen ? NARROW : (kept == "1" ? WIDE : (kept == "2" ? STRETCH : NARROW));
		widePicture = false;
	}

	/**
		The screen's shape — NARROW, WIDE or STRETCH, anything else NARROW — kept as the console's
		setting; on a backend that cannot show 16:9 it stays NARROW and nothing is kept. What a menu
		offers (SetWidescreen).
	**/
	public static function setShape(to:Int):Void {
		if (widescreen) {
			shape = to == WIDE || to == STRETCH ? to : NARROW;
			KSettings.set(WIDE_KEY, Std.string(shape));
		} else {}
	}

	/** The program draws its pictures for a 16:9 screen from the next one (`on`), or for 4:3. */
	public static function setWidePicture(on:Bool):Void {
		widePicture = on;
	}

	/** The screen is 16:9: WIDE or STRETCH. */
	public static inline function wide():Bool return shape != NARROW;

	/** This picture fills the 16:9 screen: drawn for one, or stretched over it (STRETCH). */
	public static inline function fills():Bool return shape == STRETCH || (shape == WIDE && widePicture);

	/** Keep the picture on screen for `vblanks` (0 shows the next at once), at most HOLD_MOST. */
	public static function hold(vblanks:Int):Void {
		var n = vblanks;
		if (n < 0) n = 0;
		else {}
		if (n > HOLD_MOST) n = HOLD_MOST;
		else {}
		held = n;
	}

	/** One vblank of a hold, at the scanout: true when this one keeps the picture up. */
	public static function holdOne():Bool {
		final holding = held > 0;
		if (holding) held = (held - 1) | 0;
		else {}
		return holding;
	}

	/** A new scale, kept as the console's setting; a backend that scales draws at it from the next primitive. */
	public static function set(percent:Int):Void {
		var p = percent;
		if (p < MIN) p = MIN;
		else {}
		if (p > MAX) p = MAX;
		else {}
		scale = p;
		if (scaling) Backend.gpuScale(p);
		else {}
		KSettings.set(KEY, format(p));
	}

	/**
		The lines a display of `lines` lines is drawn at, at `percent`, by this backend: its own where
		the backend cannot scale, and never more than it can draw.
	**/
	public static function linesAt(percent:Int, lines:Int):Int {
		var n = lines;
		if (scaling) n = drawnLines(percent, lines, mostLines);
		else {}
		return n;
	}

	/** `lines` at `percent`, rounded, at most `most` (0: no limit) and at least one. */
	public static function drawnLines(percent:Int, lines:Int, most:Int):Int {
		var n = IntMath.div(lines * percent + 50, 100);
		if (most > 0 && n > most) n = most;
		else {}
		if (n < 1) n = 1;
		else {}
		return n;
	}

	/** "0.8", "1", "1.25", "2" ... as percent; 0 for anything else, or out of range. */
	public static function parse(text:String):Int {
		var whole = 0;
		var frac = 0;
		var digits = 0;
		var fracDigits = 0;
		var ok = text.length > 0;
		var point = false;
		for (i in 0...text.length) {
			final c:Null<Int> = text.charCodeAt(i);
			var v = -1;
			if (c != null) v = c;
			else {}
			final digit = v >= "0".code && v <= "9".code;
			if (digit && !point) {
				whole = whole * 10 + (v - "0".code);
				digits++;
			} else if (v == ".".code && !point) {
				point = true;
			} else if (digit && fracDigits < 2) {
				frac = frac * 10 + (v - "0".code);
				fracDigits++;
			} else {
				ok = false;
			}
		}
		if (fracDigits == 1) frac *= 10;
		else {}
		var percent = whole * 100 + frac;
		if (!ok || digits == 0 || digits > 2 || percent < MIN || percent > MAX) percent = 0;
		else {}
		return percent;
	}

	/** Percent as the setting writes it, a multiplier: 80 "0.8", 100 "1", 125 "1.25", 200 "2". */
	public static function format(percent:Int):String {
		final whole = IntMath.div(percent, 100);
		final frac = percent - whole * 100;
		var s = Std.string(whole);
		if (frac == 0) {}
		else if (frac - IntMath.div(frac, 10) * 10 == 0) s += "." + Std.string(IntMath.div(frac, 10));
		else if (frac < 10) s += ".0" + Std.string(frac);
		else s += "." + Std.string(frac);
		return s;
	}
}
