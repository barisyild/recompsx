import kernel.KKeyboard;
import sio.Ps2Keyboard;

/**
	The machine's keyboard (`sio.Ps2Keyboard`, fed by `kernel.KKeyboard`, ADR-0040) the same on every
	target: what a poll answers — ID 96h, then a count and at most eleven PS/2 Set 2 bytes — each
	character the host typed as the US key presses that type it (Shift around it when it needs it),
	the three editing keys, nothing for what a US keyboard cannot type, a full buffer taking whole
	characters only, and typing that starts with the first poll and stops, dropping what waited,
	when the polls stop. Typing itself is the backend's and needs someone at a keyboard; the
	backends here (Node, the null backend) type nothing, so characters are fed by hand.
**/
class Keyboard {
	static var reply:Array<Int>;

	public static function main():Void {
		Conf.feedName("Keyboard");
		KKeyboard.init();
		reply = [for (_ in 0...Ps2Keyboard.REPLY) 0];
		final unit = Ps2Keyboard.plug();
		Conf.expect("a unit", unit, 0);
		Conf.expect("not typing before a poll", KKeyboard.isTyping() ? 1 : 0, 0);
		Conf.expect("a poll answers", Ps2Keyboard.read(unit, reply), Ps2Keyboard.ID);
		Conf.expect("nothing typed", reply[0], 0);
		Conf.expect("the poll starts typing", KKeyboard.isTyping() ? 1 : 0, 1);
		KKeyboard.sample();
		Conf.expect("no keyboard here, nothing typed", drain(unit), 0);

		Ps2Keyboard.type("1".code);
		Conf.expect("a digit: its key down and up", drain(unit), 3);
		Ps2Keyboard.type(".".code);
		Conf.expect("'.'", drain(unit), 3);
		Ps2Keyboard.type("A".code);
		Conf.expect("a capital: Shift around it", drain(unit), 6);
		Ps2Keyboard.type("~".code);
		Conf.expect("'~' is Shift and the key left of 1", drain(unit), 6);
		Ps2Keyboard.type(" ".code);
		Conf.expect("space", drain(unit), 3);
		for (c in [8, 10, 27]) Ps2Keyboard.type(c);
		Conf.expect("Backspace, Enter and Escape", drain(unit), 9);
		for (c in [0x15F, 0xE9, 0x1F600, 9, 0, 13, 127, -5, 0x7F, 0x110000]) Ps2Keyboard.type(c);
		Conf.expect("what a US keyboard cannot type: nothing", drain(unit), 0);

		// Eleven bytes a poll: twelve digits are 36 bytes, in four polls.
		for (i in 0...12) Ps2Keyboard.type(0x30 + (i % 10));
		for (i in 0...4) {
			Ps2Keyboard.read(unit, reply);
			Conf.feed(reply[0]);
			for (b in reply) Conf.feed(b);
		}
		Conf.expect("the last poll's three", reply[0], 3);
		Conf.expect("its bytes past the count are zero", reply[4], 0);

		// A full buffer takes whole characters: 256 bytes hold 42 capitals of 6, not a 43rd's start.
		for (i in 0...50) Ps2Keyboard.type(0x41 + (i % 26));
		Conf.expect("whole characters only", drain(unit), 252);

		// Every unit gets what is typed; each empties on its own.
		final second = Ps2Keyboard.plug();
		Ps2Keyboard.type("x".code);
		Conf.expect("the first unit", drain(unit), 3);
		Conf.expect("the second one too", drain(second), 3);

		// Without polls the keyboard plays again, and what waited is dropped.
		Ps2Keyboard.type("q".code);
		for (i in 0...KKeyboard.IN_USE + 1) KKeyboard.sample();
		Conf.expect("typing stops without polls", KKeyboard.isTyping() ? 1 : 0, 0);
		Conf.expect("and what waited is gone", drain(second), 0);
		Conf.expect("which polled again", KKeyboard.isTyping() ? 1 : 0, 1);

		// The same read as the Online Connection CD sends it: 01h, 42h, twelve zeros, 06h.
		final frame = [0x01, 0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x06];
		final back = [for (_ in 0...15) 0];
		Ps2Keyboard.type("7".code);
		Conf.expect("a read answers", Ps2Keyboard.exchange(unit, frame, 15, back) ? 1 : 0, 1);
		for (b in back) Conf.feed(b);
		Conf.expect("Hi-Z under the address", back[0], 0xFF);
		Conf.expect("the ID", back[1], 0x96);
		Conf.expect("5Ah", back[2], 0x5A);
		Conf.expect("three bytes", back[3], 3);
		Conf.expect("7's key", back[4], 0x3D);
		Conf.expect("let go", back[5], 0xF0);
		Conf.report("Keyboard");
	}

	/** Every byte waiting in a unit, fed in order, poll by poll; how many there were. */
	static function drain(unit:Int):Int {
		var n = 0;
		var more = true;
		while (more) {
			Ps2Keyboard.read(unit, reply);
			final count = reply[0];
			for (i in 0...count) Conf.feed(reply[1 + i]);
			n = n + count;
			if (count < Ps2Keyboard.PER_POLL) more = false;
			else {}
		}
		return n;
	}
}
