import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;
import kernel.KPads;
import mem.Memory;
import sio.DualShock;
import sio.Multitap;
import sio.Pads;
import sio.Sio0;

/**
	The DualShock on SIO0 (ADR-0052), as nocash's psx-spx describes it ("Controllers - Standard
	Digital/Analog Controllers", "- Configuration Commands", "- Vibration/Rumble Control"). These
	must agree on both targets:

	  - powered on, a digital pad's read: ID 5A41h, five bytes, L3 and R3 released;
	  - the old rumble: the small motor while the fourth byte is 40h..7Fh and the fifth odd;
	  - ANALOG pressed: ID 5A73h, nine bytes, L3 and the sticks RX RY LX LY;
	  - 43h 01h: the read answers as 42h does, and configuration mode follows, ID 5AF3h, nine bytes;
	  - 45h, 46h, 47h, 48h, 4Ch: the constants; 40h and 4Fh: zeros; a command the pad does not take
	    in its mode (45h in normal mode, 50h in configuration mode) its ID and nothing more;
	  - 4Dh: the old mapping out as the new one comes in; mapped reads drive both motors;
	  - 44h: the mode, and the lock that makes ANALOG do nothing;
	  - the motors as reported: the large one from 50h at rest, on down to 38h once running;
	  - ANALOG unlocked: the mode toggled, the motors stopped and unmapped, the old rumble gone;
	  - port 2 and the multitap's slots, the long read and its garbage, each slot's window of a
	    long read a transfer of its own (configuration and motors in it) answered by the next long
	    read (ADR-0042 amended), the BIOS's pad handler;
	  - unplugged and plugged back in, a pad powered on again.
**/
class DualShockSio {
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

	static inline var ANALOG = 0x10000;

	// Pad 0: Cross, Up and L3 held; the left stick up and to the left, the right one to the right.
	static inline var HELD = 0x4000 | 0x0010 | 0x0002;
	static inline var LX = 0x10;
	static inline var LY = 0x00;
	static inline var RX = 0xFF;
	static inline var RY = 0x80;
	/** What a digital read reports of HELD: L3 released. */
	static inline var DIGITAL_HELD = 0x4000 | 0x0010;

	// Pad 1, a DualShock: Circle; pad 2, a digital pad: Square and L1.
	static inline var PAD_B = 0x2000;
	static inline var PAD_C = 0x8000 | 0x0400;

	static inline var BUF1 = 0x80100000;
	static inline var BUF2 = 0x80100040;

	static var ctx:CpuState;

