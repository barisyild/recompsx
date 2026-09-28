package sio;

/**
	The PS1's keyboard (ADR-0040). Sony made no retail one; this is the protocol psx-spx
	("Controllers - Keyboards") documents from the Lightspan Online Connection CD, the keyboard its
	PS/2 adaptor — Sony's SCPH-2000 is thought to be one — answers with. Polled with 01h, 42h and
	zeros, it answers ID 96h, 5Ah, then twelve bytes: how many scancode bytes follow (0..11), and
	those bytes — PS/2 Scan Code Set 2: a key's make code when it goes down, F0h and the code when
	it comes up.

	**It types what the host typed, as a US keyboard would.** The host's layout and input method
	have already made characters of the keys (bp_key_next), and each is sent as the presses that
	type it on a US keyboard — left Shift down if it needs it, its key down and up, Shift up — so a
	reader decoding US Set 2 gets exactly the character typed whatever the host's layout, and the
	editing keys as Enter (5Ah), Backspace (66h) and Escape (76h). What a US keyboard cannot type
	(ş, é) is not sent: no PS1 program could show it. A character goes whole or not at all, so a
	full buffer never leaves half a key.

	A unit is one keyboard plugged in for one reader (`plug`); each has its own buffer. In a
	headless run nothing is typed on it (`kernel.KKeyboard` takes nothing from the host there).
**/
class Ps2Keyboard {
	public static inline var ID = 0x96;
	public static inline var NONE = 0xFF;
	/** Data bytes a poll answers after the ID and 5Ah: the count and eleven bytes. */
	public static inline var REPLY = 12;
	/** Scancode bytes one poll carries. */
	public static inline var PER_POLL = 11;

	// Set 2 codes.
	public static inline var BREAK = 0xF0;
	public static inline var SHIFT = 0x12;
	public static inline var ENTER = 0x5A;
	public static inline var BACKSPACE = 0x66;
	public static inline var ESCAPE = 0x76;

	static inline var UNITS = 4;
	static inline var CAPACITY = 256;          // bytes waiting per unit; a power of two
	static inline var SHIFTED = 0x100;         // in `codes`: typed with Shift held

	static var plugged:Array<Int>;
	static var buffer:Array<Int>;              // UNITS * CAPACITY, a ring per unit
	static var head:Array<Int>;
	static var count:Array<Int>;
	/** Per ASCII character: its US key's Set 2 code, with SHIFTED; 0 for none. */
	static var codes:Array<Int>;
	static var data:Array<Int>;

	public static function init():Void {
		data = [for (_ in 0...REPLY) 0];
		plugged = [for (_ in 0...UNITS) 0];
		buffer = [for (_ in 0...UNITS * CAPACITY) 0];
		head = [for (_ in 0...UNITS) 0];
		count = [for (_ in 0...UNITS) 0];
		codes = [for (_ in 0...128) 0];
		keys("`1234567890-=", "~!@#$%^&*()_+", [0x0E, 0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46, 0x45, 0x4E, 0x55]);
		keys("qwertyuiop[]\\", "QWERTYUIOP{}|", [0x15, 0x1D, 0x24, 0x2D, 0x2C, 0x35, 0x3C, 0x43, 0x44, 0x4D, 0x54, 0x5B, 0x5D]);
		keys("asdfghjkl;'", "ASDFGHJKL:\"", [0x1C, 0x1B, 0x23, 0x2B, 0x34, 0x33, 0x3B, 0x42, 0x4B, 0x4C, 0x52]);
		keys("zxcvbnm,./", "ZXCVBNM<>?", [0x1A, 0x22, 0x21, 0x2A, 0x32, 0x31, 0x3A, 0x41, 0x49, 0x4A]);
		codes[" ".code] = 0x29;
	}

	/** One row of the US keyboard: each key's character alone and with Shift. */
	static function keys(plain:String, shifted:String, code:Array<Int>):Void {
		for (i in 0...code.length) {
			codes[charAt(plain, i)] = code[i];
			codes[charAt(shifted, i)] = code[i] | SHIFTED;
		}
	}

	/** An ASCII character's code (`charCodeAt` answers `Null<Int>`, as kernel.KSettings reads it). */
	static function charAt(s:String, i:Int):Int {
		final c:Null<Int> = s.charCodeAt(i);
		var v = 0;
		if (c != null) v = c & 0x7F;
		else {}
		return v;
	}

	/** Plugs a keyboard in for one reader; its unit, or -1 when all are taken. */
	public static function plug():Int {
		var unit = -1;
		for (u in 0...UNITS) {
			if (unit < 0 && plugged[u] == 0) unit = u;
			else {}
		}
		if (unit >= 0) {
			plugged[unit] = 1;
			head[unit] = 0;
			count[unit] = 0;
		} else {}
		return unit;
	}

	/** Drops what every unit has waiting. */
	public static function clear():Void {
		for (u in 0...UNITS) count[u] = 0;
	}

	/**
		Something the host typed — a Unicode code point, or backend_c_api.h's Backspace (8), Enter
		(10) or Escape (27) — as the US key presses that type it, into every plugged unit.
	**/
	public static function type(c:Int):Void {
		var code = 0;
		if (c == 8) code = BACKSPACE;
		else if (c == 10) code = ENTER;
		else if (c == 27) code = ESCAPE;
		else if (c >= 0x20 && c < 0x7F) code = codes[c];
		else {}
		if (code != 0) {
			for (u in 0...UNITS) {
				if (plugged[u] != 0) press(u, code);
				else {}
			}
		} else {}
	}

	/** A key's presses into one unit: Shift around it if it needs it; nothing if it will not fit. */
	static function press(u:Int, code:Int):Void {
		final shift = (code & SHIFTED) != 0;
		final key = code & 0xFF;
		if (count[u] + (shift ? 6 : 3) <= CAPACITY) {
			if (shift) put(u, SHIFT);
			else {}
			put(u, key);
			put(u, BREAK);
			put(u, key);
			if (shift) {
				put(u, BREAK);
				put(u, SHIFT);
			} else {}
		} else {}
	}

	static inline function put(u:Int, b:Int):Void {
		buffer[u * CAPACITY + ((head[u] + count[u]) & (CAPACITY - 1))] = b;
		count[u]++;
	}

	/**
		One transfer with a unit, as SIO0 makes it: `send[0..length)` out — address 01h, then 42h
		and zeros (the Online Connection CD sends 06h last) — and as many bytes back into `reply`:
		Hi-Z (FFh) under the address, then ID 96h, 5Ah and the `REPLY` data bytes. False, and FFh
		throughout, when nothing answers or the transfer is not a read.
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
		A poll of one unit: `reply[0]` the count of scancode bytes, `reply[1..11]` the bytes (zero
		past the count), and the ID back — `NONE`, and FFh bytes, when nothing answers.
	**/
	public static function read(unit:Int, reply:Array<Int>):Int {
		var id = NONE;
		if (unit >= 0 && unit < UNITS && plugged[unit] != 0) {
			kernel.KKeyboard.used();
			final n = count[unit] < PER_POLL ? count[unit] : PER_POLL;
			reply[0] = n;
			for (i in 0...PER_POLL) {
				if (i < n) reply[1 + i] = buffer[unit * CAPACITY + ((head[unit] + i) & (CAPACITY - 1))];
				else reply[1 + i] = 0;
			}
			head[unit] = (head[unit] + n) & (CAPACITY - 1);
			count[unit] = count[unit] - n;
			id = ID;
		} else {
			for (i in 0...REPLY) reply[i] = 0xFF;
		}
		return id;
	}
}
