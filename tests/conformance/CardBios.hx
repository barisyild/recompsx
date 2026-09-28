import core.CpuState;
import core.Hash;
import core.Runtime;
import kernel.KCard;
import kernel.KEvents;
import kernel.Kernel;
import mem.Memory;
import shim.RawMem;
import sio.MemoryCard;

/**
	The BIOS memory card driver under HLE (kernel.KCard, kernel.KBu), driven by real vblanks the
	way a game drives it: the event order of `_card_info` for a new card, an empty slot and a card
	that is fine; `_card_write`, `_card_read` and their refusals; the slots taking turns; `_bu_init`;
	and the `bu` device — create, write, read, the lookups that fail, firstfile, rename, erase,
	format and an asynchronous write — checked against the card's own bytes, and against the size
	of the card format as saves come and go (ADR-0037).
**/
class CardBios {
	static inline var BUF = 0x80100000;
	static inline var BACK = 0x80102000;
	static inline var NAME = 0x80104000;
	static inline var NAME2 = 0x80104100;
	static inline var DIRENT = 0x80104200;

	static var ctx:CpuState;
	static var hw:Array<Int>;
	static var sw:Array<Int>;

	public static function main():Void {
		ctx = new CpuState();
		Runtime.boot(ctx);
		// Interrupts on, as in a game's main loop: the driver runs from the vblank interrupt.
		ctx.sr = 0x401;
		MemoryCard.insert("SCUS94570", "", false);
		final specs = [0x0004, 0x0100, 0x2000, 0x8000];
		hw = [for (s in specs) listen(KEvents.CLASS_CARD, s)];
		sw = [for (s in specs) listen(KEvents.CLASS_BU, s)];

		Conf.expect("InitCARD2, the first time", b0(0x4A, 1, 0, 0), 0);
		Conf.expect("StartCARD2", b0(0x4B, 0, 0, 0), 1);

		// A card just inserted: the probe says "new card", on both classes.
		Conf.expect("_card_info queued", a0(0xAB, 0x00, 0, 0), 1);
		Conf.expect("_card_status: busy with the probe", b0(0x5C, 0, 0, 0), 0x08);
		vblank();
		Conf.expect("slot 2's turn first: nothing yet", fired(), 0);
		vblank();
		Conf.expect("new card: HwCARD and SwCARD 2000h", fired(), 0x44);
		Conf.expect("the slot is ready again", b0(0x5C, 0, 0, 0), 0x01);

		// Slot 2 is empty: nobody answers, and the next vblank calls it a timeout.
		a0(0xAB, 0x10, 0, 0);
		vblank();
		Conf.expect("an empty slot: nothing at first", fired(), 0);
		vblank();
		Conf.expect("then a timeout on both classes", fired(), 0x22);
		Conf.expect("_card_status(1): timed out", b0(0x5C, 1, 0, 0), 0x11);

		// _new_card, and a write to frame 3Fh clears the latch; only HwCARD hears of it.
		for (i in 0...128) Memory.write8(BUF + i, i ^ 0x5A);
		b0(0x50, 0, 0, 0);
		Conf.expect("_card_write queued", b0(0x4E, 0x00, 0x3F, BUF), 1);
		vblank();
		Conf.expect("the write: HwCARD 4 only", fired(), 0x01);
		Conf.expect("the card has it", MemoryCard.read8(0x3F, 7), 7 ^ 0x5A);
		Conf.expect("FLAG clear", MemoryCard.flagByte(), 0);
		Conf.expect("_card_chan: slot 1", b0(0x58, 0, 0, 0), 0x00);

		// Now the probe is fine.
		a0(0xAB, 0x00, 0, 0);
		vblank();
		vblank();
		Conf.expect("a card that is fine: 4 on both classes", fired(), 0x11);

		// A read of frame 0, a read the card refuses, and ones the BIOS refuses.
		Conf.expect("_card_read queued", b0(0x4F, 0x00, 0, BACK), 1);
		Conf.expect("a second while it waits is refused", b0(0x4F, 0x00, 1, BACK), 0);
		vblank();
		vblank();
		Conf.expect("the read: HwCARD 4", fired(), 0x01);
		Conf.expect("read: M", Memory.read8u(BACK), 0x4D);
		Conf.expect("read: C", Memory.read8u(BACK + 1), 0x43);
		Conf.expect("sector 400h is let through", b0(0x4F, 0x00, 0x400, BACK), 1);
		vblank();
		vblank();
		Conf.expect("and the card refuses it: HwCARD 8000h", fired(), 0x08);
		Conf.expect("_card_status: error", b0(0x5C, 0, 0, 0), 0x21);
		Conf.expect("sector 401h is not", b0(0x4F, 0x00, 0x401, BACK), 0);

		// _bu_init: both directories read, synchronously.
		final before = Kernel.vblankCount;
		Conf.expect("_bu_init", a0(0x70, 0, 0, 0), 0);
		Conf.feed(Kernel.vblankCount - before);
		Conf.expect("slot 1's first entry: free", KCard.stateAt(0), MemoryCard.FREE);
		Conf.expect("slot 2's: nothing, the card is not there", KCard.stateAt(15), 0);
		Conf.feed(Hash.region(Hash.FNV_OFFSET, KCard.entries, 0, 2 * 15 * 32));

		// Create a one-block file, write two frames, read one back.
		putString(NAME, "bu00:BASCUS-94570TEST");
		final fd = a0(0x00, NAME, 0x10202, 0);
		Conf.expect("create: the first free descriptor", fd, 3);
		Conf.expect("entry 1: in use", MemoryCard.read8(1, 0), MemoryCard.FIRST);
		Conf.expect("entry 1: 2000h bytes", RawMem.get32(MemoryCard.image(), 0x84), 0x2000);
		Conf.expect("entry 1: the last block", RawMem.get16(MemoryCard.image(), 0x88), 0xFFFF);
		Conf.expect("entry 1: named", MemoryCard.read8(1, 0x0A + 6), 0x2D);
		Conf.expect("entry 1: sealed", MemoryCard.read8(1, 0x7F), frameXor(1));
		for (i in 0...0x100) Memory.write8(BUF + i, (i * 5) & 0xFF);
		Conf.expect("write two frames", a0(0x03, fd, BUF, 0x100), 0x100);
		Conf.expect("the card has them", MemoryCard.read8(0x40, 9), 45);
		Conf.expect("the second frame too", MemoryCard.read8(0x41, 1), (0x81 * 5) & 0xFF);
		Conf.expect("a partial frame is refused", a0(0x03, fd, BUF, 0x40), -1);
		Conf.expect("close answers the descriptor", a0(0x04, fd, 0, 0), fd);
		final out = RawMem.alloc(MemoryCard.MAX);
		Conf.expect("the card format grew to one block", MemoryCard.toFormat(MemoryCard.image(), out),
			MemoryCard.HEADER + MemoryCard.RECORD);

		final rd = a0(0x00, NAME, 0x0001, 0);
		Conf.expect("open for reading", rd, 3);
		Conf.expect("seek to frame 1", a0(0x01, rd, 0x80, 0), 0x80);
		Conf.expect("read a frame", a0(0x02, rd, BACK, 0x80), 0x80);
		Conf.expect("it is frame 1 of the file", Memory.read8u(BACK + 1), (0x81 * 5) & 0xFF);
		Conf.expect("seek from the end does nothing", a0(0x01, rd, 0, 2), 0x100);
		a0(0x04, rd, 0, 0);

		putString(NAME2, "bu00:BASCUS-94570NONE");
		Conf.expect("a file that is not there", a0(0x00, NAME2, 0x0001, 0), -1);
		Conf.expect("_get_errno: not found", b0(0x54, 0, 0, 0), 0x02);
		Conf.expect("create over one that is", a0(0x00, NAME, 0x10202, 0), -1);
		Conf.expect("_get_errno: exists", b0(0x54, 0, 0, 0), 0x11);
		Conf.expect("create more than is free", a0(0x00, NAME2, (15 << 16) | 0x0202, 0), -1);
		Conf.expect("_get_errno: no space", b0(0x54, 0, 0, 0), 0x1C);

		// firstfile/nextfile, rename, erase.
		putString(NAME2, "bu00:BASCUS*");
		Conf.expect("firstfile", b0(0x42, NAME2, DIRENT, 0), DIRENT);
		Conf.expect("its name", Memory.read8u(DIRENT + 12), 0x54);
		Conf.expect("its attribute", Memory.read32(DIRENT + 0x14), 0x50);
		Conf.expect("its size", Memory.read32(DIRENT + 0x18), 0x2000);
		Conf.expect("its first sector", Memory.read32(DIRENT + 0x20), 0x40);
		Conf.expect("nextfile: no more", b0(0x43, DIRENT, 0, 0), 0);
		putString(NAME2, "bu00:BASCUS-94570SAVE");
		Conf.expect("rename", b0(0x44, NAME, NAME2, 0), 1);
		Conf.expect("the entry has the new name", MemoryCard.read8(1, 0x0A + 12), 0x53);
		Conf.expect("erase the old name: gone", b0(0x45, NAME, 0, 0), 0);
		Conf.expect("erase the new", b0(0x45, NAME2, 0, 0), 1);
		Conf.expect("the entry is deleted, not freed", MemoryCard.read8(1, 0), 0xA1);
		Conf.expect("its name stays", MemoryCard.read8(1, 0x0A), 0x42);
		Conf.expect("the card format shrank to nothing", MemoryCard.toFormat(MemoryCard.image(), out),
			MemoryCard.HEADER);

		// An asynchronous write: 0 at once, then the file's own event and SwCARD 4.
		putString(NAME, "bu00:BASCUS-94570ASYNC");
		final af = a0(0x00, NAME, 0x18202, 0);
		Conf.expect("an asynchronous create", af, 3);
		final done = listen(af, 0x0004);
		for (i in 0...0x100) Memory.write8(BUF + i, 0xC3);
		Conf.expect("the write starts", a0(0x03, af, BUF, 0x100), 0);
		Conf.expect("close refuses while it runs", a0(0x04, af, 0, 0), -1);
		var frames = 0;
		while (KEvents.test(ctx, done) == 0 && frames < 60) {
			vblank();
			frames++;
		}
		Conf.expect("the file's event came", frames < 60 ? 1 : 0, 1);
		Conf.feed(frames);
		Conf.expect("the card has it", MemoryCard.read8(0x41, 0x7F), 0xC3);

		// format("bu00:"): a blank card again.
		putString(NAME2, "bu00:");
		Conf.expect("format", b0(0x41, NAME2, 0, 0), 1);
		Conf.expect("entry 1 free again", MemoryCard.read8(1, 0), MemoryCard.FREE);
		Conf.feed(Hash.region(Hash.FNV_OFFSET, MemoryCard.image(), 0, MemoryCard.BLOCK));

		// A card changed under the BIOS: the synchronous open's frame 0 read says "new card", and
		// the whole directory is read again before the open goes on.
		MemoryCard.insert("SCUS94570", "", false);
		putString(NAME, "bu00:BASCUS-94570AGAIN");
		Conf.expect("create on the new card", a0(0x00, NAME, 0x10202, 0), 3);
		Conf.expect("the new card's latch is clear", MemoryCard.flagByte(), 0);
		Conf.expect("entry 1 is the file", MemoryCard.read8(1, 0), MemoryCard.FIRST);

		Conf.expect("StopCARD2", b0(0x4C, 0, 0, 0), 1);
		Conf.report("CardBios");
	}

