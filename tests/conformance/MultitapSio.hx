import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;
import sio.MemoryCard;
import sio.Multitap;
import sio.Pads;
import sio.Sio0;

/**
	The multitap on SIO0, as psx-spx "Controller and Memory Card Multitap Adaptor" describes it
	(ADR-0042). These must agree on both targets:

	  - a plain read of port 1 finds slot A;
	  - a request (third byte 01h) makes the next read the long one: ID 5A80h and four slots of
	    eight bytes, a digital pad's 41h 5Ah and buttons padded with FFh, an empty slot all FFh;
	  - asked again during a long read, the next is four bytes of garbage, then long again;
	  - slots B-D are also read directly at 02h-04h;
	  - an empty slot A leaves the address unacknowledged and the request unsent;
	  - the card behind slot A answers at 81h, and nothing answers at 82h;
	  - pad 1 is in port 2 until the game uses the tap, and in slot B only after;
	  - with the tap unplugged, both ports hold a pad directly;
	  - a headless run's tap answers as an empty port does.
**/
class MultitapSio {
	static inline var DR = 0x1F801040;
	static inline var SR = 0x1F801044;
	static inline var MODE = 0x1F801048;
	static inline var CTRL = 0x1F80104A;
	static inline var BAUD = 0x1F80104E;

	static inline var TXEN = 0x0001;
	static inline var DTR = 0x0002;
	static inline var ACK = 0x0010;
	static inline var RESET = 0x0040;
	static inline var DSRIEN = 0x1000;
	static inline var PORT2 = 0x2000;

	/** 8 bits at the BIOS's rate, BR 0088h and MUL1: 136 cycles a bit. */
	static inline var BYTE = 1088;

	// Held buttons, active high: A Cross+Up, B Circle+Start, C Square+L1; D is empty.
	static inline var PAD_A = 0x4000 | 0x0010;
	static inline var PAD_B = 0x2000 | 0x0008;
	static inline var PAD_C = 0x8000 | 0x0400;

	static var ctx:CpuState;

	public static function main():Void {
		ctx = new CpuState();
		Runtime.boot(ctx);
		Pads.set(0, true, PAD_A);
		Pads.set(1, true, PAD_B);
		Pads.set(2, true, PAD_C);
		Pads.set(3, false, 0);

		Sio0.write16(CTRL, RESET);
		Sio0.write16(BAUD, 0x88);
		Sio0.write16(MODE, 0x0D);
		Sio0.write16(CTRL, 0);

		// Before the tap is used, pad 1 is in port 2 as well: a two-player game without a tap
		// finds its second player there.
		select(PORT2);
		Conf.expect("port 2 answers its address", exchange(0x01), 0xFF);
		Conf.expect("port 2 acknowledges", acknowledged(), 1);
		Conf.expect("port 2 is a digital pad", exchange(0x42), 0x41);
		acknowledged();
		exchange(0x00);
		acknowledged();
		Conf.expect("port 2 is pad 1: Start (low)", exchange(0x00), ~PAD_B & 0xFF);
		acknowledged();
		Conf.expect("port 2 is pad 1: Circle (high)", exchange(0x00), (~PAD_B >> 8) & 0xFF);
		deselect();

		// A plain read of port 1 is slot A, as if no tap were there.
		plainRead("plain", 0x00, PAD_A);

		// Asking during a read changes nothing in it; the next one is long.
		plainRead("request", 0x01, PAD_A);
		longRead("long", 0x00);

		// No request in the long read: back to slot A.
		plainRead("after long", 0x00, PAD_A);

		// Asking every time: slot A, long, garbage, long, garbage.
		plainRead("ask 1", 0x01, PAD_A);
		longRead("ask 2", 0x01);
		garbageRead("ask 3", 0x01);
		longRead("ask 4", 0x01);
		garbageRead("ask 5", 0x00);
		plainRead("after garbage without asking", 0x00, PAD_A);

		// The tap has been used: pad 1 is in slot B only, and port 2 is empty.
		Conf.expect("the tap is in use", Multitap.inUse ? 1 : 0, 1);
		select(PORT2);
		Conf.expect("port 2 now answers Hi-Z", exchange(0x01), 0xFF);
		Conf.expect("and nobody acknowledges", acknowledged(), 0);
		deselect();

		// Slots B-D read directly.
		select(0);
		Conf.expect("slot B's address", exchange(0x02), 0xFF);
		Conf.expect("slot B acknowledges", acknowledged(), 1);
		Conf.expect("slot B is a digital pad", exchange(0x42), 0x41);
		acknowledged();
		Conf.expect("slot B's ID high", exchange(0x00), 0x5A);
		acknowledged();
		Conf.expect("slot B's buttons low", exchange(0x00), ~PAD_B & 0xFF);
		acknowledged();
		Conf.expect("slot B's buttons high", exchange(0x00), (~PAD_B >> 8) & 0xFF);
		Conf.expect("slot B's last byte is not acknowledged", acknowledged(), 0);
		deselect();
		select(0);
		exchange(0x04);
		Conf.expect("empty slot D does not acknowledge", acknowledged(), 0);
		deselect();

		// Slot A empty: its address is not acknowledged, so no request is sent — the read after
		// the plug-in is slot A's again, although the one before the unplug asked.
		plainRead("ask before unplugging", 0x01, PAD_A);
		Pads.set(0, false, 0);
		select(0);
		exchange(0x01);
		Conf.expect("empty slot A does not acknowledge", acknowledged(), 0);
		deselect();
		Pads.set(0, true, PAD_A);
		plainRead("after plugging back", 0x00, PAD_A);

		// Cards: slot A's is the machine's one, and slots B-D have none.
		MemoryCard.insert("SCUS94570", "", false);
		select(0);
		Conf.expect("card A's address", exchange(0x81), 0xFF);
		Conf.expect("card A acknowledges", acknowledged(), 1);
		Conf.expect("card A's FLAG", exchange(0x53), MemoryCard.flagByte());
		deselect();
		select(0);
		exchange(0x82);
		Conf.expect("card B does not acknowledge", acknowledged(), 0);
		deselect();

		// Without the tap, both ports hold a pad directly, whatever the game did before.
		Multitap.plugged = false;
		select(0);
		exchange(0x01);
		acknowledged();
		exchange(0x42);
		acknowledged();
		exchange(0x01);
		deselect();
		plainRead("untapped port 1, after a request", 0x00, PAD_A);
		select(PORT2);
		exchange(0x01);
		Conf.expect("untapped port 2 holds pad 1", acknowledged(), 1);
		deselect();
		select(0);
		exchange(0x02);
		Conf.expect("untapped port 1 has no slot B", acknowledged(), 0);
		deselect();
		Multitap.plugged = true;

		// A headless run: no pads, and the tap answers as an empty port does.
		kernel.Kernel.haltAt = 1;
		Pads.init();
		Pads.sample();
		select(0);
		Conf.expect("headless: slot A answers Hi-Z", exchange(0x01), 0xFF);
		Conf.expect("headless: and never acknowledges", acknowledged(), 0);
		deselect();
		kernel.Kernel.haltAt = 0;

		Conf.report("MultitapSio");
	}

