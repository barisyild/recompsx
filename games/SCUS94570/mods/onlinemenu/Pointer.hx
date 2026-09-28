package onlinemenu;

import mod.ModHost;

/**
	The mouse as this mod's screens read it (`kernel.KMouse`, ADR-0038): where the pointer is in
	the menus' units, and whether it moved or clicked since the screen last looked.

	The kernel counts moves and presses from boot, so every reader keeps the counts it last saw
	and a different count is news — two mods reading the mouse never take a click from each other.
	A screen that opens calls `sync` first, so that a click made before it existed (the one that
	opened it, say) is not taken as a click on it.
**/
class Pointer {
	public static var over(default, null) = false;
	/** Menu units: a 640 x 480 space centred on the screen (see `Game.pointerX`). */
	public static var x(default, null) = 0;
	public static var y(default, null) = 0;
	public static var moved(default, null) = false;
	public static var left(default, null) = false;
	/** Back: the right button, or the side button a browser calls Back. */
	public static var back(default, null) = false;

	static var seenMoves = 0;
	static var seenLeft = 0;
	static var seenRight = 0;
	static var seenBack = 0;

	/** Once per frame of a screen the mod drives. */
	public static function read():Void {
		over = ModHost.mouseOver();
		x = Game.pointerX();
		y = Game.pointerY();
		final m = ModHost.mouseMoves();
		final l = ModHost.mouseClicks(ModHost.MOUSE_LEFT);
		final r = ModHost.mouseClicks(ModHost.MOUSE_RIGHT);
		final b = ModHost.mouseClicks(ModHost.MOUSE_BACK);
		moved = over && m != seenMoves;
		left = over && l != seenLeft;
		back = over && (r != seenRight || b != seenBack);
		seenMoves = m;
		seenLeft = l;
		seenRight = r;
		seenBack = b;
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
}
