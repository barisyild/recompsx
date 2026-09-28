import core.CpuState;
import core.Irq;
import core.Runtime;
import core.Scheduler;
import sio.MemoryCard;
import sio.Sio0;

/**
	The memory card on SIO0, as a game that bypasses the BIOS talks to it (psx-spx "Memory Card
	Read/Write Commands"): the ID command, a read of frame 0 with its checksum and the late
	acknowledge a Sony card gives its 5Ch, a write that clears the "new card" FLAG, a write with a
	bad checksum and one past the last sector, a read past it, a command the card does not know,
	and the empty slot 2.
**/
class CardSio {
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

	static inline var BYTE = 1088;

	static var ctx:CpuState;

	public static function main():Void {
		ctx = new CpuState();
		Runtime.boot(ctx);
		MemoryCard.insert("SCUS94570", "", false);

		Sio0.write16(CTRL, RESET);
		Sio0.write16(BAUD, 0x88);
		Sio0.write16(MODE, 0x0D);
		Sio0.write16(CTRL, 0);

		// Get ID.
		select(0);
		Conf.expect("the card's address answers Hi-Z", exchange(0x81), 0xFF);
		Conf.expect("and is acknowledged", acknowledged(), 1);
		Conf.expect("ID: FLAG says new card", exchange(0x53), 0x08);
		acknowledged();
		final id = [0x5A, 0x5D, 0x5C, 0x5D, 0x04, 0x00, 0x00, 0x80];
		for (i in 0...8) {
			Conf.expect("ID byte " + i, exchange(0x00), id[i]);
			Conf.expect("ID byte " + i + " acknowledged", acknowledged(), i < 7 ? 1 : 0);
		}
		deselect();

		// Read frame 0.
		select(0);
		exchange(0x81);
		acknowledged();
		Conf.expect("read: FLAG", exchange(0x52), 0x08);
		acknowledged();
		Conf.expect("read: 5Ah", exchange(0x00), 0x5A);
		acknowledged();
		Conf.expect("read: 5Dh", exchange(0x00), 0x5D);
		acknowledged();
		Conf.expect("read: 00h under the MSB", exchange(0x00), 0x00);
		acknowledged();
		Conf.expect("read: the MSB echoed under the LSB", exchange(0x00), 0x00);
		acknowledged();
		Conf.expect("read: 5Ch", exchange(0x00), 0x5C);
		Conf.expect("whose acknowledge is late", acknowledged(), 0);
		Conf.expect("but comes", lateAcknowledged(), 1);
		Conf.expect("read: 5Dh again", exchange(0x00), 0x5D);
		acknowledged();
		Conf.expect("confirmed MSB", exchange(0x00), 0x00);
		acknowledged();
		Conf.expect("confirmed LSB", exchange(0x00), 0x00);
		acknowledged();
		var sum = 0;
		for (i in 0...128) {
			final b = exchange(0x00);
			acknowledged();
			sum ^= b;
			Conf.feed(b);
			if (i == 0) Conf.expect("data: M", b, 0x4D);
			else if (i == 1) Conf.expect("data: C", b, 0x43);
			else {}
		}
		Conf.expect("checksum", exchange(0x00), sum);
		acknowledged();
		Conf.expect("end: G", exchange(0x00), 0x47);
		Conf.expect("the end is not acknowledged", acknowledged(), 0);
		deselect();
		Conf.expect("reading left FLAG as it was", MemoryCard.flagByte(), 0x08);

		// Write frame 3Fh: 128 bytes of a pattern and their checksum.
		Conf.expect("a good write ends with G", write(0x00, 0x3F, true), 0x47);
		Conf.expect("the write cleared FLAG.3", MemoryCard.flagByte(), 0x00);
		Conf.expect("the frame holds it", MemoryCard.read8(0x3F, 5), (5 * 3) & 0xFF);
		Conf.expect("a bad checksum ends with N", write(0x00, 0x3E, false), 0x4E);
		Conf.expect("and the frame is not written", MemoryCard.read8(0x3E, 5), 0xFF);
		Conf.expect("a sector past 3FFh ends with FFh", write(0x04, 0x00, true), 0xFF);

		// A read past 3FFh confirms FFFFh and stops.
		select(0);
		exchange(0x81);
		acknowledged();
		Conf.expect("FLAG now clear", exchange(0x52), 0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x04);
		acknowledged();
		exchange(0x00);
		acknowledged();
		exchange(0x00);
		lateAcknowledged();
		exchange(0x00);
		acknowledged();
		Conf.expect("confirmed MSB FFh", exchange(0x00), 0xFF);
		acknowledged();
		Conf.expect("confirmed LSB FFh", exchange(0x00), 0xFF);
		Conf.expect("and nothing after", acknowledged(), 0);
		deselect();

		// A command it does not know: FLAG, and silence.
		select(0);
		exchange(0x81);
		acknowledged();
		Conf.expect("unknown command: FLAG", exchange(0x99), 0x00);
		Conf.expect("unacknowledged", acknowledged(), 0);
		deselect();

		// Slot 2 is empty.
		select(1);
		Conf.expect("slot 2 answers Hi-Z", exchange(0x81), 0xFF);
		Conf.expect("and nobody acknowledges", acknowledged(), 0);
		deselect();

		Conf.report("CardSio");
	}

