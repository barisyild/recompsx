import kernel.KMouse;

/**
	The HLE kernel's mouse (`kernel.KMouse`, ADR-0038) the same on every target: fractions of the
	picture turned into the display's pixels at its edges and middle and for each display size,
	moves counted only when the pointer comes onto the picture or moves on it, presses counted per
	button on the sample they go down, and nothing held while the pointer is off the picture. The
	backends here have no mouse, so the samples are fed by hand.
**/
class Mouse {
	public static function main():Void {
		Conf.feedName("Mouse");
		KMouse.init();
		KMouse.sample();
		Conf.expect("no mouse, not over", KMouse.over ? 1 : 0, 0);

		KMouse.update(false, 1000, 1000, 1, 512, 240);
		Conf.expect("off the picture: no move", KMouse.moves, 0);
		Conf.expect("off the picture: nothing held", KMouse.buttons, 0);

		KMouse.update(true, 32768, 32768, 0, 512, 240);
		Conf.expect("middle x", KMouse.x, 256);
		Conf.expect("middle y", KMouse.y, 120);
		Conf.expect("coming over is a move", KMouse.moves, 1);
		KMouse.update(true, 32768, 32768, 0, 512, 240);
		Conf.expect("standing still is not", KMouse.moves, 1);

		for (f in [0, 1, 255, 256, 32767, 65279, 65535]) {
			for (w in [256, 320, 368, 512, 640]) {
				KMouse.update(true, f, f, 0, w, 480);
				Conf.feed(KMouse.x);
				Conf.feed(KMouse.y);
			}
		}
		Conf.expect("the right edge of 640", KMouse.x, 639);
		Conf.expect("the bottom edge of 480", KMouse.y, 479);
		final moved = KMouse.moves;

		KMouse.update(true, 65535, 65535, KMouse.LEFT, 640, 480);
		Conf.expect("a press", KMouse.clicks(0), 1);
		KMouse.update(true, 65535, 65535, KMouse.LEFT, 640, 480);
		Conf.expect("held is still one", KMouse.clicks(0), 1);
		KMouse.update(true, 65535, 65535, 0, 640, 480);
		KMouse.update(true, 65535, 65535, KMouse.LEFT | KMouse.RIGHT, 640, 480);
		Conf.expect("pressed again", KMouse.clicks(0), 2);
		Conf.expect("the right button", KMouse.clicks(1), 1);
		KMouse.update(true, 65535, 65535, KMouse.MIDDLE | KMouse.BACK | 32, 640, 480);
		Conf.expect("the middle one", KMouse.clicks(2), 1);
		Conf.expect("the back one", KMouse.clicks(3), 1);
		Conf.expect("only five buttons", KMouse.buttons, KMouse.MIDDLE | KMouse.BACK);
		KMouse.update(true, 65535, 65535, KMouse.FORWARD, 640, 480);
		Conf.expect("forward", KMouse.clicks(4), 1);
		Conf.expect("pressing is not moving", KMouse.moves, moved);

		KMouse.update(false, 0, 0, KMouse.LEFT, 640, 480);
		Conf.expect("off again: nothing held", KMouse.buttons, 0);
		Conf.expect("off again: where it left", KMouse.x, 639);
		KMouse.update(true, 65535, 65535, KMouse.LEFT, 640, 480);
		Conf.expect("back where it left is a move", KMouse.moves, moved + 1);
		Conf.expect("and a press held over it counts", KMouse.clicks(0), 3);
		Conf.feed(KMouse.moves);
		for (b in 0...5) Conf.feed(KMouse.clicks(b));
		Conf.report("Mouse");
	}
}
