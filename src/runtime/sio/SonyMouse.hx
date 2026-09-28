package sio;

/**
	The Sony Mouse (SCPH-1030): the PS1's own mouse, a controller-port device (psx-spx,
	"Controllers - Mouse"), and how the host's mouse reaches the emulated machine (ADR-0040).

	Polled like any controller (01h, 42h, then zeros), it answers ID 5A12h and two halfwords:

	    buttons  bits 0..7 always 1, 8..9 always 0, bit 10 the right button and bit 11 the left
	             (0 = pressed), 12..15 always 1
	    motion   the low byte across, the high byte down: signed counts, -80h..+7Fh, since the
	             last poll (right and down are positive)

	A button counts as pressed when it was held at any vblank since the last poll, so a click
	shorter than the reader's frame is never lost. The host's side buttons are the right one: the
	button that goes back.

	**Every unit keeps its reader on the host's pointer.** A unit is one mouse plugged in for one
	reader (`plug`) — a mod's own port today, a game's controller port later. Each keeps where its
	reader's cursor is taken to be: the middle of the display when it is plugged in, then the sum of
	what it has reported, kept inside the display. What it reports is the motion from there to where
	the host's pointer is over the picture, at most 7Fh a poll. So a reader that starts in the
	middle of the display, adds the motion up and keeps its cursor inside the display — as a PS1
	mouse program does — has its cursor where the host's pointer is, however often it polls and
	whoever else polls another unit; and the pointer the backend shows is right on it.

	No host mouse — none ever over the picture, as in a headless run — and nothing answers.
**/
class SonyMouse {
	/** The ID's low byte, the one a poll answers after Hi-Z; 5Ah follows it. */
	public static inline var ID = 0x12;
	/** What a poll gets when no device answers. */
	public static inline var NONE = 0xFF;
	/** The buttons halfword's bits, 0 while pressed. */
	public static inline var LEFT = 0x800;
	public static inline var RIGHT = 0x400;
	/** Data bytes a poll answers after the ID: the two halfwords. */
	public static inline var REPLY = 4;

	static inline var UNITS = 8;

	static var plugged:Array<Int>;
	static var cursorX:Array<Int>;
	static var cursorY:Array<Int>;
	/** Buttons held at any vblank since the unit's last poll (LEFT, RIGHT: 1 = pressed). */
	static var latched:Array<Int>;
	static var data:Array<Int>;

	public static function init():Void {
		data = [0, 0, 0, 0];
		plugged = [for (_ in 0...UNITS) 0];
		cursorX = [for (_ in 0...UNITS) 0];
		cursorY = [for (_ in 0...UNITS) 0];
		latched = [for (_ in 0...UNITS) 0];
	}

	/** Plugs a mouse in for one reader; its unit, or -1 when all are taken. */
	public static function plug():Int {
		var unit = -1;
		for (u in 0...UNITS) {
			if (unit < 0 && plugged[u] == 0) unit = u;
			else {}
		}
		if (unit >= 0) {
			plugged[unit] = 1;
			cursorX[unit] = kernel.KMouse.width >> 1;
			cursorY[unit] = kernel.KMouse.height >> 1;
			latched[unit] = 0;
		} else {}
		return unit;
	}

	/** Every vblank, from `kernel.KMouse`: the buttons held now, for every unit to keep. */
	public static function latch(held:Int):Void {
		for (u in 0...UNITS) latched[u] = latched[u] | held;
	}

	/**
		One transfer with a unit, as SIO0 makes it: `send[0..length)` out — address 01h, then 42h,
		the read — and as many bytes back into `reply`: Hi-Z (FFh) under the address, then ID 12h,
		5Ah and the `REPLY` data bytes, FFh past them. False, and FFh throughout, when no mouse
		answers or the transfer is not a read.
	**/
	public static function exchange(unit:Int, send:Array<Int>, length:Int, reply:Array<Int>):Bool {
		for (i in 0...length) reply[i] = 0xFF;
		var answered = false;
		if (length >= 2 && send[0] == 0x01 && send[1] == 0x42) {
			answered = read(unit, data) == ID;
			if (answered) {
				reply[1] = ID;
				if (length > 2) reply[2] = 0x5A;
				else {}
				for (i in 0...REPLY) {
					if (3 + i < length) reply[3 + i] = data[i];
					else {}
				}
			} else {}
		} else {}
		return answered;
	}

	/**
		A poll of one unit: its data bytes into `reply` (`REPLY` of them, as a transfer brings them
		after the ID and 5Ah), and the ID back — `NONE` when no mouse answers, the bytes then FFh.
	**/
	public static function read(unit:Int, reply:Array<Int>):Int {
		var id = NONE;
		if (unit >= 0 && unit < UNITS && plugged[unit] != 0 && kernel.KMouse.present()) {
			kernel.KMouse.used();
			final w = kernel.KMouse.width;
			final h = kernel.KMouse.height;
			final dx = step(kernel.KMouse.x - cursorX[unit]);
			final dy = step(kernel.KMouse.y - cursorY[unit]);
			cursorX[unit] = inside(cursorX[unit] + dx, w);
			cursorY[unit] = inside(cursorY[unit] + dy, h);
			final held = latched[unit] | kernel.KMouse.held();
			latched[unit] = 0;
			reply[0] = 0xFF;
			reply[1] = 0xF0 | ((held & LEFT) != 0 ? 0 : 8) | ((held & RIGHT) != 0 ? 0 : 4);
			reply[2] = dx & 0xFF;
			reply[3] = dy & 0xFF;
			id = ID;
		} else {
			for (i in 0...REPLY) reply[i] = 0xFF;
		}
		return id;
	}

	/** A motion count: what a poll can carry of a distance. */
	static inline function step(d:Int):Int return d > 127 ? 127 : (d < -128 ? -128 : d);

	static inline function inside(v:Int, size:Int):Int return v < 0 ? 0 : (v >= size ? size - 1 : v);
}
