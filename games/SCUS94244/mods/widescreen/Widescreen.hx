package widescreen;

import core.CpuState;
import menu.Menu;
import menu.Pro;
import mod.ModHost;

/**
	WIDESCREEN, an option in OPTIONS on the pause screen (ADR-0064): the console's screen — 4:3, 16:9,
	or 16:9 with the picture stretched over it (STRETCH); and Crash Bandicoot: Warped drawn for a 16:9
	one.

	The screen's shape is not this mod's: it is the console's, a setting kept across sessions that
	the "PS1 Pro" system calls read and set (`kernel.KPro`, ADR-0060; docs/specs/ps1pro.md), as a
	game's own options menu would — GetWidescreen, SetWidescreen. What the mod adds is the game's side:
	on 16:9 the game draws for it, anamorphic — its horizontal squeezed by 3/4, which the screen
	stretches back — and says so (SetWidePicture), so the console fills the screen with it; on
	STRETCH it draws as it always has, and the console stretches its 4:3 pictures over the screen;
	on 4:3 nothing changes.

	**The squeeze is the game's own aspect routine, once more.** Each frame the camera's update
	(f_80018a54) builds the camera's rotation from its angles (80065C90h) and hands it to f_80018988,
	which makes the matrix the world and the objects are projected with (80065CB0h): row 0 copied, row
	1 times -5/8 — the PlayStation's 512-wide pixels are narrower than they are tall, so the game
	shrinks its vertical to match — row 2 negated, the translation (the camera's position, in the
	world) copied. On a 16:9 screen the mod scales row 0 by 3/4 as well: every view-space x, so every
	projected one, comes out three quarters as far from the centre, and the game shows a third more of
	its world on each side. What it culls against its view follows by itself.

	**Only pictures of the camera are drawn wide.** The game draws a picture through its camera only
	in its main loop — the world and the objects, paused or not; its loading screens and its films
	(MDEC) are 4:3 pictures, drawn without one. So the mod says its pictures are drawn for 16:9 while
	the camera's update runs (a vblank at a time, `onFrame`: it ran within the last CAMERA_SLACK
	vblanks) and for 4:3 otherwise, and the console keeps those to the middle of the screen.

	How it is shown and chosen is the menu mod's (`Menu.option`; this mod needs it): a button that opens
	its choices. After a choice the pause screen's frozen picture, drawn at the old
	shape, is drawn anew (`Menu.redraw`): the camera's update runs every frame, paused or not, so the
	redraw's frames are projected the new way.

	**What faces the screen is squeezed where it is drawn.** Sprites, the world's billboards (wumpa
	fruit) and the screen's own objects (the HUD's icons, panels) are drawn through one matrix of
	their own, not the camera's (80041FD8h): its row 0 times 3/4 as well narrows each about its own
	place, which for the world's is the camera's squeezed one; the screen's objects are placed from
	their x (8003E67Ch), times 3/4 too, toward the screen's middle. Texts — the HUD's counters, the
	title's NEW GAME, DEMO — are glyphs the text routine projects itself (8001C3F8h): the polygons
	it writes are narrowed toward the middle afterwards, x' = 256 + (x - 256) x 3/4. So the HUD
	keeps its 4:3 places, in the middle three quarters of the screen, at its own proportions.

	**The pause screen is 4:3.** Its game view is a picture of the world shrunk into a corner and its
	panels are laid out around it for 4:3; squeezing both would keep them together only by moving
	the view, its bars and its projection as well. So while the pause screen is up — its view
	shrinking or growing (the shrink, 8006901Ch), or settled, neither the world nor the objects drawn
	(the flags the game asks for, 80068F08h; the title screen draws objects) — nothing is squeezed and
	the console is told the pictures are 4:3: the pause screen is shown in the middle of the 16:9
	screen, its frozen view as it was drawn.

	What it does not reach: the game culls its world's polygons on the screen (all three corners off
	one side), which follows the squeeze, but which parts of a level are drawn at all comes with the
	camera's place on its path, made for a 4:3 view — at the sides a corner of floor can be missing.
**/
class Widescreen {
	/** The game's aspect routine (a0 the projection's matrix, a1 the rotation's); see the class. */
	static inline var ASPECT = 0x80018988;
	/**
		The game's matrix for what faces the screen (see the class): five words in t0..t4, a GTE
		matrix's (row 0 in t0 and t1's low half), into the GTE with row 1 times 5/8 and row 2 negated.
	**/
	static inline var FACING = 0x80041fd8;
	/** A screen object's place, its draw record's first routine: the GTE's translation from the
	    object's x and y (+60h, +64h of the object in $gp), x / 256 from the screen's middle. */
	static inline var SCREEN_PLACE = 0x8003e67c;
	static inline var X = 0x60;
	/** A text's glyphs, into the frame's primitive buffer: the frame being built (*80061A84h), its
	    buffer's next free byte at +8. */
	static inline var GLYPHS = 0x8001c3f8;
	static inline var BUILDING = 0x80061A84;
	static inline var BUILDING_NEXT = 8;
	/** The screen's middle across, in the GPU's coordinates: the 512-pixel display's. */
	static inline var MIDDLE = 256;
	/** At most this many packets of a text are narrowed (a guard: a text writes one a glyph). */
	static inline var MOST_PACKETS = 1024;
	// The game's state (games/SCUS94244/notes.md, "The frozen game"): the display flags it asks for
	// (bit 0 the world, 08000000h the objects) and the pause screen's shrink.
	static inline var FLAGS = 0x80068F08;
	static inline var WORLD = 0x00000001;
	static inline var OBJECTS = 0x08000000;
	static inline var SHRINK = 0x8006901C;
	/** Vblanks a picture is still the camera's after its update last ran: the game runs at 30 Hz,
	    a frame every second vblank, and a busy one takes a third. */
	static inline var CAMERA_SLACK = 8;

