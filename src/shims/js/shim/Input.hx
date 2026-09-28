package shim;

import js.Browser;
import js.html.Element;
import js.html.Gamepad;
import js.html.KeyboardEvent;
import js.html.PointerEvent;

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

	The keyboard also types, for the HLE kernel's keyboard (`kernel.KKeyboard`, ADR-0036), while
	text entry is on (`textEntry`): each key's character as the player's own layout makes it
	(`KeyboardEvent.key`, so a Turkish keyboard types ş and a French one é), and Backspace, Enter
	and Escape. Then only the arrows are still the d-pad — typing `s` never presses square too —
	and a key held when text entry ends becomes a button only when it is pressed again.

	The pointer is the HLE kernel's mouse (`kernel.KMouse`, ADR-0038), over the element the page
	shows the picture in (`recompsxHost.screen`): both renderers stretch the picture over that
	element's whole content box, so its edges are the picture's. A position is a fraction of it,
	0..65535, worked out in plain JavaScript so that no float reaches Haxe; a press counts until
	the next poll even when it was let go before; and over the picture the right button opens no
	context menu and the side buttons leave the page's history alone, since they are the game's.
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

	static inline var TYPED_CAPACITY = 64;
	/** Whether the keyboard types (`Backend.keyText`), and what it typed, oldest first. */
	static var typing = false;
	static var typed:Array<Int> = [];

	/** The pointer as its events leave it; `poll` takes the snapshot the runtime reads. */
	static var pointerOver = false;
	static var pointerX = 0;
	static var pointerY = 0;
	static var pointerHeld = 0;
	static var pointerPressed = 0;
	static var mouseOver = 0;
	static var mouseX = 0;
	static var mouseY = 0;
	static var mouseButtons = 0;
	/** The element the picture fills, once `attach` has found it. */
	static var screen:Null<Element> = null;
	/** The machine's pointer as the kernel last said (`showPointer`): 0 none, 1 shown, 2 hidden. */
	static var pointerState = 0;

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
			mouseOver = pointerOver ? 1 : 0;
			mouseX = pointerX;
			mouseY = pointerY;
			mouseButtons = pointerOver ? (pointerHeld | pointerPressed) : 0;
			pointerPressed = 0;
		} else {}
	}

	/** `bp_mouse`'s fields: over the picture, x and y as fractions of it, the buttons held. */
	public static function mouse(field:Int):Int {
		return switch (field) {
			case 0: mouseOver;
			case 1: mouseX;
			case 2: mouseY;
			case 3: mouseButtons;
			case _: 0;
		}
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
		w.addEventListener("blur", () -> {
			keys = 0;
			pointerHeld = 0;
		});
		screen = js.Syntax.code("((globalThis.recompsxHost && globalThis.recompsxHost.screen) || null)");
		final screen = Input.screen;
		if (screen != null) {
			screen.addEventListener("pointermove", (e:PointerEvent) -> point(screen, e));
			screen.addEventListener("pointerdown", (e:PointerEvent) -> press(screen, e, true));
			screen.addEventListener("pointerup", (e:PointerEvent) -> press(screen, e, false));
			screen.addEventListener("pointerleave", () -> {
				pointerOver = false;
				pointerHeld = 0;
			});
			// While the machine has a pointer its buttons are the game's: the right one opens no
			// context menu, and the side ones — the browser's Back and Forward, taken on the way
			// up — leave no page.
			screen.addEventListener("contextmenu", (e:PointerEvent) -> {
				if (pointerState != 0) e.preventDefault();
				else {}
			});
			for (kind in ["mousedown", "mouseup", "auxclick"]) {
				screen.addEventListener(kind, (e:PointerEvent) -> {
					if (pointerState != 0 && (e.button == 3 || e.button == 4)) e.preventDefault();
					else {}
				});
			}
			// Mods turn the mouse on as they install, before the first poll finds the box.
			showPointer(pointerState);
		} else {}
	}

	/**
		The machine's pointer over the picture (`Backend.mousePointer`, backend_c_api.h): 0 none —
		the page's own cursor — 1 shown, the class `pointer` whose cursor is the art, 2 hidden while
		a pad is in use, no cursor at all.
	**/
	public static function showPointer(state:Int):Void {
		pointerState = state;
		final screen = Input.screen;
		if (screen != null) {
			if (state == 1) screen.classList.add("pointer");
			else screen.classList.remove("pointer");
			screen.style.cursor = state == 2 ? "none" : "";
		} else {}
	}

	/** Where the pointer is, as fractions of the element's content box (0..65535). */
	static function point(screen:Element, e:PointerEvent):Void {
		pointerX = js.Syntax.code("Math.min(65535, Math.max(0, ((({1}).clientX - ({0}).getBoundingClientRect().left - ({0}).clientLeft) / ({0}).clientWidth * 65536) | 0))", screen, e);
		pointerY = js.Syntax.code("Math.min(65535, Math.max(0, ((({1}).clientY - ({0}).getBoundingClientRect().top - ({0}).clientTop) / ({0}).clientHeight * 65536) | 0))", screen, e);
		pointerOver = true;
	}

	static function press(screen:Element, e:PointerEvent, down:Bool):Void {
		point(screen, e);
		final bit = switch (e.button) {
			case 0: 1;
			case 2: 2;
			case 1: 4;
			case 3: 8;
			case 4: 16;
			case _: 0;
		}
		if (bit >= 8) e.preventDefault();
		else {}
		if (down) {
			pointerHeld |= bit;
			pointerPressed |= bit;
		} else {
			pointerHeld &= ~bit;
		}
	}

	static function key(e:KeyboardEvent, down:Bool):Void {
		var b = keyBit(e.code);
		if (typing && down) {
			final c = typedBy(e);
			if (c >= 0) {
				// What a key types is the field's, not the page's: no find-as-you-type, no scrolling
				// on space.
				e.preventDefault();
				if (typed.length < TYPED_CAPACITY) typed.push(c);
				else {}
			} else {}
			if (!isArrow(b)) b = 0;
			else {}
		} else if (down && e.repeat) {
			// A held key's button went down with its first press; its repeats press nothing more,
			// and a key held since text entry ended stays a key until it is pressed again.
			b = 0;
		} else {}
		if (b != 0) {
			// The d-pad keys would scroll the page, and Enter would press whatever has focus.
			e.preventDefault();
			keys = down ? (keys | b) : (keys & ~b);
		} else {}
	}

	/**
		What a key typed: a Unicode code point, or 8, 10, 27 for Backspace, Enter and Escape (the
		backend ABI's BP_KEY_*); -1 for a key that types nothing (Shift, F1, a dead key waiting for
		its letter) and for the browser's own shortcuts. AltGr — which Windows reports as Ctrl+Alt
		— still types: it is how many layouts reach '@'.
	**/
	static function typedBy(e:KeyboardEvent):Int {
		final k = e.key;
		final shortcut = (e.ctrlKey || e.metaKey) && !e.getModifierState("AltGraph");
		var c = -1;
		if (k == null || shortcut || e.isComposing) c = -1;
		else if (k == "Backspace") c = 8;
		else if (k == "Enter") c = 10;
		else if (k == "Escape") c = 27;
		else {
			// One character, not the name of a key: one UTF-16 unit, or two for a surrogate pair.
			final cp:Int = js.Syntax.code("({0}.codePointAt(0) | 0)", k);
			final units = cp >= 0x10000 ? 2 : 1;
			if (k.length == units) c = cp;
			else {}
		}
		return c;
	}

	static inline function isArrow(b:Int):Bool return b == UP || b == DOWN || b == LEFT || b == RIGHT;

	/** Text entry on or off (`Backend.keyText`); what was typed and not read is dropped. */
	public static function textEntry(on:Bool):Void {
		typing = on;
		typed = [];
	}

	/** The next thing typed, oldest first, or -1 (`Backend.keyNext`). */
	public static function nextTyped():Int {
		var c = -1;
		if (typed.length > 0) {
			final v = typed.shift();
			if (v != null) c = v;
			else {}
		} else {}
		return c;
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
