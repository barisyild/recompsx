package onlinemenu;

import core.CpuState;
import mod.ModHost;

/**
	ONLINE, under BATTLE MODE in Crash Bash's Select Game Type menu (ADR-0033).

	The menu is data. The frontend overlay ("stage", at 800B32B4h) keeps each screen as a list of
	36-byte records — a panel, the lines, a description, the title, a banner, then a record of type
	0 — and hands the list to the builder in the boot overlay, which makes one widget per record.
	The screen's frame handler then moves a selection (0..3) with the pad, highlights line
	`selection + 1` and, on cross, switches on the selection. The facts are in
	games/SCUS94570/notes.md, "The main menu".

	So the mod does two things, and edits no code:

	- When the builder is handed the main menu's list, it is handed ours instead: the same
	  records, TOURNAMENT and OPTIONS a line lower, and ONLINE — a copy of BATTLE MODE's record —
	  appended after the banner, so that every widget the game addresses by number keeps it.
	- Around the frame handler, the mod keeps the five-line choice and sets the game's selection
	  so that the game's own up and down land where they should: the game plays the sound, starts
	  the description, and highlights; the mod then moves the highlight to ONLINE when that is
	  the choice. Cross on ONLINE is taken from the game, which never learns there is a fifth line.

	The mouse (ADR-0038) works here as the pad does: pointing at a line moves the selection to it
	— with the game's own move sound and description — a left click is cross on it, and the right
	button or the side button that means Back is triangle. Pointing moves the selection only when the pointer moves, so a mouse left
	resting on a line never fights the pad.

	Cross on ONLINE opens an address keyboard in the look of the game's ENTER NAME screen
	(`IpKeyboard`), in this same menu slot; DONE keeps the address and tries to connect to it on
	the game's own port (`Online`), CANCEL leaves it, and both come back here with ONLINE
	highlighted, the description saying what became of it. The game's own name keyboard, in the
	adventure overlay, is never touched: the builder hook changes nothing but the lists named below.
**/
class OnlineMenu {
	// The game's own addresses (notes.md, "The main menu").
	static inline var BUILD_MENU = 0x80095bec;      // boot: (slot a0, records a1)
	static inline var MAIN_FRAME = 0x800b3ca8;      // stage: Select Game Type, every frame
	static inline var MAIN_RECORDS = 0x800b8518;    // stage: the main menu's list
	static inline var ADVENTURE_TEXT = 0x800b333c;  // stage: what its first line says
	static inline var SELECTION = 0x800b95f0;       // stage: 0 adventure .. 3 options
	static inline var DESC_TIMER = 0x800b9624;      // stage: frames the description stays up
	static inline var PAD_EDGES = 0x80051380;       // buttons pressed this frame
	static inline var MENUS = 0x800a0e78;           // menu objects, 9Ch each; +6Ch its widgets

	static inline var RECORD = 36;
	static inline var RECORD_Y = 6;                 // halfword: a line's y
	static inline var RECORD_TEXT = 0x14;
	static inline var PANEL_HEIGHT = 0xA;           // halfword of the panel record
	static inline var WIDGET = 0xA8;
	static inline var WIDGET_TEXT = 0x6C;
	static inline var WIDGET_STATE = 0x7C;          // 0 plain, 2 highlighted
	static inline var STEP = 34;                    // the menu's own line spacing

	static inline var PAD_UP = 0x10;
	static inline var PAD_DOWN = 0x40;
	static inline var PAD_TRIANGLE = 0x1000;
	static inline var PAD_CROSS = 0x4000;
	static inline var RECORD_X0 = 4;                // a panel's x extent, halfwords
	static inline var RECORD_X1 = 6;

	// Records in the game's list: the panel, four lines, the description, title and banner.
	static inline var LINES = 8;
	static inline var BATTLE_LINE = 2;
	static inline var DESC_WIDGET = 5;
	// Ours: the same eight, ONLINE, the terminator.
	static inline var ONLINE_WIDGET = 8;
	static inline var OUR_RECORDS = 10;

	// The choice as the player sees it.
	static inline var ONLINE = 2;

	public static var records(default, null) = 0;
	static var onlineText = 0;
	static var aboutText = 0;
	static var resultText = 0;
	/** The online result `resultText` says (Online.IDLE.. ). */
	static var shown = 0;

	static var onMain = false;
	static var choice = 0;
	static var message = 0;
	/** Vblanks, and the last one Select Game Type's frame ran in (see `frame`). */
	static var vblanks = 0;
	static var lastFrame = 0;

	public static function install():Void {
		// The main menu and the address keyboard answer to the mouse and type on the keyboard: the
		// machine's own, on ports of the mod's (ADR-0040).
		Pointer.install();
		IpKeyboard.install();
		Online.install();
		ModHost.onBoot(boot);
		ModHost.onFrame(countVblank);
		ModHost.hook(BUILD_MENU, buildMenu);
		ModHost.hook(MAIN_FRAME, mainFrame);
	}

