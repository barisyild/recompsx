package onlinemenu;

import core.CpuState;
import mod.ModHost;
import onlinemenu.Game;

/**
	An address keyboard in the look of the game's ENTER NAME screen, built in Select Game Type's
	own menu slot.

	The game's name keyboard is code in the adventure overlay, which shares the menus' window and
	is not resident while the main menu is: it cannot be borrowed, and it is not touched. This is
	the same screen made of the main menu's own materials — the title bar with its title, a box
	holding what has been typed, and a panel of keys seven to a row, 40 units apart as the name
	keyboard's are, with DONE and CANCEL beneath them — handed to the same builder as a list of
	records in mod memory. While it is up the mod runs the frame instead of Select Game Type's
	handler (keeping the platform and its character animating), and on DONE or CANCEL it builds
	the menu again.

	The keys are what an address needs: the digits, '.', and '<' — the name keyboard's own delete,
	drawn as an arrow. Only the address is typed: the port is the game's own (`Online.PORT`), and
	DONE tries that port at this address (ADR-0035: online is built per game, never netplay). The
	menu font has no '_', so the cursor is '-'.

	The machine's keyboard types too — the PS1 keyboard on a port of the mod's own
	(`ModHost.plugKeyboard`, ADR-0040), polled every frame this is open, which is what makes the
	host's keyboard type rather than play the pad meanwhile. It sends PS/2 Set 2 scancodes as a US
	keyboard types what the host typed, and this takes a digit or '.' as its key would type it,
	Backspace as '<', Enter as DONE and Escape as CANCEL; anything else is ignored, since this
	keyboard has no key for it. The pad keeps working beside it, and so does the mouse: pointing at
	a key selects it, a left click presses it, and back (the right button) is CANCEL.

	The last address DONE accepted is a console setting (`net.last_address`, kernel.KSettings,
	ADR-0034), so it outlives the session like a network setting on a console, beside — not
	inside — the game's own saves. The keyboard opens on it; CANCEL leaves it as it was.
**/
class IpKeyboard {
	/** "255.255.255.255". */
	public static inline var MAX = 15;

	// The keyboard: its ID, and the Set 2 codes this reads.
	static inline var KEYBOARD = 0x96;
	static inline var RELEASE = 0xF0;
	static inline var EXTENDED = 0xE0;
	static inline var LEFT_SHIFT = 0x12;
	static inline var RIGHT_SHIFT = 0x59;
	static inline var CODE_BACKSPACE = 0x66;
	static inline var CODE_ENTER = 0x5A;
	static inline var CODE_ESCAPE = 0x76;

	static var keyboard = -1;
	/** A read, as the Online Connection CD sends it: 01h, 42h, twelve zeros, 06h. */
	static var keyboardRead:Array<Int>;
	static var keyboardReply:Array<Int>;
	static var releasing = false;              // F0h came: the next code is a key let go
	static var extended = false;               // E0h came: the next code is an extended key
	static var shifted = false;                // a Shift is held

	// The list, in order; the builder makes the widgets in the same order.
	static inline var ENTRY_BOX = 0;
	static inline var KEY_PANEL = 1;
	static inline var BAR = 2;
	static inline var TITLE = 3;
	static inline var ENTRY = 4;
	static inline var HINT = 5;
	static inline var FIRST_KEY = 6;
	static inline var CHAR_KEYS = 12;
	static inline var DONE = CHAR_KEYS;                  // key indices, from FIRST_KEY
	static inline var CANCEL = CHAR_KEYS + 1;
	static inline var KEYS = CHAR_KEYS + 2;
	static inline var RECORDS = FIRST_KEY + KEYS + 1;    // and the end

	static inline var DELETE = 8;                        // what the '<' key types
	static inline var HINT_FRAMES = 120;

