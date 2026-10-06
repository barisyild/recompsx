package menu;

import core.CpuState;
import mod.ModHost;
import shim.IntMath;

/**
	The pause screen's menu, for other mods: options and panels of their own, which this mod draws
	and steers. A mod says what it offers and what a choice does, nothing of how it is shown, and
	every mod's lines look and move alike, as the game's own do. RESOLUTION (`resolution`, ADR-0056)
	and WIDESCREEN (`widescreen`, ADR-0064) are two options in OPTIONS, each a mod of its own that
	`needs` this one (ADR-0033).

	- **Options** (`option`): a button, as the game's own ♫ OPTIONS is — a line with the option's
	  title (RESOLUTION) that cross opens: its choices as a panel, the title over them and the one in
	  effect chosen, where cross picks one (the owner: a button that opens the choices, "Resolution
	  Options gibi buton olsun basınca seçelim"). Its mod offers the choices once a boot.
	- **Panels** (`panel`): screens of the mods' own in the pause screen's panel, laid out as the
	  pause menu lays out its own — the title a line above the first, where the level's name stands,
	  in its colours, and the lines on the panel's last ones, where RESUME, OPTIONS and QUIT are (of
	  more than it holds, five, moving with the choice). A mod's panel holds options and links
	  (`link`: a line that opens another panel), DONE below them; an option's choices are a panel of
	  the menu's, its title over them. Up and down move along a panel, cross picks, opens or — on
	  DONE — goes back, triangle goes back. The game hears none of it and its own choice stays on
	  DONE, so the line chosen is drawn in DONE's colours, the rest in the first line's.
	- **OPTIONS** (`OPTIONS`) is the game's panel: the mods' lines go before its DONE, and a panel
	  opened from one of them is shown in place of all of OPTIONS' lines.

	The menu is GOOL, not code. The pause screen's menu is a GOOL object that owns one text object
	per line: it moves its choice (+E4h, times 256) with the pad's pressed buttons, marks the chosen
	line by writing that line's colours, and at the end of every frame the main loop draws each text
	object through one routine (8001C824h). OPTIONS is ♫ OPTIONS, VIBRATION (with a DualShock), CTR
	and DONE, a line every 4096 down. So no bytecode is edited (the facts are in
	games/SCUS94244/notes.md, "The pause menu"):

	- **Drawing.** Handed OPTIONS' DONE, the routine draws the mods' lines first — each a copy of
	  DONE's object with a string table of the mod's own — from where DONE was down, a line apart,
	  then DONE below them. With a panel open it draws the panel's lines so instead, and none of
	  OPTIONS'.
	- **Choosing.** The pad routine (80015798h) makes the pressed buttons the menu reads (pad 0's
	  +24h); right after it the mod takes what the lines need and leaves the rest. While a line of
	  the mods' is the choice the game's own stays on DONE: up and down move among them — up from the
	  first is the game's up from DONE, down from the last lands on DONE without the game hearing it
	  — cross opens, left and right do nothing. Down from the game's line above them is the game's own
	  down to DONE, and up from DONE is taken: both land on a line of the mods'.
	- **Highlight.** The game highlights DONE while a line of the mods' is the choice: that line is
	  drawn in the colours the game gave DONE, and DONE in those of the first line, never chosen then.
	- **The picture anew** (`redraw`). The pause screen's game view is the last two pictures the game
	  drew of its world while the view shrank into the corner; it draws no more of them. After a
	  change that alters them — a scale — the mod has the game draw them again: for four
	  frames, two pictures of each buffer, it asks for the world and the shrink the pause screen
	  settled at, as its last frames had them, then for what it found. Those frames come out exactly
	  as the pause screen's last two did (the same VRAM; in the browser the same picture as a pause
	  opened at the new scale) — the view inside its black bars — so the console holds the picture
	  from before on screen meanwhile (HoldPicture) until the menu is drawn over both new ones. Two
	  things the game never drew under the shrink are put back where it draws them — the texts and
	  objects it places on the screen, moved by the shrink otherwise — and the routine that applies
	  the shrink at the end of a frame (bars into that frame, offset and projection into the next) is
	  split for them.

	The game is silent while it is paused (its main volume is down), so the lines make no sound
	either. The sound options behind ♫ end in DONE too; they have no ♫ OPTIONS line, and the lines
	are only ever drawn with one. The game's font has capitals only (a lower-case p cut a line
	short), and the panel holds about nine of them with the arrows. The panel has room for a fifth
	line, where the pause menu's own QUIT stands; with two lines of the mods' and a DualShock's
	VIBRATION, OPTIONS has six, and the lines are drawn closer together to keep them in it.
**/
class Menu {
	/** The game's OPTIONS: the panel whose DONE the mods' lines go before. */
	public static inline var OPTIONS = 0;

	// The game's own (games/SCUS94244/notes.md, "The pause menu").
	static inline var DRAW_TEXT = 0x8001c824;   // (text object a0, string table a1, string a2, a3)
	static inline var READ_PADS = 0x80015798;   // once a game frame, before the objects run
	static inline var PAD0 = 0x80065bcc;        // pad 0: +24h pressed this frame, +28h held
	static inline var PRESSED = 0x24;

