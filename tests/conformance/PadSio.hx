import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;
import sio.Pads;
import sio.Sio0;

/**
	A digital pad on SIO0, read the way the BIOS reads it (psx-spx "Controllers and Memory Cards";
	the sequence OpenBIOS's sio0/driver.c follows): address 01h, read command 42h, then three
	bytes to clock out ID high and the two button bytes.

	What has to agree on both targets is the whole conversation: each answer, the status bits
	around it, and the acknowledge that drives the next byte — late enough that a driver clearing
	IRQ7 after its write does not lose it, and never after the last byte. Then the cases that must
	answer nothing: the empty port, the memory card address, and a conversation cut by /CS.
**/
class PadSio {
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

	static var ctx:CpuState;

	public static function main():Void {
		ctx = new CpuState();
		Runtime.boot(ctx);
		// Cross, Start and Up held, active high as the backend reports them.
		Pads.set(0, true, 0x4000 | 0x0008 | 0x0010);
		Pads.set(1, false, 0);

		Sio0.write16(CTRL, RESET);
		Sio0.write16(BAUD, 0x88);
		Sio0.write16(MODE, 0x0D);
		Sio0.write16(CTRL, 0);

		// Port 1: the whole read.
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN);
		Conf.expect("address answers Hi-Z", exchange(0x01), 0xFF);
		Conf.expect("the address is acknowledged", acknowledged(), 1);
		Conf.expect("ID low: a digital pad", exchange(0x42), 0x41);
		Conf.expect("the command is acknowledged", acknowledged(), 1);
		Conf.expect("ID high", exchange(0x00), 0x5A);
		Conf.expect("ID high is acknowledged", acknowledged(), 1);
		Conf.expect("buttons low: Start and Up pressed (active low)", exchange(0x00), 0xE7);
		Conf.expect("buttons low is acknowledged", acknowledged(), 1);
		Conf.expect("buttons high: Cross pressed", exchange(0x00), 0xBF);
		Conf.expect("the last byte is not acknowledged", acknowledged(), 0);
		Conf.expect("after the last byte, nothing", exchange(0x00), 0xFF);
		Conf.expect("and no acknowledge", acknowledged(), 0);
		Sio0.write16(CTRL, 0);

		// The acknowledge cannot be cleared while /ACK is still low (psx-spx: SR.9 is not edge
		// triggered), and it can once /ACK is high again.
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN);
		exchange(0x01);
		advance(170);
		Conf.expect("/ACK is low", Sio0.read16(SR) & 0x80, 0x80);
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN | ACK);
		Conf.expect("acknowledging while /ACK is low leaves SR.9 set", Sio0.read16(SR) & 0x200, 0x200);
		advance(100);
		Conf.expect("/ACK is high again", Sio0.read16(SR) & 0x80, 0);
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN | ACK);
		Conf.expect("now the acknowledge clears it", Sio0.read16(SR) & 0x200, 0);
		Sio0.write16(CTRL, 0);

		// Letting /CS go ends the conversation: the next byte is an address again, and 42h is not
		// one anybody answers.
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN);
		exchange(0x01);
		acknowledged();
		Sio0.write16(CTRL, TXEN);
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN);
		Conf.expect("a fresh selection starts at the address", exchange(0x42), 0xFF);
		Conf.expect("which nobody acknowledges", acknowledged(), 0);
		Sio0.write16(CTRL, 0);

		// Port 2 has nothing in it.
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN | PORT2);
		Conf.expect("the empty port answers Hi-Z", exchange(0x01), 0xFF);
		Conf.expect("and never acknowledges", acknowledged(), 0);
		Sio0.write16(CTRL, 0);

		// No memory cards yet: the card address on port 1 is answered by nobody.
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN);
		Conf.expect("the card address answers Hi-Z", exchange(0x81), 0xFF);
		Conf.expect("and nobody acknowledges it", acknowledged(), 0);
		Sio0.write16(CTRL, 0);

		// Without the interrupt enabled the acknowledge is still visible on SR.7, but raises nothing.
		Sio0.write16(CTRL, TXEN | DTR);
		exchange(0x01);
		advance(170);
		Conf.expect("/ACK without DSRIEN", Sio0.read16(SR) & 0x80, 0x80);
		Conf.expect("raises no SR.9", Sio0.read16(SR) & 0x200, 0);
		Conf.expect("and no IRQ7", Irq.readStat() & (1 << Irq.SIO0), 0);
		advance(100);
		Sio0.write16(CTRL, 0);

		// A headless run keeps every port empty, whatever the host would say.
		kernel.Kernel.haltAt = 1;
		Pads.init();
		Pads.sample();
		Conf.expect("headless: port 1 empty", Pads.isConnected(0) ? 1 : 0, 0);
		Conf.expect("headless: port 2 empty", Pads.isConnected(1) ? 1 : 0, 0);
		kernel.Kernel.haltAt = 0;

		Conf.report("PadSio");
	}

	/**
		One byte out, the way a driver does it: write, clear IRQ7, wait for the byte to arrive,
		read it. Returns the answer, and feeds the status bits seen along the way.
	**/
	static function exchange(v:Int):Int {
		Sio0.write8(DR, v);
		Conf.feed(Sio0.read16(SR));
		// The BIOS clears IRQ7 about 100 cycles after its write: nothing may have been lost yet.
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