	// Where things go, as the menus place them. Everything is centred where Select Game Type's
	// own panel is (its lines are 8086h: centred at +134), clear of the character on the left.
	static inline var CENTRE = 134;
	static inline var BOX_X0 = CENTRE - 150;
	static inline var BOX_X1 = CENTRE + 150;
	static inline var ENTRY_Y = -78;
	static inline var ROW0_Y = -26;
	static inline var ROW_STEP = 36;
	static inline var KEY_STEP = 40;
	static inline var WORD_HALF = 70;                    // half of DONE's and CANCEL's width, for the mouse

	public static inline var SETTING = "net.last_address";

	public static var records(default, null) = 0;
	public static var accepted(default, null) = false;
	/** Whether the backend kept the address DONE accepted (a digest run keeps nothing). */
	public static var kept(default, null) = false;

	static var titleText = 0;
	public static var entryText(default, null) = 0;
	static var hintText = 0;
	static var badText = 0;
	static var fullText = 0;

	// Per key: its label in guest memory, what it types, and where it sits.
	static var label:Array<Int>;
	static var types:Array<Int>;
	static var keyX:Array<Int>;
	static var keyRow:Array<Int>;

	/** The address, one character code a slot; `length` of them are real. */
	static var chars:Array<Int>;
	static var length = 0;

	static var open = false;
	public static var selected(default, null) = 0;
	static var hintTimer = 0;
	static var hint = 0;

	public static function boot():Void {
		records = ModHost.alloc(RECORDS * Game.RECORD);
		titleText = ModHost.cstring("ENTER IP ADDRESS");
		entryText = ModHost.alloc(MAX + 2);
		hintText = ModHost.cstring("press start when done");
		badText = ModHost.cstring("that is not an address\nlike 192.168.1.20");
		fullText = ModHost.cstring("the address is full");
		label = [];
		types = [];
		keyX = [];
		keyRow = [];
		chars = [for (_ in 0...MAX) 0];
		length = 0;
		// The first row, seven keys; the second, four and the delete in the last column, where the
		// name keyboard keeps its own; then DONE and CANCEL, one to a row.
		final top = "1234567";
		for (i in 0...7) addKey(top.charCodeAt(i), i, 0);
		final second = "890.";
		for (i in 0...4) addKey(second.charCodeAt(i), i, 1);
		addKey(DELETE, 6, 1);
		addWord("DONE", 2);
		addWord("CANCEL", 3);
		open = false;
	}

	static function addKey(code:Null<Int>, column:Int, row:Int):Void {
		var c = 0;
		if (code != null) c = code;
		else {}
		var text = 0;
		if (c == DELETE) text = ModHost.cstring("<");
		else text = ModHost.cstring(String.fromCharCode(c));
		label.push(text);
		types.push(c);
		keyX.push(CENTRE - 120 + column * KEY_STEP);
		keyRow.push(row);
	}

	static function addWord(word:String, row:Int):Void {
		label.push(ModHost.cstring(word));
		types.push(0);
		keyX.push(CENTRE);
		keyRow.push(row);
	}

	public static inline function isOpen():Bool return open;

	/** When the mod installs: the keyboard, plugged into a port of the mod's own. */
	public static function install():Void {
		keyboardRead = [0x01, 0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x06];
		keyboardReply = [for (_ in 0...15) 0];
		keyboard = ModHost.plugKeyboard();
	}

	/** Builds the keyboard in slot 0, from the main menu's own records (`menu`, the mod's list). */
	public static function show(ctx:CpuState, menu:Int):Void {
		layOut(menu);
		restore();
		open = true;
		keysSync();
		Pointer.sync();
		accepted = false;
		kept = false;
		selected = 0;
		hintTimer = HINT_FRAMES;
		hint = hintText;
		writeEntry();
		Game.build(ctx, records);
	}

