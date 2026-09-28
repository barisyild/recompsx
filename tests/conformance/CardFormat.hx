import core.CpuState;
import core.Hash;
import core.Runtime;
import shim.RawBuf;
import shim.RawMem;
import sio.MemoryCard;

/**
	The memory card's two shapes (sio.MemoryCard): a card as the BIOS formats it — every frame of
	block 0 and its checksum, per psx-spx "Memory Card Data Format" and OpenBIOS `buFormat` — and
	recompsx's card format (ADR-0037), which keeps a header and the blocks in use and nothing else:
	its size as blocks come and go, a round trip back to the same 128 KB, and the damaged or foreign
	input it must refuse.
**/
class CardFormat {
	public static function main():Void {
		final ctx = new CpuState();
		Runtime.boot(ctx);
		final c = RawMem.alloc(MemoryCard.BYTES);
		MemoryCard.format(c);

		Conf.expect("frame 0: M", RawMem.get8(c, 0), 0x4D);
		Conf.expect("frame 0: C", RawMem.get8(c, 1), 0x43);
		Conf.expect("frame 0's checksum: 4Dh xor 43h", RawMem.get8(c, 0x7F), 0x0E);
		Conf.expect("entry 1: free", RawMem.get32(c, 0x80), 0xA0);
		Conf.expect("entry 1: no next block", RawMem.get16(c, 0x88), 0xFFFF);
		Conf.expect("entry 1's checksum: A0h", RawMem.get8(c, 0xFF), 0xA0);
		Conf.expect("entry 15: free", RawMem.get8(c, 15 << 7), 0xA0);
		Conf.expect("broken list: none", RawMem.get32(c, 16 << 7), -1);
		Conf.expect("broken list: FFFFh at 08h, as the BIOS leaves it", RawMem.get16(c, (16 << 7) + 8), 0xFFFF);
		Conf.expect("broken list's checksum", RawMem.get8(c, (35 << 7) + 0x7F), 0x00);
		Conf.expect("the unused frames are FFh", RawMem.get8(c, (40 << 7) + 5), 0xFF);
		Conf.expect("frame 62 too", RawMem.get8(c, (62 << 7) + 0x7F), 0xFF);
		Conf.expect("frame 63 is frame 0's copy", RawMem.get32(c, 63 << 7), RawMem.get32(c, 0));
		Conf.expect("and its checksum", RawMem.get8(c, (63 << 7) + 0x7F), 0x0E);
		Conf.expect("file blocks are zero", RawMem.get32(c, 0x2000 + 0x100), 0);
		Conf.feed(Hash.region(Hash.FNV_OFFSET, c, 0, MemoryCard.BLOCK));
		Conf.feed(Hash.region(Hash.FNV_OFFSET, c, 0, MemoryCard.BYTES));

		// A blank card keeps nothing but its header.
		final out = RawMem.alloc(MemoryCard.MAX);
		Conf.expect("a blank card: the header alone", MemoryCard.toFormat(c, out), MemoryCard.HEADER);
		Conf.expect("magic RXMC", RawMem.get32(out, 0), 0x434D5852);
		Conf.expect("version 1", RawMem.get8(out, 4), 1);
		Conf.expect("no blocks", RawMem.get8(out, 5), 0);
		Conf.expect("an empty mask", RawMem.get16(out, 6), 0);
		Conf.feed(RawMem.get32(out, 8));

		// A one-block save in block 1 and a two-block one in blocks 3 and 4; block 2 free.
		entry(c, 1, MemoryCard.FIRST, 0x2000, 0xFFFF, "BASCUS-94570CRASH");
		entry(c, 3, MemoryCard.FIRST, 0x4000, 3, "BASCUS-94244WARP");
		entry(c, 4, MemoryCard.LAST, 0, 0xFFFF, "");
		for (i in 0...MemoryCard.BLOCK) {
			RawMem.set8(c, 1 * MemoryCard.BLOCK + i, i & 0xFF);
			RawMem.set8(c, 3 * MemoryCard.BLOCK + i, (i * 7) & 0xFF);
			RawMem.set8(c, 4 * MemoryCard.BLOCK + i, (i >> 5) & 0xFF);
			RawMem.set8(c, 2 * MemoryCard.BLOCK + i, 0x5A);   // a free block's bytes are not kept
		}
		final n = MemoryCard.toFormat(c, out);
		Conf.expect("three blocks kept", n, MemoryCard.HEADER + 3 * MemoryCard.RECORD);
		Conf.expect("N = 3", RawMem.get8(out, 5), 3);
		Conf.expect("mask: blocks 1, 3, 4", RawMem.get16(out, 6), (1 << 1) | (1 << 3) | (1 << 4));
		Conf.expect("record 1 starts with block 1's entry", RawMem.get8(out, 16), MemoryCard.FIRST);
		Conf.expect("then block 1's bytes", RawMem.get8(out, 16 + 0x80 + 0x41), 0x41);
		Conf.expect("record 3 is block 4's entry", RawMem.get8(out, 16 + 2 * MemoryCard.RECORD), MemoryCard.LAST);
		Conf.feed(RawMem.get32(out, 8));
		Conf.feed(Hash.region(Hash.FNV_OFFSET, out, 0, n));

		// Back onto another card: the same 128 KB, but for the free block's bytes, which a blank
		// card has as zero.
		final d = RawMem.alloc(MemoryCard.BYTES);
		for (i in 0...MemoryCard.BYTES) RawMem.set8(d, i, 0xEE);
		Conf.expect("it reads back", MemoryCard.fromFormat(d, out, n) ? 1 : 0, 1);
		for (i in 0...MemoryCard.BLOCK) RawMem.set8(c, 2 * MemoryCard.BLOCK + i, 0);
		Conf.expect("the same card", same(c, d), 1);

		// What is not one, and leaves the card as it was.
		for (i in 0...MemoryCard.BYTES) RawMem.set8(d, i, 0xEE);
		RawMem.set8(out, 16 + 0x80 + 9, RawMem.get8(out, 16 + 0x80 + 9) ^ 1);
		Conf.expect("a flipped bit is refused", MemoryCard.fromFormat(d, out, n) ? 1 : 0, 0);
		Conf.expect("and the card is untouched", RawMem.get8(d, 0), 0xEE);
		RawMem.set8(out, 16 + 0x80 + 9, RawMem.get8(out, 16 + 0x80 + 9) ^ 1);
		Conf.expect("a short one is refused", MemoryCard.fromFormat(d, out, n - 1) ? 1 : 0, 0);
		RawMem.set8(out, 4, 2);
		Conf.expect("another version is refused", MemoryCard.fromFormat(d, out, n) ? 1 : 0, 0);
		RawMem.set8(out, 4, 1);
		Conf.expect("the original still reads", MemoryCard.fromFormat(d, out, n) ? 1 : 0, 1);

		// A deleted file is not kept: its blocks come back free.
		entry(c, 1, 0xA1, 0x2000, 0xFFFF, "BASCUS-94570CRASH");
		final m = MemoryCard.toFormat(c, out);
		Conf.expect("two blocks now", m, MemoryCard.HEADER + 2 * MemoryCard.RECORD);
		Conf.expect("mask: blocks 3 and 4", RawMem.get16(out, 6), (1 << 3) | (1 << 4));
		MemoryCard.fromFormat(d, out, m);
		Conf.expect("block 1 comes back free", RawMem.get8(d, 0x80), 0xA0);
		Conf.expect("with a free entry's checksum", RawMem.get8(d, 0xFF), 0xA0);
		Conf.expect("block 3 is still the save", RawMem.get8(d, 3 << 7), MemoryCard.FIRST);

		// The card in slot 1: headless, it keeps nothing and is never written back.
		MemoryCard.insert("SCUS94570", "Crash Bash", false);
		Conf.expect("slot 1 has a card", MemoryCard.isPresent(0) ? 1 : 0, 1);
		Conf.expect("slot 2 has none", MemoryCard.isPresent(1) ? 1 : 0, 0);
		Conf.expect("FLAG: new card", MemoryCard.flagByte(), 0x08);
		final frame = RawMem.alloc(MemoryCard.FRAME);
		MemoryCard.readFrame(0, frame, 0);
		Conf.expect("reading leaves FLAG alone", MemoryCard.flagByte(), 0x08);
		MemoryCard.writeFrame(0x3F, frame, 0);
		Conf.expect("a write clears FLAG.3", MemoryCard.flagByte(), 0x00);
		for (_ in 0...40) MemoryCard.tick();
		Conf.expect("nothing went to the backend", MemoryCard.saves, 0);

		Conf.report("CardFormat");
	}

	/** A directory entry, sealed: state, size, next (block - 1, or FFFFh) and name. */
	static function entry(c:RawBuf, block:Int, state:Int, size:Int, next:Int, name:String):Void {
		final f = block << 7;
		for (i in 0...MemoryCard.FRAME) RawMem.set8(c, f + i, 0);
		RawMem.set32(c, f, state);
		RawMem.set32(c, f + 4, size);
		RawMem.set16(c, f + 8, next);
		for (i in 0...name.length) {
			final ch = name.charCodeAt(i);
			RawMem.set8(c, f + 0x0A + i, ch == null ? 0 : ch);
		}
		MemoryCard.seal(c, block);
	}

	static function same(a:RawBuf, b:RawBuf):Int {
		var diff = 0;
		for (i in 0...MemoryCard.BYTES) {
			if (RawMem.get8(a, i) != RawMem.get8(b, i)) diff++;
			else {}
		}
		return diff == 0 ? 1 : 0;
	}
}
