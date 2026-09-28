import kernel.KKeyboard;

/**
	The HLE kernel's keyboard (`kernel.KKeyboard`, ADR-0036) the same on every target: what it
	queues and in what order, what it drops (control codes but the three editing keys, surrogates,
	anything past Unicode), a full queue, the ring wrapping round, and text entry — nothing queued
	outside it, and what waited dropped when it ends. Typing itself is the backend's and needs
	someone at a keyboard; the backends here (Node, the null backend) type nothing, so the queue is
	fed by hand.
**/
class Keyboard {
	public static function main():Void {
		Conf.feedName("Keyboard");
		KKeyboard.init();
		KKeyboard.push("1".code);
		Conf.expect("nothing queued outside text entry", KKeyboard.next(), -1);

		KKeyboard.textEntry(true);
		KKeyboard.sample();
		Conf.expect("no keyboard, nothing typed", KKeyboard.next(), -1);

		final typed = [
			"1".code, ".".code, 0x15F, 0x1F600,                        // 1 . ş and an emoji
			KKeyboard.BACKSPACE, KKeyboard.ENTER, KKeyboard.ESCAPE,
			9, 0, 13, 127, 0x85, 0xD800, 0xDFFF, 0x110000, -5,         // all dropped
			" ".code, 0xA0, 0x10FFFF
		];
		for (c in typed) KKeyboard.push(c);
		Conf.expect("characters and editing keys kept, in order", drain(), 10);

		for (i in 0...70) KKeyboard.push(0x41 + (i & 15));
		Conf.expect("a full queue drops the rest", drain(), 64);

		// Round the ring: the queue's start has moved on, and the order survives the wrap.
		for (i in 0...40) KKeyboard.push(0x30 + (i & 7));
		for (i in 0...30) Conf.feed(KKeyboard.next());
		for (i in 0...50) KKeyboard.push(0x61 + (i & 15));
		Conf.expect("across the wrap", drain(), 60);

		KKeyboard.push("2".code);
		KKeyboard.textEntry(false);
		Conf.expect("ending text entry drops what waited", KKeyboard.next(), -1);
		KKeyboard.textEntry(true);
		Conf.expect("and starting it again finds nothing", KKeyboard.next(), -1);
		KKeyboard.textEntry(false);
		Conf.report("Keyboard");
	}

	/** Everything waiting, fed in order; how much there was. */
	static function drain():Int {
		var n = 0;
		var c = KKeyboard.next();
		while (c >= 0) {
			Conf.feed(c);
			n++;
			c = KKeyboard.next();
		}
		return n;
	}
}