	static function boot(ctx:CpuState):Void {
		records = ModHost.alloc(OUR_RECORDS * RECORD);
		onlineText = ModHost.cstring("ONLINE");
		aboutText = ModHost.cstring("play against friends\nover the internet");
		resultText = ModHost.alloc(48);
		onMain = false;
		IpKeyboard.boot();
	}

	static function countVblank(ctx:CpuState):Void {
		vblanks = (vblanks + 1) | 0;
	}

	/**
		The builder: our list for the main menu's; the menu or the keyboard built again by us; and
		any other list — every other screen of the game, its name keyboard included — as it came.
		The game building a screen of its own in slot 0 means the keyboard, if it was up, is gone.
		Lists in other slots leave the main menu where it is: OPTIONS opens in slot 4 over it, and
		closing it builds nothing — Select Game Type simply runs again.
	**/
	static function buildMenu(ctx:CpuState, addr:Int):Bool {
		if (ctx.a0 != 0) {}
		else if (ctx.a1 == MAIN_RECORDS && isMainMenu()) {
			IpKeyboard.abandon();
			layOut();
			ctx.a1 = records;
			onMain = true;
			choice = 0;
			message = aboutText;
			Pointer.sync();
			ModHost.log("onlinemenu: Select Game Type built with ONLINE (records at "
				+ ModHost.hex(records) + ")");
		} else if (ctx.a1 == records || (ctx.a1 == IpKeyboard.records && IpKeyboard.isOpen())) {
			onMain = true;
		} else {
			IpKeyboard.abandon();
			onMain = false;
		}
		return false;
	}

	/** The list really is Select Game Type's: overlays take turns at these addresses. */
	static function isMainMenu():Bool {
		return ModHost.read32(MAIN_RECORDS) == 4
			&& ModHost.read32(MAIN_RECORDS + RECORD + RECORD_TEXT) == ADVENTURE_TEXT;
	}

	static function layOut():Void {
		copyRecord(0, 0);
		ModHost.write16(records + PANEL_HEIGHT, ModHost.read16s(records + PANEL_HEIGHT) + STEP);
		for (i in 1...LINES) copyRecord(i, i);
		// TOURNAMENT, OPTIONS and the description move down a line; ONLINE takes TOURNAMENT's.
		lower(3);
		lower(4);
		lower(DESC_WIDGET);
		copyRecord(ONLINE_WIDGET, BATTLE_LINE);
		ModHost.write32(records + ONLINE_WIDGET * RECORD + RECORD_TEXT, onlineText);
		ModHost.write16(records + ONLINE_WIDGET * RECORD + RECORD_Y,
			ModHost.read16s(MAIN_RECORDS + 3 * RECORD + RECORD_Y));
		copyRecord(OUR_RECORDS - 1, LINES);   // the game's terminator
	}

	static function copyRecord(to:Int, from:Int):Void {
		for (w in 0...9) {
			ModHost.write32(records + to * RECORD + w * 4, ModHost.read32(MAIN_RECORDS + from * RECORD + w * 4));
		}
	}

	static function lower(i:Int):Void {
		final at = records + i * RECORD + RECORD_Y;
		ModHost.write16(at, ModHost.read16s(at) + STEP);
	}

	/** Select Game Type's frame: the keyboard's while it is up, the menu's around the game's. */
	static function mainFrame(ctx:CpuState, addr:Int):Bool {
		var taken = false;
		if (onMain && IpKeyboard.isOpen()) {
			if (!IpKeyboard.frame(ctx)) closed(ctx);
			else {}
			taken = true;
		} else if (onMain) {
			frame(ctx, addr);
			taken = true;
		} else {}
		return taken;
	}

	/** Back from the keyboard: the menu again, on ONLINE, saying what became of the address. */
	static function closed(ctx:CpuState):Void {
		Game.build(ctx, records);
		Pointer.sync();
		choice = ONLINE;
		ModHost.write32(SELECTION, 1);
		if (IpKeyboard.accepted) {
			final address = IpKeyboard.address();
			ModHost.log("onlinemenu: online address " + address + (IpKeyboard.kept ? " (kept)" : " (not kept)"));
			Online.connect(address);
			shown = Online.result;
			writeText(resultText, Online.describe());
			message = resultText;
		} else {
			message = aboutText;
		}
		ModHost.write32(DESC_TIMER, 90);
		show(1);
	}

	static function writeText(at:Int, text:String):Void {
		for (i in 0...text.length) {
			var c:Null<Int> = text.charCodeAt(i);
			var v = 0;
			if (c != null) v = c;
			else {}
			ModHost.write8((at + i) | 0, v);
		}
		ModHost.write8((at + text.length) | 0, 0);
	}

