package kernel;

import shim.Backend;

/**
	The host's mouse, as the HLE kernel offers it: a pointer over the picture and its buttons —
	a "PS1 Pro" service beside the keyboard (ADR-0038).

	It is read the way the controllers are (`sio.Pads`): once per vblank, right after the pads are
	latched, the backend says whether the pointer is over the picture, where as a fraction of it
	(0..65535 each way), and which buttons are held. The kernel turns the fraction into the pixels
	of the display the game has set up (`gpu.Scanout`), so a reader works in the same pixels the
	game draws in, whatever window, canvas or television the backend put the picture on. A target
	with no mouse is never over the picture.

	Readers never take anything from each other: the kernel counts moves and presses from boot,
	and a reader keeps the counts it last saw — a different count is a move, or a click, since it
	last looked. That way a screen that is read every other vblank misses nothing, and two mods can
	watch the same mouse.

	A headless digest run has no mouse, as it has no controllers: nothing is ever over its picture.
**/
class KMouse {
	public static inline var LEFT = 1;
	public static inline var RIGHT = 2;
	public static inline var MIDDLE = 4;
	/** The side buttons: back (nearer the wrist) and forward. */
	public static inline var BACK = 8;
	public static inline var FORWARD = 16;
	static inline var BUTTONS = 5;

	// The backend's fields (backend_c_api.h, BP_MOUSE_*).
	static inline var FIELD_OVER = 0;
	static inline var FIELD_X = 1;
	static inline var FIELD_Y = 2;
	static inline var FIELD_BUTTONS = 3;

	/** Whether the pointer is over the picture. */
	public static var over(default, null) = false;
	/** Where, in the display's pixels: 0..width-1, 0..height-1. */
	public static var x(default, null) = 0;
	public static var y(default, null) = 0;
	/** The buttons held: LEFT, RIGHT, MIDDLE, BACK, FORWARD. */
	public static var buttons(default, null) = 0;
	/** The display the position is in. */
	public static var width(default, null) = 320;
	public static var height(default, null) = 240;
	/** Samples at which the pointer came onto the picture or moved on it, counted from boot. */
	public static var moves(default, null) = 0;

	/** Per button (0 left, 1 right, 2 middle, 3 back, 4 forward): its presses, counted from boot. */
	static var presses:Array<Int>;

	public static function init():Void {
		over = false;
		x = 0;
		y = 0;
		buttons = 0;
		width = 320;
		height = 240;
		moves = 0;
		presses = [0, 0, 0, 0, 0, 0, 0, 0];
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
		if (on && (!over || nx != x || ny != y)) moves = (moves + 1) | 0;
		else {}
		final down = nb & ~buttons;
		for (i in 0...BUTTONS) {
			if ((down & (1 << i)) != 0) presses[i] = (presses[i] + 1) | 0;
			else {}
		}
		over = on;
		x = nx;
		y = ny;
		buttons = nb;
	}

	/** Presses of button 0 (left), 1 (right), 2 (middle), 3 (back) or 4 (forward), counted from boot. */
	public static inline function clicks(button:Int):Int return presses[button & 7];
}
