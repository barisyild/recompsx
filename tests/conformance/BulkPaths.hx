import core.CpuState;
import core.Runtime;
import dma.Dma;
import mem.Memory;

/**
	The runtime's bulk paths against the per-pixel, per-word behaviour they replace.

	VRAM-to-VRAM copies (GP0 80h), CPU-to-VRAM uploads through the port, through DMA2 blocks and
	inside a DMA2 list, the DMA6 ordering table and DMA4 into sound RAM. Each case is one the fast
	paths must refuse or get exactly right: overlap in one row both ways (the hardware copies in
	increasing order, so a copy to the right repeats its first pixels), overlap across rows,
	wrapping at either edge of VRAM, odd widths whose last word pads, mask bits set and checked, a
	DMA block that ends a transfer and goes on as commands, sound RAM wrapping at 512 KB. The
	digest was taken with the per-pixel code before the bulk paths existed; it must not move.
**/
class BulkPaths {
	static var seed = 0x2468ACE1;

	static function next(bound:Int):Int {
		seed = (shim.IntMath.mul(seed, 1664525) + 1013904223) | 0;
		return shim.IntMath.mod(seed >>> 8, bound);
	}

	static inline var RAM = 0x80100000;       // scratch area in main RAM for DMA sources
	static inline var OT = 0x80180000;

	public static function main():Void {
		Conf.feedName("BulkPaths");
		final ctx = new CpuState();
		Runtime.boot(ctx);
		reg(0x1F8010F0, 0x08888888);          // DPCR: every channel enabled
		gp0(0xE3000000);                      // drawing area: all of VRAM
		gp0(0xE4000000 | (1023 | (511 << 10)));

		// A patterned VRAM to copy from: uploads through the port, including wrapping ones.
		upload(0, 0, 256, 64);
		upload(1000, 100, 40, 12);            // wraps at the right edge
		upload(300, 505, 31, 11);             // wraps at the bottom, odd width
		upload(513, 200, 7, 5);               // odd width, padded last word

		// Copies: rows apart, one row overlapping to the right and to the left, rows overlapping
		// downwards and upwards, wrapping source and destination, and a large one.
		copy(0, 0, 400, 10, 64, 20);
		copy(10, 3, 13, 3, 50, 1);            // same row, destination right of source
		copy(40, 5, 31, 5, 50, 1);            // same row, destination left of source
		copy(0, 10, 0, 12, 120, 30);          // overlapping rows, downwards
		copy(0, 40, 2, 37, 120, 30);          // overlapping rows, upwards, shifted right
		copy(1010, 100, 20, 300, 30, 8);      // source wraps at the right edge
		copy(100, 300, 1015, 310, 20, 6);     // destination wraps at the right edge
		copy(5, 500, 600, 505, 16, 20);       // source and destination wrap at the bottom
		copy(0, 0, 0, 0, 1024, 512);          // everything onto itself
		for (i in 0...40) copy(next(1024), next(512), next(1024), next(512), 1 + next(80), 1 + next(24));

		// The same kinds of copy under each mask setting: the fast paths must stand aside.
		gp0(0xE6000001);
		copy(0, 0, 500, 60, 33, 9);
		gp0(0xE6000002);
		copy(0, 0, 500, 64, 33, 9);
		gp0(0xE6000003);
		upload(520, 70, 9, 3);
		gp0(0xE6000000);

		// DMA2 block uploads: whole, started through the port and finished by DMA, ending early
		// and running on into a fill command.
		dmaUpload(700, 20, 64, 16, 0);
		dmaUpload(777, 40, 13, 9, 0);
		dmaUploadPartial(820, 60, 21, 7, 11);
		dmaUploadThenFill(900, 80, 10, 4);
		dmaUpload(1016, 120, 16, 6, 0);       // wraps at the right edge
		dmaUpload(100, 508, 24, 8, 0);        // wraps at the bottom

		// An upload inside a DMA2 list.
		listUpload(40, 450, 12, 5);

		// DMA6: ordering tables of several lengths, one of them ending near the bottom of RAM.
		otc(OT + 0x1000, 1024);
		otc(OT + 0x3004, 17);
		otc(0x80000040, 20);                  // runs below address 0 of RAM
		Conf.feed(Dma.tablesCleared);

		// DMA4 into sound RAM, straight and wrapping at its end.
		spuDma(0x1000, 256);
		spuDma(0x7FFE0, 64);                  // wraps at 512 KB

		feedVram();
		Conf.feed(gpu.Gpu.pixels);
		Conf.feed(gpu.Gpu.uploaded);
		Conf.feed(Dma.wordsToGpu);
		Conf.feed(Dma.wordsToSpu);
		Conf.feed(spu.Spu.written);
		for (i in 0...(0x4000 >> 2)) Conf.feed(Memory.read32(OT + (i << 2)));
		for (i in 0...64) Conf.feed(Memory.read32(0x80000000 + (i << 2)));
		for (i in 0...(0x800 >> 1)) Conf.feed(shim.RawMem.get16(spu.Spu.ram, 0x1000 + (i << 1)));
		for (i in 0...16) Conf.feed(shim.RawMem.get16(spu.Spu.ram, 0x7FFE0 + (i << 1)));
		for (i in 0...64) Conf.feed(shim.RawMem.get16(spu.Spu.ram, i << 1));
		Conf.report("BulkPaths");
	}

