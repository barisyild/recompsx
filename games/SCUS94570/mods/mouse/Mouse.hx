package mouse;

import core.CpuState;
import mod.ModHost;
import shim.IntMath;

/**
	The mouse in Crash Bash's own menus (ADR-0038): point at a line, a portrait or a thumbnail and
	it is chosen, click it and it is taken, right-click or press the side (back) button to go back.

	**A choice is an index, and the mouse writes it.** Every screen keeps what is chosen as a number
	— Select Game Type 0..3 at 800B95F0h, SELECT NUMBER OF PLAYERS the players (1..4) at 8005A63Ah,
	the Adventure submenu 0..1 at 800B9628h, OPTIONS 0..2 at 800B9508h, CHARACTER SELECT each
	player's portrait 0..7 at +30h of its record (800B9FD4h + 60h per player), CHOOSE LEVEL the
	level at 8005A64Bh — and its frame handler draws the highlight, the marker or the arrow from that
	number every frame. So the mod writes the number of what the pointer is on, plays the move sound
	the game plays (190h; a player's own at character select), and for a click adds cross to the
	buttons the game read this frame — right after its pad reader (800138A4h), before any screen
	runs — so the screen's own handler takes it, as it would have taken the pad's. The facts are in
	games/SCUS94570/notes.md, "The mouse in the menus".

	What is on screen: menus are lists of widgets in nine slots (800A0E78h + slot * 9Ch, +6Ch the
	first), a text line flagged 10008000h, its x at +4 (8000h plus its centre), its top at +8 in the
	menus' 640 x 480 units, its state at +7Ch (0 plain, 2 highlighted, 3 not available). A list's
	lines share an x and follow each other at most 60 units apart — its title, at the same x, sits
	further off — and the n-th from the top is choice n. A slot counts while the screen it was built
	under is the menu screen manager's current one (8009F8A4h): OPTIONS opens in slot 4 over the
	main menu and, closed, leaves its widgets there. A list with any text in mod memory is a mod's
	screen (onlinemenu's main menu and address keyboard drive the mouse themselves) and is left
	alone. A list of a screen this mod does not know is still driven, by pressing down or up a step
	a frame until its highlight is under the pointer.

	With no menu up nothing is pressed, so gameplay and the demo never see a press from here. Any
	mouse activity zeroes the game's count of idle frames (80051604h), which would otherwise start
	the demo under a player using only the mouse.
**/
class Mouse {
	static inline var READ_PADS = 0x800138a4;
	static inline var BUILD_MENU = 0x80095bec;
	static inline var SOUND = 0x80022660;      // (id, 0, 0, 1000h; 1E00h, 0 on the stack)
	static inline var SOUND_MOVE = 0x190;
	static inline var SCREEN = 0x8009f8a4;     // the menu screen manager's current screen
	static inline var PAD_EDGES = 0x80051380;
	static inline var IDLE = 0x80051604;
	static inline var MENUS = 0x800a0e78;
	static inline var MENU = 0x9C;
	static inline var SLOTS = 9;               // menu objects up to the first widget, 800A13F4h
	static inline var FIRST = 0x6C;
	static inline var NEXT = 0x5C;
	static inline var X = 4;
	static inline var Y = 8;
	static inline var TEXT = 0x6C;
	static inline var STATE = 0x7C;
	static inline var KIND = 0x13008000;       // text, drawn — not a panel, not a model
	static inline var TEXT_LINE = 0x10008000;
	static inline var PLAIN = 0;
	static inline var SELECTED = 2;
	static inline var UNAVAILABLE = 3;
	static inline var MAX_WIDGETS = 40;
	static inline var NEIGHBOUR = 60;          // units from one line of a list to the next, at most

	static inline var UP = 0x10;
	static inline var DOWN = 0x40;
	static inline var TRIANGLE = 0x1000;
	static inline var CROSS = 0x4000;
	static inline var TAKEN = 0x50F0;          // the d-pad, cross and triangle: the pad's own presses

	static inline var GLYPH = 20;              // units a letter
	static inline var MARGIN = 16;
	static inline var ABOVE = 3;               // a line's band: from 3 above its top to 31 below
	static inline var BELOW = 31;
	static inline var PATIENCE = 6;            // frames a step may take to show before giving up
	static inline var MAX_STEPS = 16;

