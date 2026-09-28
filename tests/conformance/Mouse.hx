import kernel.KMouse;
import sio.SonyMouse;

/**
	The machine's mouse (`sio.SonyMouse`, fed by `kernel.KMouse`, ADR-0040) the same on every
	target: what a Sony Mouse answers a poll — ID 12h, the buttons halfword with bit 11 the left and
	bit 10 the right (0 = pressed), the motion as signed bytes — the motion toward the host's pointer
	at most 7Fh a poll, each unit on its own, a click between two polls kept, the side buttons as the
	right one, the cursor held inside the display; and the pointer the backend shows — none until a
	poll, hidden while a pad is in use, gone when the polls stop. The backends here have no mouse, so
	the host's samples are fed by hand.
**/
class Mouse {
	static var reply:Array<Int>;

	public static function main():Void {
		Conf.feedName("Mouse");
		sio.Pads.init();
		KMouse.init();
		reply = [0, 0, 0, 0];
		KMouse.sample();
		// A 320 x 240 display, with no pointer over it yet: a unit starts in its middle.
		KMouse.update(false, 0, 0, 0, 320, 240);
		final unit = SonyMouse.plug();
		Conf.expect("a unit", unit, 0);
		Conf.expect("no host mouse: nothing answers", SonyMouse.read(unit, reply), SonyMouse.NONE);
		Conf.expect("and the bytes read FFh", reply[1], 0xFF);
		Conf.expect("no poll answered: no pointer", KMouse.pointer(), KMouse.POINTER_OFF);

		// The host's pointer over the middle of a 320 x 240 display, where the unit starts.
		host(true, 32768, 32768, 0, 320, 240);
		Conf.expect("the mouse answers", SonyMouse.read(unit, reply), SonyMouse.ID);
		Conf.expect("the buttons' low byte", reply[0], 0xFF);
		Conf.expect("no button: bits 10 and 11 set", reply[1], 0xFC);
		Conf.expect("no motion across", reply[2], 0);
		Conf.expect("no motion down", reply[3], 0);
		Conf.expect("polled: the pointer shows", KMouse.pointer(), KMouse.POINTER_SHOWN);

		// To the top right: at most 7Fh a poll, until the unit is on the host's pointer.
		host(true, 65535, 0, 0, 320, 240);
		poll(unit);
		Conf.expect("a full step right", reply[2], 0x7F);
		Conf.expect("up is negative", reply[3], 0x88);
		poll(unit);
		Conf.expect("the rest of the way", reply[2], 32);
		Conf.expect("already there down", reply[3], 0);
		poll(unit);
		Conf.expect("on it: no motion", reply[2] | reply[3], 0);

		// Another reader's unit goes the whole way itself, from the middle.
		final other = SonyMouse.plug();
		Conf.expect("a second unit", other, 1);
		poll(other);
		Conf.expect("its own first step", reply[2], 0x7F);
		poll(other);
		Conf.expect("its own second", reply[2], 32);

		// Buttons: a click between two polls is kept for the next.
		host(true, 65535, 0, KMouse.LEFT, 320, 240);
		host(true, 65535, 0, 0, 320, 240);
		poll(unit);
		Conf.expect("the left, clicked between polls", reply[1], 0xF4);
		poll(unit);
		Conf.expect("and then let go", reply[1], 0xFC);
		host(true, 65535, 0, KMouse.RIGHT, 320, 240);
		poll(unit);
		Conf.expect("the right", reply[1], 0xF8);
		host(true, 65535, 0, KMouse.BACK, 320, 240);
		poll(unit);
		Conf.expect("the back side button is the right", reply[1], 0xF8);
		host(true, 65535, 0, KMouse.FORWARD | KMouse.LEFT | KMouse.MIDDLE, 320, 240);
		poll(unit);
		Conf.expect("forward and left: both; the middle nothing", reply[1], 0xF0);
		poll(other);
		Conf.expect("the other unit kept every press since its poll", reply[1], 0xF0);
		host(true, 65535, 0, 0, 320, 240);

		// Off the picture the pointer stays where it left; back on elsewhere, the units follow.
		host(false, 0, 0, 0, 320, 240);
		poll(unit);
		Conf.expect("off: no motion", reply[2] | reply[3], 0);
		Conf.expect("off: nothing held", reply[1], 0xFC);
		host(true, 0, 65535, 0, 320, 240);
		for (i in 0...4) {
			poll(unit);
			Conf.feed(reply[2]);
			Conf.feed(reply[3]);
		}
		Conf.expect("across to the left edge", reply[2] | reply[3], 0);

		// A smaller display: the pointer and every cursor are held inside it.
		host(true, 65535, 65535, 0, 256, 240);
		for (i in 0...5) {
			poll(unit);
			Conf.feed(reply[2]);
			Conf.feed(reply[3]);
		}
		Conf.expect("the right edge of 256", KMouse.x, 255);
		for (f in [0, 1, 255, 256, 32767, 65279, 65535]) {
			for (w in [256, 320, 368, 512, 640]) {
				host(true, f, f, 0, w, 480);
				Conf.feed(KMouse.x);
				Conf.feed(KMouse.y);
			}
		}

		// The pointer: hidden while a pad is in use, shown when the mouse moves or clicks — the
		// mouse wins a sample with both — and gone when no poll has come for a while.
		host(true, 1000, 1000, 0, 640, 480);
		poll(unit);
		Conf.expect("settling changes nothing", KMouse.showOrHide(0) ? 1 : 0, 0);
		Conf.expect("a pad press hides", KMouse.showOrHide(0x4000) ? 1 : 0, 1);
		Conf.expect("hidden", KMouse.pointer(), KMouse.POINTER_HIDDEN);
		Conf.expect("a held button is no new press", KMouse.showOrHide(0x4000) ? 1 : 0, 0);
		KMouse.update(true, 2000, 2000, 0, 640, 480);
		Conf.expect("a move shows", KMouse.showOrHide(0x4000) ? 1 : 0, 1);
		Conf.expect("another pad button hides", KMouse.showOrHide(0x4010) ? 1 : 0, 1);
		KMouse.update(true, 2000, 2000, KMouse.LEFT, 640, 480);
		Conf.expect("a click shows, too", KMouse.showOrHide(0x4010) ? 1 : 0, 1);
		KMouse.update(true, 3000, 3000, 0, 640, 480);
		Conf.expect("the mouse wins over a pad in one sample", KMouse.showOrHide(0x4050) ? 1 : 0, 0);
		Conf.expect("shown", KMouse.pointer(), KMouse.POINTER_SHOWN);
		for (i in 0...KMouse.IN_USE + 1) KMouse.frame(0);
		Conf.expect("no poll for a while: no pointer", KMouse.pointer(), KMouse.POINTER_OFF);
		poll(unit);
		Conf.expect("a poll brings it back", KMouse.pointer(), KMouse.POINTER_SHOWN);

		// The same read as SIO0 makes it: 01h, 42h, zeros; back Hi-Z, 12h, 5Ah and the four bytes.
		final frame = [0x01, 0x42, 0, 0, 0, 0, 0, 0];
		final back = [for (_ in 0...8) 0];
		host(true, 0, 0, KMouse.LEFT, 640, 480);
		Conf.expect("a read answers", SonyMouse.exchange(unit, frame, 8, back) ? 1 : 0, 1);
		for (b in back) Conf.feed(b);
		Conf.expect("Hi-Z under the address", back[0], 0xFF);
		Conf.expect("the ID", back[1], 0x12);
		Conf.expect("5Ah", back[2], 0x5A);
		Conf.expect("the left held", back[4], 0xF4);
		Conf.expect("past the data: FFh", back[7], 0xFF);
		frame[1] = 0x43;
		Conf.expect("not a read: nothing", SonyMouse.exchange(unit, frame, 8, back) ? 1 : 0, 0);
		Conf.report("Mouse");
	}

	/** One vblank's sample of the host's mouse, as the kernel takes it. */
	static function host(on:Bool, fx:Int, fy:Int, held:Int, w:Int, h:Int):Void {
		KMouse.update(on, fx, fy, held, w, h);
		KMouse.frame(0);
	}

	/** A poll, its bytes fed. */
	static function poll(unit:Int):Void {
		Conf.feed(SonyMouse.read(unit, reply));
		for (b in reply) Conf.feed(b);
	}
}