	static inline var PARENT = 0x44;            // a text object's menu
	static inline var Y = 0x64;                 // its y; a line is 4096 below the one before
	static inline var COLOURS = 0x28;           // six words: its colours
	static inline var COLOUR_WORDS = 6;
	/** The pause menu's title's colours (the level's name): the four corners' RGB, orange over red. */
	static final TITLE_COLOURS = [0x019001FF, 0x01FF0000, 0x00000190, 0x000001FF, 0x01FF0000, 0x00000000];
	static inline var COPIED = 0x200;           // what a line copies of DONE's object
	static inline var CHOICE = 0xE4;            // the menu's chosen line, times 256
	static inline var LINE_SHIFT = 12;          // 4096, a line
	static inline var STEP = 4096;
	/** The lines the panel holds at the game's spacing: the pause menu's five. */
	static inline var ROOM = 5;
	/** The most lines a screen of the mods' has (a panel's with its DONE; an option's choices): ROOM
	    of them are shown at a time. */
	static inline var MOST = 16;
	/** How deep links are followed to find whether a panel has a line to show. */
	static inline var DEPTH = 4;
	/** The capitals a line holds across the panel: longer words are drawn narrower (`~sx300~`,
	    three quarters of the width). */
	static inline var ACROSS = 11;

	// What a line of the mods' is, and what a screen opened over OPTIONS is.
	static inline var OPTION = 0;
	static inline var LINK = 1;
	static inline var PANEL = 0;
	static inline var CHOICES = 1;

	static inline var TITLE = 0x34;             // "# OPTIONS" (# is the note): OPTIONS' first line
	static inline var DONE = 0x37;              // "DONE"
	static inline var TABLE_HEADER = 12;        // a string table's strings start past it
	static inline var TABLE_BYTES = TABLE_HEADER + 64;

	// The game's button word: the d-pad in the high byte, the shapes in the low one.
	static inline var PAD_UP = 0x1000;
	static inline var PAD_RIGHT = 0x2000;
	static inline var PAD_DOWN = 0x4000;
	static inline var PAD_LEFT = 0x8000;
	static inline var PAD_TRIANGLE = 0x10;
	static inline var PAD_CROSS = 0x40;
	static inline var PAD_SHAPES = 0xF0;        // triangle, circle, cross, square

	// Drawing the pause screen's picture anew (games/SCUS94244/notes.md, "The frozen game"). The
	// game's state (80068E98h) holds the display flags it asks for (+70h), which the end of every
	// frame puts into effect (+84h, f_80016634) — bit 0 has the main loop draw the world (80011A88h)
	// — and the pause screen's shrink (+184h, 0 to 8). The end of every frame hands that to
	// f_80017834 with the one before it (gp + 88h): the bars around the view go into the frame being
	// finished (its OT word at +201Ch of the frame being built, *80061A84h), and the next frame gets
	// the drawing offset — 100 x shrink / 8 pixels left, 60 x shrink / 8 up — and the projection.
	// Pausing, the game draws its world while the shrink runs up to 8, then asks for these bits off
	// and the shrink back to 0, and its last two pictures stay.
	static inline var FLAGS = 0x80068F08;
	static inline var WORLD = 0x08002001;
	static inline var SHRINK = 0x8006901C;
	static inline var APPLY_SHRINK = 0x80017834;
	static inline var BUILDING = 0x80061A84;
	static inline var BUILDING_NEXT = 8;        // its primitive buffer's next free byte
	static inline var BUILDING_BARS = 0x201C;   // the OT word the bars are added to
	// The objects (GOOL): a pool of 96 of 23Ch bytes the game allocates at boot (its address at
	// 80068E9Ch), +0 1 for a live one. Kinds 6 and 7 (+120h) are placed on the screen, at x / 256
	// and -y / 256 (+60h, +64h; 8003C3D0h), and do not follow the shrink: the pause screen's own,
	// which the game never draws under one. 8003F3ACh draws the frame's objects.
	static inline var DRAW_OBJECTS = 0x8003f3ac;
	static inline var POOL = 0x80068E9C;
	static inline var POOL_OBJECTS = 96;
	static inline var OBJECT_BYTES = 0x23C;
	static inline var KIND = 0x120;
	static inline var X = 0x60;

	// The redraw's frames: two pictures of each buffer. One each was enough in the browser, but on
	// the Dreamcast the first frame of the world after the menu's drew Crash without his shadow,
	// which flickered at 30 Hz behind the menu; the second of each buffer follows a frame of the
	// world, as the pause screen's own last frames did.
	static inline var WORLD_FRAMES = 4;
	// Game frames the picture is held for, released by the mod (HOLD_MOST, in vblanks, only bounds
	// it): the redraw's frames and the menu's over both buffers, and the screen shows the game's
	// frame two behind the one being made — so a hold that ends with the menu's second frame ends
	// just as the first whole picture comes up, which a frame that ran a vblank late (a press at
	// another moment, a busier scene) missed: the owner saw one frame of the bars. One more keeps
	// a frame in hand.
	static inline var HOLD_FRAMES = WORLD_FRAMES + 4;
	static inline var HOLD_MOST = 30;

	/** Panels, by number (OPTIONS the game's): their titles. */
	static final panelTitles:Array<String> = [""];

