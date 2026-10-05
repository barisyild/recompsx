package sio;

/**
	Pad 0 played from a script instead of the host: real play on a machine nobody is at — a bench
	window of the cache model past a game's title screen, a headless digest of a level.

	`--pad-script F:B,F:B,...` (GenMain): from vblank F on, pad 0 holds B — button names joined by
	`+` (SELECT L3 R3 START UP RIGHT DOWN LEFT L2 R2 L1 R1 TRIANGLE CIRCLE CROSS SQUARE, and ANALOG,
	the DualShock's own button), `-` for none, or a number in hex (`0x4008`); frames in order. The
	option may be given more than once, and its parts are read as one script. While a script is set
	pad 0 is plugged in and the others are not, on every target and in a headless run too: a frame
	number and the buttons are all it reads, so two targets given one script see one pad, and their
	digests compare as they do without one.

	Pad 0 is a digital pad, unless `--pad-dualshock` makes it a DualShock (ADR-0052). Then an entry
	may give its sticks after a slash, LX.LY.RX.RY in hex (`600:CROSS/80.00.80.80` holds the left
	stick up); an entry without them has them centred.
**/
class PadScript {
	/** Whether a script is set (Pads.sample then reads it, not the host). */
	public static var active(default, null) = false;

	/** Whether the scripted pad is a DualShock rather than a digital pad (`--pad-dualshock`). */
	public static var dualShock = false;

	/** The script: from `frames[k]` on, pad 0 holds `states[k]`, its sticks `sticks[4k..4k+3]`. */
	static var frames:Array<Int> = [];
	static var states:Array<Int> = [];
	static var sticks:Array<Int> = [];
	static var next = 0;
	static var current = 0;
	/** The entry in effect, -1 before the first. */
	static var entry = -1;

	/** The names, in the order of their bits (backend_c_api.h, bp_pad_buttons). */
	static final NAMES = ["SELECT", "L3", "R3", "START", "UP", "RIGHT", "DOWN", "LEFT",
		"L2", "R2", "L1", "R1", "TRIANGLE", "CIRCLE", "CROSS", "SQUARE", "ANALOG"];

	/** Takes a script; false, and none set, when it does not read. */
	public static function parse(text:String):Bool {
		final f:Array<Int> = [];
		final s:Array<Int> = [];
		final a:Array<Int> = [];
		for (item in text.split(",")) {
			final colon = item.indexOf(":");
			if (colon <= 0) return false;
			else {}
			final frame = decimal(item.substr(0, colon));
			final rest = item.substr(colon + 1);
			final slash = rest.indexOf("/");
			final pressed = buttonsOf(slash < 0 ? rest : rest.substr(0, slash));
			if (frame < 0 || pressed < 0) return false;
			else {}
			if (f.length > 0 && frame < f[f.length - 1]) return false;
			else {}
			if (!sticksOf(slash < 0 ? "" : rest.substr(slash + 1), a)) return false;
			else {}
			f.push(frame);
			s.push(pressed);
		}
		frames = f;
		states = s;
		sticks = a;
		next = 0;
		current = 0;
		entry = -1;
		active = f.length > 0;
		return active;
	}

	/** How many changes the script makes. */
	public static function events():Int return frames.length;

	/** Pad 0's buttons at vblank `frame`, asked for in order. */
	public static function at(frame:Int):Int {
		while (next < frames.length && frames[next] <= frame) {
			current = states[next];
			entry = next;
			next++;
		}
		return current;
	}

	/** Stick axis `axis` (0 LX, 1 LY, 2 RX, 3 RY) of the entry `at` found last; 80h before the first. */
	public static function stick(axis:Int):Int return entry < 0 ? 0x80 : sticks[entry * 4 + axis];

	/** An entry's sticks, LX.LY.RX.RY in hex, onto `out`; centred for "". False when they do not read. */
	static function sticksOf(text:String, out:Array<Int>):Bool {
		var ok = true;
		if (text == "") {
			for (_ in 0...4) out.push(0x80);
		} else {
			final parts = text.split(".");
			if (parts.length != 4) ok = false;
			else {}
			for (k in 0...4) {
				final v = ok && parts[k].length <= 2 ? hexadecimal(parts[k]) : -1;
				if (v < 0) ok = false;
				else {}
				out.push(v & 0xFF);
			}
		}
		return ok;
	}

	static function buttonsOf(text:String):Int {
		if (text == "-") return 0;
		else {}
		if (StringTools.startsWith(text, "0x")) return hexadecimal(text.substr(2));
		else {}
		var mask = 0;
		for (name in text.split("+")) {
			var bit = -1;
			for (k in 0...NAMES.length) if (NAMES[k] == name) bit = k;
			else {}
			if (bit < 0) return -1;
			else {}
			mask |= 1 << bit;
		}
		return mask;
	}

	/** A non-negative decimal, or -1. */
	static function decimal(text:String):Int {
		if (text.length == 0 || text.length > 9) return -1;
		else {}
		var v = 0;
		for (k in 0...text.length) {
			final c = text.charCodeAt(k);
			if (c == null || c < 48 || c > 57) return -1;
			else {}
			v = v * 10 + (c - 48);
		}
		return v;
	}

	/** Sixteen bits of hex, or -1. */
	static function hexadecimal(text:String):Int {
		if (text.length == 0 || text.length > 4) return -1;
		else {}
		var v = 0;
		for (k in 0...text.length) {
			final c = text.charCodeAt(k);
			final d = c == null ? -1 : (c >= 48 && c <= 57 ? c - 48 : (c >= 97 && c <= 102 ? c - 87 : (c >= 65 && c <= 70 ? c - 55 : -1)));
			if (d < 0) return -1;
			else {}
			v = (v << 4) | d;
		}
		return v;
	}
}
