package shim;

import js.Browser;
import js.html.Gamepad;
import js.html.KeyboardEvent;

/**
	The browser's keyboard and gamepads as PlayStation pads, through Haxe's browser externs.

	Only in a page. Under Node there is no window and no navigator, so no pad is connected — and a
	headless run never asks anyway: `sio.Pads` keeps every port empty while a digest is taken.

	Pad 0 is the keyboard merged with the first gamepad, pad 1 the second gamepad: the desktop
	backend's arrangement (backend_sdl2.c), and its key map — arrows for the d-pad, X S Z A for
	cross, square, triangle and circle, Q W for L1 R1, 1 2 for L2 R2, Enter for Start and right
	Shift for Select. Keys are matched by position (`KeyboardEvent.code`), so the buttons under a
	player's fingers do not move with the keyboard's language. Gamepads are read in the W3C
	"standard" mapping: face buttons 0-3, shoulders 4-7, select and start 8-9, stick clicks
	10-11, d-pad 12-15.

	The Gamepad API may be missing — browsers withhold it from pages that are not a secure
	context, which a page served to the LAN over plain HTTP is not — and the keyboard still works.
**/
class Input {
	// PS1 bits, active high: backend_c_api.h, bp_pad_buttons.
	static inline var SELECT = 0x0001;
	static inline var L3 = 0x0002;
	static inline var R3 = 0x0004;
	static inline var START = 0x0008;
	static inline var UP = 0x0010;
	static inline var RIGHT = 0x0020;
	static inline var DOWN = 0x0040;
	static inline var LEFT = 0x0080;
	static inline var L2 = 0x0100;
	static inline var R2 = 0x0200;
	static inline var L1 = 0x0400;
	static inline var R1 = 0x0800;
	static inline var TRIANGLE = 0x1000;
	static inline var CIRCLE = 0x2000;
	static inline var CROSS = 0x4000;
	static inline var SQUARE = 0x8000;

	static var attached = false;
	/** Held keys, as the events arrive. */
	static var keys = 0;
	/** The snapshot `poll` takes, which is all the runtime ever reads. */
	static var pad0 = 0;
	static var pad1 = 0;
	static var pad1Connected = false;

	/** Once per vblank, from `Backend.inputPoll`: a stable snapshot of both pads. */
	public static function poll():Void {
		if (Browser.supported) {
			if (!attached) attach();
			else {}
			var first = 0;
			var second = 0;
			var seen = 0;
			if (hasGamepads()) {
				for (g in Browser.navigator.getGamepads()) {
					if (g != null && g.connected) {
						if (seen == 0) first = gamepadButtons(g);
						else if (seen == 1) second = gamepadButtons(g);
						else {}
						seen++;
					} else {}
				}
			} else {}
			pad0 = keys | first;
			pad1 = second;
			pad1Connected = seen > 1;
		} else {}
	}

	/** Pad 0 is always there in a page — it is the keyboard — and pad 1 when a second gamepad is. */
	public static function connected(pad:Int):Bool {
		return Browser.supported && (pad == 0 || (pad == 1 && pad1Connected));
	}

	public static function buttons(pad:Int):Int {
		return pad == 0 ? pad0 : (pad == 1 ? pad1 : 0);
	}

	static function attach():Void {
		attached = true;
		final w = Browser.window;
		w.addEventListener("keydown", (e:KeyboardEvent) -> key(e, true));
		w.addEventListener("keyup", (e:KeyboardEvent) -> key(e, false));
		// A key let go while the page had no focus never sends its keyup, so forget them all.
		w.addEventListener("blur", () -> keys = 0);
	}

	static function key(e:KeyboardEvent, down:Bool):Void {
		final b = keyBit(e.code);
		if (b != 0) {
			// The d-pad keys would scroll the page, and Enter would press whatever has focus.
			e.preventDefault();
			keys = down ? (keys | b) : (keys & ~b);
		} else {}
	}

	static function keyBit(code:String):Int {
		return switch (code) {
			case "ArrowUp": UP;
			case "ArrowDown": DOWN;
			case "ArrowLeft": LEFT;
			case "ArrowRight": RIGHT;
			case "KeyX": CROSS;
			case "KeyS": SQUARE;
			case "KeyZ": TRIANGLE;
			case "KeyA": CIRCLE;
			case "KeyQ": L1;
			case "KeyW": R1;
			case "Digit1": L2;
			case "Digit2": R2;
			case "Enter": START;
			case "ShiftRight": SELECT;
			case _: 0;
		}
	}

	static function hasGamepads():Bool {
		return js.Syntax.field(Browser.navigator, "getGamepads") != null;
	}

	static function gamepadButtons(g:Gamepad):Int {
		var bits = 0;
		final b = g.buttons;
		for (i in 0...b.length) {
			if (b[i].pressed) bits |= standardBit(i);
			else {}
		}
		return bits;
	}

	/** The W3C standard mapping, button index to PS1 bit. */
	static function standardBit(i:Int):Int {
		return switch (i) {
			case 0: CROSS;
			case 1: CIRCLE;
			case 2: SQUARE;
			case 3: TRIANGLE;
			case 4: L1;
			case 5: R1;
			case 6: L2;
			case 7: R2;
			case 8: SELECT;
			case 9: START;
			case 10: L3;
			case 11: R3;
			case 12: UP;
			case 13: DOWN;
			case 14: LEFT;
			case 15: RIGHT;
			case _: 0;
		}
	}
}
