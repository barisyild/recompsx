import core.CpuState;
import core.Runtime;
import dma.Dma;
import mem.Memory;

/**
	The DMA2 list walk over ordering tables, and the uploads a list carries: what any faster walk
	must leave exactly as the node-at-a-time one does (two were tried, ADR-0032).

	Tables cleared by DMA6 (linked downwards) and built as ClearOTag builds them (upwards), their
	first entry at each position in a cache line, long and short; fills hung on entries at either
	end and the middle of a line, two on one entry, on the first entry walked and on the
	terminator; a link that skips entries and one through the RAM mirror at 2 MB; a table ending
	at RAM's first word and one running off its top into it; the longest tables, with nodes enough
	to finish the walk exactly at its guard and one past it; and tables looped back on themselves,
	which the walk gives up on after 65536 nodes — at a point the fills drawn by then record
	exactly. Then uploads the channel carries: across list nodes, under each mask setting, and in
	a block that runs off the top of RAM. The digest was taken with the node-at-a-time walk and
	the word-at-a-time upload; it must not move.
**/
class OtWalk {
	static var seed = 0x13579BDF;

	static function next(bound:Int):Int {
		seed = (shim.IntMath.mul(seed, 1664525) + 1013904223) | 0;
		return shim.IntMath.mod(seed >>> 8, bound);
	}

	static inline var TABLES = 0x80100000;    // ordering tables, in the upper half of RAM
	static inline var PRIMS = 0x80080000;     // the fills hung on them, 16 bytes each
	static var prims = 0;