	// The lists this mod knows, by their screen's frame handler: where the choice is kept, in how
	// many bytes, what line 0 is stored as, and the description timer the game starts on a move.
	static var listFrames:Array<Int>;
	static var listChoices:Array<Int>;
	static var listBytes:Array<Int>;
	static var listFirst:Array<Int>;
	static var listTimers:Array<Int>;

	// CHARACTER SELECT (frame handler 800B6734h): the players' records, 60h each from 800B9FD4h —
	// +4 the pad, +24h 0 while still choosing, +30h the portrait — and each pad's move sound, a word
	// each from 800B9CB4h. Slot 0 holds the portraits as its fifth to twelfth widgets, placed from
	// the screen's top left in 640 x 480 units, each in a frame from 14 left of its x and 12 above
	// its y, 90 wide and 100 tall.
	static inline var CHARACTER_FRAME = 0x800b6734;
	static inline var PLAYERS = 0x800b9fd4;
	static inline var PLAYER_PAD = 4;
	static inline var PLAYER_STATE = 0x24;
	static inline var PLAYER_PORTRAIT = 0x30;
	static inline var PAD_SOUNDS = 0x800b9cb4;
	static inline var PORTRAITS = 8;
	static inline var FIRST_PORTRAIT = 4;
	// CHOOSE LEVEL (frame handler 800B7458h): the game state at 8005A614h keeps the arena at +36h and
	// the level at +37h (bytes); an arena's levels are counted at 800BA324h + 8 * arena + 4. The four
	// thumbnails are bands 99 units apart from -154, 135..290 across, in the menus' centred units;
	// the big preview is -287..91 across, -2..198 down.
	static inline var LEVEL_FRAME = 0x800b7458;
	static inline var GAME = 0x8005a614;
	static inline var ARENA = 0x36;
	static inline var LEVEL = 0x37;
	static inline var ARENA_LEVELS = 0x800ba324;
	static inline var LEVELS = 4;
	static inline var LEVEL_TOP = -154;
	static inline var LEVEL_STEP = 99;

	static var seenMoves = 0;
	static var seenLeft = 0;
	static var seenRight = 0;
	static var seenBack = 0;
	/** Per slot, the screen its list was built for. */
	static var builtFor:Array<Int>;
	static var list = 0;                       // the first widget of the lit line's list
	// The step-by-step fallback: the line the pointer wants lit, and whether to press cross there.
	static var target = 0;
	static var confirm = false;
	static var lastLit = 0;
	static var waited = 0;
	static var steps = 0;

	public static function install():Void {
		builtFor = [for (_ in 0...SLOTS) 0];
		listFrames = [0x800b3ca8, 0x800b3f7c, 0x800b42b0, 0x800b4910];
		listChoices = [0x800b95f0, 0x8005a63a, 0x800b9628, 0x800b9508];
		listBytes = [4, 1, 4, 4];
		listFirst = [0, 1, 0, 0];
		listTimers = [0x800b9624, 0, 0, 0];
		ModHost.hook(READ_PADS, readPads);
		ModHost.hook(BUILD_MENU, built);
	}

	/** The builder: which screen the slot's new list belongs to. */
	static function built(ctx:CpuState, addr:Int):Bool {
		if (ctx.a0 >= 0 && ctx.a0 < SLOTS) builtFor[ctx.a0] = ModHost.read32(SCREEN);
		else {}
		return false;
	}

	/** The pad reader: the game's first, then the mouse on top of what it read. */
	static function readPads(ctx:CpuState, addr:Int):Bool {
		ModHost.callOriginal(ctx, addr);
		drive(ctx);
		return true;
	}

	static function drive(ctx:CpuState):Void {
		final over = ModHost.mouseOver();
		final m = ModHost.mouseMoves();
		final l = ModHost.mouseClicks(ModHost.MOUSE_LEFT);
		final r = ModHost.mouseClicks(ModHost.MOUSE_RIGHT);
		final b = ModHost.mouseClicks(ModHost.MOUSE_BACK);
		final moved = over && m != seenMoves;
		final left = over && l != seenLeft;
		final back = over && (r != seenRight || b != seenBack);
		seenMoves = m;
		seenLeft = l;
		seenRight = r;
		seenBack = b;
		if (moved || left || back) ModHost.write32(IDLE, 0);
		else {}
		final screen = ModHost.read32(SCREEN);
		final frame = frameOf(screen);
		if (back && menuUp(screen)) {
			forget();
			press(TRIANGLE);
		} else if (frame == CHARACTER_FRAME) {
			characters(ctx, moved, left);
		} else if (frame == LEVEL_FRAME) {
			levels(ctx, moved, left);
		} else {
			final lit = highlighted(screen);
			if (lit == 0) forget();
			else lists(ctx, lit, frame, moved, left);
		}
	}

