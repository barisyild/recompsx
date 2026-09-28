package onlinemenu;

import core.CpuState;
import mod.ModHost;
import shim.IntMath;

/**
	What the mod knows about Crash Bash's menus, and the few things it asks the game to do.

	Every address here is the NTSC-U pressing's (game.json's exeSha256 pins it); the facts are in
	games/SCUS94570/notes.md, "The main menu".
**/
class Game {
	public static inline var BUILD_MENU = 0x80095bec;      // boot: (slot a0, records a1)
	public static inline var MAIN_FRAME = 0x800b3ca8;      // stage: Select Game Type, every frame
	public static inline var MAIN_ANIMATE = 0x800b3a9c;    // stage: the frame's first call — the
	                                                       // platform and its character, slot 1
	public static inline var MAIN_RECORDS = 0x800b8518;    // stage: the main menu's list
	public static inline var ADVENTURE_TEXT = 0x800b333c;  // stage: what its first line says
	public static inline var SELECTION = 0x800b95f0;       // stage: 0 adventure .. 3 options
	public static inline var DESC_TIMER = 0x800b9624;      // stage: frames the description stays up
	public static inline var PAD_EDGES = 0x80051380;       // buttons pressed this frame
	public static inline var IDLE = 0x80051604;            // exe: frames with no pad input; past
	                                                       //   900 the menu's frame starts the demo
	public static inline var MENUS = 0x800a0e78;           // menu objects, 9Ch each; +6Ch widgets
	public static inline var SOUND = 0x80022660;           // (id, 0, 0, 1000h; 1E00h, 0 on the stack)

	// A screen's records: 36 bytes; type 3 a text line, 4 a panel or bar, below 2 the end.
	public static inline var RECORD = 36;
	public static inline var RECORD_X = 4;                 // halfword: 8000h | a 14-bit centre
	public static inline var RECORD_Y = 6;                 // halfword
	public static inline var RECORD_X1 = 6;                // a panel's: x0 at +4, x1 at +6,
	public static inline var RECORD_Y0 = 8;                //   y0 at +8, y1 at +0Ah
	public static inline var RECORD_Y1 = 0xA;
	public static inline var RECORD_TEXT = 0x14;

	// The widgets the builder makes, one per record, 0A8h bytes, contiguous.
	public static inline var WIDGET = 0xA8;
	public static inline var WIDGET_FLAGS = 0;             // 8000h: drawn
	public static inline var WIDGET_TEXT = 0x6C;
	public static inline var WIDGET_STATE = 0x7C;          // 0 plain, 2 highlighted

	public static inline var PAD_UP = 0x10;
	public static inline var PAD_RIGHT = 0x20;
	public static inline var PAD_DOWN = 0x40;
	public static inline var PAD_LEFT = 0x80;
	public static inline var PAD_START = 0x800;
	public static inline var PAD_TRIANGLE = 0x1000;
	public static inline var PAD_CROSS = 0x4000;
	public static inline var PAD_SQUARE = 0x8000;

	// The menus' own sounds: the cursor, a choice made, and going back.
	public static inline var SOUND_MOVE = 0x190;
	public static inline var SOUND_SELECT = 0x192;
	public static inline var SOUND_BACK = 0x195;

	/** Slot 0's widgets: Select Game Type's, or whatever the mod built there. */
	public static inline function widgets():Int return ModHost.read32(MENUS + 0x6C);

	public static inline function widget(i:Int):Int return (widgets() + i * WIDGET) | 0;

	/** A centred x as a text record holds it. */
	public static inline function centred(x:Int):Int return 0x8000 | (x & 0x3FFF);

	/** Builds slot 0 from `records`, as a screen's enter function does. */
	public static function build(ctx:CpuState, records:Int):Void {
		ctx.a0 = 0;
		ctx.a1 = records;
		ModHost.call(ctx, BUILD_MENU);
	}

	/** One of the menus' sounds, called as the frame handler calls it. */
	public static function sound(ctx:CpuState, id:Int):Void {
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

	/** Record `to` of `dst` becomes a copy of record `from` of `src`. */
	public static function copyRecord(dst:Int, to:Int, src:Int, from:Int):Void {
		for (w in 0...9) {
			ModHost.write32((dst + to * RECORD + w * 4) | 0, ModHost.read32((src + from * RECORD + w * 4) | 0));
		}
	}

	public static inline function record(list:Int, i:Int):Int return (list + i * RECORD) | 0;

	/**
		A display pixel in the menus' own units. A record's x and y are in a 640 x 480 space centred
		on the screen, which the widget draw (8001C690h) scales to the display it draws on — x times
		the display's width over 640, y halved for its 240 lines — so the cursor's pixels go back
		the same way. A text line's y is its top; its letters are about 28 units tall, and 20 wide.
	**/
	public static function pointerX(px:Int):Int return IntMath.div(px * 640, ModHost.displayWidth()) - 320;

	public static function pointerY(py:Int):Int return IntMath.div(py * 480, ModHost.displayHeight()) - 240;
}