	public static function main():Void {
		ctx = new CpuState();
		Runtime.boot(ctx);
		// A run that halts at a frame it never reaches: the vblanks this test lives through sample
		// no host — under Node there is none, and every pad would be unplugged — so the pads stay
		// as the test sets them.
		kernel.Kernel.haltAt = 0x7FFFFFFF;
		Pads.setDualShock(0, true, HELD, LX, LY, RX, RY);
		Pads.setDualShock(1, true, PAD_B, 0x80, 0x80, 0x80, 0x80);
		Pads.set(2, false, 0);
		Pads.set(3, false, 0);

		Sio0.write16(CTRL, RESET);
		Sio0.write16(BAUD, 0x88);
		Sio0.write16(MODE, 0x0D);
		Sio0.write16(CTRL, 0);

		// Powered on: a digital pad's read, without L3.
		final dlo = ~DIGITAL_HELD & 0xFF;
		final dhi = (~DIGITAL_HELD >> 8) & 0xFF;
		transfer("digital", 0, [0x42, 0x00, 0x00, 0x00], [0x41, 0x5A, dlo, dhi]);
		select(0);
		exchange(0x01);
		acknowledged();
		exchange(0x42);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		Conf.expect("digital: nothing after the fifth byte", exchange(0x00), 0xFF);
		Conf.expect("digital: and no acknowledge", acknowledged(), 0);
		deselect();

		// A command it does not take in normal mode is answered with the ID and ends the transfer.
		refused("normal 45h", 0, 0x45, 0x41);
		refused("normal 00h", 0, 0x00, 0x41);

		// The old rumble: the small motor only, while the fourth byte is 40h..7Fh and the fifth odd.
		transfer("old 40h 01h", 0, [0x42, 0x00, 0x40, 0x01], [0x41, 0x5A, dlo, dhi]);
		Conf.expect("old rumble: the small motor on", DualShock.smallMotor(0), 1);
		transfer("old 7Fh FFh", 0, [0x42, 0x00, 0x7F, 0xFF], [0x41, 0x5A, dlo, dhi]);
		Conf.expect("old rumble: 7Fh FFh is on", DualShock.smallMotor(0), 1);
		transfer("old 80h 01h", 0, [0x42, 0x00, 0x80, 0x01], [0x41, 0x5A, dlo, dhi]);
		Conf.expect("old rumble: 80h is off", DualShock.smallMotor(0), 0);
		transfer("old 40h 02h", 0, [0x42, 0x00, 0x40, 0x02], [0x41, 0x5A, dlo, dhi]);
		Conf.expect("old rumble: an even fifth byte is off", DualShock.smallMotor(0), 0);
		Conf.expect("old rumble: the large motor never runs", DualShock.largeMotor(0), 0);

		// ANALOG: analog mode, nine bytes, L3 and the sticks; and back.
		final alo = ~HELD & 0xFF;
		final ahi = (~HELD >> 8) & 0xFF;
		press(0, HELD);
		transfer("analog", 0, [0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0x73, 0x5A, alo, ahi, RX, RY, LX, LY]);
		press(0, HELD);
		transfer("digital again", 0, [0x42, 0x00, 0x00, 0x00], [0x41, 0x5A, dlo, dhi]);

		// 43h 01h: answered as a read, then configuration mode.
		transfer("enter", 0, [0x43, 0x00, 0x01, 0x00], [0x41, 0x5A, dlo, dhi]);
		transfer("45h", 0, [0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x01, 0x02, 0x00, 0x02, 0x01, 0x00]);
		transfer("46h small", 0, [0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x00, 0x00, 0x01, 0x02, 0x00, 0x0A]);
		transfer("46h large", 0, [0x46, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x00, 0x00, 0x01, 0x01, 0x01, 0x14]);
		transfer("46h none", 0, [0x46, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("47h 0", 0, [0x47, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00]);
		transfer("47h 1", 0, [0x47, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("48h 1", 0, [0x48, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]);
		transfer("48h 2", 0, [0x48, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("4Ch 0", 0, [0x4C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00]);
		transfer("4Ch 1", 0, [0x4C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00]);
		transfer("4Ch 2", 0, [0x4C, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("40h", 0, [0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("4Fh", 0, [0x4F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		refused("config 50h", 0, 0x50, 0xF3);

		// 4Dh: the old mapping out as the new comes in — unmapped at first.
		transfer("4Dh first", 0, [0x4D, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF],
			[0xF3, 0x5A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
		transfer("4Dh again", 0, [0x4D, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF],
			[0xF3, 0x5A, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]);

		// 44h: analog mode, locked.
		transfer("44h analog locked", 0, [0x44, 0x00, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("45h analog", 0, [0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x01, 0x02, 0x01, 0x02, 0x01, 0x00]);

		// Configuration mode's 42h reads everything and drives both motors.
		transfer("config 42h", 0, [0x42, 0x00, 0x01, 0xC0, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, alo, ahi, RX, RY, LX, LY]);
		Conf.expect("config 42h: the small motor", DualShock.smallMotor(0), 1);
		Conf.expect("config 42h: the large motor", DualShock.largeMotor(0), 0xC0);

		// Back to normal mode, analog now: mapped reads drive the motors.
		transfer("exit", 0, [0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("mapped read", 0, [0x42, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00],
			[0x73, 0x5A, alo, ahi, RX, RY, LX, LY]);
		Conf.expect("mapped read: the small motor off", DualShock.smallMotor(0), 0);
		Conf.expect("mapped read: the large motor at full speed", DualShock.largeMotor(0), 0xFF);

		// Locked: ANALOG changes nothing, and the motors run on.
		press(0, HELD);
		transfer("locked", 0, [0x42, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00],
			[0x73, 0x5A, alo, ahi, RX, RY, LX, LY]);
		Conf.expect("locked: the large motor still runs", DualShock.largeMotor(0), 0xFF);

		// The motors as reported: the large one starts from 50h at rest and runs on down to 38h.
		DualShock.report(0, true);
		Conf.expect("reported: full speed", DualShock.shownLargeMotor(0), 0xFF);
		large(0x40);
		Conf.expect("reported: 40h keeps it running", DualShock.shownLargeMotor(0), 0x40);
		large(0x30);
		Conf.expect("reported: 30h stops it", DualShock.shownLargeMotor(0), 0);
		large(0x40);
		Conf.expect("reported: 40h does not start it", DualShock.shownLargeMotor(0), 0);
		large(0x50);
		Conf.expect("reported: 50h does", DualShock.shownLargeMotor(0), 0x50);
		DualShock.report(0, false);
		Conf.expect("reported: no DualShock, no motors", DualShock.shownLargeMotor(0), 0);

		// Unlocked, ANALOG resets the pad: digital mode, the motors stopped and unmapped.
		transfer("enter in analog mode", 0, [0x43, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0x73, 0x5A, alo, ahi, RX, RY, LX, LY]);
		transfer("44h unlocked", 0, [0x44, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("exit unlocked", 0, [0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		press(0, HELD);
		Conf.expect("ANALOG: the large motor stopped", DualShock.largeMotor(0), 0);
		transfer("ANALOG: digital", 0, [0x42, 0x00, 0x40, 0x01], [0x41, 0x5A, dlo, dhi]);
		Conf.expect("ANALOG: the old rumble is gone once configured", DualShock.smallMotor(0), 0);
		transfer("enter digital", 0, [0x43, 0x00, 0x01, 0x00], [0x41, 0x5A, dlo, dhi]);
		transfer("4Dh unmapped", 0, [0x4D, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
			[0xF3, 0x5A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
		transfer("44h 02h ignored", 0, [0x44, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("45h digital", 0, [0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0xF3, 0x5A, 0x01, 0x02, 0x00, 0x02, 0x01, 0x00]);
		transfer("exit digital", 0, [0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());

		// Port 2 holds pad 1 until the tap is used, a DualShock of its own.
		final blo = ~PAD_B & 0xFF;
		final bhi = (~PAD_B >> 8) & 0xFF;
		transfer("port 2 enter", PORT2, [0x43, 0x00, 0x01, 0x00], [0x41, 0x5A, blo, bhi]);
		transfer("port 2 44h", PORT2, [0x44, 0x00, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("port 2 exit", PORT2, [0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], zeros());
		transfer("port 2 analog", PORT2, [0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
			[0x73, 0x5A, blo, bhi, 0x80, 0x80, 0x80, 0x80]);
		Conf.expect("port 1 is not in analog mode", DualShock.isAnalog(0), 0);

		// The multitap's long read: slot A a DualShock in analog mode, B one too, C a digital pad,
		// D empty. Garbage names slot A's ID.
		press(0, HELD);
		Pads.set(2, true, PAD_C);
		request();
		select(0);
		exchange(0x01);
		acknowledged();
		Conf.expect("long: the tap's ID", exchange(0x42), 0x80);
		acknowledged();
		Conf.expect("long: ID high", exchange(0x01), 0x5A);
		acknowledged();
		final slots = [0x73, 0x5A, alo, ahi, RX, RY, LX, LY,
			0x73, 0x5A, blo, bhi, 0x80, 0x80, 0x80, 0x80,
			0x41, 0x5A, ~PAD_C & 0xFF, (~PAD_C >> 8) & 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
			0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
		// Each slot's window starts with the command its controller is sent: a read, as libpad sends.
		for (i in 0...32) {
			Conf.expect("long: slot byte " + i, exchange((i & 7) == 0 ? 0x42 : 0x00), slots[i]);
			Conf.expect("long: slot byte " + i + " acknowledged", acknowledged(), i < 31 ? 1 : 0);
		}
		deselect();
		select(0);
		exchange(0x01);
		acknowledged();
		Conf.expect("garbage: the tap's ID", exchange(0x42), 0x80);
		acknowledged();
		Conf.expect("garbage: ID high", exchange(0x00), 0x5A);
		acknowledged();
		Conf.expect("garbage: slot A's ID low, analog", exchange(0x00), 0x73);
		Conf.expect("garbage: and no more", acknowledged(), 0);
		deselect();

		// Slot B read directly answers as its DualShock does, and the tap is in use.
		select(0);
		Conf.expect("slot B: address", exchange(0x02), 0xFF);
		Conf.expect("slot B: acknowledged", acknowledged(), 1);
		Conf.expect("slot B: analog", exchange(0x42), 0x73);
		deselect();
		Conf.expect("the tap is in use", Multitap.inUse ? 1 : 0, 1);

		// Each slot's window of a long read is a transfer of its own, which the tap makes when the
		// read ends and answers in the next long read: slot B's DualShock is configured that way,
		// its motors mapped and driven, while A is read beside it. Each read below therefore
		// expects the answers to the one before it.
		final readA = [0x73, 0x5A, alo, ahi, RX, RY, LX, LY];
		final readB = [0x73, 0x5A, blo, bhi, 0x80, 0x80, 0x80, 0x80];
		final slotC = [0x41, 0x5A, ~PAD_C & 0xFF, (~PAD_C >> 8) & 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
		final none = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
		final read8 = [0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
		// The first long read sent reads, so this one answers reads; B is sent 43h 01h.
		longWith("long B enters", read8.concat([0x43, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]).concat(read8).concat(read8),
			readA.concat(readB).concat(slotC).concat(none));
		// 43h 01h answered as a read in analog mode, and B is in configuration mode now.
		longWith("long B 45h", read8.concat([0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]).concat(read8).concat(read8),
			readA.concat(readB).concat(slotC).concat(none));
		longWith("long B 4Dh", read8.concat([0x4D, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]).concat(read8).concat(read8),
			readA.concat([0xF3, 0x5A, 0x01, 0x02, 0x01, 0x02, 0x01, 0x00]).concat(slotC).concat(none));
		longWith("long B exits", read8.concat([0x43, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]).concat(read8).concat(read8),
			readA.concat([0xF3, 0x5A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).concat(slotC).concat(none));
		final refusedA = [0x73, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
		longWith("long A refuses 00h", [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00].concat(read8).concat(read8).concat(read8),
			readA.concat(zeros()).concat(slotC).concat(none));
		longWith("long B's motors", read8.concat([0x42, 0x00, 0x01, 0x90, 0x00, 0x00, 0x00, 0x00]).concat(read8).concat(read8),
			refusedA.concat(readB).concat(slotC).concat(none));
		// The motors run once the read that drives them has ended, before its answer comes back.
		Conf.expect("long: slot B's small motor", DualShock.smallMotor(1), 1);
		Conf.expect("long: slot B's large motor", DualShock.largeMotor(1), 0x90);
		Conf.expect("long: slot A's motors untouched", DualShock.largeMotor(0), 0);
		longWith("long after the motors", read8.concat(read8).concat(read8).concat(read8),
			readA.concat(readB).concat(slotC).concat(none));

		// The BIOS's pad handler: port 1's DualShock in analog mode, its six bytes.
		for (i in 0...0x22) Memory.write8(BUF1 + i, 0xAA);
		KPads.initPad(BUF1, 0x22, BUF2, 0x22);
		KPads.startPad();
		KPads.onInterrupt(1);
		final bios = [0x00, 0x73, alo, ahi, RX, RY, LX, LY, 0x00];
		for (i in 0...bios.length) Conf.expect("BIOS buffer byte " + i, Memory.read8u(BUF1 + i), bios[i]);
		KPads.stopPad();

		// Unplugged and plugged back in: powered on again, digital.
		Pads.setDualShock(0, false, 0, 0x80, 0x80, 0x80, 0x80);
		Pads.setDualShock(0, true, HELD, LX, LY, RX, RY);
		Conf.expect("plugged back: digital mode", DualShock.isAnalog(0), 0);
		Conf.expect("plugged back: no motor", DualShock.largeMotor(0), 0);

		// A headless run keeps every port empty, whatever the host would say.
		Pads.init();
		Pads.sample();
		Conf.expect("headless: no DualShock", Pads.isDualShock(0) ? 1 : 0, 0);
		Conf.expect("headless: port 1 empty", Pads.isConnected(0) ? 1 : 0, 0);
		kernel.Kernel.haltAt = 0;

		Conf.report("DualShockSio");
	}

	static function zeros():Array<Int> return [0xF3, 0x5A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

	/** A command the pad does not take: its ID, no acknowledge, and nothing after it. */
	static function refused(what:String, port:Int, command:Int, id:Int):Void {
		select(port);
		Conf.expect(what + ": address", exchange(0x01), 0xFF);
		Conf.expect(what + ": address acknowledged", acknowledged(), 1);
		Conf.expect(what + ": the ID", exchange(command), id);
		Conf.expect(what + ": not acknowledged", acknowledged(), 0);
		Conf.expect(what + ": nothing after it", exchange(0x00), 0xFF);
		Conf.expect(what + ": and no acknowledge", acknowledged(), 0);
		deselect();
	}

	/** The ANALOG button pressed and let go, between two vblanks' samples. */
	static function press(pad:Int, held:Int):Void {
		final lx = pad == 0 ? LX : 0x80;
		final ly = pad == 0 ? LY : 0x80;
		final rx = pad == 0 ? RX : 0x80;
		final ry = pad == 0 ? RY : 0x80;
		Pads.setDualShock(pad, true, held | ANALOG, lx, ly, rx, ry);
		Pads.setDualShock(pad, true, held, lx, ly, rx, ry);
	}

	/** Pad 0's large motor driven to `speed` by a mapped analog read, then reported. */
	static function large(speed:Int):Void {
		transfer("large " + speed, 0, [0x42, 0x00, 0x00, speed, 0x00, 0x00, 0x00, 0x00],
			[0x73, 0x5A, ~HELD & 0xFF, (~HELD >> 8) & 0xFF, RX, RY, LX, LY]);
		DualShock.report(0, true);
	}

	/**
		A request, then a long read with `out` in its four slot windows (eight bytes each), every
		answer checked against `want`; all acknowledged but the last.
	**/
	static function longWith(what:String, out:Array<Int>, want:Array<Int>):Void {
		request();
		select(0);
		exchange(0x01);
		acknowledged();
		Conf.expect(what + ": the tap's ID", exchange(0x42), 0x80);
		acknowledged();
		Conf.expect(what + ": ID high", exchange(0x00), 0x5A);
		acknowledged();
		for (i in 0...32) {
			Conf.expect(what + ": slot byte " + i, exchange(out[i]), want[i]);
			Conf.expect(what + ": slot byte " + i + " acknowledged", acknowledged(), i < 31 ? 1 : 0);
		}
		deselect();
	}

	/** A slot-A read through the tap whose third byte asks for the long one next. */
	static function request():Void {
		select(0);
		exchange(0x01);
		acknowledged();
		exchange(0x42);
		acknowledged();
		exchange(0x01);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		deselect();
	}

	/**
		One transfer on `port`: the address 01h, then `out` a byte at a time, each answer checked
		against `want`; every byte acknowledged but the last.
	**/
	static function transfer(what:String, port:Int, out:Array<Int>, want:Array<Int>):Void {
		select(port);
		Conf.expect(what + ": address", exchange(0x01), 0xFF);
		Conf.expect(what + ": address acknowledged", acknowledged(), 1);
		for (i in 0...out.length) {
			Conf.expect(what + ": byte " + (i + 1), exchange(out[i]), want[i]);
			Conf.expect(what + ": byte " + (i + 1) + " acknowledged", acknowledged(), i < out.length - 1 ? 1 : 0);
		}
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