	static function frameOf(screen:Int):Int return inRam(screen) ? ModHost.read32((screen + 4) | 0) : 0;

	/** A menu of the game's is up: a live list, or one of the two picture screens. */
	static function menuUp(screen:Int):Bool {
		final frame = frameOf(screen);
		return frame == CHARACTER_FRAME || frame == LEVEL_FRAME || highlighted(screen) != 0;
	}

	// ---- lists ----------------------------------------------------------------------------------------

	static function lists(ctx:CpuState, lit:Int, frame:Int, moved:Bool, left:Bool):Void {
		final known = knownList(frame);
		final pointed = lineAt(lit, pointerX(), pointerY());
		if (known >= 0) {
			if (pointed != 0 && (moved || left)) {
				if (pointed != lit) choose(ctx, known, indexOf(pointed, lit));
				else {}
				if (left) press(CROSS);
				else {}
			} else {}
		} else {
			stepToward(lit, pointed, moved, left);
		}
	}

	static function knownList(frame:Int):Int {
		var found = -1;
		for (i in 0...listFrames.length) {
			if (listFrames[i] == frame) found = i;
			else {}
		}
		return found;
	}

	/** Line `index` of a known list becomes the choice, with the sound and description of a move. */
	static function choose(ctx:CpuState, known:Int, index:Int):Void {
		final value = index + listFirst[known];
		if (listBytes[known] == 1) ModHost.write8(listChoices[known], value);
		else ModHost.write32(listChoices[known], value);
		if (listTimers[known] != 0) ModHost.write32(listTimers[known], 90);
		else {}
		sound(ctx, SOUND_MOVE);
	}

	/** Which line of its list `w` is, counting from the top, the lines not available included. */
	static function indexOf(w:Int, lit:Int):Int {
		final y = ModHost.read16s((w + Y) | 0);
		var above = 0;
		var v = list;
		var n = 0;
		while (inRam(v) && n < MAX_WIDGETS) {
			if (inList(v, lit, true) && ModHost.read16s((v + Y) | 0) < y) above++;
			else {}
			v = ModHost.read32((v + NEXT) | 0);
			n++;
		}
		return above;
	}

	/** The fallback for a list this mod does not know: a step a frame, cross once it is lit. */
	static function stepToward(lit:Int, pointed:Int, moved:Bool, left:Bool):Void {
		final real = ModHost.read32(PAD_EDGES);
		if ((real & TAKEN) != 0) forget();
		else {}
		if (pointed != 0 && (moved || left)) {
			target = pointed;
			confirm = left;
			lastLit = lit;
			waited = 0;
			steps = 0;
		} else {}
		if (target != 0) {
			if (lit == target) {
				if (confirm) press(CROSS);
				else {}
				forget();
			} else {
				if (lit != lastLit) {
					waited = 0;
					lastLit = lit;
				} else {
					waited++;
				}
				steps++;
				if (waited > PATIENCE || steps > MAX_STEPS) forget();
				else if (ModHost.read16s((target + Y) | 0) > ModHost.read16s((lit + Y) | 0)) press(DOWN);
				else press(UP);
			}
		} else {}
	}

	static function forget():Void {
		target = 0;
		confirm = false;
		lastLit = 0;
	}

	/** The lit line of a live list the game built, or 0: none is up, or the list is a mod's. */
	static function highlighted(screen:Int):Int {
		var lit = 0;
		for (slot in 0...SLOTS) {
			final head = ModHost.read32((MENUS + slot * MENU + FIRST) | 0);
			var found = 0;
			if (builtFor[slot] == screen) found = litIn(head);
			else {}
			if (found != 0) {
				lit = found;
				list = head;
			} else {}
		}
		return lit;
	}

