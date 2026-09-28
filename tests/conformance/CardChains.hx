import core.CpuState;
import core.Hash;
import core.Runtime;
import kernel.Kernel;
import mem.Memory;
import shim.RawMem;
import sio.MemoryCard;

/**
	Files that come and go on a card, through the BIOS's `bu` device, and the card format keeping
	up (ADR-0037): saves created first-fit into the holes others left, so a file's blocks are not
	in a row — 1, then 4, then 5 — the card format growing and shrinking a block at a time as they
	do, and the card read back from the format twice, as a restart would, with every file still
	whole: each block where it was, each chain still leading through them, every byte the same.
	Nothing is ever moved, so nothing needs putting back together.
**/
class CardChains {
	static inline var BUF = 0x80100000;
	static inline var NAME = 0x80140000;

	static var ctx:CpuState;
	static var kept:shim.RawBuf;

	public static function main():Void {
		ctx = new CpuState();
		Runtime.boot(ctx);
		ctx.sr = 0x401;
		MemoryCard.insert("SCUS94570", "", false);
		kept = RawMem.alloc(MemoryCard.MAX);
		call(0xB0, 0x4A, 0, 0, 0);
		call(0xB0, 0x4B, 0, 0, 0);
		call(0xA0, 0x70, 0, 0, 0);

		Conf.expect("A: one block", create("BASCUS-00001AAAA", 1, 0xA1), 3);
		Conf.expect("the card holds one block", blocks(), 1);
		Conf.expect("B: two blocks", create("BASCUS-00001BBBB", 2, 0xB2), 3);
		Conf.expect("three", blocks(), 3);
		Conf.expect("C: one block", create("BASCUS-00001CCCC", 1, 0xC3), 3);
		Conf.expect("four", blocks(), 4);
		Conf.expect("B took blocks 2 and 3", MemoryCard.read8(2, 0), MemoryCard.FIRST);
		Conf.expect("B's second block is its last", MemoryCard.read8(3, 0), MemoryCard.LAST);

		Conf.expect("erase A", erase("BASCUS-00001AAAA"), 1);
		Conf.expect("three again: a deleted block is not kept", blocks(), 3);
		Conf.expect("erase C", erase("BASCUS-00001CCCC"), 1);
		Conf.expect("two", blocks(), 2);

		// D needs three blocks: the holes A and C left, then the first never used.
		Conf.expect("D: three blocks", create("BASCUS-00001DDDD", 3, 0xD4), 3);
		Conf.expect("five", blocks(), 5);
		Conf.expect("D starts in block 1", MemoryCard.read8(1, 0), MemoryCard.FIRST);
		Conf.expect("its next is block 4", RawMem.get16(MemoryCard.image(), (1 << 7) + 8), 3);
		Conf.expect("block 4 is its middle", MemoryCard.read8(4, 0), MemoryCard.MIDDLE);
		Conf.expect("whose next is block 5", RawMem.get16(MemoryCard.image(), (4 << 7) + 8), 4);
		Conf.expect("block 5 is its last", MemoryCard.read8(5, 0), MemoryCard.LAST);
		Conf.expect("and ends the chain", RawMem.get16(MemoryCard.image(), (5 << 7) + 8), 0xFFFF);
		Conf.expect("mask: blocks 1 to 5", RawMem.get16(kept, 6), 0x3E);

		// A restart: the card back from its format, the directory read again.
		final before = Hash.region(Hash.FNV_OFFSET, MemoryCard.image(), 0, MemoryCard.BYTES);
		restart();
		Conf.expect("the same card after a restart",
			Hash.region(Hash.FNV_OFFSET, MemoryCard.image(), 0, MemoryCard.BYTES), before);
		Conf.expect("D reads back whole, across its chain", verify("BASCUS-00001DDDD", 3, 0xD4), 1);
		Conf.expect("B too", verify("BASCUS-00001BBBB", 2, 0xB2), 1);

		// B goes; D stays where it is, in blocks 1, 4 and 5.
		Conf.expect("erase B", erase("BASCUS-00001BBBB"), 1);
		Conf.expect("three: the card format shrank", blocks(), 3);
		Conf.expect("mask: blocks 1, 4 and 5", RawMem.get16(kept, 6), 0x32);
		restart();
		Conf.expect("B's blocks came back free", MemoryCard.read8(2, 0), MemoryCard.FREE);
		Conf.expect("D still whole", verify("BASCUS-00001DDDD", 3, 0xD4), 1);

		Conf.expect("erase D", erase("BASCUS-00001DDDD"), 1);
		Conf.expect("nothing left to keep", blocks(), 0);
		Conf.expect("the header alone", MemoryCard.toFormat(MemoryCard.image(), kept), MemoryCard.HEADER);
		Conf.feed(Kernel.vblankCount);
		Conf.report("CardChains");
	}