	/** A slot-A read through the tap answered as a digital pad, with `request` as its third byte. */
	static function plainRead(what:String, request:Int, pressed:Int):Void {
		select(0);
		Conf.expect(what + ": address", exchange(0x01), 0xFF);
		Conf.expect(what + ": address acknowledged", acknowledged(), 1);
		Conf.expect(what + ": ID low", exchange(0x42), 0x41);
		acknowledged();
		Conf.expect(what + ": ID high", exchange(request), 0x5A);
		acknowledged();
		Conf.expect(what + ": buttons low", exchange(0x00), ~pressed & 0xFF);
		acknowledged();
		Conf.expect(what + ": buttons high", exchange(0x00), (~pressed >> 8) & 0xFF);
		Conf.expect(what + ": the last byte is not acknowledged", acknowledged(), 0);
		deselect();
	}

	/** The long read: 80h 5Ah, then slots A-D, eight bytes each; every byte but the last acked. */
	static function longRead(what:String, request:Int):Void {
		select(0);
		exchange(0x01);
		acknowledged();
		Conf.expect(what + ": the tap's ID", exchange(0x42), 0x80);
		acknowledged();
		Conf.expect(what + ": ID high", exchange(request), 0x5A);
		acknowledged();
		for (slot in 0...4) {
			for (k in 0...8) {
				Conf.expect(what + ": slot " + slot + " byte " + k, exchange(0x00), slotByte(slot, k));
				final last = slot == 3 && k == 7;
				Conf.expect(what + ": slot " + slot + " byte " + k + " acknowledged", acknowledged(), last ? 0 : 1);
			}
		}
		deselect();
	}

	/** Byte `k` of a slot in the long read: pads A-C are digital pads, slot D is empty. */
	static function slotByte(slot:Int, k:Int):Int {
		var p = -1;
		if (slot == 0) p = PAD_A;
		else if (slot == 1) p = PAD_B;
		else if (slot == 2) p = PAD_C;
		else {}
		if (p < 0) return 0xFF;
		else if (k == 0) return 0x41;
		else if (k == 1) return 0x5A;
		else if (k == 2) return ~p & 0xFF;
		else if (k == 3) return (~p >> 8) & 0xFF;
		else return 0xFF;
	}

	/** Garbage: 80h 5Ah and slot A's ID low byte, then the tap stops acknowledging. */
	static function garbageRead(what:String, request:Int):Void {
		select(0);
		exchange(0x01);
		acknowledged();
		Conf.expect(what + ": the tap's ID", exchange(0x42), 0x80);
		acknowledged();
		Conf.expect(what + ": ID high", exchange(request), 0x5A);
		Conf.expect(what + ": acknowledged", acknowledged(), 1);
		Conf.expect(what + ": slot A's ID low", exchange(0x00), 0x41);
		Conf.expect(what + ": and no more", acknowledged(), 0);
		deselect();
	}

	static function select(port:Int):Void {
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN | port);
	}

	static function deselect():Void {
		Sio0.write16(CTRL, 0);
	}

	/**
		One byte out, the way a driver does it: write, clear IRQ7, wait for the byte to arrive,
		read it. Returns the answer, and feeds the status bits seen along the way.
	**/
	static function exchange(v:Int):Int {
		Sio0.write8(DR, v);
		Conf.feed(Sio0.read16(SR));
		advance(100);
		Irq.writeStat(~(1 << Irq.SIO0));
		advance(BYTE - 100);
		final sr = Sio0.read16(SR);
		Conf.feed(sr);
		Conf.expect("received", sr & 0x02, 0x02);
		return Sio0.read8(DR);
	}

	/** Whether IRQ7 arrives within the BIOS's patience, then lets /ACK rise and clears it all. */
	static function acknowledged():Int {
		advance(400);
		final irq = (Irq.readStat() & (1 << Irq.SIO0)) != 0 ? 1 : 0;
		Conf.feed(Sio0.read16(SR));
		advance(200);
		Sio0.write16(CTRL, Sio0.read16(CTRL) | ACK);
		Irq.writeStat(~(1 << Irq.SIO0));
		return irq;
	}

	static function advance(cycles:Int):Void {
		ctx.cycles = (ctx.cycles + cycles) | 0;
		Scheduler.runDue(ctx);
	}
}
