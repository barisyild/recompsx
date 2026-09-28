package kernel;

import shim.Backend;
import shim.RawBuf;
import shim.RawMem;

/**
	The console's own settings: a few named values that outlive a session, kept by the HLE
	kernel for every game and every mod — the first thing this project's "PS1 Pro" adds to the
	BIOS, where a retail console has nothing (ADR-0034).

	One small text file through the backend's storage (`bp_storage_read`/`_write`, which the ABI
	reserves for "memory card images and configuration"): `system.cfg`, a line per value,
	`key=value`. Where it lives is the backend's business — a file beside the program, the browser's
	local storage, a card or an SD card on a console. It is not a game's save, and nothing is added
	to one: a game's memory card data stays exactly what the game wrote.

	A headless digest run neither reads nor writes it: a digest is a function of the disc and the
	frame count, as with the controllers (`sio.Pads`), so every such run sees no settings at all.
**/
class KSettings {
	public static inline var FILE = "system.cfg";
	static inline var CAPACITY = 4096;

	static var loaded = false;
	static var keys:Array<String>;
	static var values:Array<String>;
	static var buf:RawBuf;

	/** A setting's value, or "" when it has none. */
	public static function get(key:String):String {
		load();
		var found = "";
		var i = 0;
		while (i < keys.length) {
			if (keys[i] == key) found = values[i];
			else {}
			i++;
		}
		return found;
	}

	/**
		Sets and keeps a value. Keys are [a-z0-9._-]; a value is printable ASCII on one line, and
		anything else in it is dropped rather than allowed to break the file. False when the backend
		could not keep it (or in a digest run, which keeps nothing).
	**/
	public static function set(key:String, value:String):Bool {
		load();
		final clean = printable(value);
		var at = -1;
		var i = 0;
		while (i < keys.length) {
			if (keys[i] == key) at = i;
			else {}
			i++;
		}
		if (at >= 0) values[at] = clean;
		else {
			keys.push(key);
			values.push(clean);
		}
		return save();
	}

	static function load():Void {
		if (!loaded) {
			loaded = true;
			keys = [];
			values = [];
			buf = RawMem.alloc(CAPACITY);
			if (Kernel.haltAt == 0) {
				final n = Backend.storageRead(FILE, buf, CAPACITY);
				if (n > 0) parse(buf, n, keys, values);
				else {}
			} else {}
		} else {}
	}

	static function save():Bool {
		var ok = false;
		if (Kernel.haltAt == 0) {
			final n = serialize(keys, values, buf, CAPACITY);
			if (n >= 0) ok = Backend.storageWrite(FILE, buf, n) == 0;
			else {}
		} else {}
		return ok;
	}

	/** `key=value` lines into two lists; lines that are neither are skipped. */
	public static function parse(from:RawBuf, length:Int, keys:Array<String>, values:Array<String>):Void {
		var i = 0;
		while (i < length) {
			var end = i;
			while (end < length && RawMem.get8(from, end) != 10) end++;
			var eq = -1;
			var j = i;
			while (j < end) {
				if (eq < 0 && RawMem.get8(from, j) == "=".code) eq = j;
				else {}
				j++;
			}
			if (eq > i) {
				keys.push(text(from, i, eq));
				values.push(text(from, eq + 1, end));
			} else {}
			i = end + 1;
		}
	}

	/** The lists as `key=value` lines; the length written, or -1 if it would not fit. */
	public static function serialize(keys:Array<String>, values:Array<String>, into:RawBuf, capacity:Int):Int {
		var n = 0;
		var fits = true;
		var i = 0;
		while (i < keys.length) {
			final line = keys[i] + "=" + values[i];
			if (n + line.length + 1 > capacity) fits = false;
			else {
				for (k in 0...line.length) RawMem.set8(into, n + k, code(line, k));
				n += line.length;
				RawMem.set8(into, n, 10);
				n++;
			}
			i++;
		}
		var result = n;
		if (!fits) result = -1;
		else {}
		return result;
	}

	static function text(from:RawBuf, start:Int, end:Int):String {
		var s = "";
		var i = start;
		while (i < end) {
			final c = RawMem.get8(from, i);
			if (c >= 32 && c < 127) s += String.fromCharCode(c);
			else {}
			i++;
		}
		return s;
	}

	static function printable(s:String):String {
		var out = "";
		for (i in 0...s.length) {
			final c = code(s, i);
			if (c >= 32 && c < 127) out += String.fromCharCode(c);
			else {}
		}
		return out;
	}

	static function code(s:String, i:Int):Int {
		final c:Null<Int> = s.charCodeAt(i);
		var v = 0;
		if (c != null) v = c;
		else {}
		return v;
	}
}