	static function frame(ctx:CpuState, addr:Int):Void {
		// What the i-mode session has come to, as it comes to it.
		if (Online.result != shown) {
			shown = Online.result;
			writeText(resultText, Online.describe());
		} else {}
		// Back from a screen that ran instead (OPTIONS): what the mouse did there was for it.
		if (vblanks - lastFrame > 4) Pointer.sync();
		else {}
		lastFrame = vblanks;
		final real = ModHost.read32(PAD_EDGES);
		final edges = real | mouse(ctx);
		final before = choice;
		var pass = edges;
		if (before == ONLINE) {
			// From ONLINE the game's up has to reach BATTLE (its 2 -> 1) and its down TOURNAMENT
			// (1 -> 2); its cross is ours.
			if ((edges & PAD_UP) != 0) ModHost.write32(SELECTION, 2);
			else ModHost.write32(SELECTION, 1);
			pass = edges & ~PAD_CROSS;
		} else {}
		final selBefore = ModHost.read32(SELECTION);
		ModHost.write32(PAD_EDGES, pass);
		ModHost.callOriginal(ctx, addr);
		ModHost.write32(PAD_EDGES, real);

		final sel = ModHost.read32(SELECTION);
		choice = next(before, sel, sel != selBefore, edges);
		if (choice == ONLINE && before == ONLINE && (edges & PAD_CROSS) != 0) {
			// The keyboard replaces the menu in its slot; this frame's highlight is its own.
			Game.sound(ctx, Game.SOUND_SELECT);
			IpKeyboard.show(ctx, records);
		} else {
			if (choice != before) message = aboutText;
			else {}
			show(sel);
		}
	}

	/**
		This frame's mouse: pointing at a line selects it, and a click adds the button it stands
		for to the frame's pad — cross on the line pointed at, triangle for back.
	**/
	static function mouse(ctx:CpuState):Int {
		Pointer.read();
		var extra = 0;
		if (Pointer.active()) ModHost.write32(Game.IDLE, 0);
		else {}
		final line = lineAt(Pointer.x, Pointer.y);
		if (line >= 0 && line != choice && (Pointer.moved || Pointer.left)) jump(ctx, line);
		else {}
		if (Pointer.left && line >= 0) extra |= PAD_CROSS;
		else {}
		if (Pointer.back) extra |= PAD_TRIANGLE;
		else {}
		return extra;
	}

	/** The line (the player's 0..4) under the pointer: inside the panel, within a line's band. */
	static function lineAt(x:Int, y:Int):Int {
		var found = -1;
		final x0 = ModHost.read16s(records + RECORD_X0);
		final x1 = ModHost.read16s(records + RECORD_X1);
		if (Pointer.over && x >= x0 && x <= x1) {
			for (c in 0...5) {
				final top = ModHost.read16s(records + lineRecord(c) * RECORD + RECORD_Y);
				if (y >= top - 3 && y < top + STEP - 3) found = c;
				else {}
			}
		} else {}
		return found;
	}

	/** Which of our records holds the player's line `c`: ONLINE is the ninth, the others in order. */
	static inline function lineRecord(c:Int):Int {
		return c == ONLINE ? ONLINE_WIDGET : (c < ONLINE ? c + 1 : c);
	}

	/** Selects line `c` as the game's own up and down would: its sound, its description. */
	static function jump(ctx:CpuState, c:Int):Void {
		choice = c;
		var sel = c;
		if (c == ONLINE) sel = BATTLE_LINE - 1;       // the game stays on BATTLE; show() moves the highlight
		else if (c > ONLINE) sel = c - 1;
		else {}
		ModHost.write32(SELECTION, sel);
		ModHost.write32(DESC_TIMER, 90);
		message = aboutText;
		Game.sound(ctx, Game.SOUND_MOVE);
	}

	/** The line the player is on now, from the one before and what the game made of the pad. */
	static function next(before:Int, sel:Int, moved:Bool, edges:Int):Int {
		var c = sel;
		if (sel >= BATTLE_LINE) c = sel + 1;   // the game's 2 and 3 are the player's 3 and 4
		else {}
		if (before == ONLINE && !moved) c = ONLINE;
		else if (before == 1 && moved && (edges & PAD_DOWN) != 0) c = ONLINE;
		else if (before == 3 && moved && (edges & PAD_UP) != 0) c = ONLINE;
		else {}
		return c;
	}

	/** The highlight on the player's line, and ONLINE's own description. */
	static function show(sel:Int):Void {
		final widgets = ModHost.read32(MENUS + 0x6C);
		if (choice == ONLINE) {
			ModHost.write32(widgets + (sel + 1) * WIDGET + WIDGET_STATE, 0);
			ModHost.write32(widgets + ONLINE_WIDGET * WIDGET + WIDGET_STATE, 2);
			ModHost.write32(widgets + DESC_WIDGET * WIDGET + WIDGET_TEXT, message);
		} else {
			ModHost.write32(widgets + ONLINE_WIDGET * WIDGET + WIDGET_STATE, 0);
		}
	}
}