	static function layOut(menu:Int):Void {
		// Templates, by their place in the mod's menu list: 0 the panel, 1 a line, 5 the
		// description, 6 the title, 7 the title bar, 9 the end.
		panel(ENTRY_BOX, menu, BOX_X0, BOX_X1, -90, -48);
		panel(KEY_PANEL, menu, BOX_X0, BOX_X1, -40, 124);
		Game.copyRecord(records, BAR, menu, 7);
		Game.copyRecord(records, TITLE, menu, 6);
		ModHost.write32((Game.record(records, TITLE) + Game.RECORD_TEXT) | 0, titleText);
		text(ENTRY, menu, 1, CENTRE, ENTRY_Y, entryText);
		text(HINT, menu, 5, CENTRE, 150, hintText);
		for (k in 0...KEYS) {
			text(FIRST_KEY + k, menu, 1, keyX[k], ROW0_Y + keyRow[k] * ROW_STEP + keyGap(keyRow[k]), label[k]);
		}
		Game.copyRecord(records, RECORDS - 1, menu, 9);
	}

	/** The address last accepted, as the console keeps it; nothing if it is not one. */
	static function restore():Void {
		final saved = ModHost.setting(SETTING);
		length = 0;
		for (i in 0...saved.length) {
			if (length < MAX) {
				final c:Null<Int> = saved.charCodeAt(i);
				var v = 0;
				if (c != null) v = c;
				else {}
				chars[length] = v;
				length++;
			} else {}
		}
		if (!Address.valid(chars, length)) length = 0;
		else {}
	}

	/** DONE sits a little apart from the keys, as on the name keyboard. */
	static inline function keyGap(row:Int):Int return row >= 2 ? 6 : 0;

	static function panel(i:Int, menu:Int, x0:Int, x1:Int, y0:Int, y1:Int):Void {
		Game.copyRecord(records, i, menu, 0);
		final r = Game.record(records, i);
		ModHost.write16((r + Game.RECORD_X) | 0, x0);
		ModHost.write16((r + Game.RECORD_X1) | 0, x1);
		ModHost.write16((r + Game.RECORD_Y0) | 0, y0);
		ModHost.write16((r + Game.RECORD_Y1) | 0, y1);
	}

	static function text(i:Int, menu:Int, from:Int, x:Int, y:Int, what:Int):Void {
		Game.copyRecord(records, i, menu, from);
		final r = Game.record(records, i);
		ModHost.write16((r + Game.RECORD_X) | 0, Game.centred(x));
		ModHost.write16((r + Game.RECORD_Y) | 0, y);
		ModHost.write32((r + Game.RECORD_TEXT) | 0, what);
	}

	/** The typed address and its cursor, where the entry widget reads it every frame. */
	static function writeEntry():Void {
		var at = entryText;
		for (i in 0...length) {
			ModHost.write8(at, chars[i]);
			at = (at + 1) | 0;
		}
		if (length < MAX) {
			ModHost.write8(at, "-".code);
			at = (at + 1) | 0;
		} else {}
		ModHost.write8(at, 0);
	}

	/** One frame of the keyboard; false once DONE or CANCEL has closed it. */
	public static function frame(ctx:CpuState):Bool {
		ModHost.call(ctx, Game.MAIN_ANIMATE);
		// The game counts frames without pad input and, back in the menu, plays its demo past 900
		// of them — and typing on a keyboard is no pad input. Nobody is idle at a keyboard.
		ModHost.write32(Game.IDLE, 0);
		final edges = ModHost.read32(Game.PAD_EDGES);
		if ((edges & Game.PAD_LEFT) != 0) move(ctx, -1, 0);
		else if ((edges & Game.PAD_RIGHT) != 0) move(ctx, 1, 0);
		else if ((edges & Game.PAD_UP) != 0) move(ctx, 0, -1);
		else if ((edges & Game.PAD_DOWN) != 0) move(ctx, 0, 1);
		else {}
		if ((edges & Game.PAD_START) != 0) finish(ctx);
		else if ((edges & Game.PAD_TRIANGLE) != 0) close(ctx, false);
		else if ((edges & Game.PAD_SQUARE) != 0) press(ctx, DELETE);
		else if ((edges & Game.PAD_CROSS) != 0) activate(ctx);
		else {}
		keys(ctx);
		if (open) pointer(ctx);
		else {}
		if (open) paint();
		else {}
		return open;
	}