	// The screen's shapes, as the PS1 Pro calls have them, and the option's choices in that order.
	static inline var NARROW = 0;
	static inline var WIDE = 1;
	static inline var STRETCH = 2;
	static final CHOICES = ["4:3", "16:9", "STRETCH"];

	/** The console was asked for its screen's shape. */
	static var asked = false;
	/** The console's screen: NARROW, WIDE or STRETCH. */
	static var shape = NARROW;
	/** The screen is 16:9 and the game draws for it: shape is WIDE. */
	static var wide = false;
	/** Vblanks, and the one the camera's update last ran in. */
	static var vblanks = 0;
	static var camera = -1000;
	/** What the console was last told the pictures are drawn for (SetWidePicture): 1 16:9, 0 4:3,
	    -1 nothing yet. */
	static var told = -1;

	public static function install():Void {
		ModHost.onBoot(boot);
		ModHost.onFrame(frame);
		ModHost.hook(ASPECT, aspect);
		ModHost.hook(FACING, facing);
		ModHost.hook(SCREEN_PLACE, screenPlace);
		ModHost.hook(GLYPHS, glyphs);
		Menu.option(Menu.OPTIONS, "WIDESCREEN", choices, current, choose);
	}

	static function boot(ctx:CpuState):Void {
		asked = false;
		shape = NARROW;
		wide = false;
		vblanks = 0;
		camera = -1000;
		told = -1;
	}

	/**
		A vblank: the pictures are drawn for 16:9 while the screen is, the camera's update runs and
		the pause screen is not up, and for 4:3 otherwise — the console told when that changes.
	**/
	static function frame(ctx:CpuState):Void {
		vblanks = (vblanks + 1) | 0;
		final now = drawingWide() ? 1 : 0;
		if (asked && now != told) {
			told = now;
			Pro.call(ctx, Pro.SET_WIDE_PICTURE, now);
		} else {}
	}

	/** The console's screen, asked once: the game draws for a 16:9 one from its first camera on. */
	static function ask(ctx:CpuState):Void {
		asked = true;
		if (Pro.present(ctx)) shapeTo(ctx, Pro.call(ctx, Pro.GET_WIDESCREEN, 0));
		else {}
	}

	/** The console's answer taken: the game draws for 16:9 on WIDE (and says so at the next vblank). */
	static function shapeTo(ctx:CpuState, answer:Int):Void {
		shape = answer == WIDE || answer == STRETCH ? answer : NARROW;
		wide = shape == WIDE;
	}

	/**
		The pause screen is up (see the class): its view shrinking or growing, or settled — neither the
		world nor the objects drawn.
	**/
	static function paused():Bool {
		return ModHost.read32(SHRINK) > 0 || (ModHost.read32(FLAGS) & (WORLD | OBJECTS)) == 0;
	}

	/** The game draws this frame for 16:9: the screen is, the camera's update runs, no pause screen. */
	static function drawingWide():Bool {
		return wide && vblanks - camera <= CAMERA_SLACK && !paused();
	}

	/** x toward the screen's middle (or a length) times 3/4, as the camera's squeeze has the world. */
	static inline function narrow(v:Int):Int {
		return (v * 3) >> 2;
	}

	/** The projection's matrix made, and for a 16:9 picture its row 0 times 3/4 (see the class). */
	static function aspect(ctx:CpuState, addr:Int):Bool {
		final to = ctx.a0;
		ModHost.callOriginal(ctx, addr);
		if (!asked) ask(ctx);
		else {}
		camera = vblanks;
		if (wide && !paused()) {
			for (i in 0...3) {
				final at = to + i * 2;
				ModHost.write16(at, narrow(ModHost.read16s(at)));
			}
		} else {}
		return true;
	}