	static function litIn(head:Int):Int {
		var lit = 0;
		var modded = false;
		var w = head;
		var n = 0;
		while (inRam(w) && n < MAX_WIDGETS) {
			if (isLine(w)) {
				if (ModHost.isModMemory(ModHost.read32((w + TEXT) | 0))) modded = true;
				else {}
				if (ModHost.read32((w + STATE) | 0) == SELECTED) lit = w;
				else {}
			} else {}
			w = ModHost.read32((w + NEXT) | 0);
			n++;
		}
		return modded ? 0 : lit;
	}

	/** The line of the lit one's list under a point, one that can be chosen. */
	static function lineAt(lit:Int, x:Int, y:Int):Int {
		var found = 0;
		if (ModHost.mouseOver()) {
			spanOf(lit);
			var w = list;
			var n = 0;
			while (inRam(w) && n < MAX_WIDGETS) {
				if (inList(w, lit, false) && holds(w, x, y)) found = w;
				else {}
				w = ModHost.read32((w + NEXT) | 0);
				n++;
			}
		} else {}
		return found;
	}

	/** The top and bottom line of the lit one's list, as far as the lines run on unbroken. */
	static var spanTop = 0;
	static var spanBottom = 0;

	static function spanOf(lit:Int):Void {
		spanTop = ModHost.read16s((lit + Y) | 0);
		spanBottom = spanTop;
		var grew = true;
		var rounds = 0;
		while (grew && rounds < MAX_WIDGETS) {
			grew = false;
			var w = list;
			var n = 0;
			while (inRam(w) && n < MAX_WIDGETS) {
				if (sibling(w, lit, true)) {
					final y = ModHost.read16s((w + Y) | 0);
					if (y < spanTop && spanTop - y <= NEIGHBOUR) {
						spanTop = y;
						grew = true;
					} else if (y > spanBottom && y - spanBottom <= NEIGHBOUR) {
						spanBottom = y;
						grew = true;
					} else {}
				} else {}
				w = ModHost.read32((w + NEXT) | 0);
				n++;
			}
			rounds++;
		}
	}

	/** A text line like the lit one: at its x, plain or highlighted — or not available, if asked. */
	static function sibling(w:Int, lit:Int, unavailable:Bool):Bool {
		final state = ModHost.read32((w + STATE) | 0);
		return isLine(w) && ModHost.read16u((w + X) | 0) == ModHost.read16u((lit + X) | 0)
			&& (state == PLAIN || state == SELECTED || (unavailable && state == UNAVAILABLE));
	}

	static function inList(w:Int, lit:Int, unavailable:Bool):Bool {
		final y = ModHost.read16s((w + Y) | 0);
		return sibling(w, lit, unavailable) && y >= spanTop && y <= spanBottom;
	}

	static function holds(w:Int, x:Int, y:Int):Bool {
		final top = ModHost.read16s((w + Y) | 0);
		final raw = ModHost.read16u((w + X) | 0);
		final width = letters(ModHost.read32((w + TEXT) | 0)) * GLYPH;
		// A centred line keeps 8000h plus its centre (8086h: 134; 7FA1h: -95); others their left.
		var x0 = ModHost.read16s((w + X) | 0);
		if (raw >= 0x4000 && raw < 0xC000) x0 = raw - 0x8000 - (width >> 1);
		else {}
		return y >= top - ABOVE && y < top + BELOW && x >= x0 - MARGIN && x < x0 + width + MARGIN;
	}

	/** A line's letters, to its end or its first line break. */
	static function letters(text:Int):Int {
		var n = 0;
		var going = inRam(text);
		while (going && n < 64) {
			final c = ModHost.read8u((text + n) | 0);
			if (c == 0 || c == 10) going = false;
			else n++;
		}
		return n;
	}

	// ---- CHARACTER SELECT -------------------------------------------------------------------------------

	/** Pointing at a portrait makes it P1's, while P1 is still choosing; a click takes it. */
	static function characters(ctx:CpuState, moved:Bool, left:Bool):Void {
		final p = portraitAt();
		if (p >= 0 && (moved || left) && ModHost.read32((PLAYERS + PLAYER_STATE) | 0) == 0) {
			if (ModHost.read32((PLAYERS + PLAYER_PORTRAIT) | 0) != p) {
				ModHost.write32((PLAYERS + PLAYER_PORTRAIT) | 0, p);
				final pad = ModHost.read32((PLAYERS + PLAYER_PAD) | 0) & 7;
				sound(ctx, ModHost.read32((PAD_SOUNDS + pad * 4) | 0));
			} else {}
			if (left) press(CROSS);
			else {}
		} else {}
	}

