package onlinemenu;

import mod.ModHost;

/**
	The mouse as this mod's screens read it: the machine's own, a Sony Mouse (SCPH-1030) on a port
	of the mod's (`ModHost.plugMouse`, ADR-0040) — where its cursor is in the menus' units, and
	whether it moved or clicked since the screen last looked.

	The mouse reports what any PS1 program gets from it: two buttons and the motion since the last
	poll. The cursor is kept here the way such a program keeps it — from the middle of the display,
	the motion added up, held inside the display — and that is where the host's pointer is, and
	where the machine shows its pointer while this polls. A click is a button down that was up at
	the last poll; back is the right button (the host's side buttons are it too). A screen that
	opens calls `sync` first, so that a click made before it existed (the one that opened it, say)
	is not taken as a click on it.
**/
class Pointer {
	/** Whether a mouse answers. */
	public static var over(default, null) = false;
	/** Menu units: a 640 x 480 space centred on the screen (see `Game.pointerX`). */
	public static var x(default, null) = 0;
	public static var y(default, null) = 0;
	public static var moved(default, null) = false;
	public static var left(default, null) = false;
	/** Back: the right button. */
	public static var back(default, null) = false;

	static inline var MOUSE = 0x12;            // the Sony Mouse's ID

	static var port = -1;
	/** A read, as the machine sends it: address 01h, 42h, and zeros under the four data bytes. */
	static var send:Array<Int>;
	static var reply:Array<Int>;
	/** The cursor, in the display's pixels. */
	static var cursorX = 0;
	static var cursorY = 0;
	static var wasLeft = false;
	static var wasRight = false;

	/** When the mod installs: the mouse, plugged into a port of the mod's own. */
	public static function install():Void {
		send = [0x01, 0x42, 0, 0, 0, 0, 0];
		reply = [0, 0, 0, 0, 0, 0, 0];
		port = ModHost.plugMouse();
		cursorX = ModHost.displayWidth() >> 1;
		cursorY = ModHost.displayHeight() >> 1;
	}

	/** Once per frame of a screen the mod drives: a poll of the mouse. */
	public static function read():Void {
		over = ModHost.exchange(port, send, 7, reply) && reply[1] == MOUSE;
		moved = false;
		left = false;
		back = false;
		if (over) {
			final dx = signed(reply[5]);
			final dy = signed(reply[6]);
			cursorX = inside(cursorX + dx, ModHost.displayWidth());
			cursorY = inside(cursorY + dy, ModHost.displayHeight());
			final l = (reply[4] & 8) == 0;         // bit 11 of the buttons: the left, 0 = pressed
			final r = (reply[4] & 4) == 0;         // bit 10: the right
			moved = dx != 0 || dy != 0;
			left = l && !wasLeft;
			back = r && !wasRight;
			wasLeft = l;
			wasRight = r;
		} else {}
		x = Game.pointerX(cursorX);
		y = Game.pointerY(cursorY);
	}

	/** Forgets whatever happened while nobody was reading. */
	public static function sync():Void {
		read();
		moved = false;
		left = false;
		back = false;
	}

	/** Anything at all: the player is at the machine, whatever the game's pad counter says. */
	public static inline function active():Bool return moved || left || back;

	static inline function signed(b:Int):Int return b >= 0x80 ? b - 0x100 : b;

	static inline function inside(v:Int, size:Int):Int return v < 0 ? 0 : (v >= size ? size - 1 : v);
}
