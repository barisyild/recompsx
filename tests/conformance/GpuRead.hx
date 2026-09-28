import core.CpuState;
import core.Runtime;
import dma.Dma;
import mem.Memory;

/**
	GP0(C0h), VRAM read back to the CPU (psx-spx, "VRAM to CPU blit"), against a reference laid
	out from the same pattern: two pixels a word, the first in the low halfword, left to right
	and top to bottom, and a zero beside the last pixel when there is an odd number of them.

	Through GPUREAD word by word, and through channel 2 in block mode as libgpu's StoreImage
	reads it: rectangles of odd and even widths and pixel counts, one wrapping VRAM's right and
	bottom edges, the zero sizes that mean all of VRAM, one uploaded with GP0(A0h) and read
	straight back. GPUSTAT bit 27 is set exactly while pixels remain; after them the port keeps
	the last word, which a channel asking for more than the rectangle then receives. The channel
	also runs backwards through RAM, and GP1(00h) gives a read up.
**/
class GpuRead {
	static inline var GP0 = 0x1F801810;
	static inline var GP1 = 0x1F801814;
	static inline var BUF = 0x80100000;

	public static function main():Void {
		Conf.feedName("GpuRead");
		final ctx = new CpuState();
		Runtime.boot(ctx);
		Dma.write(0x1F8010F0, 0x08888888);    // DPCR: every channel enabled
		for (y in 0...512) for (x in 0...1024) gpu.Vram.set(x, y, pattern(x, y));

		Conf.expect("idle: bit 27 clear", ready(), 0);
		port(10, 20, 4, 2);
		port(3, 7, 5, 3);                     // 15 pixels: the last word carries one
		port(1, 1, 1, 1);
		port(1020, 510, 8, 4);                // wraps right and bottom
		port(0, 0, 0, 0);                     // all of VRAM
		port(700, 300, 0x401, 0x201);         // sizes past the limit: one by one

		// A read the channel carries into RAM: 16 x 16 in eight blocks of sixteen words.
		channel(100, 200, 16, 16, 16, 8, false);
		// 5 x 3 is eight words, asked for as ten: the last two repeat the eighth.
		channel(40, 50, 5, 3, 10, 1, false);
		// Backwards through RAM, the first word at the top.
		channel(512, 256, 8, 2, 8, 1, true);

		// An upload, read straight back through the port.
		command(0xA0000000, 600 | (400 << 16), 6 | (2 << 16));
		for (i in 0...6) Memory.write32(GP0, 0x7C1F0000 | (i * 0x111) | ((i * 0x222) << 16));
		command(0xC0000000, 600 | (400 << 16), 6 | (2 << 16));
		for (i in 0...6) Conf.expect("uploaded, read back", Memory.read32(GP0), 0x7C1F0000 | (i * 0x111) | ((i * 0x222) << 16));
		Conf.expect("done: bit 27 clear", ready(), 0);

		// GP1(00h) gives a read up, and empties the port.
		command(0xC0000000, 0, 4 | (4 << 16));
		Conf.expect("armed", ready(), 1);
		Memory.write32(GP1, 0x00000000);
		Conf.expect("reset: bit 27 clear", ready(), 0);
		Conf.expect("reset: the port reads zero", Memory.read32(GP0), 0);
		// GP1(10h) still answers when nothing is being read: 7 is the GPU's version.
		Memory.write32(GP1, 0x10000007);
		Conf.expect("GP1(10h) version", Memory.read32(GP0), 2);
		Conf.report("GpuRead");
	}

	/** Every pixel its own value, bit 15 included. */
	static inline function pattern(x:Int, y:Int):Int return ((x * 7 + y * 1031) ^ (y << 5)) & 0xFFFF;

	static function command(op:Int, xy:Int, size:Int):Void {
		Memory.write32(GP0, op);
		Memory.write32(GP0, xy);
		Memory.write32(GP0, size);
	}

	static function ready():Int return (Memory.read32(GP1) >>> 27) & 1;

	/** The rectangle through GPUREAD, a word at a time, bit 27 checked before each and after. */
	static function port(x0:Int, y0:Int, w:Int, h:Int):Void {
		command(0xC0000000, x0 | (y0 << 16), w | (h << 16));
		final wide = ((w - 1) & 0x3FF) + 1;
		final high = ((h - 1) & 0x1FF) + 1;
		var half = -1;
		var last = 0;
		var ok = 1;
		for (r in 0...high) for (c in 0...wide) {
			final p = pattern((x0 + c) & 1023, (y0 + r) & 511);
			if (half < 0) half = p;
			else {
				last = half | (p << 16);
				if (ready() != 1 || Memory.read32(GP0) != last) ok = 0;
				else {}
				half = -1;
			}
		}
		if (half >= 0) {
			last = half;
			if (ready() != 1 || Memory.read32(GP0) != last) ok = 0;
			else {}
		} else {}
		Conf.expect("port " + x0 + "," + y0 + " " + w + "x" + h, ok, 1);
		Conf.expect("then bit 27 clears", ready(), 0);
		Conf.expect("and the port keeps the last word", Memory.read32(GP0), last);
	}

	/** The rectangle through channel 2, `size` words a block, `blocks` of them, into BUF. */
	static function channel(x0:Int, y0:Int, w:Int, h:Int, size:Int, blocks:Int, backwards:Bool):Void {
		command(0xC0000000, x0 | (y0 << 16), w | (h << 16));
		Memory.write32(GP1, 0x04000003);      // DMA direction: GPUREAD to the CPU
		final words = size * blocks;
		final start = backwards ? BUF + ((words - 1) << 2) : BUF;
		for (i in 0...words) Memory.write32(BUF + (i << 2), 0x55555555);
		Dma.write(0x1F8010A0, start & 0xFFFFFF);
		Dma.write(0x1F8010A4, size | (blocks << 16));
		Dma.write(0x1F8010A8, backwards ? 0x01000202 : 0x01000200);
		Conf.expect("channel finished", Dma.read(0x1F8010A8) & 0x01000000, 0);
		Conf.expect("MADR past the last word",
			Dma.read(0x1F8010A0), (backwards ? start - (words << 2) : start + (words << 2)) & 0xFFFFFF);
		var half = -1;
		var k = 0;
		var last = 0;
		var ok = 1;
		for (r in 0...h) for (c in 0...w) {
			final p = pattern((x0 + c) & 1023, (y0 + r) & 511);
			if (half < 0) half = p;
			else {
				last = half | (p << 16);
				if (Memory.read32(at(start, k, backwards)) != last) ok = 0;
				else {}
				k++;
				half = -1;
			}
		}
		if (half >= 0) {
			last = half;
			if (Memory.read32(at(start, k, backwards)) != last) ok = 0;
			else {}
			k++;
		} else {}
		// Words asked for past the rectangle: the port's latch, the last word again.
		while (k < words) {
			if (Memory.read32(at(start, k, backwards)) != last) ok = 0;
			else {}
			k++;
		}
		Conf.expect("channel " + x0 + "," + y0 + " " + w + "x" + h, ok, 1);
		Conf.expect("then bit 27 clears", ready(), 0);
		Memory.write32(GP1, 0x04000000);
	}

	static inline function at(start:Int, k:Int, backwards:Bool):Int
		return backwards ? start - (k << 2) : start + (k << 2);
}