	/** An event on `cls`/`spec`, polled, enabled. */
	static function listen(cls:Int, spec:Int):Int {
		final ev = KEvents.open(ctx, cls, spec, KEvents.MODE_NO_CALLBACK, 0);
		KEvents.enable(ctx, ev);
		return ev;
	}

	/** Which of the card events are ready, and consumed: HwCARD in the low nibble, SwCARD above. */
	static function fired():Int {
		var bits = 0;
		for (i in 0...4) {
			if (KEvents.test(ctx, hw[i]) != 0) bits |= 1 << i;
			else {}
			if (KEvents.test(ctx, sw[i]) != 0) bits |= 1 << (i + 4);
			else {}
		}
		Conf.feed(bits);
		return bits;
	}

	/** Emulated time to the next vblank, and its interrupt. */
	static function vblank():Void {
		final n = Kernel.vblankCount;
		while (Kernel.vblankCount == n) Runtime.idleToNextEvent(ctx);
	}

	static function a0(fn:Int, a:Int, b:Int, c:Int):Int return call(0xA0, fn, a, b, c);

	static function b0(fn:Int, a:Int, b:Int, c:Int):Int return call(0xB0, fn, a, b, c);

	static function call(vector:Int, fn:Int, a:Int, b:Int, c:Int):Int {
		ctx.a0 = a;
		ctx.a1 = b;
		ctx.a2 = c;
		ctx.v0 = 0x7777;
		Kernel.call(ctx, vector, fn);
		Conf.feed(ctx.v0);
		return ctx.v0;
	}

	static function putString(at:Int, s:String):Void {
		for (i in 0...s.length) {
			final ch = s.charCodeAt(i);
			Memory.write8(at + i, ch == null ? 0 : ch);
		}
		Memory.write8(at + s.length, 0);
	}

	static function frameXor(sector:Int):Int {
		var x = 0;
		for (i in 0...0x7F) x ^= MemoryCard.read8(sector, i);
		return x;
	}
}