	/** A write of `sector` (MSB, LSB), data `i * 3`, with its checksum good or not; the end byte. */
	static function write(msb:Int, lsb:Int, good:Bool):Int {
		select(0);
		exchange(0x81);
		acknowledged();
		exchange(0x57);
		acknowledged();
		Conf.expect("write: 5Ah", exchange(0x00), 0x5A);
		acknowledged();
		Conf.expect("write: 5Dh", exchange(0x00), 0x5D);
		acknowledged();
		exchange(msb);
		acknowledged();
		Conf.expect("write: MSB echoed", exchange(lsb), msb);
		acknowledged();
		var sum = msb ^ lsb;
		var prev = lsb;
		for (i in 0...128) {
			final v = (i * 3) & 0xFF;
			final echo = exchange(v);
			acknowledged();
			if (i < 2) Conf.expect("write: the byte before echoed", echo, prev);
			else {}
			sum ^= v;
			prev = v;
		}
		exchange(good ? sum : sum ^ 0xFF);
		acknowledged();
		Conf.expect("write: 5Ch", exchange(0x00), 0x5C);
		acknowledged();
		Conf.expect("write: 5Dh", exchange(0x00), 0x5D);
		acknowledged();
		final end = exchange(0x00);
		Conf.expect("write: the end is not acknowledged", acknowledged(), 0);
		deselect();
		return end;
	}

	static function select(port:Int):Void {
		Sio0.write16(CTRL, TXEN | DTR | DSRIEN | (port == 1 ? PORT2 : 0));
	}

	static function deselect():Void {
		Sio0.write16(CTRL, 0);
	}

	static function exchange(v:Int):Int {
		Sio0.write8(DR, v);
		advance(100);
		Irq.writeStat(~(1 << Irq.SIO0));
		advance(BYTE - 100);
		final sr = Sio0.read16(SR);
		Conf.feed(sr);
		Conf.expect("received", sr & 0x02, 0x02);
		return Sio0.read8(DR);
	}

	static function acknowledged():Int {
		advance(400);
		final irq = (Irq.readStat() & (1 << Irq.SIO0)) != 0 ? 1 : 0;
		if (irq != 0) {
			advance(200);
			Sio0.write16(CTRL, Sio0.read16(CTRL) | ACK);
			Irq.writeStat(~(1 << Irq.SIO0));
		} else {}
		return irq;
	}

	/** The 5Ch of a read: its acknowledge some 31000 cycles later than the others'. */
	static function lateAcknowledged():Int {
		advance(31000);
		return acknowledged();
	}

	static function advance(cycles:Int):Void {
		ctx.cycles = (ctx.cycles + cycles) | 0;
		Scheduler.runDue(ctx);
	}
}