	/** Lines of the mods', by number: the panel each is in, what it is, its words (an option's title,
	    a link's name); an option's mod's three functions; a link's panel. */
	static final panels:Array<Int> = [];
	static final kinds:Array<Int> = [];
	static final names:Array<String> = [];
	static final offers:Array<CpuState -> Void> = [];
	static final currents:Array<CpuState -> Int> = [];
	static final chooses:Array<CpuState -> Int -> Void> = [];
	static final targets:Array<Int> = [];
	/** An option's choices, asked of its mod once a boot: where they start among every option's
	    (-1 before they are asked), and how many there are. */
	static final firsts:Array<Int> = [];
	static final counts:Array<Int> = [];
	/** Every option's choices: the words its panel shows. */
	static final choiceWords:Array<String> = [];
	/** The option whose choices are being offered (`offer`); -1 otherwise. */
	static var asking = -1;

	/** Per line in OPTIONS: its object (DONE's, copied every frame), its string table, the words written into it. */
	static final objects:Array<Int> = [];
	static final tables:Array<Int> = [];
	static final written:Array<String> = [];
	/** OPTIONS' lines of the mods' drawn this frame, by number: the ones with words. */
	static final shown:Array<Int> = [];
	/** DONE's colours, while a line of the mods' has them. */
	static var kept = 0;

	/** The screens opened over OPTIONS, the last on top: what each is, its panel or option, the
	    line chosen in it. */
	static final screenKinds:Array<Int> = [];
	static final screenOf:Array<Int> = [];
	static final screenAt:Array<Int> = [];
	/** Per screen, its first line shown: past 0 when it has more lines than the panel holds. */
	static final screenFrom:Array<Int> = [];
	/** The top screen's lines when it is a panel (`lay`): those with words, by number, then -1, its DONE. */
	static final laid:Array<Int> = [];
	/** The screens' text objects, the title's first: their objects, string tables, the words written. */
	static final screenObjects:Array<Int> = [];
	static final screenTables:Array<Int> = [];
	static final screenWritten:Array<String> = [];

	/** The last string table walked, where its ♫ OPTIONS and DONE would be, and the pause menu's
	    table as this frame found it. */
	static var walked = 0;
	static var titleText = 0;
	static var doneText = 0;
	static var strings = 0;

	/** Game frames, counted at the pad routine: a frame's drawing steers the next one's buttons. */
	static var frames = 0;
	/** OPTIONS' first line and the frame it was drawn in. */
	static var title = 0;
	static var titleFrame = -2;
	/** OPTIONS' menu object, DONE's line number, and the frame the lines were last drawn in. */
	static var menu = 0;
	static var doneLine = 0;
	static var menuFrame = -2;
	/** The line of the mods' that is the choice, as its place among those drawn; -1 for none. */
	static var chosen = -1;
	static var logged = false;
	/** The last shrink the game drew its world at (8 once the pause screen has settled). */
	static var shrunk = 0;
	/** A redraw: WORLD_FRAMES + 1 when asked for, down to 0; the frame it began in (`frames` then);
	    what it found. */
	static var redrawing = 0;
	static var redrawFrom = -8;
	static var flagsFound = 0;
	static var shrinkFound = 0;
	/** How far what is drawn is moved back, in object units (256 a pixel); 0 but in a redraw. */
	static var backX = 0;
	static var backY = 0;
	/** Where the objects moved back were: per pool slot, moved (1 or 0), x and y. */
	static var moved = 0;
	/** Game frames the picture on screen is still held for (HoldPicture), 0 when it is not. */
	static var holding = 0;

	public static function install():Void {
		ModHost.onBoot(boot);
		ModHost.hook(READ_PADS, readPads);
		ModHost.hook(DRAW_TEXT, drawText);
		ModHost.hook(DRAW_OBJECTS, drawObjects);
		ModHost.hook(APPLY_SHRINK, applyShrink);
	}

	/**
		A panel of the mods' own: `title` over its lines (`option`, `link`), DONE below them, opened
		by a line that links to it. Called from a mod's `install`; the panel's number.
	**/
	public static function panel(title:String):Int {
		panelTitles.push(fit(title, ACROSS));
		return panelTitles.length - 1;
	}

	/**
		An option in `panel` (OPTIONS for the game's): a button `title` that opens its choices, which
		its mod offers (`choices`, calling `offer` for each, in order) the first time the line is wanted
		after a boot — none, and the line is not shown: a console without what it sets. `current`
		answers the one in effect, which the panel opens on, and `choose` hears the one picked, by its
		place. Called from a mod's `install`; the line's number.
	**/
	public static function option(panel:Int, title:String, choices:CpuState -> Void, current:CpuState -> Int,
			choose:CpuState -> Int -> Void):Int {
		return add(panel, OPTION, fit(title, ACROSS), choices, current, choose, -1);
	}

	/**
		A line `name` in `panel` that opens panel `to` with cross, shown while `to` has a line to
		show. Called from a mod's `install`; the line's number.
	**/
	public static function link(panel:Int, name:String, to:Int):Int {
		return add(panel, LINK, fit(name, ACROSS), noChoices, noCurrent, noChoose, to);
	}

	/** A choice of the option whose choices are asked for (from its `choices`): its words. */
	public static function offer(words:String):Void {
		if (asking >= 0 && counts[asking] < MOST) {
			choiceWords.push(fit(words, ACROSS));
			counts[asking] = counts[asking] + 1;
		} else {}
	}