	/** A file of `n` blocks, written whole with its pattern; the descriptor it had. */
	static function create(name:String, n:Int, seed:Int):Int {
		final fd = call(0xA0, 0x00, text("bu00:" + name), (n << 16) | 0x0202, 0);
		fill(n, seed);
		Conf.expect(name + ": written", call(0xA0, 0x03, fd, BUF, n * MemoryCard.BLOCK), n * MemoryCard.BLOCK);
		call(0xA0, 0x04, fd, 0, 0);
		return fd;
	}

	/** Whether the file reads back as `create` wrote it. */
	static function verify(name:String, n:Int, seed:Int):Int {
		final fd = call(0xA0, 0x00, text("bu00:" + name), 0x0001, 0);
		for (i in 0...(n * MemoryCard.BLOCK)) Memory.write8(BUF + i, 0);
		final got = call(0xA0, 0x02, fd, BUF, n * MemoryCard.BLOCK);
		call(0xA0, 0x04, fd, 0, 0);
		var bad = got == n * MemoryCard.BLOCK ? 0 : 1;
		for (i in 0...(n * MemoryCard.BLOCK)) {
			if (Memory.read8u(BUF + i) != byteOf(seed, i)) bad++;
			else {}
		}
		Conf.feed(bad);
		return bad == 0 ? 1 : 0;
	}

	static function erase(name:String):Int return call(0xB0, 0x45, text("bu00:" + name), 0, 0);

	/** The blocks the card format keeps now. */
	static function blocks():Int {
		final n = MemoryCard.toFormat(MemoryCard.image(), kept);
		Conf.feed(RawMem.get32(kept, 8));
		return RawMem.get8(kept, 5) + (n == MemoryCard.HEADER + RawMem.get8(kept, 5) * MemoryCard.RECORD ? 0 : 100);
	}

	/** The card rebuilt from its format onto a blank image, and `_bu_init` reading it again. */
	static function restart():Void {
		final n = MemoryCard.toFormat(MemoryCard.image(), kept);
		for (i in 0...MemoryCard.BYTES) RawMem.set8(MemoryCard.image(), i, 0x77);
		Conf.expect("it reads back", MemoryCard.fromFormat(MemoryCard.image(), kept, n) ? 1 : 0, 1);
		call(0xA0, 0x70, 0, 0, 0);
	}

	static function fill(n:Int, seed:Int):Void {
		for (i in 0...(n * MemoryCard.BLOCK)) Memory.write8(BUF + i, byteOf(seed, i));
	}

	/** A pattern that differs per file, per block and per byte. */
	static inline function byteOf(seed:Int, i:Int):Int return (seed + (i >> 13) * 29 + i * 7) & 0xFF;

	static function text(s:String):Int {
		for (i in 0...s.length) {
			final ch = s.charCodeAt(i);
			Memory.write8(NAME + i, ch == null ? 0 : ch);
		}
		Memory.write8(NAME + s.length, 0);
		return NAME;
	}

	static function call(vector:Int, fn:Int, a:Int, b:Int, c:Int):Int {
		ctx.a0 = a;
		ctx.a1 = b;
		ctx.a2 = c;
		Kernel.call(ctx, vector, fn);
		Conf.feed(ctx.v0);
		return ctx.v0;
	}
}
