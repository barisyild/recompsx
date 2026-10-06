package gpu;

import shim.Backend;

/**
	What the television is looking at.

	VRAM is a 1024x512 sheet and only a window of it is on screen. Which window is decided by two
	GP1 registers — an origin and a mode — and by nothing else, which is what makes this a pure
	read: the scanout never touches emulated state, so it can run once a frame or not at all and
	the machine behaves identically. That is also why it is safe for the headless target to do
	nothing with it.

	Called once per vblank, because that is when the display would have latched a new frame. Games
	swap buffers by writing a new origin during vblank, and taking the window here rather than at
	the moment of the write is what makes double-buffering look right instead of showing half of
	each buffer.

	Resolution table from psx-spx "GP1(08h) - Display mode".
**/
class Scanout {
	/** The five horizontal resolutions the hardware offers, in the order the mode bits name them. */
	static inline var HRES_256 = 256;
	static inline var HRES_320 = 320;
	static inline var HRES_512 = 512;
	static inline var HRES_640 = 640;
	static inline var HRES_368 = 368;

	public static function present():Void {
		// Under hardware drawing, VRAM drawn off screen since the last present is reported
		// before a picture is made (Gpu.offscreen). Nothing to do otherwise.
		Gpu.flushDrawn();
		if (!Gpu.displayOn()) return blank();
		else {}
		final origin = Gpu.displayOrigin();
		final mode = Gpu.displayModeBits();
		// Bits 0..9 are the X of the window in halfwords, bits 10..18 its Y.
		final x = origin & 0x3FF;
		final y = (origin >>> 10) & 0x1FF;
		Gpu.shown(x, y, width(mode), height(mode));
		var flags = 0;
		if ((mode & 0x10) != 0) flags |= Backend.PRESENT_24BPP;
		else {}
		if ((mode & 0x20) != 0) flags |= Backend.PRESENT_INTERLACE;
		else {}
		if ((mode & 0x08) != 0) flags |= Backend.PRESENT_PAL;
		else {}
		if (kernel.KCard.moving) flags |= Backend.PRESENT_FAST;
		else {}
		// Channel 2 walks a list over time (ADR-0039), so a vblank can come while the GPU is half
		// way through a frame. What VRAM shows is not affected — a double-buffered game is drawing
		// into the buffer it does not show — but a backend drawing the primitives it is handed
		// must not close its picture here, or the frame is shown in two halves.
		if (dma.Dma.listWalking()) flags |= Backend.PRESENT_DRAWING;
		else {}
		// A program drawing the picture anew asked for this one to stay up (HoldPicture).
		if (kernel.KVideo.holdOne()) flags |= Backend.PRESENT_HOLD;
		else {}
		Backend.present(Vram.data, x, y, width(mode), height(mode), flags | shape());
		frames++;
	}

	/** Display off still needs saying: a black screen is a picture, and a stale one is a lie. */
	static function blank():Void {
		var flags = kernel.KCard.moving ? Backend.PRESENT_FAST : 0;
		if (kernel.KVideo.holdOne()) flags |= Backend.PRESENT_HOLD;
		else {}
		Backend.present(Vram.data, 0, 0, 0, 0, flags | shape());
		frames++;
	}

	/**
		The screen's shape and the picture's (ADR-0064): a 16:9 screen, and a picture that fills it —
		drawn for it, or stretched over it (STRETCH); a picture drawn for 4:3 on 16:9 is shown at 4:3,
		between black bars.
	**/
	static inline function shape():Int {
		return (kernel.KVideo.wide() ? Backend.PRESENT_WIDE : 0)
			| (kernel.KVideo.fills() ? Backend.PRESENT_WIDE_FILL : 0);
	}

	/**
		Horizontal resolution.

		Bit 6 overrides the two low bits entirely — 368 is not part of their sequence, it is a
		separate mode that ignores them.
	**/
	public static function width(mode:Int):Int {
		if ((mode & 0x40) != 0) return HRES_368;
		else if ((mode & 3) == 0) return HRES_256;
		else if ((mode & 3) == 1) return HRES_320;
		else if ((mode & 3) == 2) return HRES_512;
		else return HRES_640;
	}

	/** 480 only when interlace is on as well: bit 2 alone means the game asked for a taller
	    buffer it is drawing into one field at a time. */
	public static function height(mode:Int):Int {
		return (mode & 0x04) != 0 && (mode & 0x20) != 0 ? 480 : 240;
	}

	/** Frames handed to the platform. Not the same as vblanks if the display is off. */
	public static var frames(default, null) = 0;

	public static function init():Void {
		frames = 0;
	}
}