	/** Left and right along a row, round at its ends; up and down to the nearest key in x. */
	static function move(ctx:CpuState, dx:Int, dy:Int):Void {
		final row = keyRow[selected];
		var target = selected;
		if (dx != 0) {
			final first = firstOf(row), last = lastOf(row);
			target = selected + dx;
			if (target < first) target = last;
			else if (target > last) target = first;
			else {}
		} else {
			final to = row + dy;
			if (to >= 0 && to <= keyRow[KEYS - 1]) target = nearest(to, keyX[selected]);
			else {}
		}
		if (target != selected) {
			selected = target;
			Game.sound(ctx, Game.SOUND_MOVE);
		} else {}
	}

	static function firstOf(row:Int):Int {
		var k = 0;
		while (keyRow[k] != row) k++;
		return k;
	}

	static function lastOf(row:Int):Int {
		var k = KEYS - 1;
		while (keyRow[k] != row) k--;
		return k;
	}

	static function nearest(row:Int, x:Int):Int {
		var best = firstOf(row);
		for (k in firstOf(row)...lastOf(row) + 1) {
			if (abs(keyX[k] - x) < abs(keyX[best] - x)) best = k;
			else {}
		}
		return best;
	}

	static inline function abs(v:Int):Int return v < 0 ? -v : v;

	static function activate(ctx:CpuState):Void {
		if (selected == DONE) finish(ctx);
		else if (selected == CANCEL) close(ctx, false);
		else press(ctx, types[selected]);
	}

	/** The mouse: the key under the pointer is selected when it moves there, pressed on a click. */
	static function pointer(ctx:CpuState):Void {
		Pointer.read();
		final k = keyAt(Pointer.x, Pointer.y);
		if (k >= 0 && k != selected && (Pointer.moved || Pointer.left)) {
			selected = k;
			if (!Pointer.left) Game.sound(ctx, Game.SOUND_MOVE);
			else {}
		} else {}
		if (Pointer.left && k >= 0) activate(ctx);
		else if (Pointer.back) close(ctx, false);
		else {}
	}

	/** The key under a point in menu units: a band a row high, as wide as the key's step. */
	static function keyAt(x:Int, y:Int):Int {
		var found = -1;
		if (Pointer.over) {
			for (k in 0...KEYS) {
				final top = ROW0_Y + keyRow[k] * ROW_STEP + keyGap(keyRow[k]);
				var half = WORD_HALF;
				if (k < CHAR_KEYS) half = KEY_STEP >> 1;
				else {}
				if (y >= top - 4 && y < top + ROW_STEP - 4 && x >= keyX[k] - half && x < keyX[k] + half) found = k;
				else {}
			}
		} else {}
		return found;
	}

	/** A poll of the keyboard: what it typed since the last one, byte by byte. */
	static function keys(ctx:CpuState):Void {
		if (ModHost.exchange(keyboard, keyboardRead, 15, keyboardReply) && keyboardReply[1] == KEYBOARD) {
			final n = keyboardReply[3] <= 11 ? keyboardReply[3] : 0;
			for (i in 0...n) {
				if (open) scancode(ctx, keyboardReply[4 + i]);
				else {}
			}
		} else {}
	}

	/** A poll that takes nothing: what was typed before the keyboard opened is not typed into it. */
	static function keysSync():Void {
		ModHost.exchange(keyboard, keyboardRead, 15, keyboardReply);
		releasing = false;
		extended = false;
		shifted = false;
	}