	/** The portrait under the pointer, 0..7, or -1. */
	static function portraitAt():Int {
		var found = -1;
		if (ModHost.mouseOver()) {
			final x = IntMath.div(ModHost.mouseX() * 640, ModHost.pictureWidth());
			final y = IntMath.div(ModHost.mouseY() * 480, ModHost.pictureHeight());
			for (p in 0...PORTRAITS) {
				final w = slot0(FIRST_PORTRAIT + p);
				if (w != 0) {
					final px = ModHost.read16s((w + X) | 0);
					final py = ModHost.read16s((w + Y) | 0);
					if (x >= px - 14 && x < px + 76 && y >= py - 12 && y < py + 88) found = p;
					else {}
				} else {}
			}
		} else {}
		return found;
	}

	// ---- CHOOSE LEVEL -------------------------------------------------------------------------------------

	/** Pointing at a thumbnail makes it the level; a click on it, or on the preview, starts it. */
	static function levels(ctx:CpuState, moved:Bool, left:Bool):Void {
		final k = levelAt();
		if (k >= 0 && (moved || left)) {
			final arena = signedByte(ModHost.read8u((GAME + ARENA) | 0));
			final count = ModHost.read32((ARENA_LEVELS + arena * 8 + 4) | 0);
			if (k < count && ModHost.read8u((GAME + LEVEL) | 0) != k) {
				ModHost.write8((GAME + LEVEL) | 0, k);
				sound(ctx, SOUND_MOVE);
			} else {}
			if (left && k < count) press(CROSS);
			else {}
		} else if (left && previewAt()) {
			press(CROSS);
		} else {}
	}

	/** The level thumbnail under the pointer, 0..3, or -1. */
	static function levelAt():Int {
		var found = -1;
		if (ModHost.mouseOver()) {
			final x = pointerX();
			final y = pointerY();
			if (x >= 135 && x <= 290) {
				for (k in 0...LEVELS) {
					final c = LEVEL_TOP + k * LEVEL_STEP;
					if (y >= c - 49 && y < c + 50) found = k;
					else {}
				}
			} else {}
		} else {}
		return found;
	}

	/** Whether the pointer is on CHOOSE LEVEL's big preview. */
	static function previewAt():Bool {
		final x = pointerX();
		final y = pointerY();
		return ModHost.mouseOver() && x >= -287 && x <= 91 && y >= -2 && y <= 198;
	}

	// ---- the game's own ---------------------------------------------------------------------------------

	static function press(bits:Int):Void {
		ModHost.write32(PAD_EDGES, ModHost.read32(PAD_EDGES) | bits);
	}

	/** One of the menus' sounds, called as their frame handlers call it. */
	static function sound(ctx:CpuState, id:Int):Void {
		final sp = ctx.sp;
		ctx.sp = (sp - 0x20) | 0;
		ModHost.write32((ctx.sp + 0x10) | 0, 0x1E00);
		ModHost.write32((ctx.sp + 0x14) | 0, 0);
		ctx.a0 = id;
		ctx.a1 = 0;
		ctx.a2 = 0;
		ctx.a3 = 0x1000;
		ModHost.call(ctx, SOUND);
		ctx.sp = sp;
	}

	/** Slot 0's widget `i`, or 0. */
	static function slot0(i:Int):Int {
		var w = ModHost.read32((MENUS + FIRST) | 0);
		var n = 0;
		while (n < i && inRam(w)) {
			w = ModHost.read32((w + NEXT) | 0);
			n++;
		}
		return inRam(w) ? w : 0;
	}

	static inline function signedByte(v:Int):Int return v >= 0x80 ? v - 0x100 : v;

	static inline function inRam(a:Int):Bool return (a & 0xFFE00000) == 0x80000000;

	static inline function isLine(w:Int):Bool return (ModHost.read32(w) & KIND) == TEXT_LINE;

	/** The pointer in the menus' centred units (the same scaling as onlinemenu's Game.pointerX). */
	static function pointerX():Int return IntMath.div(ModHost.mouseX() * 640, ModHost.pictureWidth()) - 320;

	static function pointerY():Int return IntMath.div(ModHost.mouseY() * 480, ModHost.pictureHeight()) - 240;
}
