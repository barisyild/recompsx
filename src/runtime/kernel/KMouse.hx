package kernel;

import shim.Backend;

/**
	The host's mouse, on its way to the machine's own — the Sony Mouse, `sio.SonyMouse` (ADR-0040)
	— and the pointer the backend shows for it.

	It is sampled the way the controllers are (`sio.Pads`): once per vblank, right after the pads
	are latched, the backend says whether its pointer is over the picture, where as a fraction of
	it (0..65535 each way), and which buttons are held. This keeps the position in the pixels of
	the display the game has set up (`gpu.Scanout`) — the last place over the picture while the
	pointer is off it — which every mouse unit reports its motion toward, and hands the buttons to
	the units: the left one as the mouse's left, the right one and the side buttons as its right.

	**Our pointer shows while the mouse is in use**: while something polls a Sony Mouse — a mod
	that drives its game with the mouse does, every frame — the backend shows the machine's pointer
	(the art of pointer_art.h) over the picture, and in a game nothing reads the mouse for there is
	none. It hides while a pad is in use — a pad button pressed hides it, the mouse moving or
	clicking shows it again — and goes once no poll has come for half a second.

	A headless digest run has no mouse, as it has no controllers: nothing ever answers there.
**/
class KMouse {
	// The host's buttons (backend_c_api.h, BP_MOUSE_BUTTONS).
	public static inline var LEFT = 1;
	public static inline var RIGHT = 2;
	public static inline var MIDDLE = 4;
	/** The side buttons: back (nearer the wrist) and forward. */
	public static inline var BACK = 8;
	public static inline var FORWARD = 16;

	// The backend's fields (backend_c_api.h, BP_MOUSE_*).
	static inline var FIELD_OVER = 0;
	static inline var FIELD_X = 1;
	static inline var FIELD_Y = 2;
	static inline var FIELD_BUTTONS = 3;

	// The machine's pointer, as the backend is told it (backend_c_api.h, BP_POINTER_*).
	public static inline var POINTER_OFF = 0;
	public static inline var POINTER_SHOWN = 1;
	public static inline var POINTER_HIDDEN = 2;

	/** Vblanks a poll keeps the mouse in use for. */
	public static inline var IN_USE = 30;

	/** Whether the host's pointer is over the picture now. */
	public static var over(default, null) = false;
	/** Where it is over the picture, or last was: in the display's pixels, 0..width-1, 0..height-1. */
	public static var x(default, null) = 0;
	public static var y(default, null) = 0;
	/** The host's buttons held: LEFT, RIGHT, MIDDLE, BACK, FORWARD. */
	public static var buttons(default, null) = 0;
	/** The display the position is in. */
	public static var width(default, null) = 320;
	public static var height(default, null) = 240;
	/** Whether a pad has been used since the mouse was last touched (see above). */
	public static var hidden(default, null) = false;

	/** Whether the pointer has ever been over the picture: whether there is a mouse to answer. */
	static var seen = false;
	/** Whether the last sample moved the pointer or pressed a button. */
	static var touched = false;
	static var lastPads = 0;
	static var vblank = 0;
	static var usedAt = 0;
	static var told = 0;

	public static function init():Void {
		sio.SonyMouse.init();
		over = false;
		x = 0;
		y = 0;
		buttons = 0;
		width = 320;
		height = 240;
		hidden = false;
		seen = false;
		touched = false;
		lastPads = 0;
		vblank = 0;
		usedAt = -IN_USE - 1;
		told = POINTER_OFF;
	}

	/** Once per vblank, after the pads: what the backend says of its mouse. */
	public static function sample():Void {
		if (Kernel.haltAt == 0) {
			final mode = gpu.Gpu.displayModeBits();
			final on = Backend.mouse(FIELD_OVER) != 0;
			var fx = 0;
			var fy = 0;
			var held = 0;
			if (on) {
				fx = Backend.mouse(FIELD_X);
				fy = Backend.mouse(FIELD_Y);
				held = Backend.mouse(FIELD_BUTTONS);
			} else {}
			update(on, fx, fy, held, gpu.Scanout.width(mode), gpu.Scanout.height(mode));
			frame(sio.Pads.buttonsOf(0) | sio.Pads.buttonsOf(1));
		} else {}
	}

	/**
		One sample: over the picture or not, the position as fractions (0..65535), the buttons held,
		and the display's size. Tests feed it directly.
	**/
	public static function update(on:Bool, fx:Int, fy:Int, held:Int, w:Int, h:Int):Void {
		width = w;
		height = h;
		var nx = x;
		var ny = y;
		var nb = 0;
		if (on) {
			// At most 65535 x 640: well inside 31 bits.
			nx = ((fx & 0xFFFF) * w) >> 16;
			ny = ((fy & 0xFFFF) * h) >> 16;
			nb = held & 0x1F;
		} else {}
		// Where the pointer left a larger display, the one there is now holds it at its edge.
		if (nx >= w) nx = w - 1;
		else {}
		if (ny >= h) ny = h - 1;
		else {}
		if ((on && (!over || nx != x || ny != y)) || (nb & ~buttons) != 0) touched = true;
		else {}
		if (on) seen = true;
		else {}
		over = on;
		x = nx;
		y = ny;
		buttons = nb;
	}

	/**
		The rest of a vblank, after the sample: the mouse's units keep the buttons held, the pads
		just latched may hide the pointer, and the backend hears if it changed. Tests step with it.
	**/
	public static function frame(pads:Int):Void {
		vblank = (vblank + 1) | 0;
		sio.SonyMouse.latch(held());
		showOrHide(pads);
		tell();
	}

	/**
		After a sample: a pad button newly pressed hides the pointer, the mouse moving or clicking
		shows it (the mouse wins a sample that has both). True when that changed it. Tests call it.
	**/
	public static function showOrHide(pads:Int):Bool {
		final pressed = pads & ~lastPads;
		lastPads = pads;
		var hide = hidden;
		if (touched) hide = false;
		else if (pressed != 0) hide = true;
		else {}
		touched = false;
		final changed = hide != hidden;
		hidden = hide;
		return changed;
	}

	/** A Sony Mouse was polled (`sio.SonyMouse.read`): the mouse is in use. */
	public static function used():Void {
		usedAt = vblank;
		tell();
	}

	/** Whether there is a mouse to answer a poll. */
	public static inline function present():Bool return seen;

	/** The host's buttons as the Sony Mouse has them: `sio.SonyMouse.LEFT`, `RIGHT` (1 = held). */
	public static function held():Int {
		var b = 0;
		if ((buttons & LEFT) != 0) b = b | sio.SonyMouse.LEFT;
		else {}
		if ((buttons & (RIGHT | BACK | FORWARD)) != 0) b = b | sio.SonyMouse.RIGHT;
		else {}
		return b;
	}

	/** The machine's pointer as it should be now: POINTER_OFF, _SHOWN or _HIDDEN. */
	public static function pointer():Int {
		final inUse = ((vblank - usedAt) | 0) <= IN_USE;
		return !inUse ? POINTER_OFF : (hidden ? POINTER_HIDDEN : POINTER_SHOWN);
	}

	/** The backend hears of the pointer only when it changes. */
	static function tell():Void {
		final state = pointer();
		if (state != told) {
			told = state;
			Backend.mousePointer(state);
		} else {}
	}
}