	// ---- GP0 through the port ----------------------------------------------------------------------

	static function upload(x:Int, y:Int, w:Int, h:Int):Void {
		gp0(0xA0000000);
		gp0(x | (y << 16));
		gp0(w | (h << 16));
		for (i in 0...(w * h + 1) >> 1) gp0(word());
	}

	static function copy(sx:Int, sy:Int, dx:Int, dy:Int, w:Int, h:Int):Void {
		gp0(0x80000000);
		gp0(sx | (sy << 16));
		gp0(dx | (dy << 16));
		gp0(w | (h << 16));
	}

	// ---- DMA2 --------------------------------------------------------------------------------------

	/** An upload whose header goes through the port and whose `skip` first words do too; DMA
	    carries the rest in one block. */
	static function dmaUpload(x:Int, y:Int, w:Int, h:Int, skip:Int):Void {
		final words = (w * h + 1) >> 1;
		gp0(0xA0000000);
		gp0(x | (y << 16));
		gp0(w | (h << 16));
		for (i in 0...skip) gp0(word());
		fillRam(RAM, words - skip);
		block(RAM, words - skip);
	}

	static function dmaUploadPartial(x:Int, y:Int, w:Int, h:Int, skip:Int):Void {
		dmaUpload(x, y, w, h, skip);
	}

	/** One block holding the rest of an upload and then a fill command: the words after the
	    transfer are commands again. */
	static function dmaUploadThenFill(x:Int, y:Int, w:Int, h:Int):Void {
		final words = (w * h + 1) >> 1;
		gp0(0xA0000000);
		gp0(x | (y << 16));
		gp0(w | (h << 16));
		fillRam(RAM, words);
		Memory.write32(RAM + (words << 2), 0x02123456);
		Memory.write32(RAM + ((words + 1) << 2), (x + 16) | (y << 16));
		Memory.write32(RAM + ((words + 2) << 2), 16 | (4 << 16));
		block(RAM, words + 3);
	}

	static function block(addr:Int, words:Int):Void {
		reg(0x1F8010A0, addr & 0xFFFFFF);
		reg(0x1F8010A4, 1 | (words << 16));          // slice: blocks of one word
		reg(0x1F8010A8, 0x01000201);                  // RAM to device, slice, start
	}

	/** A DMA2 list of one node: an upload header and its data. */
	static function listUpload(x:Int, y:Int, w:Int, h:Int):Void {
		final words = (w * h + 1) >> 1;
		final node = RAM + 0x8000;
		Memory.write32(node, ((3 + words) << 24) | 0xFFFFFF);
		Memory.write32(node + 4, 0xA0000000);
		Memory.write32(node + 8, x | (y << 16));
		Memory.write32(node + 12, w | (h << 16));
		for (i in 0...words) Memory.write32(node + 16 + (i << 2), word());
		reg(0x1F8010A0, node & 0xFFFFFF);
		reg(0x1F8010A4, 0);
		reg(0x1F8010A8, 0x01000401);                  // RAM to device, linked list, start
	}

	// ---- DMA6, DMA4 --------------------------------------------------------------------------------

	static function otc(top:Int, n:Int):Void {
		reg(0x1F8010E0, top & 0xFFFFFF);
		reg(0x1F8010E4, n);
		reg(0x1F8010E8, 0x11000002);
	}

	static function spuDma(spuAddr:Int, words:Int):Void {
		fillRam(RAM + 0x10000, words);
		Memory.write16(0x1F801DA6, spuAddr >>> 3);
		reg(0x1F8010C0, (RAM + 0x10000) & 0xFFFFFF);
		reg(0x1F8010C4, 16 | ((words >> 4) << 16));  // slice: blocks of sixteen words
		reg(0x1F8010C8, 0x01000201);
	}

	// ---- helpers -----------------------------------------------------------------------------------

	static function fillRam(at:Int, words:Int):Void {
		for (i in 0...words) Memory.write32(at + (i << 2), word());
	}

	/** Two halfwords, some with bit 15 set, some zero. */
	static function word():Int {
		return half() | (half() << 16);
	}

	static function half():Int {
		final r = next(10);
		return r == 0 ? 0 : (r < 3 ? next(0x8000) | 0x8000 : next(0x8000));
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