	static function add(panel:Int, kind:Int, name:String, choices:CpuState -> Void, current:CpuState -> Int,
			choose:CpuState -> Int -> Void, target:Int):Int {
		panels.push(panel);
		kinds.push(kind);
		names.push(name);
		offers.push(choices);
		currents.push(current);
		chooses.push(choose);
		targets.push(target);
		firsts.push(-1);
		counts.push(0);
		objects.push(0);
		tables.push(0);
		written.push("");
		return names.length - 1;
	}

	// A link's place in the option's functions.
	static function noChoices(ctx:CpuState):Void {}

	static function noCurrent(ctx:CpuState):Int {
		return 0;
	}

	static function noChoose(ctx:CpuState, at:Int):Void {}

	/**
		The pause screen's picture drawn anew from the next frame, by the game, as it drew it: after a
		change that alters it — a scale. Only while the pause screen shows its frozen
		picture (the world not drawn, the shrink settled) and no redraw is on its way; nothing
		otherwise, since every other frame draws the world anyway.
	**/
	public static function redraw():Void {
		if (redrawing == 0 && shrunk > 0 && (ModHost.read32(FLAGS) & 1) == 0) redrawing = WORLD_FRAMES + 1;
		else {}
	}

	static function boot(ctx:CpuState):Void {
		for (i in 0...names.length) {
			objects[i] = ModHost.alloc(COPIED);
			tables[i] = ModHost.alloc(TABLE_BYTES);
			written[i] = "";
			firsts[i] = -1;
			counts[i] = 0;
		}
		while (choiceWords.length > 0) choiceWords.pop();
		while (screenObjects.length > 0) screenObjects.pop();
		while (screenTables.length > 0) screenTables.pop();
		while (screenWritten.length > 0) screenWritten.pop();
		for (k in 0...ROOM + 1) {
			screenObjects.push(ModHost.alloc(COPIED));
			screenTables.push(ModHost.alloc(TABLE_BYTES));
			screenWritten.push("");
		}
		kept = ModHost.alloc(COLOUR_WORDS * 4);
		moved = ModHost.alloc(POOL_OBJECTS * 12);
		Pro.boot();
		redrawing = 0;
		redrawFrom = -8;
		holding = 0;
		walked = 0;
		strings = 0;
		titleFrame = -2;
		menuFrame = -2;
		away();
	}

	/**
		The pads read, then this frame's buttons steered while OPTIONS is up (it was drawn last frame)
		and no redraw is on its way — whose frames hear no buttons, the mods' lines' either.
	**/
	static function readPads(ctx:CpuState, addr:Int):Bool {
		ModHost.callOriginal(ctx, addr);
		if (redrawing == 0 && ModHost.read32(SHRINK) > 0) shrunk = ModHost.read32(SHRINK);
		else {}
		if (holding > 0) release(ctx);
		else {}
		if (menuFrame != frames || shown.length == 0) away();
		else if (redrawing == 0) steer(ctx);
		else {}
		if (redrawing > 0) redrawWorld(ctx);
		else {}
		frames = (frames + 1) | 0;
		return true;
	}

	/** OPTIONS is not up: no line of the mods' is the choice, and no screen is open over it. */
	static function away():Void {
		chosen = -1;
		while (screenKinds.length > 0) back();
	}

	/** The top screen closed: the one under it shown again, or OPTIONS. */
	static function back():Void {
		screenKinds.pop();
		screenOf.pop();
		screenAt.pop();
		screenFrom.pop();
	}

	/**
		The pause screen's picture drawn anew — by the game, as it drew it. This frame asks for the
		world and the shrink the pause screen settled at; the end of the frame puts them into effect
		(applyShrink), and the WORLD_FRAMES after draw the world into each buffer, the last two exactly
		as the pause screen's last two did, under its bars; then what was found is asked for again.
		Pressed buttons are not heard meanwhile, so nothing else moves; should the game have asked for
		something else, that stands.
	**/
	static function redrawWorld(ctx:CpuState):Void {
		final flags = ModHost.read32(FLAGS);
		final shrink = ModHost.read32(SHRINK);
		if (redrawing == WORLD_FRAMES + 1) {
			Pro.call(ctx, Pro.HOLD_PICTURE, HOLD_MOST);
			holding = HOLD_FRAMES;
			redrawFrom = frames;
			flagsFound = flags;
			shrinkFound = shrink;
			ModHost.write32(FLAGS, flags | WORLD);
			ModHost.write32(SHRINK, shrunk);
		} else if (redrawing == 1) {
			if (flags == (flagsFound | WORLD)) ModHost.write32(FLAGS, flagsFound);
			else {}
			if (shrink == shrunk) ModHost.write32(SHRINK, shrinkFound);
			else {}
		} else {}
		ModHost.write32(PAD0 + PRESSED, 0);
		redrawing--;
	}

	/**
		A frame of the hold on the picture: the last lets the screen show the game's frames again,
		by then the menu drawn over both redrawn pictures. Meanwhile the console keeps showing the
		picture from before the change, so neither the old one stretched nor the redraw's frames —
		the view inside its black bars — are seen.
	**/
	static function release(ctx:CpuState):Void {
		holding--;
		if (holding == 0) Pro.call(ctx, Pro.HOLD_PICTURE, 0);
		else {}
	}

