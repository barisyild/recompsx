package kernel;

import shim.Backend;

/**
	The host's keyboard, as the HLE kernel offers it: typed text, a frame at a time — a device the
	PS1 never had, added the way this project's "PS1 Pro" adds things (ADR-0036).

	It is read the way the controllers are (`sio.Pads`): once per vblank, right after the pads are
	latched, the backend is asked what was typed since, and that waits here for whatever reads it
	— a game's mod today, a BIOS screen later. A target with no keyboard types nothing, and a
	reader cannot tell it from a keyboard nobody touches.

	**Text entry is asked for.** Where the keyboard also plays a pad (the browser and the desktop
	map keys onto pad 0), a letter must not be a button as well: typing `s` into a field would
	press square too. So a reader turns text entry on while its field is open and off after it;
	in between the backend's keyboard types, and only its arrows still steer. Nothing is queued
	while it is off.

	What comes out is a Unicode code point — whatever the host's layout and input method made of
	the keys — or `BACKSPACE`, `ENTER`, `ESCAPE`. Which characters mean anything is the reader's to
	decide: a field takes what its game can show and ignores the rest. Anything else a backend
	passes (other control codes, surrogates, beyond U+10FFFF) is dropped here, so no reader has to
	guard against it.

	A headless digest run has no keyboard, as it has no controllers: nothing is typed there.
**/
class KKeyboard {
	public static inline var BACKSPACE = 8;
	public static inline var ENTER = 10;
	public static inline var ESCAPE = 27;

	/** What waits; typing past it is dropped, as a full keyboard buffer drops keys. */
	static inline var CAPACITY = 64;

	static var queue:Array<Int>;
	static var head = 0;
	static var count = 0;
	static var entry = false;

	public static function init():Void {
		if (entry) Backend.keyText(false);
		else {}
		queue = [for (_ in 0...CAPACITY) 0];
		head = 0;
		count = 0;
		entry = false;
	}

	/** Starts or ends text entry (see above); what was waiting is dropped either way. */
	public static function textEntry(on:Bool):Void {
		if (on != entry) {
			entry = on;
			head = 0;
			count = 0;
			Backend.keyText(on);
		} else {}
	}

	/** Once per vblank, after the pads: what the backend typed since the last one. */
	public static function sample():Void {
		if (entry && Kernel.haltAt == 0) {
			var more = true;
			while (more && count < CAPACITY) {
				final c = Backend.keyNext();
				if (c < 0) more = false;
				else push(c);
			}
		} else {}
	}

	/**
		One thing typed, queued while text entry is on if it is a character or an editing key.
		Tests feed the queue through it directly.
	**/
	public static function push(c:Int):Void {
		if (entry && count < CAPACITY && typeable(c)) {
			queue[(head + count) & (CAPACITY - 1)] = c;
			count++;
		} else {}
	}

	/** The next thing typed, oldest first, or -1 when nothing is waiting. */
	public static function next():Int {
		var c = -1;
		if (count > 0) {
			c = queue[head];
			head = (head + 1) & (CAPACITY - 1);
			count--;
		} else {}
		return c;
	}

	static function typeable(c:Int):Bool {
		final editing = c == BACKSPACE || c == ENTER || c == ESCAPE;
		final control = c < 32 || c == 127 || (c >= 0x80 && c < 0xA0);
		final surrogate = c >= 0xD800 && c < 0xE000;
		return editing || (!control && !surrogate && c <= 0x10FFFF);
	}
}