	public static function main():Void {
		Conf.feedName("OtWalk");
		final ctx = new CpuState();
		Runtime.boot(ctx);
		reg(0x1F8010F0, 0x08888888);          // DPCR: every channel enabled
		gp0(0xE3000000);                      // drawing area: all of VRAM
		gp0(0xE4000000 | (1023 | (511 << 10)));

		// Empty tables, the top word at each of a line's eight positions, short and long.
		for (k in 0...8) {
			final top = TABLES + 0x1000 + (k << 2);
			table(top, 3 + next(40));
			walk(top);
			table(top, 200 + next(600));
			walk(top);
		}

		// Fills at random entries, on the first entry walked, on the terminator, two on one.
		for (k in 0...8) {
			final top = TABLES + 0x8000 + (k << 2);
			final n = 256 + next(512);
			table(top, n);
			for (j in 0...24) hang(top - (next(n) << 2));
			hang(top);
			hang(top - ((n - 1) << 2));
			hang(top - 4);
			hang(top - 4);
			walk(top);
		}

		// Fills on the top word, a middle word and the bottom word of lines (the table's top word
		// is the top of a line, so entry m is a line's top when m % 8 == 0, its bottom at 7).
		{
			final top = TABLES + 0x20000 - 4;
			final n = 1024;
			for (m in [0, 7, 8, 15, 16, 20, 31, 63, 64, 100, 101, 255, 256, 1022, 1023]) {
				table(top, n);
				hang(top - (m << 2));
				walk(top);
			}
			table(top, n);
			for (m in [8, 9, 10, 11, 12, 13, 14, 15, 40, 47, 48, 88]) hang(top - (m << 2));
			walk(top);
		}

		// A link that skips 25 entries, a fill on one of those (never drawn), and a link through
		// the RAM mirror at 2 MB.
		{
			final top = TABLES + 0x30000 + 0x1C;
			table(top, 400);
			hang(top - 60);
			poke(top - 40, (top - 140) & 0xFFFFFF);
			hang(top - 400);
			poke(top - 800, ((top - 804) & 0x1FFFFF) | 0x200000);
			hang(top - 1200);
			walk(top);
		}

		// A table ending at RAM's first word, with a fill low in it and one on the terminator.
		table(0x80000000 + (69 << 2), 70);
		hang(0x80000000 + (3 << 2));
		hang(0x80000000);
		walk(0x80000000 + (69 << 2));

		// The longest table (BCR 0: 65536 entries). Empty, the walk's guard ends at 65535; one
		// fill makes it 65536, still a finished walk; two make it 65537 at the terminator, and
		// the walk gives up there — and with the second fill on the terminator itself, gives up
		// before drawing it.
		{
			final top = TABLES + 0x3FFFC;
			final bottom = TABLES;
			table(top, 0);
			walk(top);
			table(top, 0);
			hang(TABLES + 0x20000);
			walk(top);
			table(top, 0);
			hang(TABLES + 0x20000);
			hang(TABLES + 0x10004);
			walk(top);
			table(top, 0);
			hang(TABLES + 0x20000);
			hang(bottom);
			walk(top);
		}

		// Tables looped back on themselves — the terminator links to the top — with a fill or two
		// in the loop: the walk gives up after 65536 nodes, and the fills drawn by then say where.
		for (n in [5, 8, 9, 16, 100, 257, 1000, 4099]) {
			final top = TABLES + 0x50000 + ((n & 7) << 2);
			table(top, n);
			poke(top - ((n - 1) << 2), top & 0xFFFFFF);
			hang(top - (next(n) << 2));
			if (n > 50) hang(top - (next(n) << 2));
			else {}
			walk(top);
		}

		// Tables linked upwards, as ClearOTag builds them, walked from their lowest entry: the
		// first entry at each of a line's eight positions, fills at random, on the first entry and
		// on the terminator.
		for (k in 0...8) {
			final base = TABLES + 0x60000 + (k << 2);
			final n = 100 + next(700);
			upTable(base, n);
			walk(base);
			upTable(base, n);
			for (j in 0...6) hang(base + (next(n) << 2));
			hang(base);
			hang(base + ((n - 1) << 2));
			walk(base);
		}

		// Fills on the bottom word, a middle word and the top word of lines of an upward table.
		{
			final base = TABLES + 0x70000;
			final n = 512;
			for (m in [0, 1, 7, 8, 9, 15, 16, 24, 255, 510, 511]) {
				upTable(base, n);
				hang(base + (m << 2));
				walk(base);
			}
		}

		// An upward table running off the top of RAM: the link out of its last word is 0x200000,
		// which the walk takes as address 0, where the table goes on.
		{
			final hi = 0x801FFF00;
			for (i in 0...64) poke(hi + (i << 2), (hi + ((i + 1) << 2)) & 0xFFFFFF);
			for (i in 0...32) poke(0x80000000 + (i << 2), (i + 1) << 2);
			poke(0x80000000 + (32 << 2), 0x00FFFFFF);
			hang(hi + (40 << 2));
			hang(0x80000000 + (5 << 2));
			walk(hi);
		}

		// Upward tables looped back on themselves, and the longest one: empty, then with two fills,
		// which take the walk past its guard at the terminator.
		for (n in [7, 8, 17, 300, 2049]) {
			final base = TABLES + 0x78000 + ((n & 7) << 2);
			upTable(base, n);
			poke(base + ((n - 1) << 2), base & 0xFFFFFF);
			hang(base + (next(n) << 2));
			walk(base);
		}
		{
			final base = TABLES + 0x80000;
			upTable(base, 0x10000);
			walk(base);
			upTable(base, 0x10000);
			hang(base + 0x100);
			hang(base + 0x3FFF0);
			walk(base);
		}

		// Uploads the channel carries: in a list, the command in one node and its words across the
		// next two, ending mid-node before a fill — plain and under each mask setting, which the
		// row path leaves to the word path; and a block running off the top of RAM into its first
		// word, as the channel's address wraps.
		for (mask in 0...4) {
			gp0(0xE6000000 | mask);
			listUpload(mask);
		}
		gp0(0xE6000000);
		{
			final x = 700;
			final y = 400;
			final w = 30;
			final h = 6;
			final words = (w * h + 1) >> 1;
			gp0(0xA0000000);
			gp0(x | (y << 16));
			gp0(w | (h << 16));
			for (i in 0...words) poke(0x801FFF00 + (i << 2), word());
			block(0x801FFF00, words);
			Conf.feed(Dma.read(0x1F8010A0));
		}

		Conf.feed(prims);
		feedVram();
		Conf.report("OtWalk");
	}

	// ---- tables, fills, walks ----------------------------------------------------------------------

	/** DMA6: `n` entries from `top` down, each linking to the one below, the last ending it. */
	static function table(top:Int, n:Int):Void {
		reg(0x1F8010E0, top & 0xFFFFFF);
		reg(0x1F8010E4, n);
		reg(0x1F8010E8, 0x11000002);
	}