	/**
		The shrink a redraw draws this frame at: the WORLD_FRAMES after the one it began in (`frames`
		has counted this frame's pads already, so those are redrawFrom + 2 on); 0 otherwise.
	**/
	static function redrawShrink():Int {
		final since = frames - redrawFrom;
		return since >= 2 && since <= WORLD_FRAMES + 1 ? shrunk : 0;
	}

	/**
		The end of a frame applies the shrink. A redraw's frames need its three parts apart: the frame
		it began in is the menu's, so its next frame gets the shrink but it keeps no bars (they are
		taken out of its OT again); the redraw's last frame gets its bars, and the frame after it the
		menu's offset and projection back (the shrink applied once more as 0, which draws no bars).
	**/
	static function applyShrink(ctx:CpuState, addr:Int):Bool {
		final since = frames - redrawFrom;
		var taken = false;
		if (since == 1) {
			final building = ModHost.read32(BUILDING);
			final bars = ModHost.read32(building + BUILDING_BARS);
			final next = ModHost.read32(building + BUILDING_NEXT);
			ModHost.callOriginal(ctx, addr);
			ModHost.write32(building + BUILDING_BARS, bars);
			ModHost.write32(building + BUILDING_NEXT, next);
			taken = true;
		} else if (since == WORLD_FRAMES + 1) {
			ctx.a0 = shrunk;
			ctx.a1 = shrunk;
			ModHost.callOriginal(ctx, addr);
			ctx.a0 = 0;
			ctx.a1 = shrunk;
			ModHost.callOriginal(ctx, addr);
			taken = true;
		} else {}
		return taken;
	}

	/** Back by as much as the shrink moves the frame. */
	static function moveBack(shrink:Int):Void {
		backX = ((shrink * 100) >> 3) << 8;
		backY = ((shrink * 60) >> 3) << 8;
	}

	/** The frame's objects drawn, the screen's own moved back while a redraw has the frame shrunk. */
	static function drawObjects(ctx:CpuState, addr:Int):Bool {
		final shrink = redrawShrink();
		var taken = false;
		if (shrink > 0) {
			moveBack(shrink);
			moveScreenObjects();
			ModHost.callOriginal(ctx, addr);
			returnScreenObjects();
			taken = true;
		} else {}
		return taken;
	}

	/** Every live object of kinds 6 and 7 moved back by (backX, backY), where it was noted. */
	static function moveScreenObjects():Void {
		final pool = ModHost.read32(POOL);
		for (i in 0...POOL_OBJECTS) {
			final o = pool + i * OBJECT_BYTES;
			final kind = ModHost.read8u(o + KIND);
			final at = moved + i * 12;
			ModHost.write32(at, 0);
			if (ModHost.read32(o) == 1 && (kind == 6 || kind == 7)) {
				ModHost.write32(at, 1);
				ModHost.write32(at + 4, ModHost.read32(o + X));
				ModHost.write32(at + 8, ModHost.read32(o + Y));
				ModHost.write32(o + X, ModHost.read32(o + X) + backX);
				ModHost.write32(o + Y, ModHost.read32(o + Y) - backY);
			} else {}
		}
	}

	/** The objects moveScreenObjects moved, back where they were. */
	static function returnScreenObjects():Void {
		final pool = ModHost.read32(POOL);
		for (i in 0...POOL_OBJECTS) {
			final at = moved + i * 12;
			if (ModHost.read32(at) == 1) {
				ModHost.write32(pool + i * OBJECT_BYTES + X, ModHost.read32(at + 4));
				ModHost.write32(pool + i * OBJECT_BYTES + Y, ModHost.read32(at + 8));
			} else {}
		}
	}

	/** What the game hears of this frame's pressed buttons, with the mods' lines in OPTIONS (see the class). */
	static function steer(ctx:CpuState):Void {
		final pressed = ModHost.read32(PAD0 + PRESSED);
		final choice = ModHost.read32(menu + CHOICE) >> 8;
		final last = shown.length - 1;
		var heard = pressed;
		if (chosen > last) chosen = last;
		else {}
		if (chosen >= 0) {
			// The game's choice stays on DONE: its up from there lands on the line above the mods'.
			if (choice != doneLine) ModHost.write32(menu + CHOICE, doneLine << 8);
			else {}
			if (screenKinds.length > 0) {
				steerScreen(ctx, pressed);
				heard &= ~(PAD_UP | PAD_DOWN | PAD_SHAPES);
			} else if ((pressed & PAD_UP) != 0) {
				if (chosen > 0) heard &= ~PAD_UP;
				else {}
				chosen--;
			} else if ((pressed & PAD_DOWN) != 0) {
				heard &= ~PAD_DOWN;
				chosen = chosen < last ? chosen + 1 : -1;
			} else if ((pressed & PAD_CROSS) != 0) {
				enter(ctx, shown[chosen]);
			} else {}
			heard &= ~(PAD_LEFT | PAD_RIGHT | PAD_CROSS);
		} else if (choice == doneLine - 1 && (pressed & PAD_DOWN) != 0) {
			chosen = 0;            // the game's own down, to DONE, which the first line then stands for
		} else if (choice == doneLine && (pressed & PAD_UP) != 0) {
			chosen = last;
			heard &= ~PAD_UP;
		} else {}
		if (heard != pressed) ModHost.write32(PAD0 + PRESSED, heard);
		else {}
	}