	/** One Set 2 byte: F0h lets the next key go, E0h marks an extended one, a code is a key. */
	static function scancode(ctx:CpuState, b:Int):Void {
		if (b == RELEASE) {
			releasing = true;
		} else if (b == EXTENDED) {
			extended = true;
		} else {
			if (b == LEFT_SHIFT || b == RIGHT_SHIFT) shifted = !releasing;
			else if (!releasing && !extended) key(ctx, b);
			else {}
			releasing = false;
			extended = false;
		}
	}

	/** A key pressed on the machine's keyboard: taken if one of these keys types it, else ignored. */
	static function key(ctx:CpuState, code:Int):Void {
		final c = shifted ? -1 : typedBy(code);
		if (code == CODE_BACKSPACE) press(ctx, DELETE);
		else if (code == CODE_ENTER) finish(ctx);
		else if (code == CODE_ESCAPE) close(ctx, false);
		else if (c >= 0 && typedByKey(c)) press(ctx, c);
		else {}
	}

	/** What a US key types without Shift, of what this keyboard has: the digits and '.'; else -1. */
	static function typedBy(code:Int):Int {
		return switch (code) {
			case 0x16: "1".code;
			case 0x1E: "2".code;
			case 0x26: "3".code;
			case 0x25: "4".code;
			case 0x2E: "5".code;
			case 0x36: "6".code;
			case 0x3D: "7".code;
			case 0x3E: "8".code;
			case 0x46: "9".code;
			case 0x45: "0".code;
			case 0x49: ".".code;
			default: -1;
		}
	}

	static function typedByKey(c:Int):Bool {
		var found = false;
		for (k in 0...CHAR_KEYS) {
			if (types[k] == c) found = true;
			else {}
		}
		return found;
	}

	static function press(ctx:CpuState, code:Int):Void {
		if (code == DELETE) {
			if (length > 0) {
				length--;
				Game.sound(ctx, Game.SOUND_BACK);
			} else {}
		} else if (length < MAX) {
			chars[length] = code;
			length++;
			Game.sound(ctx, Game.SOUND_SELECT);
		} else {
			say(fullText);
		}
		writeEntry();
	}

	static function finish(ctx:CpuState):Void {
		if (Address.valid(chars, length)) close(ctx, true);
		else {
			Game.sound(ctx, Game.SOUND_BACK);
			say(badText);
		}
	}

	static function close(ctx:CpuState, keep:Bool):Void {
		accepted = keep;
		open = false;
		if (keep) kept = ModHost.setSetting(SETTING, address());
		else {}
		if (keep) Game.sound(ctx, Game.SOUND_SELECT);
		else Game.sound(ctx, Game.SOUND_BACK);
	}

	/**
		The game has left the menu under the keyboard (its demo, a reset): close it without keeping
		anything. Nothing polls the keyboard then, so the host's keyboard plays the pad again.
	**/
	public static function abandon():Void {
		if (open) {
			open = false;
			accepted = false;
		} else {}
	}

	static function say(what:Int):Void {
		hint = what;
		hintTimer = HINT_FRAMES;
	}

	/** The highlight on the selected key; the hint while its timer runs. */
	static function paint():Void {
		for (k in 0...KEYS) {
			var state = 0;
			if (k == selected) state = 2;
			else {}
			ModHost.write32((Game.widget(FIRST_KEY + k) + Game.WIDGET_STATE) | 0, state);
		}
		final w = Game.widget(HINT);
		final flags = ModHost.read32((w + Game.WIDGET_FLAGS) | 0);
		if (hintTimer > 0) {
			hintTimer--;
			ModHost.write32((w + Game.WIDGET_TEXT) | 0, hint);
			ModHost.write32((w + Game.WIDGET_FLAGS) | 0, flags | 0x8000);
		} else {
			ModHost.write32((w + Game.WIDGET_FLAGS) | 0, flags & ~0x8000);
		}
	}

	/** The address as typed, for what comes next; empty until DONE accepted one. */
	public static function address():String {
		var s = "";
		for (i in 0...length) s += String.fromCharCode(chars[i]);
		return s;
	}
}