	/**
		The matrix of what faces the screen, for a 16:9 picture with its row 0 times 3/4: what the
		game handed in (t0, t1's low half) is put back after, the rest of the routine's own left.
	**/
	static function facing(ctx:CpuState, addr:Int):Bool {
		var taken = false;
		if (drawingWide()) {
			final t0 = ctx.t0;
			final t1 = ctx.t1;
			ctx.t0 = (narrow(t0 >> 16) << 16) | (narrow((t0 << 16) >> 16) & 0xFFFF);
			ctx.t1 = (t1 & 0xFFFF0000) | (narrow((t1 << 16) >> 16) & 0xFFFF);
			ModHost.callOriginal(ctx, addr);
			ctx.t0 = t0;
			ctx.t1 = (ctx.t1 & 0xFFFF0000) | (t1 & 0xFFFF);
			taken = true;
		} else {}
		return taken;
	}

	/** A screen object placed, for a 16:9 picture at 3/4 of its x from the screen's middle. */
	static function screenPlace(ctx:CpuState, addr:Int):Bool {
		var taken = false;
		if (drawingWide()) {
			final at = ctx.gp + X;
			final x = ModHost.read32(at);
			ModHost.write32(at, narrow(x));
			ModHost.callOriginal(ctx, addr);
			ModHost.write32(at, x);
			taken = true;
		} else {}
		return taken;
	}

	/** A text's glyphs drawn, and for a 16:9 picture narrowed toward the screen's middle. */
	static function glyphs(ctx:CpuState, addr:Int):Bool {
		var taken = false;
		if (drawingWide()) {
			final building = ModHost.read32(BUILDING);
			final from = ModHost.read32(building + BUILDING_NEXT);
			ModHost.callOriginal(ctx, addr);
			narrowPackets(from, ModHost.read32(building + BUILDING_NEXT));
			taken = true;
		} else {}
		return taken;
	}

	/**
		The packets the game wrote from `from` to `to` of its primitive buffer — a tag word, the
		packet's length in its top byte, then the GPU's words: every polygon's x toward the screen's
		middle by 3/4. A packet with anything else in it is left as it is from there.
	**/
	static function narrowPackets(from:Int, to:Int):Void {
		var p = from;
		var packets = 0;
		while (p < to && packets < MOST_PACKETS) {
			final words = (ModHost.read32(p) >> 24) & 0xFF;
			narrowPacket(p + 4, words);
			p = (p + 4 + words * 4) | 0;
			packets++;
		}
	}

	static function narrowPacket(at:Int, words:Int):Void {
		var i = 0;
		while (i < words) {
			final command = ModHost.read8u(at + i * 4 + 3);
			final n = command >= 0x20 && command < 0x40 ? polygonWords(command) : 0;
			if (n > 0 && i + n <= words) {
				narrowPolygon(at + i * 4, command);
				i += n;
			} else if (command >= 0xE1 && command <= 0xE6) {
				i++;
			} else {
				i = words;
			}
		}
	}

	/** A polygon's words: its command, then per corner its colour (shaded, past the first), place and texture place (textured). */
	static function polygonWords(command:Int):Int {
		final corners = (command & 0x08) != 0 ? 4 : 3;
		final textured = (command & 0x04) != 0 ? 1 : 0;
		final shaded = (command & 0x10) != 0 ? 1 : 0;
		return 1 + corners * (1 + textured) + shaded * (corners - 1);
	}

	static function narrowPolygon(at:Int, command:Int):Void {
		final corners = (command & 0x08) != 0 ? 4 : 3;
		final textured = (command & 0x04) != 0 ? 1 : 0;
		final shaded = (command & 0x10) != 0 ? 1 : 0;
		var w = 1;
		for (c in 0...corners) {
			if (c > 0) w += shaded;
			else {}
			final place = at + w * 4;
			final word = ModHost.read32(place);
			final x = (word << 21) >> 21;
			ModHost.write32(place, (word & 0xFFFF0000) | ((MIDDLE + narrow(x - MIDDLE)) & 0xFFFF));
			w += 1 + textured;
		}
	}

	/** The three shapes, on a console with the PS1 Pro calls. */
	static function choices(ctx:CpuState):Void {
		if (!asked) ask(ctx);
		else {}
		if (Pro.present(ctx)) {
			for (i in 0...CHOICES.length) Menu.offer(CHOICES[i]);
		} else {}
	}

	/** The shape in effect. */
	static function current(ctx:CpuState):Int {
		return shape;
	}

	/**
		A shape chosen: kept as the console's setting, and the game draws for what the console answers
		— one that cannot show 16:9 stays at 4:3. The pause screen's frozen picture stays as it is: it
		is 4:3 on every shape (see the class).
	**/
	static function choose(ctx:CpuState, at:Int):Void {
		final was = shape;
		if (at != was) shapeTo(ctx, Pro.call(ctx, Pro.SET_WIDESCREEN, at));
		else {}
		if (shape != was) ModHost.log("widescreen: " + CHOICES[shape]);
		else {}
	}
}