	/** Cross on line `line`: an option's choices, on the one in effect, or a link's panel, opened over what is shown. */
	static function enter(ctx:CpuState, line:Int):Void {
		final room = screenKinds.length <= DEPTH;
		if (room && kinds[line] == OPTION && counts[line] > 0) open(CHOICES, line, choiceNow(ctx, line));
		else if (room && kinds[line] == LINK) open(PANEL, targets[line], 0);
		else {}
	}

	static function open(kind:Int, of:Int, at:Int):Void {
		screenKinds.push(kind);
		screenOf.push(of);
		screenAt.push(at);
		screenFrom.push(0);
	}

	/** An option's choice in effect, held among its choices. */
	static function choiceNow(ctx:CpuState, line:Int):Int {
		final at = currents[line](ctx);
		return at >= 0 && at < counts[line] ? at : 0;
	}

	/** The top screen's buttons (see the class). */
	static function steerScreen(ctx:CpuState, pressed:Int):Void {
		final top = screenKinds.length - 1;
		final n = lay(ctx);
		var at = screenAt[top];
		if (at > n - 1) at = n - 1;
		else {}
		final line = screenKinds[top] == PANEL ? laid[at] : -1;
		if ((pressed & PAD_UP) != 0) {
			if (at > 0) screenAt[top] = at - 1;
			else {}
		} else if ((pressed & PAD_DOWN) != 0) {
			if (at < n - 1) screenAt[top] = at + 1;
			else {}
		} else if ((pressed & PAD_CROSS) != 0) {
			pick(ctx, top, at, line);
		} else if ((pressed & PAD_TRIANGLE) != 0) {
			back();
		} else {}
	}

	/**
		Cross on the top screen's line `at`: a choice handed to its option's mod, its screen closed
		first; a panel's line entered (`line`), or its DONE (-1), which goes back.
	**/
	static function pick(ctx:CpuState, top:Int, at:Int, line:Int):Void {
		if (screenKinds[top] == CHOICES) {
			final option = screenOf[top];
			back();
			chooses[option](ctx, at);
		} else if (line >= 0) {
			enter(ctx, line);
		} else {
			back();
		}
	}

	/**
		A text object drawn while the redraw has the frame shrunk: the pause screen's texts are placed
		on the screen and do not follow the shrink, under which the game never draws them — moved by as
		much the other way, they land where every other frame draws them. And OPTIONS, closer together
		when it has more lines than the panel holds at the game's spacing, and not at all under a screen.
	**/
	static function drawText(ctx:CpuState, addr:Int):Bool {
		final kind = ModHost.read8u(ctx.a0 + KIND);
		final shrink = kind == 6 || kind == 7 ? redrawShrink() : 0;
		backX = 0;
		backY = 0;
		if (shrink > 0) moveBack(shrink);
		else {}
		var taken = drawLine(ctx, addr);
		if (!taken && screenKinds.length > 0 && ModHost.read32(ctx.a0 + PARENT) == menu) taken = true;
		else {}
		final options = !taken && inOptions(ctx.a0);
		if (!taken && (backX != 0 || options)) {
			draw(ctx, addr, ModHost.read32(ctx.a0 + Y), options);
			taken = true;
		} else {}
		return taken;
	}

	/** The game's own drawing of the text object in $a0, at `y` (moved back while a redraw has the
	    frame shrunk), and closer to OPTIONS' first line when OPTIONS is crowded (`options`). */
	static function draw(ctx:CpuState, addr:Int, y:Int, options:Bool):Void {
		final text = ctx.a0;
		final x = ModHost.read32(text + X);
		final was = ModHost.read32(text + Y);
		ModHost.write32(text + X, x + backX);
		ModHost.write32(text + Y, (options ? closer(y) : y) - backY);
		ModHost.callOriginal(ctx, addr);
		ModHost.write32(text + X, x);
		ModHost.write32(text + Y, was);
	}

	/**
		A line of OPTIONS above the mods' — its first drawn this frame, its menu the one the mods'
		lines were drawn in last frame or this one — when OPTIONS is crowded.
	**/
	static function inOptions(text:Int):Bool {
		return crowded() && titleFrame == frames && ModHost.read32(text + PARENT) == menu;
	}

	/** OPTIONS, drawn with the mods' lines this frame or the last, has more lines than the panel holds. */
	static function crowded():Bool {
		return menu != 0 && menuFrame >= frames - 1 && doneLine + shown.length + 1 > ROOM;
	}

	/**
		`y` in OPTIONS as drawn: the game's spacing while the panel holds every line, and closer
		together from the first line on when it does not — the lines then fill the room of ROOM.
	**/
	static function closer(y:Int):Int {
		var at = y;
		if (crowded()) {
			final first = ModHost.read32(title + Y);
			at = first + IntMath.div((y - first) * (ROOM - 1), doneLine + shown.length);
		} else {}
		return at;
	}