	/** `n` entries from `base` up, each linking to the one above, the last ending the table:
	    ClearOTag's order, which a game walks from its lowest entry. */
	static function upTable(base:Int, n:Int):Void {
		for (i in 0...n - 1) poke(base + (i << 2), (base + ((i + 1) << 2)) & 0xFFFFFF);
		poke(base + ((n - 1) << 2), 0x00FFFFFF);
	}

	/** A fill hung on the entry at `entry` as libgpu's addPrim does: the fill links to what the
	    entry linked to, and the entry to the fill. */
	static function hang(entry:Int):Void {
		final p = PRIMS + (prims << 4);
		prims++;
		final old = Memory.read32(entry);
		Memory.write32(p, (3 << 24) | (old & 0xFFFFFF));
		Memory.write32(p + 4, 0x02000000 | next(0x1000000));
		Memory.write32(p + 8, (next(512) << 16) | next(1024));
		Memory.write32(p + 12, ((1 + next(8)) << 16) | (1 + next(48)));
		Memory.write32(entry, (old & 0xFF000000) | (p & 0xFFFFFF));
	}

	/** A three-node list: GP0(A0h) with its corner and size; half the upload's words; the rest,
	    then a fill in the same node. */
	static function listUpload(k:Int):Void {
		final x = 64 + (k << 7);
		final y = 300 + k;
		final w = 21;
		final h = 5;
		final words = (w * h + 1) >> 1;
		final first = words >> 1;
		final rest = words - first;
		final n0 = PRIMS + 0x8000 + (k << 12);
		final n1 = n0 + 0x100;
		final n2 = n0 + 0x400;
		poke(n0, (3 << 24) | (n1 & 0xFFFFFF));
		poke(n0 + 4, 0xA0000000);
		poke(n0 + 8, x | (y << 16));
		poke(n0 + 12, w | (h << 16));
		poke(n1, (first << 24) | (n2 & 0xFFFFFF));
		for (i in 0...first) poke(n1 + 4 + (i << 2), word());
		poke(n2, ((rest + 3) << 24) | 0xFFFFFF);
		for (i in 0...rest) poke(n2 + 4 + (i << 2), word());
		poke(n2 + 4 + (rest << 2), 0x02000000 | next(0x1000000));
		poke(n2 + 8 + (rest << 2), ((y + 10) << 16) | x);
		poke(n2 + 12 + (rest << 2), (4 << 16) | 32);
		walk(n0);
	}

	/** DMA2 in slice mode: `words` words from `addr`, one-word blocks. */
	static function block(addr:Int, words:Int):Void {
		reg(0x1F8010A0, addr & 0xFFFFFF);
		reg(0x1F8010A4, 1 | (words << 16));
		reg(0x1F8010A8, 0x01000201);          // RAM to device, slice, start
	}

	/** Two halfwords, some with bit 15 set, some zero. */
	static function word():Int {
		return half() | (half() << 16);
	}

	static function half():Int {
		final r = next(10);
		return r == 0 ? 0 : (r < 3 ? next(0x8000) | 0x8000 : next(0x8000));
	}

	/** DMA2 in list mode from `top`, and what it left: lists finished, words sent, MADR, pixels. */
	static function walk(top:Int):Void {
		reg(0x1F8010A0, top & 0xFFFFFF);
		reg(0x1F8010A4, 0);
		reg(0x1F8010A8, 0x01000401);          // RAM to device, linked list, start
		Conf.feed(Dma.listsWalked);
		Conf.feed(Dma.wordsToGpu);
		Conf.feed(Dma.read(0x1F8010A0));
		Conf.feed(gpu.Gpu.pixels);
	}

	static inline function poke(a:Int, v:Int):Void {
		Memory.write32(a, v);
	}

	static inline function gp0(v:Int):Void {
		gpu.Gpu.writeGp0(v);
	}

	static inline function reg(p:Int, v:Int):Void {
		Dma.write(p, v);
	}

	static function feedVram():Void {
		for (y in 0...512) {
			var row = 0;
			for (x in 0...1024) row = (shim.IntMath.mul(row, 31) + gpu.Vram.get(x, y)) | 0;
			Conf.feed(row);
		}
	}
}