	/**
		The pause menu's lines: OPTIONS' first noted, DONE drawn with the mods' lines before it, or the
		top screen in place of them all (true when drawn).
	**/
	static function drawLine(ctx:CpuState, addr:Int):Bool {
		var taken = false;
		if (ctx.a2 == TITLE && isPauseTable(ctx.a1)) {
			title = ctx.a0;
			titleFrame = frames;
			strings = ctx.a1;
		} else if (ctx.a2 == DONE && ctx.a1 == strings && titleFrame == frames
				&& ModHost.read32(ctx.a0 + PARENT) == ModHost.read32(title + PARENT)) {
			final line = (ModHost.read32(title + Y) - ModHost.read32(ctx.a0 + Y)) >> LINE_SHIFT;
			if (line >= 2 && line <= 6) {
				label(ctx);
				taken = shown.length > 0;
			} else {}
			if (taken) {
				menu = ModHost.read32(ctx.a0 + PARENT);
				doneLine = line;
				menuFrame = frames;
			} else {}
			if (taken && screenKinds.length > 0) drawScreen(ctx, addr);
			else if (taken) drawLines(ctx, addr, line);
			else {}
		} else {}
		return taken;
	}

	/** The mods' lines where DONE was, a line apart, then DONE below them (see the class). */
	static function drawLines(ctx:CpuState, addr:Int, line:Int):Void {
		final done = ctx.a0;
		final from = ctx.a1;
		final number = ctx.a2;
		final a3 = ctx.a3;
		final y = ModHost.read32(done + Y);
		if (!logged) {
			logged = true;
			// Std.string: reflaxe.CPP adds an Array's length (a size_t) to a String as it is.
			ModHost.log("menu: " + Std.string(shown.length) + " line(s) in OPTIONS, DONE now line "
				+ Std.string(line + shown.length + 1));
		} else {}
		final doneChosen = (ModHost.read32(menu + CHOICE) >> 8) == line;
		for (k in 0...shown.length) {
			final i = shown[k];
			final object = objects[i];
			final table = tables[i];
			for (w in 0...(COPIED >> 2)) ModHost.write32(object + w * 4, ModHost.read32(done + w * 4));
			for (w in 0...(TABLE_HEADER >> 2)) ModHost.write32(table + w * 4, ModHost.read32(from + w * 4));
			// DONE's colours, the highlight's while the game has DONE chosen: plain unless this line
			// is the player's choice, in the first line's colours.
			if (doneChosen && chosen != k) colours(object + COLOURS, title + COLOURS);
			else {}
			ctx.a0 = object;
			ctx.a1 = table;
			ctx.a2 = 0;
			ctx.a3 = a3;
			draw(ctx, addr, y - k * STEP, true);
		}
		if (chosen >= 0) {
			colours(kept, done + COLOURS);
			colours(done + COLOURS, title + COLOURS);
		} else {}
		ctx.a0 = done;
		ctx.a1 = from;
		ctx.a2 = number;
		ctx.a3 = a3;
		draw(ctx, addr, y - shown.length * STEP, true);
		if (chosen >= 0) colours(done + COLOURS, kept);
		else {}
	}

	/**
		The top screen in place of OPTIONS' lines, each a copy of DONE's object as the mods' lines in
		OPTIONS are: its title a line above the first, where the pause menu's stands, in its colours;
		its lines on the panel's last ones — of more than it holds, ROOM from the first shown — the one
		chosen in DONE's colours, the rest in the first line's (see the class).
	**/
	static function drawScreen(ctx:CpuState, addr:Int):Void {
		final done = ctx.a0;
		final from = ctx.a1;
		final number = ctx.a2;
		final a3 = ctx.a3;
		final top = screenKinds.length - 1;
		final first = ModHost.read32(title + Y);
		final n = lay(ctx);
		var at = screenAt[top];
		if (at > n - 1) at = n - 1;
		else {}
		final from = window(top, n, at);
		final count = n < ROOM ? n : ROOM;
		for (k in 0...count + 1) {
			final object = screenObjects[k];
			final table = screenTables[k];
			final text = k == 0 ? screenTitle(top) : screenWords(ctx, top, from + k - 1);
			for (w in 0...(COPIED >> 2)) ModHost.write32(object + w * 4, ModHost.read32(done + w * 4));
			for (w in 0...(TABLE_HEADER >> 2)) ModHost.write32(table + w * 4, ModHost.read32(from + w * 4));
			if (text != screenWritten[k]) {
				screenWritten[k] = text;
				write(table + TABLE_HEADER, text);
			} else {}
			if (k == 0) titleColours(object + COLOURS);
			else if (from + k - 1 != at) colours(object + COLOURS, title + COLOURS);
			else {}
			ctx.a0 = object;
			ctx.a1 = table;
			ctx.a2 = 0;
			ctx.a3 = a3;
			draw(ctx, addr, k == 0 ? first + STEP : first - (ROOM - count + k - 1) * STEP, false);
		}
		ctx.a0 = done;
		ctx.a1 = from;
		ctx.a2 = number;
		ctx.a3 = a3;
	}

	/**
		The top screen's lines, counted: an option's choices, or a panel's lines with words (in `laid`,
		by number, at most MOST - 1 of them) and its DONE (-1).
	**/
	static function lay(ctx:CpuState):Int {
		final top = screenKinds.length - 1;
		var n = 0;
		while (laid.length > 0) laid.pop();
		if (screenKinds[top] == CHOICES) {
			n = counts[screenOf[top]];
		} else {
			for (i in 0...names.length) {
				if (panels[i] == screenOf[top] && laid.length < MOST - 1 && words(ctx, i) != "") laid.push(i);
				else {}
			}
			laid.push(-1);
			n = laid.length;
		}
		return n;
	}

	/** The top screen's title: its option's, or its panel's. */
	static function screenTitle(top:Int):String {
		return screenKinds[top] == CHOICES ? names[screenOf[top]] : panelTitles[screenOf[top]];
	}

	/** The top screen's line `k` (after `lay`): a choice's words, a panel's line's, or DONE. */
	static function screenWords(ctx:CpuState, top:Int, k:Int):String {
		var text = "DONE";
		if (screenKinds[top] == CHOICES) text = choiceWords[firsts[screenOf[top]] + k];
		else if (laid[k] >= 0) text = words(ctx, laid[k]);
		else {}
		return text;
	}

	/**
		The first line the top screen shows of its `n`, `at` the one chosen: 0 while the panel holds
		them all, and otherwise moved no more than it takes to show the one chosen.
	**/
	static function window(top:Int, n:Int, at:Int):Int {
		var from = screenFrom[top];
		if (at < from) from = at;
		else {}
		if (at > from + ROOM - 1) from = at - ROOM + 1;
		else {}
		if (from > n - ROOM) from = n - ROOM;
		else {}
		if (from < 0) from = 0;
		else {}
		screenFrom[top] = from;
		return from;
	}

	/** Six colour words from one place to another. */
	static function colours(to:Int, from:Int):Void {
		for (w in 0...COLOUR_WORDS) ModHost.write32(to + w * 4, ModHost.read32(from + w * 4));
	}

	/** The pause menu's title's colours, at `to`. */
	static function titleColours(to:Int):Void {
		for (w in 0...COLOUR_WORDS) ModHost.write32(to + w * 4, TITLE_COLOURS[w]);
	}

	/** OPTIONS' lines of the mods': their words written into their string tables when they change; those with words, in order. */
	static function label(ctx:CpuState):Void {
		while (shown.length > 0) shown.pop();
		for (i in 0...names.length) {
			final text = panels[i] == OPTIONS ? words(ctx, i) : "";
			if (text != "") {
				shown.push(i);
				if (text != written[i]) {
					written[i] = text;
					write(tables[i] + TABLE_HEADER, text);
				} else {}
			} else {}
		}
	}

	/** A line's words: an option's title, a link's name; "" while it is not shown. */
	static function words(ctx:CpuState, line:Int):String {
		var text = "";
		if (kinds[line] == OPTION) {
			ask(ctx, line);
			if (counts[line] > 0) text = names[line];
			else {}
		} else if (filled(ctx, targets[line], DEPTH)) {
			text = names[line];
		} else {}
		return text;
	}

	/** Whether panel `p` has a line to show: an option with choices, or a link to one, `depth` deep. */
	static function filled(ctx:CpuState, p:Int, depth:Int):Bool {
		var any = false;
		for (i in 0...names.length) {
			if (!any && panels[i] == p) {
				if (kinds[i] == OPTION) {
					ask(ctx, i);
					any = counts[i] > 0;
				} else if (depth > 0) {
					any = filled(ctx, targets[i], depth - 1);
				} else {}
			} else {}
		}
		return any;
	}

	/** An option's choices, asked of its mod the first time they are wanted after a boot. */
	static function ask(ctx:CpuState, line:Int):Void {
		if (firsts[line] < 0) {
			firsts[line] = choiceWords.length;
			counts[line] = 0;
			asking = line;
			offers[line](ctx);
			asking = -1;
		} else {}
	}

	/** Words for a line without arrows: narrower when longer than the panel holds. */
	static function fit(words:String, most:Int):String {
		return words.length > most ? "~sx300~" + words : words;
	}

	/**
		Whether a string table is the pause menu's: ♫ OPTIONS and DONE where this game keeps them.
		Walked once for a table, then checked at the two places found.
	**/
	static function isPauseTable(t:Int):Bool {
		if (t != walked) {
			walked = t;
			titleText = skip(t + TABLE_HEADER, TITLE);
			doneText = skip(titleText, DONE - TITLE);
		} else {}
		return matches(titleText, "# OPTIONS") && matches(doneText, "DONE");
	}

	/** Past `count` strings from `at` (a table's strings are short: the walk stops at 4 KB). */
	static function skip(at:Int, count:Int):Int {
		var p = at;
		var n = count;
		final end = (at + 4096) | 0;
		while (n > 0 && p < end) {
			while (p < end && ModHost.read8u(p) != 0) p++;
			p++;
			n--;
		}
		return p;
	}

	static function matches(at:Int, s:String):Bool {
		var same = ModHost.read8u(at + s.length) == 0;
		for (i in 0...s.length) {
			final c:Null<Int> = s.charCodeAt(i);
			var v = 0;
			if (c != null) v = c;
			else {}
			if (ModHost.read8u(at + i) != v) same = false;
			else {}
		}
		return same;
	}

	/** A string into guest memory, NUL-terminated, at most TABLE_BYTES - TABLE_HEADER - 1 of it. */
	static function write(at:Int, s:String):Void {
		var n = s.length;
		if (n > TABLE_BYTES - TABLE_HEADER - 1) n = TABLE_BYTES - TABLE_HEADER - 1;
		else {}
		for (i in 0...n) {
			final c:Null<Int> = s.charCodeAt(i);
			var v = 0;
			if (c != null) v = c;
			else {}
			ModHost.write8((at + i) | 0, v);
		}
		ModHost.write8((at + n) | 0, 0);
	}
}
